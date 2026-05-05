// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Testing
import Foundation
@testable import SnapHaul

@Suite("NamingTemplate")
struct NamingTemplateTests {

    let testDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 3
        components.hour = 14
        components.minute = 30
        components.second = 45
        return Calendar.current.date(from: components)!
    }()

    @Test("Default template produces expected filename")
    func test_defaultTemplate_standardInput_producesExpectedFilename() {
        let template = NamingTemplate(template: "{date}_{camera}_{sequence}.{ext}")
        let result = template.apply(
            originalName: "IMG_20260503_143045.dng",
            date: testDate,
            cameraModel: "Galaxy S25 Ultra",
            sequenceNumber: 1
        )
        #expect(result == "20260503_GalaxyS25Ultra_0001.dng")
    }

    @Test("Template with time token")
    func test_timeTemplate_includesTime() {
        let template = NamingTemplate(template: "{date}_{time}_{original}.{ext}")
        let result = template.apply(
            originalName: "photo.arw",
            date: testDate,
            cameraModel: nil,
            sequenceNumber: 42
        )
        #expect(result == "20260503_143045_photo.arw")
    }

    @Test("Template with subfolder tokens")
    func test_subfolderTokens_resolveCorrectly() {
        let template = NamingTemplate(template: "{year}/{month}/{day}/{original}.{ext}")
        let result = template.apply(
            originalName: "video.mp4",
            date: testDate,
            cameraModel: "Pixel 9 Pro",
            sequenceNumber: 1
        )
        #expect(result == "2026/05/03/video.mp4")
    }

    @Test("Nil camera model uses Unknown")
    func test_nilCamera_usesUnknown() {
        let template = NamingTemplate(template: "{camera}_{sequence}.{ext}")
        let result = template.apply(
            originalName: "file.dng",
            date: testDate,
            cameraModel: nil,
            sequenceNumber: 7
        )
        #expect(result == "Unknown_0007.dng")
    }

    @Test("Sequence number zero-padded to 4 digits")
    func test_sequenceNumber_zeroPadded() {
        let template = NamingTemplate(template: "{sequence}.{ext}")
        let result = template.apply(
            originalName: "x.cr3",
            date: testDate,
            cameraModel: nil,
            sequenceNumber: 42
        )
        #expect(result == "0042.cr3")
    }

    @Test("Extension is lowercased")
    func test_extension_lowercased() {
        let template = NamingTemplate(template: "{original}.{ext}")
        let result = template.apply(
            originalName: "PHOTO.DNG",
            date: testDate,
            cameraModel: nil,
            sequenceNumber: 1
        )
        #expect(result == "PHOTO.dng")
    }
}
