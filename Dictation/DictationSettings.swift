import Combine
import Foundation

@MainActor
final class DictationSettings: ObservableObject {
    @Published var language: String {
        didSet { defaults.set(language, forKey: Storage.language) }
    }
    @Published var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: Storage.vocabulary) }
    }
    @Published var zeroRetention: Bool {
        didSet { defaults.set(zeroRetention, forKey: Storage.zeroRetention) }
    }
    @Published var privacyReviewed: Bool {
        didSet { defaults.set(privacyReviewed, forKey: Storage.privacyGuidanceReviewed) }
    }
    @Published var transcriptRetentionDays: Int {
        didSet {
            let clamped = Self.clampedRetentionDays(transcriptRetentionDays)
            guard transcriptRetentionDays == clamped else {
                transcriptRetentionDays = clamped
                return
            }
            defaults.set(transcriptRetentionDays, forKey: Storage.transcriptRetentionDays)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Storage.language) ?? ""
        vocabulary = defaults.string(forKey: Storage.vocabulary) ?? ""
        zeroRetention = defaults.object(forKey: Storage.zeroRetention) as? Bool ?? false
        privacyReviewed = defaults.object(forKey: Storage.privacyGuidanceReviewed) as? Bool ?? false
        transcriptRetentionDays = Self.clampedRetentionDays(
            defaults.object(forKey: Storage.transcriptRetentionDays) as? Int ?? Self.defaultTranscriptRetentionDays
        )
        if defaults.object(forKey: Storage.transcriptRetentionDays) == nil
            || defaults.integer(forKey: Storage.transcriptRetentionDays) != transcriptRetentionDays {
            defaults.set(transcriptRetentionDays, forKey: Storage.transcriptRetentionDays)
        }
    }


    var keyterms: [String] {
        vocabulary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var vocabularyValid: Bool {
        keyterms.count <= 50 && keyterms.allSatisfy { $0.count <= 20 }
    }

    var configuration: RealtimeConfiguration {
        RealtimeConfiguration(
            language: language.isEmpty ? nil : language,
            keyterms: keyterms,
            zeroRetention: zeroRetention
        )
    }

    static let defaultTranscriptRetentionDays = 14

    static func clampedRetentionDays(_ days: Int) -> Int {
        min(max(days, 1), 3_650)
    }

    private enum Storage {
        static let language = "dictation.language"
        static let vocabulary = "dictation.vocabulary"
        static let zeroRetention = "dictation.zeroRetention"
        static let privacyGuidanceReviewed = "privacyGuidanceReviewed"
        static let transcriptRetentionDays = "dictation.transcriptRetentionDays"
    }
}
