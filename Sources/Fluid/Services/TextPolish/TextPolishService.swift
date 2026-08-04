import Foundation

/// Locale options for the local text polish pipeline.
enum TextPolishLocale: String, CaseIterable, Identifiable {
    case uk
    case us

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .uk: return "British English (UK)"
        case .us: return "American English (US)"
        }
    }
}

/// Text Polish Pipeline — ported from VoiceAssist's `text-polish.js`.
///
/// Cleans up dictated text with pure local rules: repetition filtering,
/// filler removal, common misspelling correction, UK/US locale enforcement,
/// and a grammar tidy. No network, no API key, runs in <10 ms.
///
/// Stage order matches the VoiceAssist implementation:
/// repetition → fillers → misspellings → locale → grammar.
final class TextPolishService {
    static let shared = TextPolishService()

    /// Sentinel prompt-selection ID for "Local polish" in the dictation
    /// enhancement picker (mirrors PrivateAIProviderFeature.promptSelectionID).
    static let promptSelectionID = "__LOCAL_POLISH__"

    struct Options {
        var locale: TextPolishLocale = .uk
        var fixSpelling: Bool = true
        var fixGrammar: Bool = true
        var removeFillerWords: Bool = true
    }

    private var usToUk: [String: String] = [:]
    private var ukToUs: [String: String] = [:]
    private var misspellings: [String: String] = [:]
    private var didLoadDictionaries = false

    private init() {}

    /// Options snapshot from user settings (see SettingsStore+TextPolish).
    var currentOptions: Options {
        Options(
            locale: SettingsStore.shared.textPolishLocale,
            fixSpelling: SettingsStore.shared.textPolishFixSpellingEnabled,
            fixGrammar: SettingsStore.shared.textPolishFixGrammarEnabled,
            removeFillerWords: SettingsStore.shared.textPolishRemoveFillersEnabled
        )
    }

    // MARK: - Dictionary loading

