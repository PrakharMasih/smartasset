// Usage: SATests [filter]   runs every test whose name contains `filter`; exit status 1 if any fails.
import Foundation

@main
struct Runner {
    static func main() async {
        let filter = CommandLine.arguments.dropFirst().first ?? ""
        let all = bridgeTests + workerTests + formatTests + kitTests + duplicateTests
        let selected = all.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        var failed = 0
        var unverified = 0
        let started = ContinuousClock.now
        for test in selected {
            let t0 = ContinuousClock.now
            do {
                try await test.body()
                print("PASS  \(test.name)  (\(t0.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))))")
            } catch let skipped as Unverified {
                unverified += 1
                print("UNVERIFIED  \(test.name)\n      \(skipped.reason)")
            } catch {
                failed += 1
                print("FAIL  \(test.name)\n      \(error)")
            }
        }
        let total = started.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        print("\n\(selected.count - failed - unverified) passed, \(failed) failed, \(unverified) unverified, \(selected.count) run in \(total)")
        exit(failed == 0 ? 0 : 1)
    }
}
