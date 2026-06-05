import ServiceManagement
import Sparkle
import SwiftUI

/// Settings window with icon style, launch at login, plugin management, and remote servers.
struct SettingsView: View {
    var pluginState: PluginInstallState
    var updater: SPUUpdater?
    var onInstallPlugin: () -> Void
    var onUninstallPlugin: () -> Void

    @AppStorage("iconStyle", store: UserDefaults(suiteName: "group.com.poisonpenllc.Claude-Status"))
    private var iconStyle: SessionIconStyle = .emoji
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var remoteHosts: [RemoteHostConfig] = []
    @State private var editingHost: RemoteHostConfig?
    @State private var showingAddSheet = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Status Icon Style", selection: $iconStyle) {
                    ForEach(SessionIconStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
            }

            if let updater {
                Section("Updates") {
                    Toggle(isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic Updates")
                                .font(.body)
                            Text("Check for updates daily and install automatically")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    HStack {
                        Spacer()
                        Button("Check for Updates\u{2026}") {
                            updater.checkForUpdates()
                        }
                        .disabled(!updater.canCheckForUpdates)
                    }
                }
            }

            Section("Plugin") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Claude Code Plugin")
                                .font(.body)
                            statusBadge
                        }
                        Text("Reports session activity via Claude Code hooks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    pluginButtons
                }
            }

            Section("Remote Servers") {
                if remoteHosts.isEmpty {
                    HStack {
                        Text("Monitor Claude Code sessions on remote servers via SSH")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Server") {
                            showingAddSheet = true
                        }
                    }
                } else {
                    ForEach(remoteHosts) { host in
                        HStack {
                            Circle()
                                .fill(host.isEnabled ? .green : .gray)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.label.isEmpty ? host.hostname : host.label)
                                    .font(.body)
                                Text(host.hostname)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") {
                                editingHost = host
                            }
                            .buttonStyle(.borderless)
                            Button {
                                remoteHosts.removeAll { $0.id == host.id }
                                saveRemoteHosts()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Add Server") {
                            showingAddSheet = true
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loadRemoteHosts()
        }
        .sheet(isPresented: $showingAddSheet) {
            RemoteHostEditView(host: RemoteHostConfig()) { newHost in
                remoteHosts.append(newHost)
                saveRemoteHosts()
            }
        }
        .sheet(item: $editingHost) { host in
            RemoteHostEditView(host: host) { updated in
                if let index = remoteHosts.firstIndex(where: { $0.id == updated.id }) {
                    remoteHosts[index] = updated
                    saveRemoteHosts()
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch pluginState {
        case .installed:
            Text("Installed")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .notInstalled:
            Text("Not Installed")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .unknown:
            Text("Unknown")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.15))
                .foregroundStyle(.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private var pluginButtons: some View {
        switch pluginState {
        case .installed:
            HStack(spacing: 8) {
                Button("Reinstall") { onInstallPlugin() }
                Button("Uninstall") { onUninstallPlugin() }
            }
        case .notInstalled:
            Button("Install") { onInstallPlugin() }
        case .unknown:
            Button("Install") { onInstallPlugin() }
        }
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enabled
        }
    }

    // MARK: - Remote Host Persistence

    private func loadRemoteHosts() {
        let defaults = UserDefaults(suiteName: "group.com.poisonpenllc.Claude-Status")
        guard let data = defaults?.data(forKey: "remoteHosts"),
              let hosts = try? JSONDecoder().decode([RemoteHostConfig].self, from: data) else {
            return
        }
        remoteHosts = hosts
    }

    private func saveRemoteHosts() {
        let defaults = UserDefaults(suiteName: "group.com.poisonpenllc.Claude-Status")
        if let data = try? JSONEncoder().encode(remoteHosts) {
            defaults?.set(data, forKey: "remoteHosts")
        }
    }
}

// MARK: - Remote Host Edit Sheet

/// Sheet for adding or editing a remote server configuration.
private struct RemoteHostEditView: View {
    let host: RemoteHostConfig
    var onSave: (RemoteHostConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var config: RemoteHostConfig
    @State private var sshConfigHosts: [SSHConfigHost] = []
    @State private var selectedSSHHost: SSHConfigHost?

    init(host: RemoteHostConfig, onSave: @escaping (RemoteHostConfig) -> Void) {
        self.host = host
        self.onSave = onSave
        self._config = State(initialValue: host)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !sshConfigHosts.isEmpty {
                    Section("SSH Config") {
                        Picker("Import from ~/.ssh/config", selection: $selectedSSHHost) {
                            Text("None").tag(nil as SSHConfigHost?)
                            ForEach(sshConfigHosts) { sshHost in
                                Text(sshHost.alias).tag(sshHost as SSHConfigHost?)
                            }
                        }
                        .onChange(of: selectedSSHHost) { _, newValue in
                            if let ssh = newValue {
                                applySSHHost(ssh)
                            }
                        }
                    }
                }

                Section("Server") {
                    TextField("Label", text: $config.label)
                        .help("A friendly name shown in the session list")
                    HStack {
                        TextField("Hostname", text: $config.hostname)
                            .help("IP address, domain, or SSH config alias")
                        if !sshConfigHosts.isEmpty {
                            Menu {
                                ForEach(sshConfigHosts) { sshHost in
                                    Button(sshHost.alias) {
                                        applySSHHost(sshHost)
                                    }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                                    .foregroundStyle(.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("22", value: $config.port, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Username", text: $config.username)
                        .help("SSH username (leave empty if specified in SSH config)")
                }

                Section("Authentication") {
                    TextField("SSH Key Path", text: $config.sshKeyPath)
                        .help("Leave empty to use default SSH key discovery or SSH config")
                }

                Section("Options") {
                    TextField("Remote Projects Path", text: $config.remotePath)
                        .help("Path to ~/.claude/projects on the remote host")
                    Toggle("Enabled", isOn: $config.isEnabled)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(config)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(config.hostname.isEmpty)
            }
            .padding()
        }
        .frame(width: 380)
        .onAppear {
            sshConfigHosts = SSHConfigParser.parse()
        }
    }

    /// Apply values from a parsed SSH config host to the form fields.
    private func applySSHHost(_ ssh: SSHConfigHost) {
        // Use alias as label if label is empty
        if config.label.isEmpty {
            config.label = ssh.alias
        }
        // Use alias as hostname — SSH will resolve it via config
        config.hostname = ssh.alias
        if let user = ssh.user {
            config.username = user
        }
        if let port = ssh.port {
            config.port = port
        }
        if let key = ssh.identityFile {
            config.sshKeyPath = key
        }
    }
}
