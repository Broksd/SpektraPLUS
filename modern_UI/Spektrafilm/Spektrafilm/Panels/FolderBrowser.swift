//  FolderBrowser.swift — the folder tree, the left rail's Folders page.
//
//  Two lists, each folder opening into its subfolders: Places (the home
//  folder, Pictures, every mounted disk and card) and Favorites (folders the
//  person keeps — a NAS photo library, say — remembered between launches).
//  A click on a folder opens it: its photographs fill the filmstrip and its
//  record (`FolderRecord`) brings back the flags, the filter, the frame that
//  was open and every edit. A folder that has a record carries a small dot.
//
//  Under the tree, the flag filter: All, Flagged, Unflagged, Rejected, with
//  how many frames each one shows. P, X and U set the flags (Library menu).
//
//  Nothing is listed until it is expanded, so opening the window does not
//  ask macOS for every protected folder at once.

import AppKit
import SwiftUI

@MainActor
@Observable
final class FolderTree {
    /// The folders the person added before Favorites existed; read once and
    /// moved into `favoritesKey`.
    nonisolated static let rootsKey = "library.roots"
    nonisolated static let favoritesKey = "library.favorites"
    nonisolated static let expandedKey = "library.expanded"
    nonisolated static let foldedKey = "library.foldedSections"

    /// Places: the home folder, Pictures and every mounted disk, found anew
    /// each launch. Favorites: the person's own folders — a NAS photo
    /// library, a project — kept between launches.
    enum Section: String, CaseIterable { case places, favorites }

    struct Row: Identifiable, Equatable {
        let url: URL
        let depth: Int
        let section: Section
        /// One folder can be in both sections, so a row is named by both.
        var id: String { FolderTree.rowID(url, section) }
    }

    enum RootKind { case home, pictures, volume, favorite }

    nonisolated static func rowID(_ url: URL, _ section: Section) -> String {
        "\(section.rawValue):\(url.standardizedFileURL.path)"
    }

