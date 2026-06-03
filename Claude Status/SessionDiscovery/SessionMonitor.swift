import Foundation
import WidgetKit

/// Monitors Claude Code sessions by scanning .cstatus files and filesystem state.
///
/// Uses three complementary mechanisms for timely updates:
/// 1. **Darwin notifications** — instant push from the hook script via `notifyutil -p`
/// 2. **File system watching** — `DispatchSource` on `~/.claude/projects/`
/// 3. **Polling timer** — 5s fallback for sessions without hooks (IDE agents, etc.)
@Observable
@MainActor
final class SessionMonitor {

    private(set) var sessions: [ClaudeSession] = []
    private(set) var productivityData: ProductivityData = ProductivityData(today: .empty(), allTime: .empty())
    /// Per-host connection status for UI display.
    private(set) var hostStatuses: [UUID: HostStatus] = [:]

    /// Whether the Claude Code session-status plugin is installed.
    /// Based on `PluginDetector` checking installed_plugins.json and settings.json hooks.
    /// `true` = installed, `false` = not installed, `nil` = can't determine.
    private(set) var hookDetected: Bool?

    /// The most urgent state across all sessions, or nil if none.
    var aggregateState: SessionState? {
        sessions.map(\.state).max(by: { $0.priority < $1.priority })
    }

    /// Connection status for a remote host.
    enum HostStatus: Equatable {
        case ok
        case error(String)
        case unreachable
    }

    private var discovery: SessionDiscovery
    private let stateResolver: StateResolver
    private let pluginDetector: PluginDetector
    private let tracker: ProductivityTracker
    private let remoteDiscovery: RemoteSessionDiscovery
    nonisolated(unsafe) private var timer: Timer?
    nonisolated(unsafe) private var remoteTimer: Timer?
    private let scanInterval: TimeInterval
    private var remoteSessions: [ClaudeSession] = []
    private var isRemoteFetchInProgress = false
    private static let remotePollInterval: TimeInterval = 12.0

    /// Maps session ID → .cstatus file URL for fast notification-driven refresh.
    private var cstatusCache: [String: URL] = [:]

    /// Cached plugin detection state and when it was last checked.
    private var lastPluginCheck: Date = .distantPast
    private var cachedPluginState: PluginInstallState = .unknown
    private static let pluginCheckInterval: TimeInterval = 30

    /// Throttle widget reloads to avoid excessive writes on every 5s poll.
    private var lastWidgetUpdate: Date = .distantPast
    private static let widgetUpdateInterval: TimeInterval = 30

    /// Darwin notification name posted by the hook script.
    private static let darwinNotificationName = "com.poisonpenllc.Claude-Status.session-changed" as CFString

    init(scanInterval: TimeInterval = 5.0) {
        self.scanInterval = scanInterval
        self.discovery = SessionDiscovery()
        self.stateResolver = StateResolver()
        self.pluginDetector = PluginDetector()
        self.tracker = ProductivityTracker()
        self.remoteDiscovery = RemoteSessionDiscovery()
    }

