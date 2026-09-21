import Foundation

/// What a session is for, when it is finished, and what it must not touch.
///
/// A session used to carry a mode, a policy and a working directory, and no
/// statement of the job. Everything about the objective lived in whatever was
/// typed into the composer — which means it is gone after a compaction, it was
/// never available to the card, and nothing could check the work against it
/// afterwards.
///
/// The expensive omission is `doneWhen`. Without a stopping condition an agent
/// keeps going: one more refactor, one more file that could be tidied, one
/// more test that might as well be written. `doNot` is the other half — the
/// cheapest way to say "fix the bug, leave the public API alone" once, rather
/// than three times in repair turns after it has already been changed.
public struct TaskContract: Codable, Sendable, Equatable {

    /// The job, in the human's own words.
    public var goal: String

    /// The objective condition that ends the work.
    ///
    /// Deliberately free text rather than a structured check. The useful
    /// version of this is "the reproduction test passes and the auth suite
    /// stays green", and no enum was going to hold that.
    public var doneWhen: String?

    /// What is out of scope, when that is not obvious from the goal.
    public var doNot: String?

    public init(goal: String, doneWhen: String? = nil, doNot: String? = nil) {
        self.goal = goal
        self.doneWhen = doneWhen
        self.doNot = doNot
    }

    /// Whether this says anything worth sending.
    public var isEmpty: Bool {
        goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (doneWhen?.isBlank ?? true)
            && (doNot?.isBlank ?? true)
    }

    /// The contract as the agent should receive it.
    ///
    /// Labelled lines rather than a paragraph. This is machine-to-machine
    /// text: the labels are what make "done when" survive a summarisation that
    /// would otherwise smooth it into the rest of the request.
    public var promptClause: String? {
        guard !isEmpty else { return nil }

        var lines: [String] = []
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGoal.isEmpty {
            lines.append("GOAL: " + trimmedGoal)
        }
        if let doneWhen, !doneWhen.isBlank {
            lines.append("DONE WHEN: " + doneWhen.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let doNot, !doNot.isBlank {
            lines.append("DO NOT: " + doNot.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        lines.append(
            "Stop when the done-when condition is met. Anything beyond it is a "
            + "suggestion to me, not work to do now."
        )
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
