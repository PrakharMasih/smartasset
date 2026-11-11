// Datasets, timing, memory and the dump format, shared by every runtime comparison (Phase 3).
import Darwin
import Foundation

public enum Bench {
    /// The Phase 3 workspace; the isolation script passes it as P3 because HOME is redirected.
    public static var workspace: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["P3"] ?? "/nonexistent") }
    public static func data(_ path: String) -> URL { workspace.appending(path: "data/\(path)") }
    public static func models(_ path: String) -> URL { workspace.appending(path: "models/\(path)") }
    public static func results(_ path: String) -> URL { workspace.appending(path: "results/\(path)") }
}

public struct CocoItem: Decodable, Sendable { public let file: String; public let captions: [String] }
public struct SoundItem: Decodable, Sendable { public let file: String; public let label: String }
public struct SpeechItem: Decodable, Sendable {
    public let group: String, file: String, text: String, voice: String, language: String
    public let seconds: Double
}

public enum Datasets {
    public static func coco() throws -> [CocoItem] {
        try JSONDecoder().decode([CocoItem].self, from: Data(contentsOf: Bench.data("coco/captions500.json")))
    }
    public static func cocoImage(_ item: CocoItem) -> URL { Bench.data("coco/images500/\(item.file)") }
    /// The whole COCO 5k test split (decision D5: real vectors at a larger size). Built by spikes/data-prep/make_coco_full.py.
    public static func cocoFull() throws -> [CocoItem] {
        try JSONDecoder().decode([CocoItem].self, from: Data(contentsOf: Bench.data("coco/captions5k.json")))
    }
    public static func cocoFullImage(_ item: CocoItem) -> URL { Bench.data("coco/images5k/\(item.file)") }

    public static func sounds() throws -> [SoundItem] {
        try JSONDecoder().decode([SoundItem].self, from: Data(contentsOf: Bench.data("esc50/labels.json")))
    }
    public static func soundClip(_ item: SoundItem) -> URL { Bench.data("esc50/clips16k/\(item.file)") }
    /// ESC-50's five major categories, from the class number in `esc50.csv`.
    public static func soundCategories() throws -> [String: String] {
        let names = ["animals", "natural soundscapes", "human non-speech", "interior/domestic", "exterior/urban"]
        var out: [String: String] = [:]
        let rows = try String(contentsOf: Bench.data("esc50/esc50.csv"), encoding: .utf8).split(separator: "\n").dropFirst()
        for row in rows {
            let f = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if f.count > 3, let target = Int(f[2]) { out[f[0]] = names[min(4, target / 10)] }
        }
        return out
    }

    public static func speech() throws -> [SpeechItem] {
        try JSONDecoder().decode([SpeechItem].self, from: Data(contentsOf: Bench.data("speech/speech.json")))
    }
    public static func speechClip(_ item: SpeechItem) -> URL { Bench.data("speech/\(item.file)") }
}

// MARK: - Memory, time, thermal

/// Physical footprint (what Activity Monitor calls Memory) of this process, in MB.
public func physFootprintMB() -> Double { vmInfo().map { Double($0.phys_footprint) / 1_048_576 } ?? -1 }
/// Highest physical footprint this process has reached, in MB.
public func peakFootprintMB() -> Double { vmInfo().map { Double($0.ledger_phys_footprint_peak) / 1_048_576 } ?? -1 }

private func vmInfo() -> task_vm_info_data_t? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? info : nil
}

public func thermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

public func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

/// Latency samples in milliseconds.
public struct Samples: Sendable {
    public var ms: [Double] = []
    public init() {}
    public mutating func add(_ v: Double) { ms.append(v) }
    public var summary: [String: Double] {
        guard !ms.isEmpty else { return [:] }
        let s = ms.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
        return ["count": Double(s.count), "p50_ms": p(0.5), "p95_ms": p(0.95), "max_ms": s[s.count - 1],
                "mean_ms": s.reduce(0, +) / Double(s.count), "total_s": s.reduce(0, +) / 1000]
    }
}

/// Times an async operation and records it.
public func timed<T>(_ samples: inout Samples, _ body: () async throws -> T) async rethrows -> T {
    let t0 = now()
    let r = try await body()
    samples.add(now() - t0)
    return r
}

// MARK: - Dumps (the evaluator in spikes/vector-bench reads these)

public struct Dump {
    public var task: String
    public var runtime: String
    public var queries: [[Float]]
    public var corpus: [[Float]]
    public var relevance: [[Int]]
    public var groups: [String]
    public var queryTexts: [String]
    public var perf: [String: Any]

    public init(task: String, runtime: String, queries: [[Float]], corpus: [[Float]], relevance: [[Int]], groups: [String],
                queryTexts: [String], perf: [String: Any] = [:]) {
        self.task = task; self.runtime = runtime; self.queries = queries; self.corpus = corpus
        self.relevance = relevance; self.groups = groups; self.queryTexts = queryTexts; self.perf = perf
    }

    public func write(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dims = queries.first?.count ?? corpus.first?.count ?? 0
        func raw(_ rows: [[Float]]) -> Data {
            var d = Data(capacity: rows.count * dims * 4)
            for r in rows { precondition(r.count == dims); r.withUnsafeBytes { d.append(contentsOf: $0) } }
            return d
        }
        try raw(queries).write(to: dir.appending(path: "queries.f32"))
        try raw(corpus).write(to: dir.appending(path: "corpus.f32"))
        let meta: [String: Any] = ["dims": dims, "queries": queries.count, "corpus": corpus.count, "task": task, "runtime": runtime,
                                   "thermal_at_end": thermalState()]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appending(path: "meta.json"))
        try JSONSerialization.data(withJSONObject: relevance).write(to: dir.appending(path: "relevance.json"))
        try JSONSerialization.data(withJSONObject: groups).write(to: dir.appending(path: "groups.json"))
        try JSONSerialization.data(withJSONObject: queryTexts).write(to: dir.appending(path: "queries.json"))
        try JSONSerialization.data(withJSONObject: perf, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appending(path: "perf.json"))
    }
}

/// How the words of a caption are bucketed for the per-group breakdown.
public func lengthBucket(_ text: String) -> String {
    let n = text.split(separator: " ").count
    return n <= 8 ? "short (8 words or fewer)" : n <= 12 ? "medium (9-12 words)" : "long (13+ words)"
}

/// The sentence-to-clips relevance used by the speech sets.
public func speechSentences(_ items: [SpeechItem]) -> (sentences: [String], languageOfSentence: [String]) {
    var seen: [String] = [], lang: [String] = []
    for it in items where !seen.contains(it.text) {
        seen.append(it.text)
        lang.append(it.group == "hindi" || it.group == "hinglish" ? it.group : "english")
    }
    return (seen, lang)
}

public func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
