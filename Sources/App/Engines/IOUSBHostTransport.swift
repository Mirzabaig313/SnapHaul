// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//
// IOUSBHost-based USB transport for MTP.
//
// Replaces libusb with Apple's native IOUSBHost.framework (macOS 10.15+).
// Uses IOUSBHostObjectInitOptions.deviceCapture to forcefully detach macOS
// drivers (PTPCamera, ApplePhotoMTPClientAgent) and claim exclusive access
// to the Android device's MTP interface.
//
// Requires entitlement: com.apple.vm.device-access

import Foundation
import IOKit
import IOKit.usb
import IOUSBHost
import CMTPCore
import os

// MARK: - IOUSBHost Transport Errors

/// Errors specific to the IOUSBHost transport layer.
enum IOUSBHostTransportError: Error, LocalizedError, Sendable {
    case deviceNotFound
    case authorizationFailed(kern_return_t)
    case deviceCaptureFailed(String)
    case configurationNotFound
    case mtpInterfaceNotFound
    case interfaceServiceNotFound
    case endpointNotFound(String)
    case pipeCreationFailed(String)
    case transferFailed(String)
    case alreadyOpen
    case notOpen

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "USB device not found via IOUSBHost"
        case .authorizationFailed(let status):
            return "IOServiceAuthorize failed: \(status) — missing com.apple.vm.device-access entitlement?"
        case .deviceCaptureFailed(let reason):
            return "IOUSBHostDevice capture failed: \(reason)"
        case .configurationNotFound:
            return "No active USB configuration descriptor found"
        case .mtpInterfaceNotFound:
            return "No MTP interface found (need class 6/1/1 or vendor-specific with 2 bulk + 1 interrupt)"
        case .interfaceServiceNotFound:
            return "Could not find IOKit service for MTP interface"
        case .endpointNotFound(let detail):
            return "Required USB endpoint not found: \(detail)"
        case .pipeCreationFailed(let detail):
            return "Failed to create IOUSBHostPipe: \(detail)"
        case .transferFailed(let detail):
            return "USB transfer failed: \(detail)"
        case .alreadyOpen:
            return "Transport is already open"
        case .notOpen:
            return "Transport is not open"
        }
    }
}

// MARK: - MTP Interface Descriptor

/// Describes the MTP interface endpoints discovered on the device.
private struct MTPEndpointInfo {
    let interfaceNumber: Int
    let bulkInAddress: Int
    let bulkOutAddress: Int
    let interruptInAddress: Int
}

// MARK: - IOUSBHost Transport