    deinit {
        timer?.invalidate()
        remoteTimer?.invalidate()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    func start() {
        stateResolver.onProjectsChanged = { [weak self] in
            self?.refresh()
        }

        registerDarwinNotification()
        refresh()

        timer = Timer.scheduledTimer(
            withTimeInterval: scanInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }

        // Remote polling timer
        remoteTimer = Timer.scheduledTimer(
            withTimeInterval: Self.remotePollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshRemote()
        }
        // Immediate first fetch
        refreshRemote()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        remoteTimer?.invalidate()
        remoteTimer = nil
        unregisterDarwinNotification()
    }

    // MARK: - Darwin Notifications

    private func registerDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let monitor = Unmanaged<SessionMonitor>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    monitor.refreshFromNotification()
                }
            },
            Self.darwinNotificationName,
            nil,
            .deliverImmediately
        )
    }

    private func unregisterDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, nil, nil)
    }

    // MARK: - Refresh

    /// Full refresh: directory scan + PID validation.
    /// Called on timer ticks and file system changes.
    func refresh() {
        let result = discovery.discoverAll()
        applyResult(result)
    }

    /// Notification-driven refresh: always do a full scan since the notification
    /// may signal a new session that isn't in our cache yet.
    private func refreshFromNotification() {
        discovery.clearDeadSessions()
        refresh()
    }

    /// Fetches sessions from configured remote hosts via SSH.
    private func refreshRemote() {
        guard !isRemoteFetchInProgress else { return }
        let hosts = loadRemoteHosts()
        guard !hosts.isEmpty else {
            if !remoteSessions.isEmpty {
                remoteSessions = []
                hostStatuses.removeAll()
                refresh()
            }
            return
        }

        isRemoteFetchInProgress = true
        remoteDiscovery.fetchAll(hosts: hosts) { [weak self] results in
            guard let self else { return }
            self.isRemoteFetchInProgress = false

            var allRemote: [ClaudeSession] = []
            for result in results {
                self.hostStatuses[result.host.id] = result.error.map { .error($0) } ?? .ok
                allRemote.append(contentsOf: result.sessions)
            }

            let changed = self.remoteSessions != allRemote
            self.remoteSessions = allRemote
            if changed {
                self.refresh()
            }
        }
    }

    /// Loads remote host configurations from the shared App Group UserDefaults.
    private func loadRemoteHosts() -> [RemoteHostConfig] {
        let defaults = UserDefaults(suiteName: "group.com.poisonpenllc.Claude-Status")
        guard let data = defaults?.data(forKey: "remoteHosts"),
              let hosts = try? JSONDecoder().decode([RemoteHostConfig].self, from: data) else {
            return []
        }
        return hosts
    }

    /// Applies a discovery result: updates sessions, cache, and hook detection.
    /// Only writes to the shared container and reloads the widget when data changes.
    private func applyResult(_ result: SessionDiscovery.DiscoveryResult) {
        // Merge local and remote sessions
        let merged = (result.sessions + remoteSessions).sortedByStateAndActivity
        let sessionsChanged = sessions != merged
        sessions = merged
        cstatusCache = result.cstatusFiles

        // Track time-in-state for productivity scoring
        tracker.recordSnapshot(sessions: result.sessions)
        let newProductivity = tracker.currentData
        let productivityChanged = productivityData != newProductivity
        productivityData = newProductivity

        updatePluginState()

        // Session changes write immediately; productivity changes are throttled
        if sessionsChanged {
            writeToSharedContainer()
        } else if productivityChanged {
            let now = Date()
            if now.timeIntervalSince(lastWidgetUpdate) >= Self.widgetUpdateInterval {
                writeToSharedContainer()
            }
        }
    }

    /// Checks plugin installation state, caching the result to avoid
    /// reading JSON files from disk on every refresh cycle.
    private func updatePluginState() {
        let now = Date()
        if now.timeIntervalSince(lastPluginCheck) >= Self.pluginCheckInterval {
            cachedPluginState = pluginDetector.detect()
            lastPluginCheck = now
        }
        switch cachedPluginState {
        case .installed: hookDetected = true
        case .notInstalled: hookDetected = false
        case .unknown: hookDetected = nil
        }
    }

    /// Forces a fresh plugin detection check (e.g. after install/uninstall).
    func invalidatePluginCache() {
        lastPluginCheck = .distantPast
    }

    // MARK: - Shared Data

    private func writeToSharedContainer() {
        guard let sharedURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.poisonpenllc.Claude-Status"
        ) else {
            return
        }

        if let encoded = try? JSONEncoder().encode(sessions) {
            let dataURL = sharedURL.appendingPathComponent("sessions.json")
            try? encoded.write(to: dataURL, options: .atomic)
        }

        if let encoded = try? JSONEncoder().encode(productivityData) {
            let prodURL = sharedURL.appendingPathComponent("productivity.json")
            try? encoded.write(to: prodURL, options: .atomic)
        }

        lastWidgetUpdate = Date()

        WidgetCenter.shared.reloadTimelines(ofKind: "Claude_StatusWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "Claude_ProductivityWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "Claude_ScoreWidget")
    }
}
