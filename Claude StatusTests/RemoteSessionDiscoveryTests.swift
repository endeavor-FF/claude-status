import Foundation
import Testing
@testable import Claude_Status

struct RemoteSessionDiscoveryTests {

    // MARK: - Output Parsing Tests

    @Test func parseEmptyOutput() {
        let discovery = RemoteSessionDiscovery()
        let sessions = discovery.parseSSHOutput("", hostLabel: "test-server")
        #expect(sessions.isEmpty)
    }

    @Test func parseSingleSession() {
        let discovery = RemoteSessionDiscovery()
        let json = """
        {"session_id":"abc-123","pid":1234,"state":"active","timestamp":"2026-06-03T10:00:00Z","cwd":"/home/user/project","activity":"Edit","event":"PreToolUse"}
        """
        let output = "<<<CSTATUS:/home/user/.claude/projects/test/abc-123.cstatus>>>\n\(json)"

        let sessions = discovery.parseSSHOutput(output, hostLabel: "prod-server")
        #expect(sessions.count == 1)
        #expect(sessions[0].sessionId == "abc-123")
        #expect(sessions[0].state == .active)
        #expect(sessions[0].remoteHost == "prod-server")
        #expect(sessions[0].projectName == "project")
        #expect(sessions[0].activity == "Edit")
    }

    @Test func parseMultipleSessions() {
        let discovery = RemoteSessionDiscovery()
        let json1 = """
        {"session_id":"session-1","pid":100,"state":"active","timestamp":"2026-06-03T10:00:00Z","cwd":"/tmp/proj1","activity":"Bash","event":"PreToolUse"}
        """
        let json2 = """
        {"session_id":"session-2","pid":200,"state":"waiting","timestamp":"2026-06-03T10:00:00Z","cwd":"/tmp/proj2","activity":"","event":"PermissionRequest"}
        """
        let output = """
        <<<CSTATUS:/path/1.cstatus>>>
        \(json1)
        <<<CSTATUS:/path/2.cstatus>>>
        \(json2)
        """

        let sessions = discovery.parseSSHOutput(output, hostLabel: "server")
        #expect(sessions.count == 2)
        #expect(sessions.contains { $0.sessionId == "session-1" })
        #expect(sessions.contains { $0.sessionId == "session-2" })
    }

