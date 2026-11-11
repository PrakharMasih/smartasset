// measure-run --out result.json [--interval-ms 250] [--idle-s 5] -- <command> [args...]
//
// Samples every interval while the command runs:
//   system memory in use, as Activity Monitor defines it: app memory (internal pages minus purgeable) + wired + compressed.
//   This includes memory held for the command by other processes, e.g. a model that Core ML keeps in a system service;
//   the command's own physical footprint and CPU time, and the thermal state.
// A quiet-machine baseline is taken first. The result is the peak and mean *increase over that baseline*.
// Energy: the kernel's per-process energy counters (ri_billed_energy / ri_serviced_energy, nanojoules) are read from the last sample;
// whether they include GPU or Neural Engine work is checked by the caller, not assumed. powermetrics, which does, needs root and is not used.
import BenchSupport
import Darwin
import Foundation

func systemUsedMB() -> Double {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    let page = Double(sysconf(_SC_PAGESIZE))
    let pages = Double(stats.internal_page_count) - Double(stats.purgeable_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)
    return pages * page / 1_048_576
}

struct Usage { var footprintMB = 0.0, cpuS = 0.0, billedNJ: UInt64 = 0, servicedNJ: UInt64 = 0 }

func usage(pid: pid_t) -> Usage? {
    var info = rusage_info_current()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
    }
    guard r == 0 else { return nil }
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    let cpuNs = Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom)
    return Usage(footprintMB: Double(info.ri_phys_footprint) / 1_048_576, cpuS: cpuNs / 1e9,
                 billedNJ: info.ri_billed_energy, servicedNJ: info.ri_serviced_energy)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let dash = args.firstIndex(of: "--"), dash + 1 < args.count else { fatalError("usage: measure-run --out file.json [--interval-ms N] [--idle-s N] -- cmd args...") }
let opts = Array(args[..<dash]), cmd = Array(args[(dash + 1)...])
func opt(_ name: String, _ def: String) -> String { opts.firstIndex(of: name).flatMap { $0 + 1 < opts.count ? opts[$0 + 1] : nil } ?? def }
let out = opt("--out", "measure.json"), intervalMs = Double(opt("--interval-ms", "250")) ?? 250, idleS = Double(opt("--idle-s", "5")) ?? 5

// Baseline.
var base: [Double] = []
let tIdle = now()
while now() - tIdle < idleS * 1000 { base.append(systemUsedMB()); usleep(UInt32(intervalMs * 1000)) }
let baseline = base.sorted()[base.count / 2]

let process = Process()
process.executableURL = URL(fileURLWithPath: cmd[0])
process.arguments = Array(cmd.dropFirst())
let start = now()
try process.run()
let pid = process.processIdentifier

var samples: [[String: Double]] = []
var last = Usage(), peakFootprint = 0.0, worst = "nominal"
let rank = ["nominal": 0, "fair": 1, "serious": 2, "critical": 3]
while process.isRunning {
    usleep(UInt32(intervalMs * 1000))
    let used = systemUsedMB()
    if let u = usage(pid: pid) { last = u; peakFootprint = max(peakFootprint, u.footprintMB) }
    let th = thermalState(); if (rank[th] ?? 0) > (rank[worst] ?? 0) { worst = th }
    samples.append(["t_s": (now() - start) / 1000, "system_used_delta_mb": used - baseline, "process_footprint_mb": last.footprintMB, "process_cpu_s": last.cpuS])
}
process.waitUntilExit()
let elapsed = (now() - start) / 1000
let deltas = samples.map { $0["system_used_delta_mb"] ?? 0 }
let result: [String: Any] = [
    "command": cmd, "exit": process.terminationStatus, "seconds": elapsed,
    "baseline_system_used_mb": baseline, "baseline_idle_samples": base.count,
    "system_used_increase_peak_mb": deltas.max() ?? 0,
    "system_used_increase_mean_mb": deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count),
    "process_footprint_peak_mb": peakFootprint,
    "process_cpu_seconds": last.cpuS, "cpu_utilisation_of_one_core": elapsed > 0 ? last.cpuS / elapsed : 0,
    "billed_energy_joules_last_sample": Double(last.billedNJ) / 1e9, "serviced_energy_joules_last_sample": Double(last.servicedNJ) / 1e9,
    "worst_thermal_state": worst, "thermal_at_end": thermalState(), "samples": samples.count,
]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
print(String(format: "%.1f s | system memory +%.0f MB peak (+%.0f mean) | process footprint peak %.0f MB | cpu %.1f s | billed energy %.1f J | thermal worst %@",
             elapsed, deltas.max() ?? 0, deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count), peakFootprint, last.cpuS,
             Double(last.billedNJ) / 1e9, worst))
exit(process.terminationStatus)
