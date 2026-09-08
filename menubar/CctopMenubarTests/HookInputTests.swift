import XCTest
@testable import CctopMenubar

final class HookInputTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixturesDirectory().appendingPathComponent("\(name).json"))
    }

    private func fixturesDirectory() -> URL {
        let projectDir = ProcessInfo.processInfo.environment["PROJECT_DIR"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // CctopMenubarTests/
                .deletingLastPathComponent()  // menubar/
                .deletingLastPathComponent()  // repo root
                .path
        return URL(fileURLWithPath: projectDir).appendingPathComponent("fixtures")
    }

    // MARK: - SessionStart

    func testDecodeSessionStart() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SessionStart"))
        XCTAssertEqual(input.sessionId, "test-session-001")
        XCTAssertEqual(input.cwd, "/tmp/test-project")
        XCTAssertEqual(input.hookEventName, "SessionStart")
        XCTAssertEqual(input.transcriptPath, "/tmp/transcript.jsonl")
        XCTAssertFalse(input.transcriptPathWasExplicitlyNull)
    }

    func testTranscriptPathFieldPresenceDistinguishesNullFromMissing() throws {
        let explicitNull = try JSONDecoder().decode(HookInput.self, from: Data("""
        {"session_id":"null-path","cwd":"/tmp","hook_event_name":"SessionStart","transcript_path":null}
        """.utf8))
        XCTAssertTrue(explicitNull.transcriptPathWasExplicitlyNull)

        let missing = try JSONDecoder().decode(HookInput.self, from: Data("""
        {"session_id":"missing-path","cwd":"/tmp","hook_event_name":"SessionStart"}
        """.utf8))
        XCTAssertFalse(missing.transcriptPathWasExplicitlyNull)
    }

    // MARK: - UserPromptSubmit

    func testDecodeUserPromptSubmit() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("UserPromptSubmit"))
        XCTAssertEqual(input.hookEventName, "UserPromptSubmit")
        XCTAssertEqual(input.prompt, "Fix the login bug")
    }

    // MARK: - Stop

    func testDecodeStop() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("Stop"))
        XCTAssertEqual(input.hookEventName, "Stop")
    }

    // MARK: - PreToolUse

    func testDecodePreToolUse() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PreToolUse"))
        XCTAssertEqual(input.hookEventName, "PreToolUse")
        XCTAssertEqual(input.toolName, "Bash")
        XCTAssertEqual(input.toolInput?["command"], "npm test")
    }

    // MARK: - PostToolUse

    func testDecodePostToolUse() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PostToolUse"))
        XCTAssertEqual(input.hookEventName, "PostToolUse")
        XCTAssertEqual(input.toolName, "Bash")
    }

    // MARK: - PostToolUseFailure

    func testDecodePostToolUseFailure() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PostToolUseFailure"))
        XCTAssertEqual(input.hookEventName, "PostToolUseFailure")
        XCTAssertEqual(input.error, "Command exited with code 1")
    }

    // MARK: - PermissionRequest

    func testDecodePermissionRequest() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PermissionRequest"))
        XCTAssertEqual(input.hookEventName, "PermissionRequest")
        XCTAssertEqual(input.toolName, "Bash")
        XCTAssertEqual(input.title, "Allow Bash: rm -rf /tmp/old")
        XCTAssertEqual(input.toolInput?["command"], "rm -rf /tmp/old")
    }

    // MARK: - Notification (idle)

    func testDecodeNotificationIdle() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("Notification-idle"))
        XCTAssertEqual(input.hookEventName, "Notification")
        XCTAssertEqual(input.notificationType, "idle_prompt")
        XCTAssertEqual(input.message, "Claude is waiting for input")
    }

    // MARK: - Notification (permission)

    func testDecodeNotificationPermission() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("Notification-permission"))
        XCTAssertEqual(input.hookEventName, "Notification")
        XCTAssertEqual(input.notificationType, "permission_prompt")
        XCTAssertEqual(input.message, "Permission needed for Bash")
    }

    func testDecodeOpencodeQuestionPermissionRequest() throws {
        let input = try JSONDecoder().decode(
            HookInput.self,
            from: loadFixture("PermissionRequest-opencode-question")
        )
        XCTAssertEqual(input.hookEventName, "PermissionRequest")
        XCTAssertEqual(input.title, "Which direction should I take?")
        XCTAssertEqual(input.harnessName, "opencode")
        XCTAssertEqual(input.source, "opencode")
        XCTAssertEqual(input.resolvedHarnessName, "opencode")
    }

    // MARK: - SubagentStart

    func testDecodeSubagentStart() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SubagentStart"))
        XCTAssertEqual(input.hookEventName, "SubagentStart")
        XCTAssertEqual(input.agentId, "agent-abc-123")
        XCTAssertEqual(input.agentType, "general-purpose")
    }

    // MARK: - SubagentStop

    func testDecodeSubagentStop() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SubagentStop"))
        XCTAssertEqual(input.hookEventName, "SubagentStop")
        XCTAssertEqual(input.agentId, "agent-abc-123")
        XCTAssertEqual(input.agentType, "general-purpose")
    }

    // MARK: - PreCompact

    func testDecodePreCompact() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PreCompact"))
        XCTAssertEqual(input.hookEventName, "PreCompact")
    }

    // MARK: - PostCompact

    func testDecodePostCompact() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PostCompact"))
        XCTAssertEqual(input.hookEventName, "PostCompact")
    }

    // MARK: - SessionError

    func testDecodeSessionError() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SessionError"))
        XCTAssertEqual(input.hookEventName, "SessionError")
        XCTAssertEqual(input.error, "Context window exceeded")
        XCTAssertEqual(input.message, "Session encountered an error")
    }

    // MARK: - SessionStart (opencode)

    func testDecodeSessionStartOpencode() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SessionStart-opencode"))
        XCTAssertEqual(input.sessionId, "opencode-12345")
        XCTAssertEqual(input.hookEventName, "SessionStart")
        XCTAssertEqual(input.source, "opencode")
        XCTAssertEqual(input.harnessName, "opencode")
        XCTAssertEqual(input.sessionName, "Fix login bug")
    }

    // MARK: - SessionEnd

    func testDecodeSessionEnd() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SessionEnd"))
        XCTAssertEqual(input.hookEventName, "SessionEnd")
    }

    // MARK: - Unknown fields are ignored

    func testUnknownFieldsIgnored() throws {
        let json = """
        {
          "session_id": "test",
          "cwd": "/tmp",
          "hook_event_name": "SessionStart",
          "model": "gpt-5.1-codex",
          "unknown_future_field": true
        }
        """
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        XCTAssertEqual(input.sessionId, "test")
    }

    // MARK: - Fixture coverage

    func testAllFixturesDecode() throws {
        let fixtureURLs = try FileManager.default.contentsOfDirectory(
            at: fixturesDirectory(),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }

        XCTAssertFalse(fixtureURLs.isEmpty)

        for url in fixtureURLs {
            XCTAssertNoThrow(
                try JSONDecoder().decode(HookInput.self, from: Data(contentsOf: url)),
                "Fixture \(url.lastPathComponent) should decode"
            )
        }
    }

    // MARK: - resolvedHarnessName

    func testHarnessNamePrefersHarnessNameField() throws {
        let input = try JSONDecoder().decode(
            HookInput.self, from: loadFixture("SessionStart-opencode")
        )
        XCTAssertEqual(input.harnessName, "opencode")
        XCTAssertEqual(input.source, "opencode")
        XCTAssertEqual(input.resolvedHarnessName, "opencode")
    }

    func testHarnessNameFallsBackToSourceForLegacyPlugins() throws {
        let json = """
        {"session_id":"test","cwd":"/tmp","hook_event_name":"SessionStart","source":"opencode"}
        """
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        XCTAssertNil(input.harnessName)
        XCTAssertEqual(input.resolvedHarnessName, "opencode")
    }

    func testHarnessNameIgnoresCodexTriggerKind() throws {
        let input = try JSONDecoder().decode(
            HookInput.self, from: loadFixture("codex-SessionStart")
        )
        XCTAssertEqual(input.source, "startup")
        XCTAssertNil(input.resolvedHarnessName, "'startup' is not a harness name")
        XCTAssertEqual(input.codexSessionStartKind, "startup")
    }

    func testHarnessNameSetViaCLIArg() throws {
        // Codex path: shim passes --harness codex, HookMain sets input.harnessName
        // before calling handleHook. We simulate that by setting harnessName directly.
        var input = try JSONDecoder().decode(
            HookInput.self, from: loadFixture("codex-SessionStart")
        )
        XCTAssertNil(input.harnessName)
        input.harnessName = "codex"
        XCTAssertEqual(input.resolvedHarnessName, "codex")
    }

    func testHarnessNameRejectsUnknownSourceValue() throws {
        let json = """
        {"session_id":"test","cwd":"/tmp","hook_event_name":"SessionStart","source":"../../etc/passwd"}
        """
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        XCTAssertNil(input.resolvedHarnessName, "non-allowlisted source must be rejected")
    }

    func testClaudeChildMarkerIsDelegatedOnlyForCodex() throws {
        let legacyCodex = try JSONDecoder().decode(HookInput.self, from: Data("""
        {"session_id":"codex-child","cwd":"/tmp","hook_event_name":"SessionStart","source":"codex"}
        """.utf8))
        XCTAssertTrue(legacyCodex.hasDelegatedSessionEvidence(environment: [
            "CLAUDE_CODE_CHILD_SESSION": ""
        ]))
        XCTAssertFalse(legacyCodex.hasDelegatedSessionEvidence(environment: [:]))

        let claude = try JSONDecoder().decode(HookInput.self, from: Data("""
        {"session_id":"claude","cwd":"/tmp","hook_event_name":"SessionStart","harness_name":"cc"}
        """.utf8))
        XCTAssertFalse(claude.hasDelegatedSessionEvidence(environment: [
            "CLAUDE_CODE_CHILD_SESSION": ""
        ]))
    }

    private func hookInput(harness: String, isSubagent: Bool = false) throws -> HookInput {
        let subagentField = isSubagent ? ",\"is_subagent\":true" : ""
        return try JSONDecoder().decode(HookInput.self, from: Data("""
        {"session_id":"s","cwd":"/tmp","hook_event_name":"SessionStart","harness_name":"\(harness)"\(subagentField)}
        """.utf8))
    }

    func testCodexDelegateCarriesItsClaudeParentWhenTheSessionIdIsExported() throws {
        let codex = try hookInput(harness: "codex")

        XCTAssertEqual(
            codex.delegatedSessionEvidence(environment: [
                "CLAUDE_CODE_CHILD_SESSION": "",
                "CLAUDE_CODE_SESSION_ID": "parent-uuid"
            ]),
            HookInput.DelegatedSessionEvidence(
                parentHarness: SessionData.ccSource, parentHarnessSessionId: "parent-uuid"
            )
        )
        // Marker alone still delegates; it just cannot name a parent.
        XCTAssertEqual(
            codex.delegatedSessionEvidence(environment: ["CLAUDE_CODE_CHILD_SESSION": ""]),
            .unattributed
        )
        XCTAssertEqual(
            codex.delegatedSessionEvidence(environment: [
                "CLAUDE_CODE_CHILD_SESSION": "", "CLAUDE_CODE_SESSION_ID": ""
            ]),
            .unattributed
        )
    }

    func testClaudeHookInheritingCodexThreadIdIsDelegatedToThatThread() throws {
        let claude = try hookInput(harness: "cc")

        XCTAssertEqual(
            claude.delegatedSessionEvidence(environment: [
                "CODEX_THREAD_ID": "thread-uuid", "CODEX_SANDBOX": "seatbelt"
            ]),
            HookInput.DelegatedSessionEvidence(
                parentHarness: SessionData.codexSource, parentHarnessSessionId: "thread-uuid"
            )
        )
        XCTAssertNil(claude.delegatedSessionEvidence(environment: ["CODEX_THREAD_ID": ""]))
        XCTAssertNil(claude.delegatedSessionEvidence(environment: [:]))
    }

    /// Claude exports CLAUDE_CODE_SESSION_ID for its own children, so for a `cc` hook it is
    /// the session's own reference — never parent evidence.
    func testClaudeOwnSessionIdIsNotParentEvidenceForAClaudeHook() throws {
        let claude = try hookInput(harness: "cc")
        XCTAssertNil(claude.delegatedSessionEvidence(environment: [
            "CLAUDE_CODE_CHILD_SESSION": "", "CLAUDE_CODE_SESSION_ID": "s"
        ]))
    }

    func testCodexThreadIdDoesNotDelegateACodexHookToItself() throws {
        let codex = try hookInput(harness: "codex")
        XCTAssertNil(codex.delegatedSessionEvidence(environment: ["CODEX_THREAD_ID": "s"]))
    }

    /// Same-harness delegation has no native marker, so the delegate wrappers export an
    /// explicit pair. It is a fallback: the native rules stay exact when they fire.
    func testExplicitParentPairDelegatesSameHarnessChildren() throws {
        let claude = try hookInput(harness: "cc")
        XCTAssertEqual(
            claude.delegatedSessionEvidence(environment: [
                "CLAUDE_CODE_CHILD_SESSION": "", "CLAUDE_CODE_SESSION_ID": "s",
                "CCTOP_PARENT_HARNESS": "cc", "CCTOP_PARENT_SESSION_ID": "parent-uuid"
            ]),
            HookInput.DelegatedSessionEvidence(
                parentHarness: SessionData.ccSource, parentHarnessSessionId: "parent-uuid"
            )
        )
        let codex = try hookInput(harness: "codex")
        XCTAssertEqual(
            codex.delegatedSessionEvidence(environment: [
                "CODEX_THREAD_ID": "s",
                "CCTOP_PARENT_HARNESS": "codex", "CCTOP_PARENT_SESSION_ID": "thread-parent"
            ]),
            HookInput.DelegatedSessionEvidence(
                parentHarness: SessionData.codexSource, parentHarnessSessionId: "thread-parent"
            )
        )
    }

    func testExplicitParentPairIsIgnoredWhenIncompleteUnknownOrSelf() throws {
        let claude = try hookInput(harness: "cc")
        XCTAssertNil(claude.delegatedSessionEvidence(environment: ["CCTOP_PARENT_HARNESS": "cc"]))
        XCTAssertNil(claude.delegatedSessionEvidence(environment: ["CCTOP_PARENT_SESSION_ID": "p"]))
        XCTAssertNil(claude.delegatedSessionEvidence(environment: [
            "CCTOP_PARENT_HARNESS": "", "CCTOP_PARENT_SESSION_ID": "p"
        ]))
        XCTAssertNil(claude.delegatedSessionEvidence(environment: [
            "CCTOP_PARENT_HARNESS": "../etc", "CCTOP_PARENT_SESSION_ID": "p"
        ]))
        // A stale pair naming the session itself (inherited from its own launcher) is not a parent.
        XCTAssertNil(claude.delegatedSessionEvidence(environment: [
            "CCTOP_PARENT_HARNESS": "cc", "CCTOP_PARENT_SESSION_ID": "s"
        ]))
    }

    /// The native cross-harness rule is exact and outranks an inherited explicit pair.
    func testNativeRuleOutranksExplicitParentPair() throws {
        let claude = try hookInput(harness: "cc")
        XCTAssertEqual(
            claude.delegatedSessionEvidence(environment: [
                "CODEX_THREAD_ID": "thread-uuid",
                "CCTOP_PARENT_HARNESS": "cc", "CCTOP_PARENT_SESSION_ID": "grandparent"
            ]),
            HookInput.DelegatedSessionEvidence(
                parentHarness: SessionData.codexSource, parentHarnessSessionId: "thread-uuid"
            )
        )
    }

    /// The login is read from the harness's own home variable, or an explicit override.
    func testAccountEvidenceIsScopedToTheHarnessOwnHome() throws {
        let claude = try hookInput(harness: "cc")
        XCTAssertEqual(
            claude.accountEvidence(environment: ["CLAUDE_CONFIG_DIR": "/Users/j/.claude-ent"]), "klick"
        )
        XCTAssertNil(claude.accountEvidence(environment: ["CLAUDE_CONFIG_DIR": "/Users/j/.claude"]))
        // A Klick Claude session exports CODEX_HOME for its children; that is not its own login.
        XCTAssertNil(claude.accountEvidence(environment: ["CODEX_HOME": "/Users/j/.codex-klick"]))
        XCTAssertNil(claude.accountEvidence(environment: [:]))

        let codex = try hookInput(harness: "codex")
        XCTAssertEqual(codex.accountEvidence(environment: ["CODEX_HOME": "/Users/j/.codex-klick"]), "klick")
        XCTAssertNil(codex.accountEvidence(environment: ["CODEX_HOME": "/Users/j/.codex"]))
        XCTAssertNil(codex.accountEvidence(environment: ["CLAUDE_CONFIG_DIR": "/Users/j/.claude-ent"]))
    }

    func testExplicitAccountOverrideIsSanitized() throws {
        let claude = try hookInput(harness: "cc")
        XCTAssertEqual(claude.accountEvidence(environment: ["CCTOP_ACCOUNT": "Klick"]), "klick")
        XCTAssertEqual(claude.accountEvidence(environment: ["CCTOP_ACCOUNT": "../acme corp!"]), "acmecorp")
        XCTAssertNil(claude.accountEvidence(environment: ["CCTOP_ACCOUNT": "  "]))
        XCTAssertNil(claude.accountEvidence(environment: ["CCTOP_ACCOUNT": "///"]))
        XCTAssertEqual(
            claude.accountEvidence(environment: [
                "CCTOP_ACCOUNT": "personal2", "CLAUDE_CONFIG_DIR": "/Users/j/.claude-ent"
            ]),
            "personal2", "explicit override wins"
        )
    }

    func testExplicitSubagentPayloadStaysDelegatedWithoutAParent() throws {
        let opencode = try hookInput(harness: "opencode", isSubagent: true)
        XCTAssertEqual(opencode.delegatedSessionEvidence(environment: [:]), .unattributed)

        // An env rule that also matches still wins and supplies the parent.
        let claude = try hookInput(harness: "cc", isSubagent: true)
        XCTAssertEqual(
            claude.delegatedSessionEvidence(environment: ["CODEX_THREAD_ID": "thread-uuid"]),
            HookInput.DelegatedSessionEvidence(
                parentHarness: SessionData.codexSource, parentHarnessSessionId: "thread-uuid"
            )
        )
    }
}