    @Test func parseStaleSessionDropped() {
        let discovery = RemoteSessionDiscovery()
        // Timestamp from 5 minutes ago should be dropped (staleness threshold is 60s)
        let staleTime = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300))
        let json = """
        {"session_id":"stale-1","pid":999,"state":"idle","timestamp":"\(staleTime)","cwd":"/tmp","activity":"","event":"Stop"}
        """
        let output = "<<<CSTATUS:/path/stale.cstatus>>>\n\(json)"

        let sessions = discovery.parseSSHOutput(output, hostLabel: "server")
        #expect(sessions.isEmpty)
    }

    @Test func parseMalformedJSONSkipped() {
        let discovery = RemoteSessionDiscovery()
        let output = "<<<CSTATUS:/path/bad.cstatus>>>\nnot valid json at all"

        let sessions = discovery.parseSSHOutput(output, hostLabel: "server")
        #expect(sessions.isEmpty)
    }

    @Test func parseMissingRequiredFieldsSkipped() {
        let discovery = RemoteSessionDiscovery()
        // Missing "state" field
        let json = """
        {"session_id":"incomplete","pid":123,"timestamp":"2026-06-03T10:00:00Z","cwd":"/tmp"}
        """
        let output = "<<<CSTATUS:/path/incomplete.cstatus>>>\n\(json)"

        let sessions = discovery.parseSSHOutput(output, hostLabel: "server")
        #expect(sessions.isEmpty)
    }

    @Test func parseSessionWithSessionName() {
        let discovery = RemoteSessionDiscovery()
        let json = """
        {"session_id":"named-1","pid":500,"state":"active","timestamp":"2026-06-03T10:00:00Z","cwd":"/home/user/my-project","activity":"think","event":"UserPromptSubmit","session_name":"API Refactor"}
        """
        let output = "<<<CSTATUS:/path/named.cstatus>>>\n\(json)"

        let sessions = discovery.parseSSHOutput(output, hostLabel: "server")
        #expect(sessions.count == 1)
        #expect(sessions[0].sessionName == "API Refactor")
        #expect(sessions[0].projectName == "my-project")
    }

    // MARK: - Session Assembly Tests

    @Test func remoteSessionHasNoITermFields() {
        let discovery = RemoteSessionDiscovery()
        let json = """
        {"session_id":"remote-1","pid":100,"state":"active","timestamp":"2026-06-03T10:00:00Z","cwd":"/tmp","activity":"","event":"PreToolUse"}
        """
        let output = "<<<CSTATUS:/path/remote.cstatus>>>\n\(json)"

        let sessions = discovery.parseSSHOutput(output, hostLabel: "server")
        #expect(sessions.count == 1)
        #expect(sessions[0].iTermSessionId == nil)
        #expect(sessions[0].tmuxPaneId == nil)
        #expect(sessions[0].tmuxSocket == nil)
    }

    @Test func remoteSessionSourceIsTerminal() {
        let discovery = RemoteSessionDiscovery()
        let json = """
        {"session_id":"src-1","pid":100,"state":"idle","timestamp":"2026-06-03T10:00:00Z","cwd":"/tmp","activity":"","event":"Stop"}
        """
        let output = "<<<CSTATUS:/path/src.cstatus>>>\n\(json)"

        let sessions = discovery.parseSSHOutput(output, hostLabel: "server")
        #expect(sessions.count == 1)
        #expect(sessions[0].source == .terminal(app: "Terminal"))
    }

    // MARK: - State Mapping Tests

    @Test func stateMappingActive() {
        let discovery = RemoteSessionDiscovery()
        let json = """
        {"session_id":"s1","pid":1,"state":"active","timestamp":"2026-06-03T10:00:00Z","cwd":"/tmp","activity":"","event":""}
        """
        let sessions = discovery.parseSSHOutput("<<<CSTATUS:/x>>>\n\(json)", hostLabel: "h")
        #expect(sessions.first?.state == .active)
    }

    @Test func stateMappingWaiting() {
        let discovery = RemoteSessionDiscovery()
        let json = """
        {"session_id":"s2","pid":1,"state":"waiting","timestamp":"2026-06-03T10:00:00Z","cwd":"/tmp","activity":"","event":""}
        """
        let sessions = discovery.parseSSHOutput("<<<CSTATUS:/x>>>\n\(json)", hostLabel: "h")
        #expect(sessions.first?.state == .waiting)
    }

    @Test func stateMappingCompacting() {
        let discovery = RemoteSessionDiscovery()
        let json = """
        {"session_id":"s3","pid":1,"state":"compacting","timestamp":"2026-06-03T10:00:00Z","cwd":"/tmp","activity":"","event":""}
        """
        let sessions = discovery.parseSSHOutput("<<<CSTATUS:/x>>>\n\(json)", hostLabel: "h")
        #expect(sessions.first?.state == .compacting)
    }

    @Test func stateMappingUnknownDefaultsToIdle() {
        let discovery = RemoteSessionDiscovery()
        let json = """
        {"session_id":"s4","pid":1,"state":"unknown_state","timestamp":"2026-06-03T10:00:00Z","cwd":"/tmp","activity":"","event":""}
        """
        let sessions = discovery.parseSSHOutput("<<<CSTATUS:/x>>>\n\(json)", hostLabel: "h")
        #expect(sessions.first?.state == .idle)
    }

    // MARK: - CStatusRecord Parse Tests

    @Test func cstatusRecordParseValid() {
        let json: [String: Any] = [
            "session_id": "test-id",
            "pid": 1234,
            "state": "active",
            "timestamp": "2026-06-03T10:00:00Z",
            "cwd": "/tmp/test",
            "activity": "Bash",
            "event": "PreToolUse"
        ]
        let url = URL(fileURLWithPath: "/path/to/test.cstatus")
        let record = CStatusRecord.parse(json: json, fileURL: url)

        #expect(record != nil)
        #expect(record?.sessionId == "test-id")
        #expect(record?.pid == 1234)
        #expect(record?.state == .active)
        #expect(record?.cwd == "/tmp/test")
        #expect(record?.activity == "Bash")
        #expect(record?.fileURL == url)
    }

    @Test func cstatusRecordParseMissingSessionId() {
        let json: [String: Any] = [
            "pid": 1234,
            "state": "active",
            "timestamp": "2026-06-03T10:00:00Z"
        ]
        let url = URL(fileURLWithPath: "/path/to/test.cstatus")
        let record = CStatusRecord.parse(json: json, fileURL: url)
        #expect(record == nil)
    }

    // MARK: - ClaudeSession Codable with remoteHost

    @Test func claudeSessionCodableWithRemoteHost() throws {
        let session = ClaudeSession(
            sessionId: "remote-test",
            pid: 100,
            workingDirectory: "/tmp/project",
            projectName: "project",
            state: .active,
            lastActivityAt: Date(),
            iTermSessionId: nil,
            tmuxPaneId: nil,
            tmuxSocket: nil,
            source: .terminal(app: "Terminal"),
            activity: "Edit",
            sessionName: nil,
            remoteHost: "prod-server"
        )

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ClaudeSession.self, from: encoded)

        #expect(decoded.remoteHost == "prod-server")
        #expect(decoded.sessionId == "remote-test")
    }

    @Test func claudeSessionCodableWithoutRemoteHost() throws {
        // Simulate JSON without remoteHost key (backward compatibility)
        let json = """
        {"sessionId":"local-test","pid":100,"workingDirectory":"/tmp","projectName":"tmp","state":"active","lastActivityAt":696000000,"source":{"terminal":{"app":"Terminal"}},"activity":"","sessionName":null}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ClaudeSession.self, from: data)

        #expect(decoded.remoteHost == nil)
        #expect(decoded.sessionId == "local-test")
    }
}
