// Performance check for a big library (plan §8): APP_BENCH=1 with APP_DATA pointing at a synthetic library in /tmp.
// Prints launch-to-results time, scroll smoothness (main-thread stalls while flicking the whole grid), memory and idle CPU.
import AppKit
import Darwin
import Foundation

enum Bench {
    static let started = ContinuousClock.now

    static var isRequested: Bool { ProcessInfo.processInfo.environment["APP_BENCH"] == "1" }

    static func runIfRequested(model: AppModel) async {
        guard isRequested else { return }
        let data = AppModel.dataDirectory.path
        guard ["/tmp/", "/private/tmp/"].contains(where: { data.hasPrefix($0) }) else { print("BENCH refused: APP_DATA must be in /tmp"); NSApp.terminate(nil); return }
        func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000) }
        let ready = started.duration(to: .now)
        print("BENCH launched_to_ready_ms=\(ms(ready)) files=\(model.stats?.total ?? 0)")
        // The app opens on the Search page, which has no grid until words are typed. The grid under test is All Files.
        model.sidebar = .all
        while model.resultCount == 0 || model.source == nil { try? await Task.sleep(for: .milliseconds(10)) }
        // Wait for the first page of tiles to be drawn.
        try? await Task.sleep(for: .milliseconds(600))
        print("BENCH launched_to_first_grid_ms<=\(ms(started.duration(to: .now))) results=\(model.resultCount)")
        print("BENCH rss_mb_after_launch=\(Int(residentMegabytes()))")

        guard let scroll = findCollectionScroll() else { print("BENCH no grid found"); NSApp.terminate(nil); return }
        let doc = scroll.documentView?.bounds.height ?? 0
        print("BENCH grid_height_points=\(Int(doc))")

        // Flick through the grid for eight seconds (APP_BENCH_STEP points per 8 ms tick; 120 is about 15,000 points per second, a fast trackpad flick), watching the main thread.
        var drifts: [Double] = []
        var last = ContinuousClock.now
        let interval = 0.008
        let step = CGFloat(Double(ProcessInfo.processInfo.environment["APP_BENCH_STEP"] ?? "") ?? 120)
        print("BENCH scroll_points_per_second=\(Int(Double(step) / interval))")
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ContinuousClock.now
                let dt = last.duration(to: now)
                last = now
                drifts.append(Double(dt.components.attoseconds) / 1e18 + Double(dt.components.seconds) - interval)
                let clip = scroll.contentView
                var origin = clip.bounds.origin
                origin.y = min(origin.y + step, max(0, doc - clip.bounds.height))
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        try? await Task.sleep(for: .seconds(8))
        timer.invalidate()
        let sorted = drifts.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
        let over16 = drifts.filter { $0 > 0.008 }.count   // a tick more than 8 ms late: at 60 Hz that is a dropped frame
        print(String(format: "BENCH scroll ticks=%d late_p50_ms=%.1f late_p99_ms=%.1f late_max_ms=%.1f ticks_over_8ms_late=%d", drifts.count, pct(0.5), pct(0.99), (sorted.last ?? 0) * 1000, over16))
        print("BENCH rss_mb_after_scroll=\(Int(residentMegabytes()))")

        // Idle: nothing is happening; the CPU should be (almost) still.
        try? await Task.sleep(for: .seconds(3))
        let cpu0 = cpuSeconds(), t0 = ContinuousClock.now
        try? await Task.sleep(for: .seconds(10))
        let wall = Double(t0.duration(to: .now).components.seconds)
        print(String(format: "BENCH idle_cpu_percent=%.2f over %.0fs", (cpuSeconds() - cpu0) / max(1, wall) * 100, wall))
        print("BENCH rss_mb_idle=\(Int(residentMegabytes()))")
        await model.shutdown()
        NSApp.terminate(nil)
    }

    private static func findCollectionScroll() -> NSScrollView? {
        func search(_ view: NSView) -> NSScrollView? {
            if let c = view as? NSCollectionView { return c.enclosingScrollView }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        for window in NSApp.windows { if let content = window.contentView?.superview, let found = search(content) { return found } }
        return nil
    }

    /// The physical footprint Activity Monitor shows as "Memory": private memory, without shared system frameworks.
    private static func residentMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return secs(usage.ru_utime) + secs(usage.ru_stime)
    }
}
