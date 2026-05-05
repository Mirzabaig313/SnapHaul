// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit

/// An ingest profile defines the rules for automated file transfer
/// from an Android device to the Mac.
public struct IngestProfile: Sendable, Codable, Identifiable {

    public let id: UUID
    public var name: String
    public var sourceDirectories: [String]
    public var fileTypeFilters: FileTypeFilter
    public var destinationPath: String
    public var namingTemplate: String
    public var subfolderStructure: String?
    public var postIngestAction: PostIngestAction
    public var autoTrigger: Bool
    public var checksumVerification: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        sourceDirectories: [String] = ["/DCIM/Camera"],
        fileTypeFilters: FileTypeFilter = .defaultMediaFilter,
        destinationPath: String,
        namingTemplate: String = "{date}_{camera}_{sequence}.{ext}",
        subfolderStructure: String? = "{year}/{month}/{day}",
        postIngestAction: PostIngestAction = .verifyOnly,
        autoTrigger: Bool = false,
        checksumVerification: Bool = true
    ) {
        self.id = id
        self.name = name
        self.sourceDirectories = sourceDirectories
        self.fileTypeFilters = fileTypeFilters
        self.destinationPath = destinationPath
        self.namingTemplate = namingTemplate
        self.subfolderStructure = subfolderStructure
        self.postIngestAction = postIngestAction
        self.autoTrigger = autoTrigger
        self.checksumVerification = checksumVerification
    }
}

/// Action to perform after successful file transfer.
public enum PostIngestAction: String, Sendable, Codable {
    case doNothing
    case verifyOnly
    case verifyAndDeleteFromDevice
}
