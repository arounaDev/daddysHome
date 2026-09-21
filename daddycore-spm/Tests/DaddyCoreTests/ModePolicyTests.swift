import XCTest
@testable import DaddyCore

/// The point of these is narrow: a work mode used to change one string and
/// nothing else, so the tests that matter are the ones asserting a selected
/// mode reaches the command line.
final class ModePolicyTests: XCTestCase {

    // MARK: Claude — the CLI that can enforce the most

    func testClaudeCarriesEffortForEveryMode() {
        let adapter = ClaudeAdapter()
        XCTAssertEqual(
            adapter.policyArgs(WorkMode.targeted.policy).prefix(2).joined(separator: " "),
            "--effort low"
        )
        XCTAssertEqual(
            adapter.policyArgs(WorkMode.planAndBuild.policy).prefix(2).joined(separator: " "),
            "--effort high"
        )
        XCTAssertEqual(
            adapter.policyArgs(WorkMode.exploreAndResearch.policy).prefix(2).joined(separator: " "),
            "--effort medium"
        )
    }

    func testExploreAsksRatherThanDeniesByDefault() {
        // The default has to stay soft. Taking the editing tools away at
        // launch cannot be undone from inside the conversation, so an Explore
        // session that turns out to need a one-line fix would be stuck.
        let args = ClaudeAdapter().policyArgs(WorkMode.exploreAndResearch.policy)
        XCTAssertFalse(args.contains("--disallowedTools"), "\(args)")

        let clause = SessionPolicy(workMode: .exploreAndResearch, buildPolicy: .compile).promptClause ?? ""
        XCTAssertTrue(clause.contains("Change no files"))
        XCTAssertTrue(clause.contains("let me decide"))
    }

    func testReadOnlyIsEnforcedOnlyWhenTheSessionAsksForIt() {
        let policy = SessionPolicy(
            workMode: .exploreAndResearch,
            buildPolicy: .compile,
            enforceReadOnly: true
        )
        let args = ClaudeAdapter().policyArgs(policy.mode)
        guard let flag = args.firstIndex(of: "--disallowedTools") else {
            return XCTFail("opting in must actually deny the tools: \(args)")
        }
        // One comma-joined value, not three argv entries: the flag is variadic
        // and would otherwise swallow whatever flag follows it.
        XCTAssertEqual(args[flag + 1], "Edit,Write,NotebookEdit")
        XCTAssertFalse(args[flag + 1].contains(" "))

        XCTAssertEqual(CursorAdapter().policyArgs(policy.mode), ["--mode", "ask"])
        XCTAssertEqual(OpenCodeAdapter().policyArgs(policy.mode), ["--agent", "plan"])
    }

    func testOptingInCannotMakeAnEditingModeReadOnly() {
        // The flag is a way to harden an intent the mode already has, not a
        // second, hidden read-only switch.
        let policy = SessionPolicy(workMode: .debug, buildPolicy: .compile, enforceReadOnly: true)
        XCTAssertFalse(policy.mode.deniesEditingTools)
        XCTAssertTrue(ClaudeAdapter().policyArgs(policy.mode).isEmpty == false)
        XCTAssertFalse(ClaudeAdapter().policyArgs(policy.mode).contains("--disallowedTools"))
    }

    func testEditingModesDoNotDenyTheEditingTools() {
        for mode in [WorkMode.targeted, .planAndBuild, .debug] {
            XCTAssertFalse(
                ClaudeAdapter().policyArgs(mode.policy).contains("--disallowedTools"),
                "\(mode) edits code and must keep its editing tools"
            )
        }
    }

    func testTargetedNarrowsTheToolSurfaceAndOthersDoNot() {
        XCTAssertTrue(
            ClaudeAdapter().policyArgs(WorkMode.targeted.policy).contains("--strict-mcp-config")
        )
        XCTAssertFalse(
            ClaudeAdapter().policyArgs(WorkMode.planAndBuild.policy).contains("--strict-mcp-config")
        )
    }

    // MARK: The CLIs that can enforce less

    func testCodexCarriesEffortAsATOMLString() {
        // The quotes belong to the argument, not to a shell. Codex accepts
        // the bare word too — it validates neither key nor value — so this
        // asserts the documented spelling precisely because the CLI will not.
        XCTAssertEqual(
            CodexAdapter().policyArgs(WorkMode.debug.policy),
            ["-c", "model_reasoning_effort=\"high\""]
        )
    }

    func testCursorAndOpenCodeSayNothingUntilReadOnlyIsOptedInto() {
        XCTAssertEqual(CursorAdapter().policyArgs(WorkMode.exploreAndResearch.policy), [])
        XCTAssertEqual(CursorAdapter().policyArgs(WorkMode.debug.policy), [])

        XCTAssertEqual(OpenCodeAdapter().policyArgs(WorkMode.exploreAndResearch.policy), [])
        XCTAssertEqual(OpenCodeAdapter().policyArgs(WorkMode.debug.policy), [])
    }

    // MARK: Resolution

    func testExploreCannotVerifyEvenUnderTheLoosestBuildPolicy() {
        // Orthogonal axes, but not independent: there is nothing to build when
        // nothing may be edited.
        let policy = SessionPolicy(workMode: .exploreAndResearch, buildPolicy: .free)
        XCTAssertEqual(policy.verification, VerificationProfile.none)
    }

    func testBuildPolicyOtherwiseDecidesWhatCountsAsProof() {
        XCTAssertEqual(SessionPolicy(workMode: .debug, buildPolicy: .frozen).verification, .none)
        XCTAssertEqual(SessionPolicy(workMode: .debug, buildPolicy: .compile).verification, .targeted)
        XCTAssertEqual(SessionPolicy(workMode: .debug, buildPolicy: .run).verification, .broad)
    }

    // MARK: The half that only prose can carry

    func testTheRetryCapIsStatedWithItsNumber() {
        let clause = SessionPolicy(workMode: .debug, buildPolicy: .compile).promptClause ?? ""
        XCTAssertTrue(
            clause.contains("at most 2 attempts"),
            "the cap must reach the agent as its number, not as a vibe: \(clause)"
        )
    }

    func testTargetedForbidsDelegationAndPlanAndBuildRequiresAPlan() {
        let targeted = SessionPolicy(workMode: .targeted, buildPolicy: .compile).promptClause ?? ""
        XCTAssertTrue(targeted.contains("no subagents"))
        XCTAssertFalse(targeted.contains("Agree a plan"))

        let plan = SessionPolicy(workMode: .planAndBuild, buildPolicy: .compile).promptClause ?? ""
        XCTAssertTrue(plan.contains("Agree a plan"))
        XCTAssertFalse(plan.contains("no subagents"))
        // maxRepairLoops 4 is not a tight budget, so it should not be spent on.
        XCTAssertFalse(plan.contains("Retry budget"))
    }

    func testEverySessionIsToldWhatDoneMeans() {
        for mode in WorkMode.allCases {
            for build in BuildPolicy.allCases {
                let clause = SessionPolicy(workMode: mode, buildPolicy: build).promptClause
                XCTAssertNotNil(clause, "\(mode)/\(build) said nothing about verification")
            }
        }
    }
}
