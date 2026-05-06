// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import IOKit
import IOKit.usb
import SnapHaulKit
import os

/// Monitors USB device connect/disconnect events via IOKit.
///
/// Uses `IOServiceAddMatchingNotification` for event-driven detection.
/// Runs its own RunLoop on a background thread. All IOKit resource
/// cleanup happens on that same thread to avoid data races.
final class DeviceMonitor: @unchecked Sendable {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "usb"
    )

    /// Called on the main thread when an Android device is connected.
    var onDeviceConnected: ((USBDevice) -> Void)?
    var onDeviceDisconnected: ((String) -> Void)?

    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var monitorThread: Thread?
    private var isRunning = false

    /// Signaled by the monitor thread just before it exits.
    /// `stopMonitoring()` waits on this to ensure `cleanupOnExit()` has
    /// run and `retainedSelf` has been released before we return.
    private let threadExitSemaphore = DispatchSemaphore(value: 0)

    /// Reference to the background thread's CFRunLoop so we can stop it
    /// from the main thread during shutdown.
    private var backgroundRunLoop: CFRunLoop?

    /// Retained reference to self, passed to IOKit callbacks.
    /// Must be released exactly once during cleanup.
    private var retainedSelf: Unmanaged<DeviceMonitor>?

    /// Known Android USB vendor IDs → manufacturer label.
    /// Used for display purposes. Detection gate uses `knownAndroidVIDs` (broader set).
    private static let androidVendors: [UInt16: String] = [
        0x04E8: "Samsung",
        0x18D1: "Google",
        0x054C: "Sony",
        0x2717: "Xiaomi",
        0x2A70: "OPPO",
        0x22D9: "OnePlus",
        0x22B8: "Motorola",
        0x1004: "LG",
        0x0BB4: "HTC",
        0x12D1: "Huawei",
        0x2A45: "Meizu",
        0x0FCE: "Sony",
        0x19D2: "ZTE",
        0x1532: "Razer",
        0x2D95: "vivo",
        0x3511: "Honor",
        0x2A96: "realme",
    ]

    /// Broader set of VIDs that indicate an Android device, including chipset-vendor
    /// VIDs used by brands we can't identify by VID alone (e.g., MediaTek for Transsion).
    /// Devices matching these VIDs pass the detection gate; brand is resolved later
    /// via the USB product string in DeviceQuirks.
    private static let knownAndroidVIDs: Set<UInt16> = {
        var vids = Set(androidVendors.keys)
        vids.insert(0x0E8D)  // MediaTek — used by Transsion (Tecno, Infinix, itel)
        vids.insert(0x2B4C)  // ZUK/Beijing SHENQI — possibly Nothing
        return vids
    }()

    // MARK: - Start / Stop

    /// Start listening for USB device events on a background thread.
    func startMonitoring() {
        guard !isRunning else { return }
        isRunning = true

        retainedSelf = Unmanaged.passRetained(self)

        let thread = Thread { [weak self] in
            self?.runMonitorLoop()
        }
        thread.name = "com.snaphaul.usb-monitor"
        thread.qualityOfService = .utility
        thread.start()
        monitorThread = thread

        logger.info("USB device monitoring started")
    }

    /// Stop listening and clean up IOKit resources.
    ///
    /// Signals the background run loop to exit, waits for it to finish,
    /// then releases all IOKit resources. Thread-safe — cleanup happens
    /// on the background thread via CFRunLoopStop.
    func stopMonitoring() {
        guard isRunning else { return }
        isRunning = false

        if let rl = backgroundRunLoop {
            CFRunLoopStop(rl)
        }

        // Wait for the monitor thread to fully exit — ensures cleanupOnExit()
        // has released retainedSelf before we return.
        _ = threadExitSemaphore.wait(timeout: .now() + 2)
        monitorThread = nil
        backgroundRunLoop = nil

        logger.info("USB device monitoring stopped")
    }

    deinit {
        // Signal the run loop to exit. cleanupOnExit() on the monitor thread
        // will release retainedSelf — we must NOT release it here too.
        if isRunning {
            isRunning = false
            if let rl = backgroundRunLoop {
                CFRunLoopStop(rl)
            }
        }
    }

    // MARK: - IOKit Monitor Loop

    private func runMonitorLoop() {
        backgroundRunLoop = CFRunLoopGetCurrent()

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.error("Failed to create IONotificationPort")
            cleanupOnExit()
            return
        }
        notificationPort = port

        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)

        guard let selfPtr = retainedSelf?.toOpaque() else {
            logger.error("No retained self pointer for IOKit callbacks")
            cleanupOnExit()
            return
        }

        guard let matching = IOServiceMatching(kIOUSBDeviceClassName) else {
            logger.error("Failed to create matching dictionary")
            cleanupOnExit()
            return
        }

        let addResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matching,
            deviceAddedCallback,
            selfPtr,
            &addedIterator
        )

        if addResult != KERN_SUCCESS {
            logger.error("Failed to register for device arrival: \(addResult)")
            cleanupOnExit()
            return
        }

        // Drain the iterator to arm the notification (required by IOKit)
        drainIterator(addedIterator, isArrival: true)

        guard let removalMatching = IOServiceMatching(kIOUSBDeviceClassName) else {
            logger.error("Failed to create removal matching dictionary")
            cleanupOnExit()
            return
        }

        let removeResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            removalMatching,
            deviceRemovedCallback,
            selfPtr,
            &removedIterator
        )

        if removeResult != KERN_SUCCESS {
            logger.error("Failed to register for device removal: \(removeResult)")
            cleanupOnExit()
            return
        }

        // Drain the removal iterator to arm it
        drainIterator(removedIterator, isArrival: false)

        logger.info("IOKit notifications registered, entering run loop")
        while isRunning && !Thread.current.isCancelled {
            CFRunLoopRunInMode(.defaultMode, 1.0, true)
        }

        // Clean up IOKit resources on this thread (same thread that created them)
        cleanupOnExit()

        logger.info("USB monitor run loop exited")

        // Signal that this thread has fully exited and retainedSelf is released.
        threadExitSemaphore.signal()
    }

    /// Release all IOKit resources. Must be called on the monitor thread.
    private func cleanupOnExit() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }

        retainedSelf?.release()
        retainedSelf = nil
    }

    // MARK: - IOKit Callbacks

    /// Called by IOKit when a USB device is connected.
    func handleDeviceAdded(_ iterator: io_iterator_t) {
        drainIterator(iterator, isArrival: true)
    }

    /// Called by IOKit when a USB device is removed.
    func handleDeviceRemoved(_ iterator: io_iterator_t) {
        drainIterator(iterator, isArrival: false)
    }

    /// Iterate through all devices in the iterator and process them.
    /// IOKit requires draining the iterator to arm the next notification.
    private func drainIterator(_ iterator: io_iterator_t, isArrival: Bool) {
        var service: io_service_t = IOIteratorNext(iterator)

        while service != 0 {
            if let usbDevice = extractDeviceInfo(from: service) {
                if isArrival {
                    handleAndroidDeviceArrival(usbDevice)
                } else {
                    handleAndroidDeviceRemoval(usbDevice)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    // MARK: - Device Info Extraction

    /// Extract USB device properties from an IOKit service object.
    ///
    /// Returns nil if the device is not a known Android device.
    /// Uses `knownAndroidVIDs` (broad set) for the detection gate, and
    /// `androidVendors` (labeled dictionary) for the manufacturer display name.
    private func extractDeviceInfo(from service: io_service_t) -> USBDevice? {
        var props: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            service, &props, kCFAllocatorDefault, 0
        )

        guard result == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let vendorID = (dict["idVendor"] as? Int).map { UInt16($0) } ?? 0
        let productID = (dict["idProduct"] as? Int).map { UInt16($0) } ?? 0

        // Gate: only process devices with known Android VIDs
        guard Self.knownAndroidVIDs.contains(vendorID) else {
            return nil
        }

        // Label: use the vendor dictionary if available, otherwise derive from product string
        let manufacturer = Self.androidVendors[vendorID] ?? "Android"

        let productName = dict["USB Product Name"] as? String
            ?? dict["Product Name"] as? String
            ?? "Android Device"

        let serialNumber = dict["kUSBSerialNumberString"] as? String
            ?? dict["USB Serial Number"] as? String
            ?? "unknown-\(vendorID)-\(productID)"

        let deviceSpeed = dict["Device Speed"] as? Int ?? 0
        let usbSpeed = Self.mapUSBSpeed(deviceSpeed)

        // USB mode detection from device-level properties is unreliable
        // because bInterfaceClass is on interface descriptors, not the device.
        // Default to .mtp for known Android vendors. Accurate detection
        // requires enumerating interface descriptors (Phase 2).
        let usbMode: USBMode = .mtp

        return USBDevice(
            serialNumber: serialNumber,
            vendorID: vendorID,
            productID: productID,
            displayName: productName,
            manufacturer: manufacturer,
            usbMode: usbMode,
            usbSpeed: usbSpeed
        )
    }

    /// Map IOKit device speed value to our USBSpeed enum.
    ///
    /// IOKit speed values:
    /// - 0 = Low Speed (1.5 Mbps)
    /// - 1 = Full Speed (12 Mbps)
    /// - 2 = High Speed (480 Mbps) = USB 2.0
    /// - 3 = Super Speed (5 Gbps) = USB 3.x Gen 1
    /// - 4 = Super Speed Plus (10 Gbps) = USB 3.x Gen 2
    /// - 5 = Super Speed Plus x2 (20 Gbps) = USB 3.2 Gen 2x2
    private static func mapUSBSpeed(_ speed: Int) -> USBSpeed {
        switch speed {
        case 0, 1: return .usb2
        case 2: return .usb2
        case 3: return .usb3Gen1
        case 4, 5: return .usb3Gen2
        default: return .unknown
        }
    }

    // MARK: - Event Handling

    private func handleAndroidDeviceArrival(_ device: USBDevice) {
        let vendorHex = String(device.vendorID, radix: 16, uppercase: true)
        logger.info(
            "Android device connected: \(device.displayName) [\(device.manufacturer)] vendor:0x\(vendorHex) mode:\(device.usbMode.rawValue) speed:\(device.usbSpeed.description)"
        )

        DispatchQueue.main.async { [weak self] in
            self?.onDeviceConnected?(device)
        }
    }

    private func handleAndroidDeviceRemoval(_ device: USBDevice) {
        let redactedSerial = device.serialNumber.count > 4
            ? "***" + String(device.serialNumber.suffix(4))
            : "****"

        logger.info("Android device disconnected: \(device.displayName) [\(redactedSerial)]")

        DispatchQueue.main.async { [weak self] in
            self?.onDeviceDisconnected?(device.serialNumber)
        }
    }
}

// MARK: - C Callback Trampolines

/// C function pointer callback for device arrival.
/// IOKit requires a C function pointer — we bridge back via `Unmanaged`.
private func deviceAddedCallback(
    refcon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let refcon = refcon else { return }
    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handleDeviceAdded(iterator)
}

/// C function pointer callback for device removal.
private func deviceRemovedCallback(
    refcon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let refcon = refcon else { return }
    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handleDeviceRemoved(iterator)
}
