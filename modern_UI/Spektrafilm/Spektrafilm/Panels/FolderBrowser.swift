//  FolderBrowser.swift — the folder tree at the window's leading edge.
//
//  A list of places (the home folder, Pictures, every mounted disk and card,
//  and any folder the person adds), each one opening into its subfolders.
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
    nonisolated static let rootsKey = "library.roots"
    nonisolated static let expandedKey = "library.expanded"

    struct Row: Identifiable, Equatable {
        let url: URL
        let depth: Int
        var id: String { url.path }
    }

    enum RootKind { case home, pictures, volume, added }

    private let defaults: UserDefaults
    /// The places at the top of the tree.
    private(set) var roots: [(url: URL, kind: RootKind)] = []
    private(set) var expanded: Set<String>
    /// Subfolders by folder path, listed on first expansion. Caches, filled
    /// while the tree is drawn, so not observed: `revision` is what a view
    /// re-reads when one is dropped.
    @ObservationIgnored private var children: [String: [URL]] = [:]
    @ObservationIgnored private var records: [String: Bool] = [:]
    private var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expanded = Set(defaults.stringArray(forKey: Self.expandedKey) ?? [])
        reloadRoots()
    }

    /// The person's own places, kept between launches.
    private var added: [URL] {
        (defaults.stringArray(forKey: Self.rootsKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func reloadRoots() {
        let fm = FileManager.default
        var out: [(url: URL, kind: RootKind)] = []
        let home = fm.homeDirectoryForCurrentUser
        out.append((home, .home))
        if let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first {
            out.append((pictures, .pictures))
        }
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey],
                                           options: [.skipHiddenVolumes]) ?? []
        for v in volumes where v.path != "/" { out.append((v, .volume)) }
        for a in added where !out.contains(where: { $0.url.path == a.path }) { out.append((a, .added)) }
        roots = out
    }

    /// Forget every listing: folders made or removed in Finder show up.
    func refresh() {
        children = [:]
        records = [:]
        revision += 1
        reloadRoots()
    }

    var rows: [Row] {
        _ = revision
        var out: [Row] = []
        func walk(_ url: URL, _ depth: Int) {
            out.append(Row(url: url, depth: depth))
            guard expanded.contains(url.path) else { return }
            for c in subfolders(of: url) { walk(c, depth + 1) }
        }
        for r in roots { walk(r.url, 0) }
        return out
    }

    func kind(of url: URL) -> RootKind? { roots.first { $0.url.path == url.path }?.kind }

    func isExpanded(_ url: URL) -> Bool { expanded.contains(url.path) }

    /// Whether a disclosure arrow is worth drawing: unknown until listed, so
    /// an unlisted folder gets one.
    func mayHaveSubfolders(_ url: URL) -> Bool {
        guard let listed = children[url.path] else { return true }
        return !listed.isEmpty
    }

    func toggle(_ url: URL) {
        if expanded.contains(url.path) { expanded.remove(url.path) } else { expanded.insert(url.path) }
        defaults.set(Array(expanded), forKey: Self.expandedKey)
    }

    /// Open every ancestor of `folder` that sits under one of the roots, so
    /// the open folder can be seen in the tree.
    func reveal(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard let root = roots.map({ $0.url }).filter({ path.hasPrefix($0.path + "/") })
                .max(by: { $0.path.count < $1.path.count }) else { return }
        var cursor = folder.standardizedFileURL.deletingLastPathComponent()
        var changed = false
        while cursor.path.count >= root.path.count {
            if !expanded.contains(cursor.path) { expanded.insert(cursor.path); changed = true }
            if cursor.path == root.path { break }
            cursor = cursor.deletingLastPathComponent()
        }
        if changed { defaults.set(Array(expanded), forKey: Self.expandedKey) }
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

    func addRoot(_ url: URL) {
        var paths = defaults.stringArray(forKey: Self.rootsKey) ?? []
        guard !paths.contains(url.path) else { return }
        paths.append(url.path)
        defaults.set(paths, forKey: Self.rootsKey)
        reloadRoots()
    }

    func removeRoot(_ url: URL) {
        let paths = (defaults.stringArray(forKey: Self.rootsKey) ?? []).filter { $0 != url.path }
        defaults.set(paths, forKey: Self.rootsKey)
        reloadRoots()
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = L("Add folders to the folder browser.", zh: "把文件夹添加到文件夹浏览器。")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addRoot(url) }
    }
}

struct FolderBrowser: View {
    @Bindable var session: Session
    @Bindable var tree: FolderTree

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tree.rows) { row in
                            FolderRow(row: row, tree: tree, session: session).id(row.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                // A flag or an edit can be what first writes the folder's
                // record: its dot appears without a refresh.
                .onChange(of: session.flags) { _, _ in
                    if let folder = session.libraryFolder { tree.recordChanged(in: folder) }
                }
                .onChange(of: session.frameStates) { _, _ in
                    if let folder = session.libraryFolder { tree.recordChanged(in: folder) }
                }
                .onChange(of: session.libraryFolder) { _, folder in
                    guard let folder else { return }
                    tree.reveal(folder)
                    tree.recordChanged(in: folder)
                    proxy.scrollTo(folder.standardizedFileURL.path, anchor: .center)
                }
            }
            Hairline()
            FlagFilterList(session: session)
        }
        .railCard()
    }

    private var header: some View {
        HStack(spacing: 0) {
            // The window buttons sit on this row while the browser is open
            // (Windows/TrafficLights.swift); this is their reservation.
            Spacer().frame(width: Theme.Metric.trafficLightClearance)
            Text(L("Folders", zh: "文件夹"))
                .font(Theme.Font.railTitle)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            PanelIconButton(systemImage: "arrow.clockwise",
                            help: L("Refresh the folder list", zh: "刷新文件夹列表")) { tree.refresh() }
            PanelIconButton(systemImage: "plus",
                            help: L("Add a folder to the list", zh: "添加文件夹到列表")) { tree.chooseRoot() }
                .padding(.trailing, 6)
        }
        .frame(height: Theme.Metric.panelHeaderHeight)
        .background(WindowDragHandle())
    }
}

private struct FolderRow: View {
    let row: FolderTree.Row
    @Bindable var tree: FolderTree
    @Bindable var session: Session

    private var isOpen: Bool { session.libraryFolder?.path == row.url.standardizedFileURL.path }

    private var icon: String {
        switch tree.kind(of: row.url) {
        case .home?: "house"
        case .pictures?: "photo.on.rectangle"
        case .volume?: "externaldrive"
        case .added?, nil: isOpen ? "folder.fill" : "folder"
        }
    }

    private var title: String {
        let fm = FileManager.default
        return row.depth == 0 ? fm.displayName(atPath: row.url.path) : row.url.lastPathComponent
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.12)) { tree.toggle(row.url) } } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .rotationEffect(.degrees(tree.isExpanded(row.url) ? 90 : 0))
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
                    .help(L("This folder has a SpektraLab record", zh: "此文件夹有 SpektraLab 记录"))
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
            if !tree.isExpanded(row.url) { tree.toggle(row.url) }
        }
        .help(row.url.path)
        .contextMenu {
            Button(L(.helpRevealInFinder)) { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
            if tree.kind(of: row.url) == .added {
                Button(L("Remove from List", zh: "从列表移除")) { tree.removeRoot(row.url) }
            } else if tree.kind(of: row.url) == nil {
                Button(L("Add to List", zh: "添加到列表")) { tree.addRoot(row.url) }
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
