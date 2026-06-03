import Foundation

/// Configuration for a remote server whose Claude Code sessions should be monitored.
struct RemoteHostConfig: Codable, Identifiable, Equatable {
    var id: UUID
    /// User-facing label shown in the UI (e.g. "prod-server").
    var label: String
    /// SSH host — IP address, domain name, or `~/.ssh/config` alias.
    var hostname: String
    /// SSH port. Default 22.
    var port: Int
    /// SSH username. Required unless the hostname is an SSH config alias that specifies User.
    var username: String
    /// Path to the SSH private key (e.g. "~/.ssh/id_ed25519").
    /// Empty string lets SSH use its default key discovery (agent, config, standard paths).
    var sshKeyPath: String
    /// Path to the Claude projects directory on the remote host. Default "~/.claude/projects".
    var remotePath: String
    /// Whether this host is actively monitored. Allows temporarily disabling without deleting.
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        label: String = "",
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        sshKeyPath: String = "",
        remotePath: String = "~/.claude/projects",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.sshKeyPath = sshKeyPath
        self.remotePath = remotePath
        self.isEnabled = isEnabled
    }
}
