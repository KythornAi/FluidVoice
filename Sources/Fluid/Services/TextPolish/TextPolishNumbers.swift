import Foundation

/// Spoken-number → digits converter for the text polish pipeline (Phase 6).
///
/// Converts unambiguous spoken number phrases to digits:
///   "zero point eight five"  → "0.85"
///   "twenty five percent"    → "25%"
///   "one hundred and two"    → "102"
///   "minus five degrees"     → "-5 degrees"
///
/// Conservative by design:
///  - Lone zero…nine stay words ("I have two dogs" untouched) unless they
///    sit in a decimal ("point five") or before "percent".
///  - English number grammar is enforced ("thirty five" = 35 parses, but
///    "five thirty" does NOT — ones never precede tens), so time-of-day
///    ("five thirty", "six forty five") stays words.
///  - Money and times are deliberately NOT converted — too ambiguous
///    without context. Skipped entirely in Terminal format mode.
enum TextPolishNumberConverter {

    private static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000,
    ]
    /// "oh" reads as zero only inside a decimal tail ("point oh five").
    private static let decimalDigits: [String: Int] = {
        var map = TextPolishNumberConverter.ones
        map["oh"] = 0
        return map
    }()

    private static var allNumberWords: Set<String> {
        Set(self.ones.keys).union(self.teens.keys).union(self.tens.keys).union(self.scales.keys)
    }

    /// Split trailing sentence punctuation off a token ("five," → ("five", ",")).
    private static func splitToken(_ token: String) -> (core: String, suffix: String) {
        var core = token
        var suffix = ""
        while let last = core.last, ".,!?;:".contains(last) {
            suffix = String(last) + suffix
            core.removeLast()
        }
        return (core.lowercased(), suffix)
    }

    private static func hasSentenceEnd(_ token: String) -> Bool {
        token.contains(".") || token.contains("!") || token.contains("?")
    }

    /// Expand hyphenated number tokens ("twenty-five," → "twenty" "five,").
    private static func expandHyphenated(_ tokens: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(tokens.count)
        for token in tokens {
            let (core, suffix) = self.splitToken(token)
            if core.contains("-") {
                let parts = core.split(separator: "-").map(String.init)
                if parts.count > 1, parts.allSatisfy({ self.allNumberWords.contains($0) }) {
                    for part in parts.dropLast() { out.append(part) }
                    out.append(parts.last! + suffix)
                    continue
                }
            }
            out.append(token)
        }
        return out
    }

    private enum ParseResult {
        case converted(replacement: String, nextIndex: Int)
        /// A valid number phrase was found but policy keeps it as words
        /// (lone small number). Carries the consumed span.
        case words(span: Int)
        case none
    }

    private enum SmallKind { case none, ones, teens, tens, scale }

    /// Attempt to parse a number phrase starting at `start`.
    private static func parseNumber(at start: Int, in tokens: [String]) -> ParseResult {
        var index = start
        var negative = false

        let firstCore = self.splitToken(tokens[index]).core

        // Leading decimal: "point five" → "0.5"
        if firstCore == "point", index + 1 < tokens.count {
            var tail = ""
            var cursor = index + 1
            while cursor < tokens.count {
                let core = self.splitToken(tokens[cursor]).core
                guard let digit = self.decimalDigits[core] else { break }
                tail.append(String(digit))
                cursor += 1
            }
            guard !tail.isEmpty else { return .none }
            let suffix = self.splitToken(tokens[cursor - 1]).suffix
            return .converted(replacement: "0." + tail + suffix, nextIndex: cursor)
        }

        if firstCore == "minus" || firstCore == "negative",
           index + 1 < tokens.count
        {
            negative = true
            index += 1
        }

        var total = 0
        var current = 0
        var consumed = 0
        var sawScale = false
        var lastKind = SmallKind.none

        // "a hundred" / "a thousand" → 100 / 1000
        if index < tokens.count {
            let core = self.splitToken(tokens[index]).core
            if (core == "a" || core == "an"),
               index + 1 < tokens.count,
               self.scales[self.splitToken(tokens[index + 1]).core] != nil
            {
                current = 1
                consumed += 1
                lastKind = .ones
                index += 1
            }
        }

        while index < tokens.count {
            let core = self.splitToken(tokens[index]).core
            if let value = self.ones[core] {
                // Ones may start a phrase or follow tens/scale/and — never
                // follow ones/teens ("five three" is not a number).
                guard lastKind == .none || lastKind == .tens || lastKind == .scale else { break }
                current += value
                lastKind = .ones
                consumed += 1
                index += 1
            } else if let value = self.teens[core] {
                guard lastKind == .none || lastKind == .scale else { break }
                current += value
                lastKind = .teens
                consumed += 1
                index += 1
            } else if let value = self.tens[core] {
                // Tens may start or follow a scale ("hundred twenty") —
                // never follow ones/teens ("five thirty" is a time, not 35).
                guard lastKind == .none || lastKind == .scale else { break }
                current += value
                lastKind = .tens
                consumed += 1
                index += 1
            } else if let scale = self.scales[core] {
                if scale == 100 {
                    current = max(current, 1) * 100
                } else {
                    total += max(current, 1) * scale
                    current = 0
                }
                sawScale = true
                lastKind = .scale
                consumed += 1
                index += 1
            } else if core == "and", consumed > 0, sawScale,
                      index + 1 < tokens.count,
                      self.allNumberWords.contains(self.splitToken(tokens[index + 1]).core)
            {
                index += 1 // connector: "one hundred and two"
            } else {
                break
            }
        }

        guard consumed > 0 else { return .none }
        var value = total + current

        // Decimal tail: "point <digit> <digit>…" (digit words incl. "oh")
        var decimalTail = ""
        var sawPoint = false
        if index < tokens.count, self.splitToken(tokens[index]).core == "point" {
            var cursor = index + 1
            while cursor < tokens.count {
                let core = self.splitToken(tokens[cursor]).core
                guard let digit = self.decimalDigits[core] else { break }
                decimalTail.append(String(digit))
                cursor += 1
            }
            if !decimalTail.isEmpty {
                sawPoint = true
                index = cursor
            }
        }

        // Percent: "percent" / "per cent" attaches "%" to the number
        var sawPercent = false
        if index < tokens.count {
            let core = self.splitToken(tokens[index]).core
            if core == "percent" {
                sawPercent = true
                index += 1
            } else if core == "per",
                      index + 1 < tokens.count,
                      self.splitToken(tokens[index + 1]).core == "cent"
            {
                sawPercent = true
                index += 2
            }
        }

        // Conversion policy: lone zero…nine stay words unless decimal,
        // percent, or explicitly negative.
        guard sawPoint || sawPercent || negative || value >= 10 else {
            return .words(span: index - start)
        }

        let lastSuffix = self.splitToken(tokens[index - 1]).suffix
        var replacement = negative ? "-" : ""
        replacement += String(value)
        if sawPoint { replacement += "." + decimalTail }
        if sawPercent { replacement += "%" }
        replacement += lastSuffix
        return .converted(replacement: replacement, nextIndex: index)
    }

    /// Convert spoken number phrases in `text` to digits. Runs after locale
    /// enforcement, before the grammar tidy (which normalises spacing).
    static func convert(in text: String) -> String {
        let tokens = self.expandHyphenated(
            text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        )
        guard tokens.count > 0 else { return text }

        var out: [String] = []
        out.reserveCapacity(tokens.count)
        var index = 0
        // After a rejected small phrase ("five" in "five thirty"), a lone
        // tens/teens word immediately following also stays words — this is
        // the time-of-day guard ("six forty five" stays fully verbatim).
        var tensBlocked = false
        while index < tokens.count {
            let core = self.splitToken(tokens[index]).core
            if tensBlocked, self.teens[core] != nil || self.tens[core] != nil {
                out.append(tokens[index])
                if self.hasSentenceEnd(tokens[index]) { tensBlocked = false }
                index += 1
                continue
            }
            tensBlocked = false
            switch self.parseNumber(at: index, in: tokens) {
            case let .converted(replacement, nextIndex):
                out.append(replacement)
                index = nextIndex
            case let .words(span):
                for token in tokens[index ..< index + span] { out.append(token) }
                index += span
                if !self.hasSentenceEnd(tokens[index - 1]) { tensBlocked = true }
            case .none:
                out.append(tokens[index])
                index += 1
            }
        }
        return out.joined(separator: " ")
    }
}
