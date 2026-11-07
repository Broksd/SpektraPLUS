//  FolderRecordTests.swift — the folder's own record: flags, the filter, the
//  frame that was open, and every frame's edits, read back when the folder is
//  chosen again.

import XCTest

@MainActor
final class FolderRecordTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FolderRecordStore.useForTests(true)
    }

    override func tearDown() {
        FolderRecordStore.useForTests(nil)
        super.tearDown()
    }

    private func makeFolder(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: FrameOrder.url(for: dir))
        }
        for n in names { try Data().write(to: dir.appending(path: n)) }
        return dir
    }

    private func session() throws -> Session {
        let suite = "spk-folder-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Session(clipboardDefaults: defaults)
    }

    private func names(_ frames: [Frame]) -> [String] { frames.map(\.id.lastPathComponent) }

    func testARecordRoundTripsAndToleratesMissingFields() throws {
        var record = FolderRecord()
        record.filter = .flagged
        record.current = "b.png"
        record.photos["a.png"] = .init(flag: .rejected, edited: Date(timeIntervalSince1970: 0), sidecar: Sidecar())
        record.log("flag", file: "b.png")
        let data = try FolderRecord.encoder().encode(record)
        let back = try FolderRecord.decoder().decode(FolderRecord.self, from: data)
        // Field by field, not `==`: ISO 8601 drops the history entry's
        // fractions of a second, and the sidecar's own codec is not an
        // identity for every field (see `Session.flushSave`).
        XCTAssertEqual(back.format, FolderRecord.formatName)
        XCTAssertEqual(back.filter, .flagged)
        XCTAssertEqual(back.current, "b.png")
        XCTAssertEqual(back.flag(of: "a.png"), .rejected)
        XCTAssertEqual(back.photos["a.png"]?.edited, Date(timeIntervalSince1970: 0))
        XCTAssertNotNil(back.photos["a.png"]?.sidecar)
        XCTAssertEqual(back.history.map(\.file), ["b.png"])
        XCTAssertEqual(back.history.map(\.action), ["flag"])

        let sparse = try FolderRecord.decoder().decode(FolderRecord.self, from: Data(#"{"photos":{"x.NEF":{"flag":"flagged"}}}"#.utf8))
        XCTAssertEqual(sparse.filter, .all)
        XCTAssertEqual(sparse.flag(of: "x.NEF"), .flagged)
        XCTAssertNil(sparse.photos["x.NEF"]?.sidecar)
    }

    func testARunOfEditsOnOneFrameIsOneHistoryEntry() {
        var record = FolderRecord()
        let t = Date()
        record.log("edit", file: "a", at: t)
        record.log("edit", file: "a", at: t.addingTimeInterval(10))
        record.log("edit", file: "b", at: t.addingTimeInterval(20))
        record.log("flag", file: "a", at: t.addingTimeInterval(30))
        XCTAssertEqual(record.history.map(\.action), ["edit", "edit", "flag"])
        XCTAssertEqual(record.history[0].time, t.addingTimeInterval(10))
    }

    func testFlagsFilterAndTheOpenFrameComeBackWithTheFolder() throws {
        let dir = try makeFolder(["a.png", "b.png", "c.png", "d.png"])
        let first = try session()
        first.open(urls: [dir])
        let urls = first.frames.map(\.id)
        XCTAssertFalse(FolderRecordStore.exists(in: dir), "opening alone writes nothing into the folder")

        first.setFlag(.flagged, for: [urls[0], urls[2]])
        first.setFlag(.rejected, for: [urls[3]])
        XCTAssertTrue(FolderRecordStore.exists(in: dir))
        first.flagFilter = .flagged
        XCTAssertEqual(names(first.visibleFrames), ["a.png", "c.png"])
        first.click(urls[2])

        let again = try session()
        again.open(urls: [dir])
        XCTAssertEqual(again.flag(of: urls[0]), .flagged)
        XCTAssertEqual(again.flag(of: urls[2]), .flagged)
        XCTAssertEqual(again.flag(of: urls[3]), .rejected)
        XCTAssertNil(again.flag(of: urls[1]))
        XCTAssertEqual(again.flagFilter, .flagged)
        XCTAssertEqual(again.selection, urls[2], "the frame that was open is open again")
        XCTAssertEqual(again.count(for: .unflagged), 1)
        XCTAssertEqual(again.count(for: .rejected), 1)
    }

    func testPAndXAreSwitches() throws {
        let dir = try makeFolder(["a.png", "b.png"])
        let s = try session()
        s.open(urls: [dir])
        s.click(s.frames[0].id)
        s.toggleFlag(.flagged)
        XCTAssertEqual(s.flag(of: s.frames[0].id), .flagged)
        s.toggleFlag(.flagged)
        XCTAssertNil(s.flag(of: s.frames[0].id))
        s.toggleFlag(.rejected)
        XCTAssertEqual(s.flag(of: s.frames[0].id), .rejected)
        s.toggleFlag(.flagged)
        XCTAssertEqual(s.flag(of: s.frames[0].id), .flagged, "X then P is a keeper, not a cleared flag")
    }

    func testSelectAllPicksWhatTheFilterShows() throws {
        let dir = try makeFolder(["a.png", "b.png", "c.png"])
        let s = try session()
        s.open(urls: [dir])
        let urls = s.frames.map(\.id)
        s.setFlag(.flagged, for: [urls[1], urls[2]])
        s.flagFilter = .flagged
        s.selectAllFrames()
        XCTAssertEqual(s.selectedFrames, [urls[1], urls[2]])
    }

    func testAnEditIsInTheFolderAndAnotherStoreReadsItBack() throws {
        let dir = try makeFolder(["a.png"])
        let image = dir.appending(path: "a.png")
        var sidecar = Sidecar()
        sidecar.noFilm = true
        try sidecar.save(for: image)
        let photo = try XCTUnwrap(FolderRecordStore.photo(for: image))
        XCTAssertEqual(photo.sidecar?.noFilm, true)
        XCTAssertNil(photo.sidecar?.source, "a path and an inode mean nothing on another Mac")

        // The application store is gone (another Mac, a cleared store): the
        // folder's copy is the frame's edit, and lands in the new store.
        let store = FileManager.default.temporaryDirectory.appending(path: "spk-folder-store-\(UUID().uuidString)")
        Sidecar.useStore(at: store)
        addTeardownBlock {
            Sidecar.useStore(at: nil)
            try? FileManager.default.removeItem(at: store)
        }
        let read = try XCTUnwrap(Sidecar.load(for: image))
        XCTAssertTrue(read.noFilm)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Sidecar.url(for: image).path))
    }

    func testTheStoreWinsWhenItIsTheNewerCopy() throws {
        let dir = try makeFolder(["a.png"])
        let image = dir.appending(path: "a.png")
        var sidecar = Sidecar()
        sidecar.noFilm = true
        try sidecar.save(for: image)
        // The folder was read-only for the next edit: only the store has it.
        FolderRecordStore.useForTests(false)
        sidecar.noFilm = false
        try sidecar.save(for: image)
        FolderRecordStore.useForTests(true)
        XCTAssertEqual(FolderRecordStore.photo(for: image)?.sidecar?.noFilm, true)
        XCTAssertEqual(Sidecar.load(for: image)?.noFilm, false)
    }

    func testAResetKeepsTheFlag() throws {
        let dir = try makeFolder(["a.png"])
        let image = dir.appending(path: "a.png")
        try Sidecar().save(for: image)
        FolderRecordStore.setFlag(.flagged, for: image)
        Sidecar.remove(for: image)
        let photo = try XCTUnwrap(FolderRecordStore.photo(for: image))
        XCTAssertNil(photo.sidecar)
        XCTAssertEqual(photo.flag, .flagged)
    }

    func testTheDraggedOrderTravelsWithTheFolder() throws {
        let dir = try makeFolder(["a.png", "b.png", "c.png"])
        let s = try session()
        s.open(urls: [dir])
        let urls = s.frames.map(\.id)
        s.moveFrame(urls[2], onto: urls[0])
        s.frameOrderChanged()
        XCTAssertEqual(FolderRecordStore.read(dir)?.order, ["c.png", "a.png", "b.png"])
        // Without this Mac's own copy of the order, the record's is used.
        try FileManager.default.removeItem(at: FrameOrder.url(for: dir))
        XCTAssertEqual(names(FrameOrder.applied(to: Library.frames(at: dir))), ["c.png", "a.png", "b.png"])
    }

    func testOffWritesNothing() throws {
        FolderRecordStore.useForTests(false)
        let dir = try makeFolder(["a.png"])
        let image = dir.appending(path: "a.png")
        try Sidecar().save(for: image)
        FolderRecordStore.setFlag(.flagged, for: image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: FolderRecordStore.url(for: dir).path))
    }

    func testFoldersAreAPageOfTheLeftRail() throws {
        let key = Session.uiKey + "leftRailPage"
        let saved = UserDefaults.standard.object(forKey: key)
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: key) }
        let s = try session()
        s.leftRailPage = .material
        s.leftCollapsed = true
        s.toggleFolderBrowser()
        XCTAssertEqual(s.leftRailPage, .folders)
        XCTAssertFalse(s.leftCollapsed, "⇧⌘L opens a folded rail on its Folders page")
        XCTAssertTrue(s.showsFolderBrowser)
        s.toggleFolderBrowser()
        XCTAssertEqual(s.leftRailPage, .material)
        XCTAssertFalse(s.showsFolderBrowser)
        s.leftRailPage = .folders
        s.snapshotPanelWidths = true
        XCTAssertFalse(s.showsFolderBrowser, "a capture shows Film and Print")
    }

    func testAFolderWithoutPhotographsStillOpens() throws {
        let s = try session()
        let photos = try makeFolder(["a.png", "b.png"])
        s.open(urls: [photos])
        XCTAssertEqual(s.frames.count, 2)
        // A year folder: only day folders inside.
        let year = try makeFolder([])
        try FileManager.default.createDirectory(at: year.appending(path: "2026-01-10"), withIntermediateDirectories: true)
        s.open(urls: [year])
        XCTAssertEqual(s.libraryFolder, year.standardizedFileURL, "the browser shows it as the open folder")
        XCTAssertTrue(s.frames.isEmpty, "the last folder's photographs are not left on screen")
        XCTAssertNil(s.selection)
    }

    func testFlagFilterAdmits() {
        XCTAssertTrue(FlagFilter.all.admits(.rejected))
        XCTAssertTrue(FlagFilter.unflagged.admits(nil))
        XCTAssertFalse(FlagFilter.unflagged.admits(.flagged))
        XCTAssertTrue(FlagFilter.rejected.admits(.rejected))
        XCTAssertFalse(FlagFilter.flagged.admits(nil))
    }
}