/// Native macOS USB transport using IOUSBHost.framework.
///
/// This class manages the lifecycle of an IOUSBHostDevice and its pipes.
/// It provides `mtp_usb_interface_t` callbacks compatible with CMTPCore,
/// allowing the MTP protocol layer to perform USB I/O without knowing
/// whether libusb or IOUSBHost is the underlying transport.
///
/// Thread safety: All USB I/O is synchronous (blocking). The caller (MTPNativeEngine actor)
/// ensures serialized access. The C callbacks are invoked from CMTPCore's context
/// which runs within the actor's isolation.
final class IOUSBHostTransport: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.snaphaul.app", category: "usb-host")

    // MARK: - State

    private var hostDevice: IOUSBHostDevice?
    private var hostInterface: IOUSBHostInterface?
    private var bulkInPipe: IOUSBHostPipe?
    private var bulkOutPipe: IOUSBHostPipe?
    private var interruptPipe: IOUSBHostPipe?

    /// The io_service_t from IOKit device detection. Retained during transport lifetime.
    private var ioService: io_service_t = 0

    /// Whether the transport is currently open and ready for I/O.
    private(set) var isOpen: Bool = false

    /// Last error message for diagnostics.
    private(set) var lastError: String = ""

    /// Transfer timeout for bulk operations (10 seconds, matching libusb transport).
    private let bulkTimeout: TimeInterval = 10.0

    /// Transfer timeout for interrupt operations (1 second — events are non-critical).
    private let interruptTimeout: TimeInterval = 1.0

    /// DMA-optimized I/O buffers allocated via IOUSBHostObject.ioData(withCapacity:).
    /// Reused across transfers to avoid per-operation allocation.
    private var writeBuffer: NSMutableData?
    private var readBuffer: NSMutableData?

    /// Maximum buffer size for bulk transfers (4 MB — matches CMTPCore data_buf_size).
    private let maxBufferSize = 4 * 1024 * 1024

    // MARK: - Open / Close

    /// Open the USB transport for an MTP device using IOUSBHost with device capture.
    ///
    /// This forcefully detaches any macOS drivers (PTPCamera, Image Capture) from
    /// the device and claims exclusive access to the MTP interface.
    ///
    /// - Parameter service: The `io_service_t` from IOKit device detection.
    ///   This method retains its own reference — the caller keeps ownership of theirs.
    /// - Throws: `IOUSBHostTransportError` on failure.
    func open(ioService service: io_service_t) throws {
        guard !isOpen else { throw IOUSBHostTransportError.alreadyOpen }

        // Retain the io_service_t for our use
        IOObjectRetain(service)
        self.ioService = service

        logger.info("Opening IOUSBHost transport with device capture")

        // Step 1: Open the device with DeviceCapture option.
        // This forcefully terminates PTPCamera and detaches all macOS drivers,
        // giving us exclusive access to the USB device.
        do {
            let device = try IOUSBHostDevice(
                __ioService: service,
                options: .deviceCapture,
                queue: nil,
                interestHandler: nil
            )
            self.hostDevice = device
            logger.info("IOUSBHostDevice opened with device capture — macOS drivers detached")
        } catch {
            let nsError = error as NSError
            lastError = "IOUSBHostDevice init failed: \(nsError.localizedDescription) (code: \(nsError.code))"
            logger.error("\(self.lastError, privacy: .public)")
            cleanup()
            throw IOUSBHostTransportError.deviceCaptureFailed(lastError)
        }

        guard let device = hostDevice else {
            cleanup()
            throw IOUSBHostTransportError.deviceNotFound
        }

        // Step 2: Find the MTP interface endpoints from the configuration descriptor
        let endpointInfo: MTPEndpointInfo
        do {
            endpointInfo = try findMTPEndpoints(on: device)
        } catch {
            cleanup()
            throw error
        }

        logger.info("MTP endpoints found: interface=\(endpointInfo.interfaceNumber), bulkIn=0x\(String(endpointInfo.bulkInAddress, radix: 16)), bulkOut=0x\(String(endpointInfo.bulkOutAddress, radix: 16)), interrupt=0x\(String(endpointInfo.interruptInAddress, radix: 16))")

        // Step 3: Find the IOKit service for the MTP interface and open it
        do {
            let ifaceService = try findInterfaceService(
                deviceService: service,
                interfaceNumber: endpointInfo.interfaceNumber
            )
            defer { IOObjectRelease(ifaceService) }

            let iface = try IOUSBHostInterface(
                __ioService: ifaceService,
                options: [],
                queue: nil,
                interestHandler: nil
            )
            self.hostInterface = iface
        } catch {
            lastError = "Failed to open MTP interface: \(error.localizedDescription)"
            logger.error("\(self.lastError, privacy: .public)")
            cleanup()
            throw IOUSBHostTransportError.pipeCreationFailed(lastError)
        }

        guard let iface = hostInterface else {
            cleanup()
            throw IOUSBHostTransportError.mtpInterfaceNotFound
        }

        // Step 4: Create pipes for bulk-in, bulk-out, and interrupt-in endpoints
        do {
            bulkInPipe = try iface.copyPipe(withAddress: endpointInfo.bulkInAddress)
            bulkOutPipe = try iface.copyPipe(withAddress: endpointInfo.bulkOutAddress)

            if endpointInfo.interruptInAddress != 0 {
                interruptPipe = try iface.copyPipe(withAddress: endpointInfo.interruptInAddress)
            }
        } catch {
            lastError = "Failed to create USB pipes: \(error.localizedDescription)"
            logger.error("\(self.lastError, privacy: .public)")
            cleanup()
            throw IOUSBHostTransportError.pipeCreationFailed(lastError)
        }

        // Step 5: Pre-allocate DMA-optimized I/O buffers
        do {
            writeBuffer = try device.ioData(withCapacity: maxBufferSize)
            readBuffer = try device.ioData(withCapacity: maxBufferSize)
        } catch {
            // Non-fatal — fall back to regular NSMutableData
            logger.warning("Could not allocate DMA-optimized buffers: \(error.localizedDescription, privacy: .public) — using standard buffers")
            writeBuffer = NSMutableData(length: maxBufferSize)
            readBuffer = NSMutableData(length: maxBufferSize)
        }

        isOpen = true
        logger.info("IOUSBHost transport open — pipes ready for MTP I/O")
    }

    /// Close the transport and release all USB resources.
    func close() {
        guard isOpen else { return }
        logger.info("Closing IOUSBHost transport")

        // Destroy the device — this re-registers drivers (PTPCamera will come back)
        hostDevice?.destroy()
        cleanup()
    }

    /// Build an `mtp_usb_interface_t` struct with callbacks pointing to this transport.
    ///
    /// The returned struct is valid only while this transport instance is alive and open.
    /// The `context` field points to this instance via `Unmanaged` — the caller must
    /// ensure the transport outlives the MTP session.
    ///
    /// - Returns: A populated `mtp_usb_interface_t` for use with CMTPCore.
    func makeUSBInterface() -> mtp_usb_interface_t {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        return mtp_usb_interface_t(
            bulk_write: ioUSBHostBulkWrite,
            bulk_read: ioUSBHostBulkRead,
            interrupt_read: ioUSBHostInterruptRead,
            context: selfPtr
        )
    }

    // MARK: - USB I/O (called from C callbacks)

    /// Write data to the bulk-out pipe (sends MTP commands/data to device).
    func bulkWrite(data: UnsafeRawPointer, length: Int) -> Int {
        guard let pipe = bulkOutPipe else {
            lastError = "Bulk-out pipe not available"
            return -1
        }

        // Copy data into an NSMutableData for IOUSBHost API
        let ioData = NSMutableData(bytes: data, length: length)

        var bytesTransferred: Int = 0
        do {
            try pipe.__sendIORequest(with: ioData, bytesTransferred: &bytesTransferred, completionTimeout: bulkTimeout)
            return bytesTransferred
        } catch {
            lastError = "Bulk write failed: \(error.localizedDescription)"
            return -1
        }
    }

    /// Read data from the bulk-in pipe (receives MTP responses/data from device).
    func bulkRead(buffer: UnsafeMutableRawPointer, maxLength: Int) -> Int {
        guard let pipe = bulkInPipe else {
            lastError = "Bulk-in pipe not available"
            return -1
        }

        // Use a pre-sized NSMutableData for the read
        let ioData = NSMutableData(length: maxLength) ?? NSMutableData()

        var bytesTransferred: Int = 0
        do {
            try pipe.__sendIORequest(with: ioData, bytesTransferred: &bytesTransferred, completionTimeout: bulkTimeout)

            // Copy received data into the caller's buffer
            if bytesTransferred > 0 {
                memcpy(buffer, ioData.bytes, min(bytesTransferred, maxLength))
            }
            return bytesTransferred
        } catch {
            lastError = "Bulk read failed: \(error.localizedDescription)"
            return -1
        }
    }

    /// Read from the interrupt-in pipe (receives MTP event notifications).
    func interruptRead(buffer: UnsafeMutableRawPointer, maxLength: Int) -> Int {
        guard let pipe = interruptPipe else {
            // No interrupt endpoint — not an error, just no events
            return -1
        }

        let ioData = NSMutableData(length: maxLength) ?? NSMutableData()

        var bytesTransferred: Int = 0
        do {
            try pipe.__sendIORequest(with: ioData, bytesTransferred: &bytesTransferred, completionTimeout: interruptTimeout)

            if bytesTransferred > 0 {
                memcpy(buffer, ioData.bytes, min(bytesTransferred, maxLength))
            }
            return bytesTransferred
        } catch {
            // Timeout on interrupt is normal (no pending events) — return 0
            return 0
        }
    }

    // MARK: - Interface & Endpoint Discovery

    /// Find the MTP interface endpoints by parsing the configuration descriptor.
    ///
    /// Two-pass approach:
    /// 1. Standard MTP: USB Still Image class (6/1/1)
    /// 2. Vendor-specific (0xFF) with MTP-like topology (2 bulk + 1 interrupt)
    private func findMTPEndpoints(on device: IOUSBHostDevice) throws -> MTPEndpointInfo {
        guard let configDescriptor = device.configurationDescriptor else {
            throw IOUSBHostTransportError.configurationNotFound
        }

        // Parse the raw configuration descriptor bytes
        let configLength = Int(configDescriptor.pointee.wTotalLength)
        let configPtr = UnsafeRawPointer(configDescriptor)
        let configData = Data(bytes: configPtr, count: configLength)

        // Pass 1: Standard MTP interface (class 6, subclass 1, protocol 1)
        if let info = scanForMTPEndpoints(in: configData, classFilter: 6, subclassFilter: 1, protocolFilter: 1) {
            return info
        }

        // Pass 2: Vendor-specific (0xFF) with 3 endpoints (2 bulk + 1 interrupt)
        if let info = scanForVendorMTPEndpoints(in: configData) {
            return info
        }

        throw IOUSBHostTransportError.mtpInterfaceNotFound
    }

    /// Scan configuration descriptor for a standard MTP interface.
    private func scanForMTPEndpoints(
        in configData: Data,
        classFilter: UInt8,
        subclassFilter: UInt8,
        protocolFilter: UInt8
    ) -> MTPEndpointInfo? {
        var offset = 0
        var currentInterfaceNumber: Int?
        var bulkIn: Int?
        var bulkOut: Int?
        var interruptIn: Int?

        while offset < configData.count {
            let length = Int(configData[offset])
            guard length >= 2, offset + length <= configData.count else { break }

            let descriptorType = configData[offset + 1]

            // Interface descriptor (type 4)
            if descriptorType == 4 && length >= 9 {
                // If we already found a matching interface, check if it's complete
                if currentInterfaceNumber != nil {
                    if let bi = bulkIn, let bo = bulkOut {
                        return MTPEndpointInfo(
                            interfaceNumber: currentInterfaceNumber!,  // safe: guarded by != nil
                            bulkInAddress: bi,
                            bulkOutAddress: bo,
                            interruptInAddress: interruptIn ?? 0
                        )
                    }
                }

                let bInterfaceClass = configData[offset + 5]
                let bInterfaceSubClass = configData[offset + 6]
                let bInterfaceProtocol = configData[offset + 7]

                if bInterfaceClass == classFilter &&
                   bInterfaceSubClass == subclassFilter &&
                   bInterfaceProtocol == protocolFilter {
                    currentInterfaceNumber = Int(configData[offset + 2])
                    bulkIn = nil
                    bulkOut = nil
                    interruptIn = nil
                } else {
                    currentInterfaceNumber = nil
                }
            }

            // Endpoint descriptor (type 5)
            if descriptorType == 5 && length >= 7 && currentInterfaceNumber != nil {
                let address = configData[offset + 2]
                let attributes = configData[offset + 3]

                let transferType = attributes & 0x03
                let direction = address & 0x80  // 0x80 = IN, 0x00 = OUT

                if transferType == 2 {  // Bulk
                    if direction != 0 {
                        bulkIn = Int(address)
                    } else {
                        bulkOut = Int(address)
                    }
                } else if transferType == 3 && direction != 0 {  // Interrupt IN
                    interruptIn = Int(address)
                }
            }

            offset += length
        }

        // Check final interface
        if let ifaceNum = currentInterfaceNumber, let bi = bulkIn, let bo = bulkOut {
            return MTPEndpointInfo(
                interfaceNumber: ifaceNum,
                bulkInAddress: bi,
                bulkOutAddress: bo,
                interruptInAddress: interruptIn ?? 0
            )
        }

        return nil
    }

    /// Scan for vendor-specific (class 0xFF) interface with MTP-like endpoint topology.
    /// Requires exactly 3 endpoints: 2 bulk (1 in + 1 out) + 1 interrupt-in.
    private func scanForVendorMTPEndpoints(in configData: Data) -> MTPEndpointInfo? {
        var offset = 0

        struct InterfaceCandidate {
            let number: Int
            var endpoints: [(address: UInt8, attributes: UInt8)] = []
        }

        var candidates: [InterfaceCandidate] = []
        var current: InterfaceCandidate?

        while offset < configData.count {
            let length = Int(configData[offset])
            guard length >= 2, offset + length <= configData.count else { break }

            let descriptorType = configData[offset + 1]

            // Interface descriptor
            if descriptorType == 4 && length >= 9 {
                if let c = current {
                    candidates.append(c)
                }

                let bInterfaceClass = configData[offset + 5]
                if bInterfaceClass == 0xFF {
                    current = InterfaceCandidate(number: Int(configData[offset + 2]))
                } else {
                    current = nil
                }
            }

            // Endpoint descriptor
            if descriptorType == 5 && length >= 7 && current != nil {
                let address = configData[offset + 2]
                let attributes = configData[offset + 3]
                current?.endpoints.append((address: address, attributes: attributes))
            }

            offset += length
        }

        if let c = current {
            candidates.append(c)
        }

        // Find a candidate with exactly 2 bulk + 1 interrupt
        for candidate in candidates {
            guard candidate.endpoints.count == 3 else { continue }

            var bulkIn: Int?
            var bulkOut: Int?
            var interruptIn: Int?
            var bulkCount = 0
            var interruptCount = 0

            for ep in candidate.endpoints {
                let transferType = ep.attributes & 0x03
                let direction = ep.address & 0x80

                if transferType == 2 {  // Bulk
                    bulkCount += 1
                    if direction != 0 {
                        bulkIn = Int(ep.address)
                    } else {
                        bulkOut = Int(ep.address)
                    }
                } else if transferType == 3 && direction != 0 {  // Interrupt IN
                    interruptCount += 1
                    interruptIn = Int(ep.address)
                }
            }

            if let bi = bulkIn, let bo = bulkOut,
               bulkCount == 2, interruptCount == 1 {
                return MTPEndpointInfo(
                    interfaceNumber: candidate.number,
                    bulkInAddress: bi,
                    bulkOutAddress: bo,
                    interruptInAddress: interruptIn ?? 0
                )
            }
        }

        return nil
    }

    /// Find the IOKit service for a specific USB interface on the device.
    ///
    /// IOUSBHost requires an `io_service_t` for the interface (not the device) to
    /// create an `IOUSBHostInterface`. We find it by iterating the device's children
    /// in the IORegistry and matching on bInterfaceNumber.
    private func findInterfaceService(deviceService: io_service_t, interfaceNumber: Int) throws -> io_service_t {
        var iterator: io_iterator_t = 0
        let result = IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &iterator)
        guard result == KERN_SUCCESS else {
            throw IOUSBHostTransportError.interfaceServiceNotFound
        }
        defer { IOObjectRelease(iterator) }

        var child = IOIteratorNext(iterator)
        while child != 0 {
            // Check if this child is the interface we want
            var props: Unmanaged<CFMutableDictionary>?
            let propResult = IORegistryEntryCreateCFProperties(child, &props, kCFAllocatorDefault, 0)

            if propResult == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let ifaceNum = dict["bInterfaceNumber"] as? Int,
               ifaceNum == interfaceNumber {
                // Found it — return without releasing (caller will release)
                return child
            }

            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }

        throw IOUSBHostTransportError.interfaceServiceNotFound
    }

    // MARK: - Cleanup

    private func cleanup() {
        isOpen = false

        writeBuffer = nil
        readBuffer = nil
        interruptPipe = nil
        bulkOutPipe = nil
        bulkInPipe = nil

        if let iface = hostInterface {
            iface.destroy()
            hostInterface = nil
        }

        // Don't destroy hostDevice here — it's destroyed in close()
        hostDevice = nil

        if ioService != 0 {
            IOObjectRelease(ioService)
            ioService = 0
        }
    }

    deinit {
        if isOpen {
            hostDevice?.destroy()
            cleanup()
        } else if ioService != 0 {
            IOObjectRelease(ioService)
        }
    }
}

