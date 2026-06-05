import Foundation

/// A parsed entry from `~/.ssh/config`.
struct SSHConfigHost: Identifiable, Hashable {
    /// The `Host` alias (e.g. "linuxserver").
    let alias: String
    /// The `HostName` directive, or nil if not specified (defaults to alias).
    let hostName: String?
    /// The `User` directive, or nil if not specified.
    let user: String?
    /// The `IdentityFile` directive, or nil if not specified.
    let identityFile: String?
    /// The `Port` directive, or nil if not specified (defaults to 22).
    let port: Int?

    var id: String { alias }
}

/// Parses `~/.ssh/config` into a list of `SSHConfigHost` entries.
///
/// Handles the standard SSH config format:
/// ```
/// Host alias
///     HostName 10.0.0.1
///     User myuser
///     IdentityFile ~/.ssh/id_rsa
///     Port 2222
/// ```
///
/// Lines starting with `*` in the Host pattern are skipped (wildcard entries).
enum SSHConfigParser {
    /// Path to the user's SSH config file.
    private static var configPath: String {
        NSHomeDirectory() + "/.ssh/config"
    }

    /// Parses `~/.ssh/config` and returns all concrete `Host` entries.
    static func parse() -> [SSHConfigHost] {
        guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return []
        }

        var hosts: [SSHConfigHost] = []
        var currentAlias: String?
        var currentHostName: String?
        var currentUser: String?
        var currentIdentityFile: String?
        var currentPort: Int?

        func flush() {
            if let alias = currentAlias {
                hosts.append(SSHConfigHost(
                    alias: alias,
                    hostName: currentHostName,
                    user: currentUser,
                    identityFile: currentIdentityFile,
                    port: currentPort
                ))
            }
            currentAlias = nil
            currentHostName = nil
            currentUser = nil
            currentIdentityFile = nil
            currentPort = nil
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty lines and comments
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts[1]

            if key == "host" {
                flush()
                // Skip wildcard entries like "Host *"
                let alias = value
                if !alias.contains("*") {
                    currentAlias = alias
                }
            } else if currentAlias != nil {
                switch key {
                case "hostname":
                    currentHostName = value
                case "user":
                    currentUser = value
                case "identityfile":
                    // Expand ~ to home directory
                    currentIdentityFile = value.replacingOccurrences(
                        of: "~", with: NSHomeDirectory()
                    )
                case "port":
                    currentPort = Int(value)
                default:
                    break
                }
            }
        }

        flush()
        return hosts
    }
}
