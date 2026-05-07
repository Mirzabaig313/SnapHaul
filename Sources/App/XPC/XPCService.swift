// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
internal import CryptoKit
import SnapHaulKit
import os

/// XPC service that the host app exposes to extensions (File Provider, Finder Sync).
///
/// Registers a Mach service named "com.snaphaul.app.xpc" that extensions
/// connect to. Implements `SnapHaulXPCProtocol` by delegating to `AppState`.
///
/// Lifecycle: started once in `AppState.init()`, runs for the lifetime of the app.
final class XPCService: NSObject {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "xpc"
    )

    private var listener: NSXPCListener?

    /// Weak reference to AppState — the XPC handler delegates all work here.
    weak var appState: AppState?

    static let machServiceName = "com.snaphaul.app.xpc"

    // MARK: - Start / Stop

    func start() {
        let listener = NSXPCListener(machServiceName: Self.machServiceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
        logger.info("XPC service started on Mach service: \(Self.machServiceName)")
    }

    func stop() {
        listener?.invalidate()
        listener = nil
        logger.info("XPC service stopped")
    }
}

// MARK: - NSXPCListenerDelegate

extension XPCService: NSXPCListenerDelegate {

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Configure the connection
        newConnection.exportedInterface = NSXPCInterface(with: SnapHaulXPCProtocol.self)
        newConnection.exportedObject = XPCHandler(appState: appState)

        newConnection.invalidationHandler = { [weak self] in
            self?.logger.debug("XPC connection invalidated")
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.logger.debug("XPC connection interrupted")
        }

        newConnection.resume()
        logger.info("Accepted new XPC connection from extension")
        return true
    }
}

// MARK: - XPC Handler (implements the protocol)

/// Implements `SnapHaulXPCProtocol` on behalf of the host app.
/// Each method bridges from the XPC call to the async AppState methods.
///
/// Marked `@unchecked Sendable` because XPC reply handlers are inherently
/// cross-isolation — the XPC runtime calls methods from arbitrary threads.
/// Thread safety is guaranteed by delegating all mutable state access to
/// `AppState` (which is `@MainActor`) or to actor-isolated engines.
final class XPCHandler: NSObject, SnapHaulXPCProtocol, @unchecked Sendable {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "xpc-handler"
    )

    weak var appState: AppState?

    init(appState: AppState?) {
        self.appState = appState
    }

    // MARK: - Device Status

    func deviceStatus(reply: @escaping (Data?, Error?) -> Void) {
        nonisolated(unsafe) let reply = reply
        Task { @MainActor in
            guard let state = self.appState?.deviceState else {
                reply(nil, nil)
                return
            }
            do {
                let data = try JSONEncoder().encode(state)
                reply(data, nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    // MARK: - File Operations

    func listFiles(at path: String, reply: @escaping (Data?, Error?) -> Void) {
        nonisolated(unsafe) let reply = reply
        Task {
            do {
                guard let appState = self.appState else {
                    reply(nil, XPCError.noAppState)
                    return
                }
                let files = try await appState.listDeviceFiles(at: path)
                let data = try JSONEncoder().encode(files)
                reply(data, nil)
            } catch {
                self.logger.error("listFiles failed: \(error.localizedDescription)")
                reply(nil, error)
            }
        }
    }

    func pullFile(
        from remotePath: String,
        to localPath: String,
        reply: @escaping (UInt64, Error?) -> Void
    ) {
        nonisolated(unsafe) let reply = reply
        Task {
            do {
                guard let appState = self.appState else {
                    reply(0, XPCError.noAppState)
                    return
                }
                let localURL = URL(fileURLWithPath: localPath)
                let bytes = try await appState.pullFile(from: remotePath, to: localURL)
                reply(bytes, nil)
            } catch {
                self.logger.error("pullFile failed: \(error.localizedDescription)")
                reply(0, error)
            }
        }
    }

    func pushFile(
        from localPath: String,
        to remotePath: String,
        reply: @escaping (Bool, Error?) -> Void
    ) {
        nonisolated(unsafe) let reply = reply
        Task {
            do {
                guard let appState = self.appState else {
                    reply(false, XPCError.noAppState)
                    return
                }
                let localURL = URL(fileURLWithPath: localPath)
                try await appState.pushFile(from: localURL, to: remotePath)
                reply(true, nil)
            } catch {
                self.logger.error("pushFile failed: \(error.localizedDescription)")
                reply(false, error)
            }
        }
    }

    func deleteFile(at path: String, reply: @escaping (Bool, Error?) -> Void) {
        nonisolated(unsafe) let reply = reply
        Task {
            do {
                guard let appState = self.appState else {
                    reply(false, XPCError.noAppState)
                    return
                }
                guard let engine = await appState.activeEngine else {
                    reply(false, XPCError.noDevice)
                    return
                }
                try await engine.deleteFile(at: path)
                reply(true, nil)
            } catch {
                self.logger.error("deleteFile failed: \(error.localizedDescription)")
                reply(false, error)
            }
        }
    }

    func renameFile(at path: String, to newName: String, reply: @escaping (Bool, Error?) -> Void) {
        nonisolated(unsafe) let reply = reply
        Task {
            do {
                guard let appState = self.appState else {
                    reply(false, XPCError.noAppState)
                    return
                }
                guard let engine = await appState.activeEngine else {
                    reply(false, XPCError.noDevice)
                    return
                }
                try await engine.renameFile(at: path, to: newName)
                reply(true, nil)
            } catch {
                self.logger.error("renameFile failed: \(error.localizedDescription)")
                reply(false, error)
            }
        }
    }

    func transferProgress(reply: @escaping (Data?, Error?) -> Void) {
        nonisolated(unsafe) let reply = reply
        Task { @MainActor in
            guard let progress = self.appState?.transferProgress else {
                reply(nil, nil)
                return
            }
            do {
                let data = try JSONEncoder().encode(progress)
                reply(data, nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    // MARK: - Checksum

    func checksumLocalFile(at localPath: String, reply: @escaping (String?, Error?) -> Void) {
        nonisolated(unsafe) let reply = reply
        Task {
            do {
                let url = URL(fileURLWithPath: localPath)
                // Memory-mapped read for large files
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let digest = SHA256.hash(data: data)
                let hex = digest.map { String(format: "%02x", $0) }.joined()
                reply(hex, nil)
            } catch {
                self.logger.error("checksumLocalFile failed: \(error.localizedDescription)")
                reply(nil, error)
            }
        }
    }
}

// MARK: - XPC Errors

enum XPCError: LocalizedError {
    case noAppState
    case noDevice

    var errorDescription: String? {
        switch self {
        case .noAppState: return "Host app state is unavailable"
        case .noDevice: return "No Android device is connected"
        }
    }
}
