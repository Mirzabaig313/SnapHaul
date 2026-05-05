// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Connection state of an Android device.
public enum ConnectionStatus: String, Sendable, Codable {
    case disconnected
    case connecting
    case connected
    case transferring
    case error
}

/// Transfer engine currently in use.
public enum EngineType: String, Sendable, Codable {
    case mtp
    case adb
    case ptp
}

/// Represents the current state of a connected Android device.
public struct DeviceState: Sendable, Codable, Equatable {

    public let serialNumber: String
    public let displayName: String
    public let manufacturer: String
    public let model: String
    public let connectionStatus: ConnectionStatus
    public let engineType: EngineType?
    public let usbSpeedDescription: String?
    public let storageTotal: UInt64?
    public let storageFree: UInt64?

    public init(
        serialNumber: String,
        displayName: String,
        manufacturer: String,
        model: String,
        connectionStatus: ConnectionStatus,
        engineType: EngineType? = nil,
        usbSpeedDescription: String? = nil,
        storageTotal: UInt64? = nil,
        storageFree: UInt64? = nil
    ) {
        self.serialNumber = serialNumber
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.model = model
        self.connectionStatus = connectionStatus
        self.engineType = engineType
        self.usbSpeedDescription = usbSpeedDescription
        self.storageTotal = storageTotal
        self.storageFree = storageFree
    }

    /// Truncated serial for logging (last 4 characters). Never log the full serial.
    public var redactedSerial: String {
        guard serialNumber.count > 4 else { return "****" }
        return "***" + String(serialNumber.suffix(4))
    }
}
