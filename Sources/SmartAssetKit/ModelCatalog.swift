// The AI models SmartAsset can use, and which one suits this Mac (plan D5, H5). Pure logic.
import Foundation

public struct ModelEntry: Identifiable, Hashable, Sendable {
    public enum Job: String, Sendable { case transcription = "Transcripts and voice search", embedding = "Search by meaning" }
    public enum Availability: Sendable, Hashable {
        /// Needs a milestone that is not built yet; the text says which.
        case planned(String)
        case available
    }

    public let id: String
    public let name: String
    public let job: Job
    public let detail: String
    /// Approximate download size in gigabytes, or nil when it is not confirmed yet.
    public let approxGigabytes: Double?
    public let license: String
    public let availability: Availability

    public init(id: String, name: String, job: Job, detail: String, approxGigabytes: Double?, license: String, availability: Availability) {
        self.id = id; self.name = name; self.job = job; self.detail = detail
        self.approxGigabytes = approxGigabytes; self.license = license; self.availability = availability
    }
}

public enum ModelCatalog {
    public static let entries: [ModelEntry] = [
        ModelEntry(id: "whisper-small", name: "Whisper Small", job: .transcription,
                   detail: "Fast and light. Recommended on Macs with 8 GB of memory.",
                   approxGigabytes: 0.5, license: "MIT (OpenAI Whisper)",
                   availability: .planned("Transcripts arrive in the Audio & Voice milestone")),
        ModelEntry(id: "whisper-large-v3-turbo", name: "Whisper Large-v3 Turbo", job: .transcription,
                   detail: "Most accurate. Recommended on Macs with 16 GB of memory or more.",
                   approxGigabytes: 1.6, license: "MIT (OpenAI Whisper)",
                   availability: .planned("Transcripts arrive in the Audio & Voice milestone")),
        ModelEntry(id: "embeddinggemma-2", name: "EmbeddingGemma 2", job: .embedding,
                   detail: "One model that understands text, pictures, video and sound, so you can search by describing what you want.",
                   approxGigabytes: nil, license: "To be confirmed before release",
                   availability: .planned("Search by meaning arrives in the Visual Search milestone, after it is tested on real footage")),
    ]

    /// The transcription model that fits this much memory (plan D5: Small on 8 GB, Large-v3 Turbo from 16 GB).
    public static func recommendedTranscription(memoryGigabytes: Double) -> String {
        memoryGigabytes < 12 ? "whisper-small" : "whisper-large-v3-turbo"
    }

    public static func memoryGigabytes(bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }

    /// "about 1.6 GB", "about 500 MB", or "size shown when available".
    public static func sizeText(_ gigabytes: Double?) -> String {
        guard let gigabytes else { return "Size shown when available" }
        return gigabytes < 1 ? "About \(Int((gigabytes * 1000 / 50).rounded() * 50)) MB" : String(format: "About %.1f GB", gigabytes)
    }
}