    private let defaults: UserDefaults
    private(set) var places: [(url: URL, kind: RootKind)] = []
    private(set) var favorites: [URL] = []
    /// Expanded rows by `rowID`, so a folder opened under Favorites does not
    /// open the same folder deep in the home tree.
    private(set) var expanded: Set<String>
    private(set) var folded: Set<String>
    /// Subfolders by folder path, listed on first expansion. Caches, filled
    /// while the tree is drawn, so not observed: `revision` is what a view
    /// re-reads when one is dropped.
    @ObservationIgnored private var children: [String: [URL]] = [:]
    @ObservationIgnored private var records: [String: Bool] = [:]
    private var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expanded = Set(defaults.stringArray(forKey: Self.expandedKey) ?? [])
        folded = Set(defaults.stringArray(forKey: Self.foldedKey) ?? [])
        if defaults.object(forKey: Self.favoritesKey) == nil {
            defaults.set(defaults.stringArray(forKey: Self.rootsKey) ?? [], forKey: Self.favoritesKey)
        }
        reloadRoots()
    }

    func reloadRoots() {
        let fm = FileManager.default
        var out: [(url: URL, kind: RootKind)] = []
        out.append((fm.homeDirectoryForCurrentUser, .home))
        if let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first {
            out.append((pictures, .pictures))
        }
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey],
                                           options: [.skipHiddenVolumes]) ?? []
        for v in volumes where v.path != "/" { out.append((v, .volume)) }
        places = out
        favorites = (defaults.stringArray(forKey: Self.favoritesKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Forget every listing: folders made or removed in Finder show up.
    func refresh() {
        children = [:]
        records = [:]
        revision += 1
        reloadRoots()
    }

    func roots(in section: Section) -> [URL] {
        section == .places ? places.map(\.url) : favorites
    }

    func rows(in section: Section) -> [Row] {
        _ = revision
        guard !isFolded(section) else { return [] }
        var out: [Row] = []
        func walk(_ url: URL, _ depth: Int) {
            out.append(Row(url: url, depth: depth, section: section))
            guard isExpanded(url, in: section) else { return }
            for c in subfolders(of: url) { walk(c, depth + 1) }
        }
        for r in roots(in: section) { walk(r, 0) }
        return out
    }

    /// What a top-level row is; nil below the top.
    func kind(of row: Row) -> RootKind? {
        guard row.depth == 0 else { return nil }
        return row.section == .favorites ? .favorite : places.first { $0.url.path == row.url.path }?.kind
    }

    func isFolded(_ section: Section) -> Bool { folded.contains(section.rawValue) }

    func toggleFolded(_ section: Section) {
        if folded.contains(section.rawValue) { folded.remove(section.rawValue) } else { folded.insert(section.rawValue) }
        defaults.set(Array(folded), forKey: Self.foldedKey)
    }

    func isExpanded(_ url: URL, in section: Section) -> Bool { expanded.contains(Self.rowID(url, section)) }

    /// Whether a disclosure arrow is worth drawing: unknown until listed, so
    /// an unlisted folder gets one.
    func mayHaveSubfolders(_ url: URL) -> Bool {
        guard let listed = children[url.path] else { return true }
        return !listed.isEmpty
    }

    func toggle(_ url: URL, in section: Section) {
        let id = Self.rowID(url, section)
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        defaults.set(Array(expanded), forKey: Self.expandedKey)
    }

    /// Open every ancestor of `folder` under the deepest root that holds it
    /// — a favorite before a place — and say which row is the folder's.
    @discardableResult
    func reveal(_ folder: URL) -> String? {
        let path = folder.standardizedFileURL.path
        for section in [Section.favorites, .places] {
            let holders = roots(in: section).filter { path == $0.standardizedFileURL.path || path.hasPrefix($0.standardizedFileURL.path + "/") }
            guard let root = holders.max(by: { $0.path.count < $1.path.count }) else { continue }
            if isFolded(section) { toggleFolded(section) }
            var cursor = folder.standardizedFileURL.deletingLastPathComponent()
            while cursor.path.count >= root.standardizedFileURL.path.count, path != root.standardizedFileURL.path {
                expanded.insert(Self.rowID(cursor, section))
                if cursor.path == root.standardizedFileURL.path { break }
                cursor = cursor.deletingLastPathComponent()
            }
            defaults.set(Array(expanded), forKey: Self.expandedKey)
            return Self.rowID(folder, section)
        }
        return nil
    }

    func subfolders(of url: URL) -> [URL] {
        if let hit = children[url.path] { return hit }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let folders = items.filter { item in
            guard let v = try? item.resourceValues(forKeys: Set(keys)) else { return false }
            return v.isDirectory == true && v.isPackage != true && v.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        children[url.path] = folders
        return folders
    }

    /// Whether the folder has a `SpektraLab.folder.json`.
    func hasRecord(_ url: URL) -> Bool {
        _ = revision
        if let hit = records[url.path] { return hit }
        let has = FolderRecordStore.exists(in: url)
        records[url.path] = has
        return has
    }

    /// The open folder's record may have been written since it was listed.
    func recordChanged(in url: URL) {
        records[url.path] = nil
        revision += 1
    }

    func isFavorite(_ url: URL) -> Bool {
        favorites.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    func addFavorite(_ url: URL) {
        var paths = defaults.stringArray(forKey: Self.favoritesKey) ?? []
        let path = url.standardizedFileURL.path
        guard !paths.contains(path) else { return }
        paths.append(path)
        defaults.set(paths, forKey: Self.favoritesKey)
        if isFolded(.favorites) { toggleFolded(.favorites) }
        reloadRoots()
    }

    func removeFavorite(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = (defaults.stringArray(forKey: Self.favoritesKey) ?? []).filter { $0 != path }
        defaults.set(paths, forKey: Self.favoritesKey)
        reloadRoots()
    }

    func chooseFavorite() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = L("Add folders to Favorites.", zh: "把文件夹加入收藏。")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFavorite(url) }
    }
}

struct FolderBrowser: View {
    @Bindable var session: Session
    @Bindable var tree: FolderTree

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        sectionHeader(.places, L("Places", zh: "位置"))
                        ForEach(tree.rows(in: .places)) { row in
                            FolderRow(row: row, tree: tree, session: session).id(row.id)
                        }
                        sectionHeader(.favorites, L("Favorites", zh: "收藏")) {
                            PanelIconButton(systemImage: "plus",
                                            help: L("Add a folder to Favorites", zh: "添加文件夹到收藏")) {
                                tree.chooseFavorite()
                            }
                        }
                        .padding(.top, 6)
                        ForEach(tree.rows(in: .favorites)) { row in
                            FolderRow(row: row, tree: tree, session: session).id(row.id)
                        }
                        if tree.favorites.isEmpty && !tree.isFolded(.favorites) {
                            Text(L("Right-click a folder to add it here.", zh: "在文件夹上右键即可加入收藏。"))
                                .font(Theme.Font.small).foregroundStyle(Theme.dim)
                                .padding(.leading, 26).padding(.vertical, 4)
                        }
                    }
                    .padding(.bottom, 6)
                }
                // A flag or an edit can be what first writes the folder's
                // record: its dot appears without a refresh.
                .onChange(of: session.flags) { _, _ in
                    if let folder = session.libraryFolder { tree.recordChanged(in: folder) }
                }
                .onChange(of: session.frameStates) { _, _ in
                    if let folder = session.libraryFolder { tree.recordChanged(in: folder) }
                }
                // A folder opened while this page was not on screen.
                .onAppear {
                    guard let folder = session.libraryFolder, let id = tree.reveal(folder) else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: session.libraryFolder) { _, folder in
                    guard let folder else { return }
                    let id = tree.reveal(folder)
                    tree.recordChanged(in: folder)
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Hairline()
            FlagFilterList(session: session)
        }
    }

    /// A section's title; a click folds it.
    private func sectionHeader<Trailing: View>(_ section: FolderTree.Section, _ title: String,
                                               @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Theme.dim)
                .rotationEffect(.degrees(tree.isFolded(section) ? 0 : 90))
                .frame(width: 10)
            Text(title).font(Theme.Font.small).foregroundStyle(Theme.dim)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { tree.toggleFolded(section) } }
    }

    /// The browser's own tools, under the rail's tabs.
    private var toolbar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            PanelIconButton(systemImage: "arrow.clockwise",
                            help: L("Refresh the folder list", zh: "刷新文件夹列表")) { tree.refresh() }
            PanelIconButton(systemImage: "square.and.arrow.down.on.square",
                            help: L("Import Photos… (⇧⌘I)", zh: "导入照片…（⇧⌘I）")) { session.showImport = true }
                .padding(.trailing, 6)
        }
        .frame(height: 28)
    }
}