// MARK: - C Callback Trampolines
//
// These match the exact signatures in mtp_usb_interface_t:
//   ssize_t (*bulk_write)(const void *data, size_t length, void *context);
//   ssize_t (*bulk_read)(void *buffer, size_t max_length, void *context);
//   ssize_t (*interrupt_read)(void *buffer, size_t max_length, void *context);

/// Bulk write callback for CMTPCore — bridges to IOUSBHostTransport.bulkWrite().
private func ioUSBHostBulkWrite(
    _ data: UnsafeRawPointer?,
    _ length: Int,
    _ context: UnsafeMutableRawPointer?
) -> Int {
    guard let context, let data else { return -1 }
    let transport = Unmanaged<IOUSBHostTransport>.fromOpaque(context).takeUnretainedValue()
    return transport.bulkWrite(data: data, length: length)
}

/// Bulk read callback for CMTPCore — bridges to IOUSBHostTransport.bulkRead().
private func ioUSBHostBulkRead(
    _ buffer: UnsafeMutableRawPointer?,
    _ maxLength: Int,
    _ context: UnsafeMutableRawPointer?
) -> Int {
    guard let context, let buffer else { return -1 }
    let transport = Unmanaged<IOUSBHostTransport>.fromOpaque(context).takeUnretainedValue()
    return transport.bulkRead(buffer: buffer, maxLength: maxLength)
}

/// Interrupt read callback for CMTPCore — bridges to IOUSBHostTransport.interruptRead().
private func ioUSBHostInterruptRead(
    _ buffer: UnsafeMutableRawPointer?,
    _ maxLength: Int,
    _ context: UnsafeMutableRawPointer?
) -> Int {
    guard let context, let buffer else { return -1 }
    let transport = Unmanaged<IOUSBHostTransport>.fromOpaque(context).takeUnretainedValue()
    return transport.interruptRead(buffer: buffer, maxLength: maxLength)
}
