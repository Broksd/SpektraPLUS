import XCTest

/// The folder browser's Places and Favorites.
@MainActor
final class FolderTreeTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "spk-tree-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return d
    }

    private func library() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "2026/2026-01-10"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.standardizedFileURL
    }

    func testFavoritesAreKeptBetweenLaunches() throws {
        let d = try defaults(), lib = try library()
        FolderTree(defaults: d).addFavorite(lib)
        let again = FolderTree(defaults: d)
        XCTAssertEqual(again.favorites.map(\.standardizedFileURL.path), [lib.path])
        XCTAssertEqual(again.rows(in: .favorites).first.map { again.kind(of: $0) }, .favorite)
        again.removeFavorite(lib)
        XCTAssertTrue(FolderTree(defaults: d).favorites.isEmpty)
    }

    func testAddedPlacesBecomeFavorites() throws {
        let d = try defaults(), lib = try library()
        d.set([lib.path], forKey: FolderTree.rootsKey)
        XCTAssertEqual(FolderTree(defaults: d).favorites.map(\.standardizedFileURL.path), [lib.path])
    }

    func testOpeningAFolderUnderAFavoriteRevealsItThere() throws {
        let d = try defaults(), lib = try library()
        let tree = FolderTree(defaults: d)
        tree.addFavorite(lib)
        tree.toggleFolded(.favorites)
        let day = lib.appending(path: "2026/2026-01-10")
        let id = tree.reveal(day)
        XCTAssertEqual(id, FolderTree.rowID(day, .favorites))
        XCTAssertFalse(tree.isFolded(.favorites), "a folded section opens to show the folder")
        XCTAssertTrue(tree.rows(in: .favorites).contains { $0.id == id })
        XCTAssertFalse(tree.isExpanded(lib.appending(path: "2026"), in: .places),
                       "the same folder under Places is left as it was")
    }

    func testAFoldedSectionHasNoRows() throws {
        let d = try defaults(), lib = try library()
        let tree = FolderTree(defaults: d)
        tree.addFavorite(lib)
        tree.toggleFolded(.favorites)
        XCTAssertTrue(tree.rows(in: .favorites).isEmpty)
        XCTAssertTrue(FolderTree(defaults: d).isFolded(.favorites), "folding is remembered")
    }
}
