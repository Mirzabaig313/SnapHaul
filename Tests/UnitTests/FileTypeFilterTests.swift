// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Testing
import Foundation
@testable import SnapHaul
import SnapHaulKit

@Suite("FileTypeFilter")
struct FileTypeFilterTests {

    @Test("Default media filter includes RAW formats")
    func test_defaultFilter_includesRAW() {
        let filter = FileTypeFilter.defaultMediaFilter
        #expect(filter.matches(filename: "photo.dng"))
        #expect(filter.matches(filename: "photo.arw"))
        #expect(filter.matches(filename: "photo.cr3"))
        #expect(filter.matches(filename: "photo.nef"))
        #expect(filter.matches(filename: "photo.raf"))
    }

    @Test("Default media filter includes video formats")
    func test_defaultFilter_includesVideo() {
        let filter = FileTypeFilter.defaultMediaFilter
        #expect(filter.matches(filename: "clip.mp4"))
        #expect(filter.matches(filename: "clip.mov"))
    }

    @Test("Default media filter excludes JPEG thumbnails")
    func test_defaultFilter_excludesJPEG() {
        let filter = FileTypeFilter.defaultMediaFilter
        #expect(!filter.matches(filename: "thumb.jpg"))
        #expect(!filter.matches(filename: "thumb.jpeg"))
        #expect(!filter.matches(filename: "thumb.png"))
    }

    @Test("Empty filter matches everything")
    func test_emptyFilter_matchesAll() {
        let filter = FileTypeFilter(include: [], exclude: [])
        #expect(filter.matches(filename: "anything.xyz"))
        #expect(filter.matches(filename: "file.txt"))
    }

    @Test("Exclude takes precedence over include")
    func test_excludePrecedence() {
        let filter = FileTypeFilter(include: ["jpg", "png"], exclude: ["jpg"])
        #expect(!filter.matches(filename: "photo.jpg"))
        #expect(filter.matches(filename: "photo.png"))
    }

    @Test("Case insensitive extension matching")
    func test_caseInsensitive() {
        let filter = FileTypeFilter(include: ["dng"], exclude: [])
        #expect(filter.matches(filename: "PHOTO.DNG"))
        #expect(filter.matches(filename: "photo.Dng"))
    }
}