    private func loadDictionariesIfNeeded() {
        guard !self.didLoadDictionaries else { return }
        self.didLoadDictionaries = true

        if let url = Bundle.main.url(forResource: "textpolish_uk_us_pairs", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pairs = root["pairs"] as? [String: String]
        {
            for (us, uk) in pairs {
                self.usToUk[us.lowercased()] = uk
                self.ukToUs[uk.lowercased()] = us
            }
        } else {
            DebugLogger.shared.error("TextPolishService: failed to load textpolish_uk_us_pairs.json", source: "TextPolishService")
        }

        if let url = Bundle.main.url(forResource: "textpolish_common_misspellings", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let corrections = root["corrections"] as? [String: String]
        {
            for (wrong, right) in corrections {
                self.misspellings[wrong.lowercased()] = right
            }
        } else {
            DebugLogger.shared.error("TextPolishService: failed to load textpolish_common_misspellings.json", source: "TextPolishService")
        }

        DebugLogger.shared.debug(
            "TextPolishService: loaded \(self.usToUk.count) locale pairs, \(self.misspellings.count) misspelling corrections",
            source: "TextPolishService"
        )
    }

    // MARK: - Pipeline stages

    /// Fix common misspellings. Locale-neutral; locale conversion happens later.
    private func fixMisspellings(in text: String) -> String {
        guard !self.misspellings.isEmpty else { return text }
        return self.replacingWords(in: text, pattern: #"\b[\w']+\b"#) { word in
            guard let correction = self.misspellings[word.lowercased()] else { return word }
            return self.matchCase(original: word, replacement: correction)
        }
    }

    /// Enforce UK or US spelling based on the locale setting.
    private func enforceLocale(in text: String, locale: TextPolishLocale) -> String {
        let map = locale == .uk ? self.usToUk : self.ukToUs
        guard !map.isEmpty else { return text }
        return self.replacingWords(in: text, pattern: #"\b\w+\b"#) { word in
            guard let replacement = map[word.lowercased()] else { return word }
            return self.matchCase(original: word, replacement: replacement)
        }
    }

    /// Basic grammar cleanup: collapse double spaces, remove space before
    /// punctuation, capitalise sentence starts and standalone "i", and ensure
    /// the text ends with punctuation.
    private func tidyGrammar(in text: String) -> String {
        var result = text

        // Fix double/triple spaces
        result = self.replacing(#"\s{2,}"#, in: result, with: " ")

        // Remove space before punctuation
        result = self.replacing(#"\s+([.,!?;:])"#, in: result, with: "$1")

        // Capitalise after sentence-ending punctuation
        let sentenceInput = result
        result = self.replacing(#"([.!?])\s+([a-z])"#, in: sentenceInput) { match in
            let punct = match.capture(1, in: sentenceInput) ?? ""
            let letter = (match.capture(2, in: sentenceInput) ?? "").uppercased()
            return punct + " " + letter
        }

        // Capitalise first character
        if let first = result.first, first.isLetter, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        // Capitalise standalone "i"
        result = self.replacing(#"\bi\b"#, in: result, with: "I")
        // Fix "i'm", "i've", "i'll", "i'd" etc.
        result = self.replacing(#"\bi'([a-z])"#, in: result, with: "I'$1")

        // Add full stop at end if missing punctuation
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let last = trimmed.last, !".!?".contains(last) {
            result = trimmed + "."
            return result
        }

        return trimmed
    }

    /// Remove filler words and phrases (um, uh, you know, sort of, ...).
    private func removeFillers(from text: String) -> String {
        var result = text
        result = self.replacing(
            #"\b(um|uh|ah|er|hm|hmm|like|you know|sort of|kind of)\b([,.]*\s*)"#,
            in: result,
            with: "",
            options: .caseInsensitive
        )
        result = self.replacing(#"\s+"#, in: result, with: " ")
        result = self.replacing(#" ,"#, in: result, with: ",")
        result = self.replacing(#"^[,.\s]+"#, in: result, with: "")
        result = self.replacing(#"([.?!])\s*[,.]+"#, in: result, with: "$1")
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Filter repetitive tail sequences (speech-model hallucination guard).
    /// Catches "word word word word word..." patterns.
    private func filterRepetition(in text: String) -> String {
        if text.count <= 20 { return text }

        let words = text.split(separator: " ").map(String.init)
        if words.count <= 8 { return text }

        let stripPunctuation: (String) -> String = { word in
            var lower = word.lowercased()
            while let last = lower.last, ".,!?;:".contains(last) {
                lower.removeLast()
            }
            return lower
        }

        let lastWord = stripPunctuation(words[words.count - 1])
        var repeats = 0
        for word in words.reversed() {
            if stripPunctuation(word) == lastWord {
                repeats += 1
            } else {
                break
            }
        }

        if repeats > 4 {
            let sequenceStartIndex = words.count - repeats
            let kept = words[0 ... sequenceStartIndex]
            return kept.joined(separator: " ") + "..."
        }

        return text
    }

    // MARK: - Helpers

    /// Match the capitalisation pattern of the original word.
    private func matchCase(original: String, replacement: String) -> String {
        if original == original.uppercased() {
            return replacement.uppercased()
        }
        if let first = original.first, String(first) == String(first).uppercased() {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement.lowercased()
    }

    private struct RegexMatch {
        let range: Range<String.Index>
        let captures: [Range<String.Index>?]

        func capture(_ index: Int, in text: String) -> String? {
            guard index - 1 < self.captures.count, let range = self.captures[index - 1] else { return nil }
            return String(text[range])
        }
    }

    /// Replace every regex match using a closure that receives the match.
    private func replacing(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [],
        with transform: (RegexMatch) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += String(text[cursor ..< range.lowerBound])
            var captures: [Range<String.Index>?] = []
            for i in 1 ..< match.numberOfRanges {
                captures.append(Range(match.range(at: i), in: text))
            }
            result += transform(RegexMatch(range: range, captures: captures))
            cursor = range.upperBound
        }
        result += String(text[cursor...])
        return result
    }

    private func replacing(
        _ pattern: String,
        in text: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: nsRange, withTemplate: template)
    }

    /// Replace whole words matched by `pattern` via a word transform.
    private func replacingWords(
        in text: String,
        pattern: String,
        with transform: (String) -> String
    ) -> String {
        self.replacing(pattern, in: text) { match in
            transform(String(text[match.range]))
        }
    }

    // MARK: - Main pipeline

    /// Run the full text polish pipeline on a raw transcript.
    func polish(_ text: String, options: Options? = nil) -> String {
        let options = options ?? self.currentOptions
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        self.loadDictionariesIfNeeded()

        var result = trimmed

        // 1. Repetition filter (first, before other processing)
        result = self.filterRepetition(in: result)

        // 2. Filler word removal
        if options.removeFillerWords {
            result = self.removeFillers(from: result)
        }

        // 3. Spelling correction
        if options.fixSpelling {
            result = self.fixMisspellings(in: result)
        }

        // 4. Locale enforcement (after spelling fix, working with correct base words)
        result = self.enforceLocale(in: result, locale: options.locale)

        // 5. Grammar tidy (last, so capitalisation applies to final text)
        if options.fixGrammar {
            result = self.tidyGrammar(in: result)
        }

        return result
    }
}
