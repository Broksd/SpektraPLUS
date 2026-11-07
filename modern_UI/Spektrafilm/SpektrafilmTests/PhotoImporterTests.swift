import XCTest
@testable import SpektraLab

/// `PhotoImporter`: where each photograph goes, what is skipped, and that the
/// copy leaves the source alone.
final class PhotoImporterTests: XCTestCase {
    private func folder(_ files: [String: String] = [:]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (name, body) in files {
            let url = dir.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
        return dir
    }

    func testLayouts() {
        XCTAssertNil(DateFolderLayout.none.subpath(year: 2026, month: 11, day: 7))
        XCTAssertEqual(DateFolderLayout.yearThenDay.subpath(year: 2026, month: 11, day: 7), "2026/2026-11-07")
        XCTAssertEqual(DateFolderLayout.day.subpath(year: 2026, month: 1, day: 2), "2026-01-02")
        XCTAssertEqual(DateFolderLayout.yearMonthDay.subpath(year: 2026, month: 1, day: 2), "2026/01/02")
        XCTAssertEqual(DateFolderLayout.yearThenMonth.subpath(year: 2026, month: 1, day: 2), "2026/2026-01")
    }

    func testExifDays() {
        XCTAssertEqual(PhotoImporter.parseExifDay("2026:11:07 14:03:22").map { [$0.year, $0.month, $0.day] }, [2026, 11, 7])
        XCTAssertNil(PhotoImporter.parseExifDay("0000:00:00 00:00:00"), "an unset camera clock is not a day")
        XCTAssertNil(PhotoImporter.parseExifDay(""))
    }

    func testOnlyPhotographsAndSubfoldersOnRequest() throws {
        let src = try folder(["a.NEF": "1", "b.jpg": "2", "notes.txt": "x",
                              "DCIM/100MSDCF/c.ARW": "3", "x.spektrapair": "p"])
        XCTAssertEqual(PhotoImporter.photos(in: src, recursive: false).map(\.lastPathComponent), ["a.NEF", "b.jpg"])
        XCTAssertEqual(PhotoImporter.photos(in: src, recursive: true).map(\.lastPathComponent), ["a.NEF", "b.jpg", "c.ARW"])
    }

    func testFiledByDaySkippingWhatIsThereAndRenamingWhatDiffers() throws {
        let src = try folder(["a.jpg": "aaa", "b.jpg": "bbb", "c.jpg": "ccc"])
        let dst = try folder()
        let days: [String: (Int, Int, Int)] = ["a.jpg": (2026, 11, 7), "b.jpg": (2026, 11, 7), "c.jpg": (2026, 11, 8)]
        let day: (URL) -> (year: Int, month: Int, day: Int)? = { u in days[u.lastPathComponent].map { ($0.0, $0.1, $0.2) } }
        let photos = PhotoImporter.photos(in: src, recursive: false)

        let first = PhotoImporter.run(PhotoImporter.plan(photos, into: dst, layout: .yearThenDay, day: day))
        XCTAssertEqual(first.copied.count, 3)
        XCTAssertEqual(first.folders.map { $0.path.replacingOccurrences(of: dst.path + "/", with: "") },
                       ["2026/2026-11-07", "2026/2026-11-08"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appending(path: "2026/2026-11-07/b.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appending(path: "a.jpg").path), "the source stays")

        // The same card again: nothing new.
        let again = PhotoImporter.run(PhotoImporter.plan(photos, into: dst, layout: .yearThenDay, day: day))
        XCTAssertEqual(again.copied.count, 0)
        XCTAssertEqual(again.skipped, 3)

        // Another photograph with a taken name: kept beside it, renamed.
        let other = try folder(["a.jpg": "a different picture"])
        let plan = PhotoImporter.plan(PhotoImporter.photos(in: other, recursive: false), into: dst,
                                      layout: .yearThenDay, day: { _ in (2026, 11, 7) })
        XCTAssertEqual(plan.map(\.destination.lastPathComponent), ["a-1.jpg"])
        XCTAssertFalse(plan[0].skip)
    }

    func testTwoNewFilesWithOneNameBothArrive() throws {
        let src = try folder(["100/a.jpg": "one", "101/a.jpg": "two"])
        let dst = try folder()
        let plan = PhotoImporter.plan(PhotoImporter.photos(in: src, recursive: true), into: dst, layout: .none)
        XCTAssertEqual(plan.map(\.destination.lastPathComponent), ["a.jpg", "a-1.jpg"])
        XCTAssertEqual(PhotoImporter.run(plan).copied.count, 2)
    }

    @MainActor
    func testGridAndSingleAreOneSwitch() throws {
        let key = Session.uiKey + "viewMode"
        let saved = UserDefaults.standard.object(forKey: key)
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: key) }
        let suite = "spk-import-\(UUID().uuidString)"
        let s = Session(clipboardDefaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        s.viewMode = .grid
        XCTAssertTrue(s.showsGrid)
        s.snapshotPanelWidths = true
        XCTAssertFalse(s.showsGrid, "a capture shows the canvas")
        s.snapshotPanelWidths = false
        s.viewMode = .single
        XCTAssertFalse(s.showsGrid)
    }
}
