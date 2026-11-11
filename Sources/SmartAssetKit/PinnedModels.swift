// The models SmartAsset may download (plan H5), pinned file by file. Owner's rules (2026-11-09): Hugging Face is the only
// source, and only these files at this exact commit; every file is checked against a trusted SHA-256 before anything is
// installed; the download starts only when the person chooses it; nothing is checked for updates. Pure logic, no network:
// the download itself lives in the app (Models/ModelDownload.swift), the only networking code in SmartAsset.
import CryptoKit
import Foundation

public struct PinnedFile: Sendable, Hashable {
    /// Path inside the repository and inside the installed folder.
    public let path: String
    public let bytes: Int64
    /// Lower-case hex. For the large files it is the SHA-256 Hugging Face publishes (its Git LFS id); for the small text
    /// files, which Hugging Face lists only by git blob id, it was computed from copies whose git blob ids matched the
    /// published ones (docs/research/model-download.md).
    public let sha256: String

    public init(path: String, bytes: Int64, sha256: String) {
        self.path = path; self.bytes = bytes; self.sha256 = sha256
    }
}

public struct PinnedModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let publisher: String
    /// The Hugging Face repository, "owner/name".
    public let repository: String
    /// The full commit hash: files are fetched from this commit, never from a branch.
    public let commit: String
    public let license: String
    /// The folder name under the models folder that the app loads from.
    public let folder: String
    public let files: [PinnedFile]

    public init(id: String, name: String, publisher: String, repository: String, commit: String, license: String, folder: String, files: [PinnedFile]) {
        self.id = id; self.name = name; self.publisher = publisher; self.repository = repository
        self.commit = commit; self.license = license; self.folder = folder; self.files = files
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    /// Free space needed: the files are downloaded beside their final place and moved in, never copied, so the total is
    /// enough; a tenth more leaves room for the volume's own needs.
    public var requiredFreeBytes: Int64 { totalBytes + totalBytes / 10 }
    public var shortCommit: String { String(commit.prefix(7)) }

    /// Where a file is fetched from: the pinned commit, over HTTPS.
    public func url(for file: PinnedFile) -> URL? {
        let path = file.path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(commit)/\(path)")
    }
}

public enum PinnedModels {
    /// EmbeddingGemma 2 for MLX Swift: text and picture parts, 8-bit. Pinned in Phase 3 (phase3/PINS.md).
    public static let embeddingGemma2 = PinnedModel(
        id: "embeddinggemma-2",
        name: "EmbeddingGemma 2",
        publisher: "Google DeepMind (model) · converted for MLX by Nurymanau",
        repository: "Nurymanau/EmbeddingGemma-2-MLX-Swift",
        commit: "06b4e075e6b3772e3c29df9f2a2ace7bd4950bdd",
        license: "Apache 2.0, with Google's Gemma Prohibited Use Policy",
        folder: "mlx",
        files: [
            PinnedFile(path: "text-q8/config.json", bytes: 2_359, sha256: "e090bf087c627155c55b481fca9d216461bdaf44d5a980e018ed3deb92fc7664"),
            PinnedFile(path: "text-q8/config_sentence_transformers.json", bytes: 1_565, sha256: "031e56a498d33c349ab489a21885bcfe25b4fcba841149dc99e1e90d4a7c28f5"),
            PinnedFile(path: "text-q8/manifest.json", bytes: 379, sha256: "d9cdb30351293694b7343078970c72b3696eb12034ff06bff2af663fdc3c5cd8"),
            PinnedFile(path: "text-q8/model.safetensors", bytes: 288_118_885, sha256: "eb8a067456a3cff750bebadc7b985420444e673508a2da5bcf56e726e52d62c9"),
            PinnedFile(path: "text-q8/quantization.json", bytes: 16_288, sha256: "9de7e788a89f36a07387c9758dd187b596675bfe9e0dbf9e56c3a09f1f410965"),
            PinnedFile(path: "text-q8/tokenizer.json", bytes: 32_170_510, sha256: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"),
            PinnedFile(path: "text-q8/tokenizer_config.json", bytes: 1_599, sha256: "17bd5d6e9364ca49a534e1502076593317c298d4a663623091ed45388f004874"),
            PinnedFile(path: "vision-q8/config.json", bytes: 3_453, sha256: "6ece510cf4df3d5370011ea0e856486f971dbd8019f5587c6a059977d61571d4"),
            PinnedFile(path: "vision-q8/manifest.json", bytes: 380, sha256: "db92014f981b36cde052bc4759929d343d30b22f7888c623375b50427ffa11a4"),
            PinnedFile(path: "vision-q8/quantization.json", bytes: 11_258, sha256: "19c4f4d59a942f0829b4c5b6d8da12e24c5a5306434a22f0705e10ff2ced1186"),
            PinnedFile(path: "vision-q8/vision.safetensors", bytes: 193_095_171, sha256: "9b18ee38272989696737fe3a0c4302dfa06f47cc37192b1b8f7583f8447da173"),
        ]
    )

    public static let all = [embeddingGemma2]

    /// A redirect is followed only to Hugging Face's own hosts over HTTPS (it serves large files from its CDN, *.hf.co).
    public static func allowsRedirect(to url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host == "hf.co" || host.hasSuffix(".hf.co")
    }
}

public enum ModelFiles {
    public enum Problem: Error, Equatable, Sendable {
        case missing(String)
        case wrongSize(String)
        case wrongChecksum(String)
    }

    /// SHA-256 of a file, read in 4 MB pieces (the weights are hundreds of megabytes).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks one file of `folder` against the pin: present, the right size, the right SHA-256.
    public static func check(_ file: PinnedFile, in folder: URL) throws -> Problem? {
        let url = folder.appending(path: file.path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attributes[.size] as? NSNumber else {
            return .missing(file.path)
        }
        guard size.int64Value == file.bytes else { return .wrongSize(file.path) }
        return try sha256(of: url) == file.sha256 ? nil : .wrongChecksum(file.path)
    }

    /// Every file of the model, checked; empty when all are right.
    public static func problems(_ model: PinnedModel, in folder: URL) throws -> [Problem] {
        try model.files.compactMap { try check($0, in: folder) }
    }

    /// Name of the file that records which commit a folder holds once it was verified and installed.
    public static let receipt = "installed.json"

    /// Moves a verified staging folder into place in one step: the folder appears whole or not at all. An older install
    /// is replaced atomically (`replaceItemAt`). Writes the receipt first, so an installed folder always carries it.
    public static func install(_ model: PinnedModel, from staging: URL, to destination: URL) throws {
        let receipt = ["model": model.id, "repository": model.repository, "commit": model.commit]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        try data.write(to: staging.appending(path: Self.receipt), options: .atomic)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    /// True when `folder` holds this model as installed: the receipt names the pinned commit and every file has its size.
    /// (Checksums are verified once, before installing; sizes are checked at each launch because reading 500 MB is slow.)
    public static func isInstalled(_ model: PinnedModel, in folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appending(path: receipt)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              json["commit"] == model.commit else { return false }
        return model.files.allSatisfy { file in
            (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: file.path).path)[.size] as? NSNumber)?.int64Value == file.bytes
        }
    }
}
