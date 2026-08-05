import Combine
import Foundation

/// User settings for the local text polish pipeline.
/// Kept in an extension so all Phase 4 polish code stays isolated from
/// upstream's SettingsStore (merge-pain rule, roadmap §7.4).
extension SettingsStore {
    private enum TextPolishKeys {
        static let locale = "TextPolishLocale"
        static let fixSpelling = "TextPolishFixSpellingEnabled"
        static let fixGrammar = "TextPolishFixGrammarEnabled"
        static let removeFillers = "TextPolishRemoveFillersEnabled"
        static let collapseDuplicates = "TextPolishCollapseDuplicatesEnabled"
        static let formatMode = "TextPolishFormatMode"
    }

    /// Format mode preset (Note/Email/Chat/Terminal). Default: Note.
    var textPolishFormatMode: TextPolishFormatMode {
        get {
            let raw = UserDefaults.standard.string(forKey: TextPolishKeys.formatMode) ?? TextPolishFormatMode.note.rawValue
            return TextPolishFormatMode(rawValue: raw) ?? .note
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: TextPolishKeys.formatMode)
        }
    }

    /// Spelling locale enforced by the local polish pipeline. Default: UK.
    var textPolishLocale: TextPolishLocale {
        get {
            let raw = UserDefaults.standard.string(forKey: TextPolishKeys.locale) ?? TextPolishLocale.uk.rawValue
            return TextPolishLocale(rawValue: raw) ?? .uk
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: TextPolishKeys.locale)
        }
    }

    /// Correct common misspellings (~330 entries). Default: on.
    var textPolishFixSpellingEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: TextPolishKeys.fixSpelling) as? Bool ?? true
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: TextPolishKeys.fixSpelling)
        }
    }

    /// Grammar tidy (capitalisation, spacing, trailing punctuation). Default: on.
    var textPolishFixGrammarEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: TextPolishKeys.fixGrammar) as? Bool ?? true
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: TextPolishKeys.fixGrammar)
        }
    }

    /// Remove filler words/phrases (um, uh, you know, sort of, ...). Default: on.
    var textPolishRemoveFillersEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: TextPolishKeys.removeFillers) as? Bool ?? true
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: TextPolishKeys.removeFillers)
        }
    }

    /// Collapse immediately repeated words ("already, already" → "already,").
    /// Default: on. Skipped in Terminal format mode (near-verbatim).
    var textPolishCollapseDuplicatesEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: TextPolishKeys.collapseDuplicates) as? Bool ?? true
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: TextPolishKeys.collapseDuplicates)
        }
    }
}
