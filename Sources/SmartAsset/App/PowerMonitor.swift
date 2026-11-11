// Tells the engine how busy and how hot the Mac is, so indexing backs off (plan global requirement 11).
// Everything here is event-driven: no polling timer, so an idle app uses no CPU.
import AppKit
import CoreBridge
import Foundation
import IOKit.ps

final class PowerMonitor {
    static let shared = PowerMonitor()

    var onChange: ((Conditions) -> Void)?
    private(set) var conditions = Conditions(onBattery: false, lowPowerMode: false, thermal: .nominal, memory: .normal, userActive: false)

    private var runLoopSource: CFRunLoopSource?
    private var memorySource: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var idleTask: Task<Void, Never>?

    func start() {
        guard runLoopSource == nil else { return }
        refresh()

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PowerMonitor.shared.refresh() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PowerMonitor.shared.refresh() }
        })
        let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        memory.setEventHandler { @Sendable in
            MainActor.assumeIsolated {
                let event = PowerMonitor.shared.memorySource?.data ?? []
                PowerMonitor.shared.conditions.memory = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
                PowerMonitor.shared.publish()
            }
        }
        memory.resume()
        memorySource = memory

        // The person is typing, scrolling or dragging in the app: keep background work to a gentle level.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .leftMouseDragged]) { [weak self] event in
            self?.userDidSomething()
            return event
        }
    }

    func stop() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        runLoopSource = nil
        memorySource?.cancel()
        memorySource = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        idleTask?.cancel()
    }

    private func userDidSomething() {
        if !conditions.userActive {
            conditions.userActive = true
            publish()
        }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.conditions.userActive = false
            self.publish()
        }
    }

    private func refresh() {
        let info = ProcessInfo.processInfo
        var next = conditions
        next.lowPowerMode = info.isLowPowerModeEnabled
        next.thermal = switch info.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? {
            next.onBattery = type == kIOPSBatteryPowerValue
        }
        if next != conditions {
            conditions = next
            publish()
        }
    }

    private func publish() { onChange?(conditions) }
}
