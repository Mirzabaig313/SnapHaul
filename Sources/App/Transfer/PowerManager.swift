// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

@preconcurrency import Foundation
@preconcurrency import CoreFoundation
import IOKit.ps
import os

/// Monitors AC vs battery power state and provides transfer performance parameters.
@MainActor
final class PowerManager: ObservableObject {

    @Published private(set) var isOnBattery: Bool = false
    @Published var isAppForeground: Bool = true

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "power"
    )

    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var retainedSelf: Unmanaged<PowerManager>?

    init() {
        updatePowerState()
        startMonitoring()
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        retainedSelf?.release()
    }

    // MARK: - Performance Parameters

    var recommendedConcurrency: Int {
        isOnBattery ? 2 : 4
    }

    var recommendedQoS: DispatchQoS.QoSClass {
        if !isAppForeground { return .background }
        return isOnBattery ? .utility : .userInitiated
    }

    /// On battery, defer checksums to a single batch pass after transfer.
    var shouldDeferChecksums: Bool {
        isOnBattery
    }

    /// On battery, update UI less frequently to reduce P-core wake-ups.
    var progressUpdateInterval: Int {
        isOnBattery ? 5 : 1
    }

    // MARK: - Power State Detection

    private func updatePowerState() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]

        var onBattery = false
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let state = info[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSBatteryPowerValue {
                onBattery = true
                break
            }
        }

        if onBattery != isOnBattery {
            isOnBattery = onBattery
            logger.info("Power: \(onBattery ? "battery" : "AC")")
        }
    }

    private func startMonitoring() {
        let retained = Unmanaged.passRetained(self)
        self.retainedSelf = retained

        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let manager = Unmanaged<PowerManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                manager.updatePowerState()
            }
        }, retained.toOpaque()).takeRetainedValue()

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.runLoopSource = source
    }
}
