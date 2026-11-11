// Finding and loading the model for search by meaning (Phase 4). Everything that touches a runtime sits behind
// `EmbeddingModel`; this file decides where the files are and whether a runtime was built in.
import CoreBridge
import Foundation
import SmartAssetKit
import Workers

public enum SemanticModelError: LocalizedError {
    case notBuiltIn
    case filesMissing(URL)
    case disabled

    public var errorDescription: String? {
        switch self {
        case .notBuiltIn: "This build of SmartAsset does not include the search model."
        case .filesMissing: "Search by meaning needs its model. Download it in Settings ▸ Models."
        case .disabled: "Search by meaning is turned off."
        }
    }
}

public enum SemanticModels {
    /// The folders the model needs, inside the models folder.
    static let requiredFolders = ["text-q8", "vision-q8"]

    /// Where the installed models live: SmartAsset's own folder in Application Support (owner's rule, 2026-11-09).
    /// `SA_MODELS_ROOT` moves it for tests (a download test must never touch the person's own folder).
    public static var modelsRoot: URL {
        if let root = ProcessInfo.processInfo.environment["SA_MODELS_ROOT"], !root.isEmpty { return URL(fileURLWithPath: root, isDirectory: true) }
        return URL.applicationSupportDirectory.appending(path: "SmartAsset/Models", directoryHint: .isDirectory)
    }

    /// Where the model files are. `SA_MODELS_DIR` wins (tests and development point it at a verified copy); otherwise
    /// only a complete, verified install in Application Support counts. Nothing is ever loaded from anywhere else.
    public static func directory() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SA_MODELS_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            return requiredFolders.allSatisfy { fm.fileExists(atPath: dir.appending(path: $0).path) } ? dir : nil
        }
        let model = PinnedModels.embeddingGemma2
        let installed = modelsRoot.appending(path: model.folder, directoryHint: .isDirectory)
        return ModelFiles.isInstalled(model, in: installed) ? installed : nil
    }

    /// `APP_SEMANTIC=0` turns search by meaning off (tests that must not load a model).
    public static var isDisabled: Bool { ProcessInfo.processInfo.environment["APP_SEMANTIC"] == "0" }

    /// True when a runtime was compiled in.
    public static var isBuiltIn: Bool {
        #if SA_MLX
        true
        #else
        false
        #endif
    }

    /// Loads the model. Takes a few seconds the first time: the weights are read and put on the GPU.
    public static func load() async throws -> any EmbeddingModel {
        guard !isDisabled else { throw SemanticModelError.disabled }
        #if SA_MLX
        guard let dir = directory() else {
            throw SemanticModelError.filesMissing(URL.applicationSupportDirectory.appending(path: "SmartAsset/Models/mlx"))
        }
        return try await GemmaModel(directory: dir)
        #else
        throw SemanticModelError.notBuiltIn
        #endif
    }
}