private struct FolderRow: View {
    let row: FolderTree.Row
    @Bindable var tree: FolderTree
    @Bindable var session: Session

    private var isOpen: Bool { session.libraryFolder?.standardizedFileURL.path == row.url.standardizedFileURL.path }

    private var icon: String {
        switch tree.kind(of: row) {
        case .home?: "house"
        case .pictures?: "photo.on.rectangle"
        case .volume?: "externaldrive"
        case .favorite?: "star"
        case nil: isOpen ? "folder.fill" : "folder"
        }
    }

    private var title: String {
        let fm = FileManager.default
        return row.depth == 0 ? fm.displayName(atPath: row.url.path) : row.url.lastPathComponent
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.12)) { tree.toggle(row.url, in: row.section) } } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .rotationEffect(.degrees(tree.isExpanded(row.url, in: row.section) ? 90 : 0))
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(tree.mayHaveSubfolders(row.url) ? 1 : 0)
            .disabled(!tree.mayHaveSubfolders(row.url))
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isOpen ? Theme.accent : Theme.secondaryText)
                .frame(width: 16)
            Text(title)
                .font(Theme.Font.body)
                .foregroundStyle(isOpen ? Theme.accent : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if tree.hasRecord(row.url) {
                Circle().fill(Theme.accent.opacity(0.8)).frame(width: 5, height: 5)
                    .help(L("This folder has a Spektraplus record", zh: "此文件夹有 Spektraplus 记录"))
            }
        }
        .padding(.leading, 6 + CGFloat(row.depth) * 12)
        .padding(.trailing, 10)
        .frame(height: 22)
        .background(isOpen ? Theme.well : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !session.batchExporting else { return }
            session.flushSave()
            session.open(urls: [row.url])
            if !tree.isExpanded(row.url, in: row.section) { tree.toggle(row.url, in: row.section) }
        }
        .help(row.url.path)
        .contextMenu {
            Button(L(.helpRevealInFinder)) { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
            if tree.isFavorite(row.url) {
                Button(L("Remove from Favorites", zh: "从收藏移除")) { tree.removeFavorite(row.url) }
            } else {
                Button(L("Add to Favorites", zh: "加入收藏")) { tree.addFavorite(row.url) }
            }
        }
    }
}

/// All · Flagged · Unflagged · Rejected, each with its count. The filter is
/// the folder's and comes back with it.
struct FlagFilterList: View {
    @Bindable var session: Session

    static func title(_ f: FlagFilter) -> String {
        switch f {
        case .all: L("All Photos", zh: "全部照片")
        case .flagged: L("Flagged", zh: "留用")
        case .unflagged: L("Unflagged", zh: "未标记")
        case .rejected: L("Rejected", zh: "排除")
        }
    }

    static func symbol(_ f: FlagFilter) -> String {
        switch f {
        case .all: "square.grid.2x2"
        case .flagged: "flag.fill"
        case .unflagged: "flag.slash"
        case .rejected: "xmark.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Filter", zh: "筛选"))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(FlagFilter.allCases) { f in
                let on = session.flagFilter == f
                Button { session.flagFilter = f } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Self.symbol(f)).font(.system(size: 10)).frame(width: 16)
                        Text(Self.title(f)).font(Theme.Font.body)
                        Spacer(minLength: 4)
                        Text("\(session.count(for: f))").font(Theme.Font.small).foregroundStyle(Theme.dim)
                    }
                    .foregroundStyle(on ? Theme.accent : Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .background(on ? Theme.well : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.frames.isEmpty)
            }
            Text(L("P flag · X reject · U clear", zh: "P 留用 · X 排除 · U 清除"))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .padding(.bottom, 4)
    }
}
