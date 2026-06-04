import Foundation

/// Discovers Claude Code sessions on remote servers by fetching `.cstatus` files over SSH.
///
/// Uses `Foundation.Process` to run `ssh` commands, following the same pattern as
/// `PluginInstaller.runCLI`. Each host is polled independently and in parallel.
nonisolated struct RemoteSessionDiscovery {

    /// Result of fetching sessions from a single remote host.
    struct RemoteResult {
        let host: RemoteHostConfig
        let sessions: [ClaudeSession]
        let error: String?
    }

    /// Staleness threshold: sessions with timestamps older than this are dropped.
    /// Generous enough to accommodate clock skew between machines.
    private static let stalenessThreshold: TimeInterval = 60

    /// Timeout for a single SSH command.
    private static let sshTimeout: TimeInterval = 10

    /// Delimiter used to separate `.cstatus` file contents in SSH output.
    private static let delimiter = "<<<CSTATUS:"
    private static let delimiterEnd = ">>>"

    // MARK: - Public API

    /// Fetches sessions from all enabled hosts in parallel.
    /// Calls `completion` on the main queue with results for each host.
    func fetchAll(hosts: [RemoteHostConfig], completion: @escaping ([RemoteResult]) -> Void) {
        let enabledHosts = hosts.filter { $0.isEnabled }
        guard !enabledHosts.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }

        let queue = DispatchQueue(label: "com.poisonpenllc.Claude-Status.remote-discovery", attributes: .concurrent)
        let group = DispatchGroup()
        var results: [RemoteResult] = []
        let lock = NSLock()

        for host in enabledHosts {
            group.enter()
            queue.async {
                let result = self.fetchSingle(host: host)
                lock.lock()
                results.append(result)
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(results)
        }
    }

    // MARK: - Single Host Fetch

    /// Fetches sessions from a single remote host via SSH.
    func fetchSingle(host: RemoteHostConfig) -> RemoteResult {
        let command = buildSSHCommand(host: host)
        let (stdout, stderr, exitCode) = runSSH(command)

        if exitCode != 0 {
            let error = stderr.isEmpty ? "SSH exited with code \(exitCode)" : stderr
            return RemoteResult(host: host, sessions: [], error: error)
        }

        let sessions = parseSSHOutput(stdout, hostLabel: host.label)
        return RemoteResult(host: host, sessions: sessions, error: nil)
    }

    // MARK: - SSH Command Construction

    /// Builds the SSH command array for `Foundation.Process`.
    private func buildSSHCommand(host: RemoteHostConfig) -> [String] {
        var args = ["/usr/bin/ssh"]

        // SSH options
        args += ["-o", "ConnectTimeout=5"]
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        args += ["-o", "BatchMode=yes"]
        args += ["-o", "NumberOfPasswordPrompts=0"]

        // Key file
        if !host.sshKeyPath.isEmpty {
            args += ["-i", host.sshKeyPath]
        }

        // Port
        if host.port != 22 {
            args += ["-p", String(host.port)]
        }

        // Remote command: find all .cstatus files and output them with delimiters
        let remotePath = host.remotePath.isEmpty ? "~/.claude/projects" : host.remotePath
        let remoteCmd = """
        find \(remotePath) -name '*.cstatus' -print0 2>/dev/null | \
          xargs -0 -I{} sh -c 'echo "\(Self.delimiter){}\(Self.delimiterEnd)"; cat "{}"'
        """

        // Target
        let target: String
        if host.username.isEmpty {
            target = host.hostname
        } else {
            target = "\(host.username)@\(host.hostname)"
        }

        args += [target, remoteCmd]
        return args
    }

    // MARK: - SSH Execution

    /// Runs an SSH command and returns (stdout, stderr, exitCode).
    /// Follows the PluginInstaller.runCLI pattern with async pipe reading and timeout.
    private func runSSH(_ command: [String]) -> (String, String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        let pipeQueue = DispatchQueue(label: "com.poisonpenllc.Claude-Status.remote-pipeIO")
        var stderrData = Data()
        var stdoutData = Data()

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            pipeQueue.sync { stderrData.append(chunk) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            pipeQueue.sync { stdoutData.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return ("", error.localizedDescription, -1)
        }

        // Timeout
        let deadline = DispatchTime.now() + .seconds(Int(Self.sshTimeout))
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return ("", "SSH command timed out after \(Int(Self.sshTimeout)) seconds", -1)
        }

        // Drain remaining data and clean up handlers
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        pipeQueue.sync {
            stderrData.append(remainingStderr)
            stdoutData.append(remainingStdout)
        }

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = (String(data: stderrData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (stdout, stderr, process.terminationStatus)
    }

    // MARK: - Output Parsing

    /// Parses SSH output containing delimited `.cstatus` file contents.
    /// Returns assembled sessions, skipping stale or unparseable entries.
    func parseSSHOutput(_ output: String, hostLabel: String) -> [ClaudeSession] {
        guard !output.isEmpty else { return [] }

        let now = Date()
        var sessions: [ClaudeSession] = []

        // Split by delimiter pattern: <<<CSTATUS:/path/to/file>>>
        let components = output.components(separatedBy: Self.delimiter)
        for component in components {
            // Each component is: "/path/to/file>>>\n{json content}"
            guard let endRange = component.range(of: Self.delimiterEnd) else { continue }

            let jsonStart = component.index(endRange.upperBound, offsetBy: 0)
            let jsonSubstring = component[jsonStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !jsonSubstring.isEmpty else { continue }

            guard let jsonData = jsonSubstring.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            // Use a dummy fileURL since we don't have the actual remote path
            let dummyURL = URL(fileURLWithPath: "/remote/\(hostLabel)")
            guard let record = CStatusRecord.parse(json: json, fileURL: dummyURL) else {
                continue
            }

            // Staleness check: skip sessions with old timestamps
            let age = now.timeIntervalSince(record.timestamp)
            if age > Self.stalenessThreshold {
                continue
            }

            let projectName = (record.cwd as NSString).lastPathComponent
            let session = ClaudeSession(
                sessionId: record.sessionId,
                pid: record.pid,
                workingDirectory: record.cwd,
                projectName: projectName,
                state: record.state,
                lastActivityAt: record.timestamp,
                iTermSessionId: nil,
                tmuxPaneId: nil,
                tmuxSocket: nil,
                source: .terminal(app: "Terminal"),
                activity: record.activity,
                sessionName: record.sessionName,
                remoteHost: hostLabel
            )
            sessions.append(session)
        }

        return sessions
    }
}
