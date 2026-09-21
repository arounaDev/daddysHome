import XCTest
@testable import DaddyCore

final class TaskContractTests: XCTestCase {

    func testTheStoppingConditionReachesTheAgentLabelled() {
        let contract = TaskContract(
            goal: "Fix the duplicate refresh request.",
            doneWhen: "The reproduction test passes and auth tests stay green.",
            doNot: "Change public auth APIs."
        )
        let clause = contract.promptClause ?? ""
        XCTAssertTrue(clause.contains("GOAL: Fix the duplicate refresh request."))
        XCTAssertTrue(clause.contains("DONE WHEN: The reproduction test passes"))
        XCTAssertTrue(clause.contains("DO NOT: Change public auth APIs."))
    }

    func testAGoalAloneIsStillWorthSending() {
        let clause = TaskContract(goal: "Rename the button.").promptClause ?? ""
        XCTAssertTrue(clause.contains("GOAL: Rename the button."))
        XCTAssertFalse(clause.contains("DONE WHEN"))
        XCTAssertFalse(clause.contains("DO NOT"))
    }

    func testAnEmptyContractSendsNothing() {
        XCTAssertNil(TaskContract(goal: "   ", doneWhen: "", doNot: nil).promptClause)
        XCTAssertTrue(TaskContract(goal: "\n").isEmpty)
    }
}

final class VerificationTests: XCTestCase {

    func testPassedIsReachableOnlyThroughAnExitCode() {
        var v = Verification(profile: .targeted)
        XCTAssertFalse(v.isVerified)
        XCTAssertEqual(v.displayName, "Unverified")

        v.record(exitCode: 0, command: "swift test", summary: "12/12")
        XCTAssertTrue(v.isVerified)
        XCTAssertEqual(v.displayName, "Verified")
        XCTAssertEqual(v.summary, "12/12")
        XCTAssertNotNil(v.checkedAt)
    }

    func testANonZeroExitIsAFailureWhateverTheSummarySays() {
        var v = Verification(profile: .targeted)
        // The summary is the agent's account of itself and decides nothing.
        v.record(exitCode: 1, command: "swift test", summary: "all tests pass")
        XCTAssertEqual(v.outcome, .failed)
        XCTAssertFalse(v.isVerified)
    }

    func testAPassGoesStaleWhenTheTreeMoves() {
        var v = Verification(profile: .targeted)
        v.record(exitCode: 0, command: "swift build")
        v.invalidate()
        XCTAssertEqual(v.outcome, .stale)
        XCTAssertFalse(v.isVerified)
    }

    func testAFailureIsNotStaledByAnEdit() {
        // An edit is not evidence the failure is gone.
        var v = Verification(profile: .targeted)
        v.record(exitCode: 1, command: "swift build")
        v.invalidate()
        XCTAssertEqual(v.outcome, .failed)
    }

    func testRaisingTheBarStalesAPassAndLoweringItDoesNot() {
        var raised = Verification(profile: .targeted)
        raised.record(exitCode: 0, command: "swift test")
        raised.retarget(to: .broad)
        XCTAssertEqual(raised.outcome, .stale)

        var lowered = Verification(profile: .broad)
        lowered.record(exitCode: 0, command: "swift test")
        lowered.retarget(to: .targeted)
        XCTAssertEqual(lowered.outcome, .passed)
    }

    func testRunningClearsTheLastResultRatherThanLettingItStand() {
        var v = Verification(profile: .targeted)
        v.record(exitCode: 0, command: "swift test", summary: "12/12")
        v.markRunning(command: "swift test")
        XCTAssertEqual(v.outcome, .running)
        XCTAssertNil(v.summary)
        XCTAssertNil(v.checkedAt)
    }

    func testItSurvivesARoundTripThroughTheStateFile() throws {
        var v = Verification(profile: .broad)
        v.record(exitCode: 0, command: "swift test", summary: "164 tests")

        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(Verification.self, from: data)
        XCTAssertEqual(back, v)
        XCTAssertTrue(back.isVerified)
    }

    func testAStateFileWrittenBeforeTheseExistedStillLoads() throws {
        // Every saved session predates these two keys. Decoding them with
        // `decode` rather than `decodeIfPresent` would fail the whole workflow
        // load, not just drop one session's goal.
        let json = """
        {
          "id": "s1", "projectID": "p1", "workUnitID": "w1",
          "agent": "claude", "state": {"ready": null},
          "createdAt": 0, "lastActivityAt": 0
        }
        """
        let state = try JSONDecoder().decode(
            WorkflowState.SessionState.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(state.contract)
        XCTAssertNil(state.verification)
    }
}
