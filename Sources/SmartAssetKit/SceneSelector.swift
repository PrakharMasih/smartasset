// Which frames of a video describe it (Phase 4, S2). The video is sampled at evenly spaced instants, each reduced to a
// tiny grey picture; a frame joins the video's scenes when it differs enough from the last scene chosen. Pure logic, so
// the rule is tested without a video: the decoding and the model live in Workers.
import Foundation

public enum SceneSelector {
    /// How different (0 to 1, mean grey-level change) a frame must be from the last scene to start a new one.
    public static let threshold = 0.10
    /// No two scenes closer than this, however much changed (a flash or a fade is not two scenes).
    public static let minimumGap = 2.0
    /// A video is described by at most this many scenes, and by at least `minimumScenes` when it has that many instants.
    public static let maximumScenes = 16
    public static let minimumScenes = 3

    /// The instants (seconds) that start a scene. `signatures[i]` is the grey picture of `times[i]`; every signature has
    /// the same length. The first instant always starts a scene.
    public static func select(times: [Double], signatures: [[UInt8]], duration: Double) -> [Double] {
        guard !times.isEmpty, times.count == signatures.count else { return [] }
        var chosen = [0]
        for i in 1..<times.count {
            let last = chosen[chosen.count - 1]
            guard times[i] - times[last] >= minimumGap else { continue }
            if change(signatures[last], signatures[i]) >= threshold { chosen.append(i) }
        }
        if chosen.count > maximumScenes {
            // Too many cuts (a music video): keep an even spread rather than only the start.
            chosen = (0..<maximumScenes).map { chosen[Int((Double($0) * Double(chosen.count - 1) / Double(maximumScenes - 1)).rounded())] }
        }
        if chosen.count < min(minimumScenes, times.count), duration > 0 {
            // A video without cuts is still described at a few places along it.
            for fraction in [0.5, 0.8, 0.2] where chosen.count < min(minimumScenes, times.count) {
                let nearest = times.indices.min { abs(times[$0] - duration * fraction) < abs(times[$1] - duration * fraction) } ?? 0
                if !chosen.contains(nearest) { chosen.append(nearest) }
            }
        }
        return Array(Set(chosen)).sorted().map { times[$0] }
    }

    /// Mean absolute difference of two grey pictures of the same size, from 0 (same) to 1 (black against white).
    public static func change(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count * 255)
    }

    /// Instants to look at for a video of `duration` seconds: one a second up to `limit`, then evenly spread.
    public static func candidateTimes(duration: Double, limit: Int = 96) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let count = min(limit, max(6, Int(duration.rounded(.up))))
        return (0..<count).map { (Double($0) + 0.5) * duration / Double(count) }
    }
}
