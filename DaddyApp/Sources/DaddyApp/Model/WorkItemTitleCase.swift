import Foundation

/// Article/headline title case for work-item titles only.
///
/// First and last words are always capitalized. Short articles, coordinating
/// conjunctions, and short prepositions stay lowercase in the middle — the
/// usual English headline rules — so typing `fix drag of the board card`
/// saves as `Fix Drag of the Board Card`.
enum WorkItemTitleCase {
    /// Words left lowercase unless they are the first or last word.
    private static let smallWords: Set<String> = [
        "a", "an", "the",
        "and", "but", "or", "nor", "for", "yet", "so",
        "as", "at", "by", "in", "of", "on", "to", "up", "via", "vs", "vs.",
        "per", "if", "than", "from", "with", "into", "onto", "over", "upon",
        "amid", "among", "around", "aside", "atop", "down", "off", "out",
        "past", "plus", "till", "unto",
    ]

    static func apply(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return trimmed }

        return words.enumerated().map { index, word in
            let force = index == 0 || index == words.count - 1
            return styleCompound(word, forceCapitalize: force)
        }
        .joined(separator: " ")
    }

    /// Hyphenated compounds get each segment styled (`drag-and-drop` →
    /// `Drag-and-Drop`); the segment after a hyphen follows the same small-word
    /// rule unless this is a forced (first/last) word's leading segment.
    private static func styleCompound(_ word: String, forceCapitalize: Bool) -> String {
        let parts = word.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count > 1 else {
            return styleSegment(word, forceCapitalize: forceCapitalize)
        }
        return parts.enumerated().map { index, part in
            let force = forceCapitalize && index == 0
            return styleSegment(String(part), forceCapitalize: force)
        }
        .joined(separator: "-")
    }

    private static func styleSegment(_ segment: String, forceCapitalize: Bool) -> String {
        guard !segment.isEmpty else { return segment }

        // Peel leading/trailing non-letters so `"board,"` → `"Board,"` and
        // `"(draft)"` → `"(Draft)"`.
        var start = segment.startIndex
        var end = segment.endIndex
        while start < end, !segment[start].isLetter, !segment[start].isNumber {
            start = segment.index(after: start)
        }
        while end > start {
            let prev = segment.index(before: end)
            if segment[prev].isLetter || segment[prev].isNumber { break }
            end = prev
        }
        guard start < end else { return segment }

        let prefix = String(segment[..<start])
        let core = String(segment[start..<end])
        let suffix = String(segment[end...])

        // Keep intentional acronyms the user typed in caps (API, URL, …).
        let letters = core.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) {
            return prefix + core + suffix
        }

        let lower = core.lowercased()
        if !forceCapitalize, smallWords.contains(lower) {
            return prefix + lower + suffix
        }

        return prefix + capitalizeWord(core) + suffix
    }

    private static func capitalizeWord(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst().lowercased()
    }
}
