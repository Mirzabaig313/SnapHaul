// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// USB mode detected on the Android device.
public enum USBMode: String, Sendable {
    case mtp
    case ptp
    case adb
    case charging
    case unknown
}

/// Represents a physically connected USB device detected via IOKit.
public struct USBDevice: Sendable, Equatable {

    public let serialNumber: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let displayName: String
    public let manufacturer: String
    public let usbMode: USBMode
    public let usbSpeed: USBSpeed

    /// IOKit service handle for this device. Used by IOUSBHost transport to
    /// open the device with exclusive capture. The handle is retained by the
    /// caller (DeviceMonitor) and must be released when no longer needed.
    /// Value is 0 if the service handle is not available.
    public let ioService: UInt32

    public init(
        serialNumber: String,
        vendorID: UInt16,
        productID: UInt16,
        displayName: String,
        manufacturer: String,
        usbMode: USBMode,
        usbSpeed: USBSpeed,
        ioService: UInt32 = 0
    ) {
        self.serialNumber = serialNumber
        self.vendorID = vendorID
        self.productID = productID
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.usbMode = usbMode
        self.usbSpeed = usbSpeed
        self.ioService = ioService
    }
}

/// USB connection speed tier.
public enum USBSpeed: String, Sendable {
    case usb2     // 480 Mbps
    case usb3Gen1 // 5 Gbps
    case usb3Gen2 // 10 Gbps
    case unknown

    public var description: String {
        switch self {
        case .usb2: "USB 2.0"
        case .usb3Gen1: "USB 3.2 Gen 1"
        case .usb3Gen2: "USB 3.2 Gen 2"
        case .unknown: "USB"
        }
    }
}
