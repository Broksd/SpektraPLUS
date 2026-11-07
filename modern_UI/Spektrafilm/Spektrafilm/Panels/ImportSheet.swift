//  ImportSheet.swift — Import Photos (⇧⌘I, or the folder browser's import
//  button): from the open folder or any other (a card), all of it or the
//  picked frames, copied into a destination and filed by capture day.
//  `PhotoImporter` does the work; this is the form and the progress.

import AppKit
import SwiftUI

struct ImportSheet: View {
    @Bindable var session: Session
    let tree: FolderTree
    @Environment(\.dismiss) private var dismiss

    nonisolated static let destinationKey = "library.importDestination"
    nonisolated static let layoutKey = "library.importLayout"
    nonisolated static let recursiveKey = "library.importRecursive"

    enum Scope: Hashable { case all, picked }

    /// nil: the open folder.
    @State private var otherSource: URL?
    @State private var scope: Scope = .all
    @State private var recursive = UserDefaults.standard.object(forKey: recursiveKey) as? Bool ?? true
    @State private var destination: URL? = UserDefaults.standard.string(forKey: destinationKey)
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    @State private var layout = DateFolderLayout(rawValue: UserDefaults.standard.string(forKey: layoutKey) ?? "")
        ?? .yearThenDay
    @State private var running = false
    @State private var progress = ImportProgress()
    @State private var total = 0
    @State private var outcome: PhotoImporter.Outcome?

    private var source: URL? { otherSource ?? session.libraryFolder }
    private var fromOpenFolder: Bool { otherSource == nil && session.libraryFolder != nil }
    private var pickedPhotos: [URL] { session.selectedFrames.filter(PhotoImporter.isPhoto) }

    /// The files the import will take, for the count; the open folder's are
    /// already listed, another folder's are listed when it is chosen.
    @State private var otherPhotos: [URL] = []
    private var sources: [URL] {
        if fromOpenFolder {
            return scope == .picked ? pickedPhotos : session.frames.map(\.id).filter(PhotoImporter.isPhoto)
        }
        return otherPhotos
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Import Photos", zh: "导入照片")).font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
            if let outcome { summary(outcome) } else { form }
        }
        .padding(20)
        .frame(width: 480)
        // Last time's card or folder, when it is there again.
        .onAppear {
            if let last = ImportSources.last(), last.standardizedFileURL != session.libraryFolder?.standardizedFileURL {
                useSource(last)
            }
        }
        .background(Theme.card)
        .preferredColorScheme(.dark)
    }

    // MARK: the form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(L("From", zh: "来源")) {
                pathLine(source, empty: L("No folder", zh: "未选择文件夹"))
                // The open folder, then the recent sources — a card that is
                // not in the reader is listed, greyed, so it is recognisable.
                Menu(L("Choose…", zh: "选择…")) {
                    if let open = session.libraryFolder {
                        Button(L("Open Folder: \(open.lastPathComponent)", zh: "当前文件夹：\(open.lastPathComponent)")) {
                            otherSource = nil
                        }
                    }
                    let recents = ImportSources.recents()
                    if !recents.isEmpty {
                        Divider()
                        Section(L("Recent", zh: "最近的来源")) {
                            ForEach(recents, id: \.path) { r in
                                let here = ImportSources.isAvailable(r)
                                Button(here ? ImportSources.title(r)
                                            : L("\(ImportSources.title(r)) (not connected)", zh: "\(ImportSources.title(r))（未连接）")) {
                                    useSource(r)
                                }
                                .disabled(!here)
                            }
                        }
                    }
                    Divider()
                    Button(L("Other Folder…", zh: "其他文件夹…")) { chooseSource() }
                }
                .fixedSize()
                .disabled(running)
            }
            if fromOpenFolder {
                Picker("", selection: $scope) {
                    Text(L("All photos (\(session.frames.count))", zh: "全部照片（\(session.frames.count) 张）"))
                        .tag(Scope.all)
                    Text(L("Selected photos (\(pickedPhotos.count))", zh: "选中的照片（\(pickedPhotos.count) 张）"))
                        .tag(Scope.picked)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .padding(.leading, 64)
                .disabled(running)
            } else if otherSource != nil {
                Toggle(L("Include subfolders", zh: "包含子文件夹（如存储卡的 DCIM）"), isOn: $recursive)
                    .padding(.leading, 64)
                    .disabled(running)
                    .onChange(of: recursive) { _, v in
                        UserDefaults.standard.set(v, forKey: Self.recursiveKey)
                        listOther()
                    }
            }
            row(L("To", zh: "导入到")) {
                pathLine(destination, empty: L("Choose a destination", zh: "请选择目标文件夹"))
                // Favorites first: the library folder is usually one of them.
                Menu(L("Choose…", zh: "选择…")) {
                    ForEach(tree.favorites, id: \.path) { f in
                        Button(FileManager.default.displayName(atPath: f.path)) { setDestination(f) }
                            .help(f.path)
                    }
                    if !tree.favorites.isEmpty { Divider() }
                    Button(L("Other Folder…", zh: "其他文件夹…")) { chooseDestination() }
                }
                .fixedSize()
                .disabled(running)
            }
            row(L("Folders", zh: "分文件夹")) {
                Picker("", selection: $layout) {
                    Text(L("None", zh: "不分，直接放入")).tag(DateFolderLayout.none)
                    ForEach(DateFolderLayout.allCases.filter { $0 != .none }) { l in
                        Text(L("By date: \(l.example)", zh: "按拍摄日期：\(l.example)")).tag(l)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(running)
                .onChange(of: layout) { _, v in UserDefaults.standard.set(v.rawValue, forKey: Self.layoutKey) }
            }
            Text(L("Photos are copied; the originals are not moved or deleted. A file already in the destination is skipped.",
                   zh: "只复制，不移动、不删除原文件。目标里已有的相同文件会跳过。"))
                .font(Theme.Font.small).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            if running {
                ProgressView(value: Double(progress.done), total: Double(max(total, 1)))
                Text(L("Copying \(progress.done) of \(total)…", zh: "正在复制 \(progress.done) / \(total)…"))
                    .font(Theme.Font.small).foregroundStyle(Theme.dim)
            }
            HStack {
                Spacer()
                Button(L("Cancel", zh: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(running)
                Button(L("Import \(sources.count)", zh: "导入 \(sources.count) 张")) { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || sources.isEmpty || destination == nil || isInsideSource)
            }
            if isInsideSource {
                Text(L("The destination cannot be the source folder or inside it.",
                       zh: "目标文件夹不能是来源文件夹或在它里面。"))
                    .font(Theme.Font.small).foregroundStyle(Theme.accent)
            }
        }
    }

    /// Importing a folder into itself would copy files onto themselves, or,
    /// with subfolders, copy what it has just copied.
    private var isInsideSource: Bool {
        guard let s = source?.standardizedFileURL.path, let d = destination?.standardizedFileURL.path else { return false }
        return d == s || d.hasPrefix(s + "/")
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.Font.label).foregroundStyle(Theme.secondaryText)
                .frame(width: 56, alignment: .leading)
            content()
        }
    }

    private func pathLine(_ url: URL?, empty: String) -> some View {
        Text(url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? empty)
            .font(Theme.Font.body)
            .foregroundStyle(url == nil ? Theme.dim : Theme.text)
            .lineLimit(1).truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(url?.path ?? "")
    }

    // MARK: the result

    private func summary(_ o: PhotoImporter.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("\(o.copied.count) copied, \(o.skipped) already there",
                   zh: "已复制 \(o.copied.count) 张，跳过已存在的 \(o.skipped) 张"))
                .font(Theme.Font.body).foregroundStyle(Theme.text)
            if !o.failed.isEmpty {
                Text(L("\(o.failed.count) could not be copied:", zh: "\(o.failed.count) 张复制失败："))
                    .font(Theme.Font.body).foregroundStyle(Theme.accent)
                ScrollView {
                    Text(o.failed.joined(separator: "\n")).font(Theme.Font.small).foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 120)
            }
            if o.folders.count > 1 {
                Text(L("Into \(o.folders.count) folders.", zh: "分到了 \(o.folders.count) 个文件夹。"))
                    .font(Theme.Font.small).foregroundStyle(Theme.dim)
            }
            HStack {
                Spacer()
                Button(L("Close", zh: "关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                if let folder = openTarget(o) {
                    Button(L("Open \(folder.lastPathComponent)", zh: "打开 \(folder.lastPathComponent)")) {
                        open(folder)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// The one folder the photographs went into, or the destination.
    private func openTarget(_ o: PhotoImporter.Outcome) -> URL? {
        o.folders.count == 1 ? o.folders[0] : destination
    }

    private func open(_ folder: URL) {
        // The library folder (a NAS `lightroom`, say) stays one click away.
        if let d = destination { tree.addFavorite(d) }
        tree.refresh()
        session.flushSave()
        session.open(urls: [folder])
        dismiss()
    }

    // MARK: actions

    private func chooseSource() {
        guard let url = pickFolder(L("Choose the folder or card to import from.", zh: "选择要导入的文件夹或存储卡。"))
        else { return }
        useSource(url)
    }

    private func useSource(_ url: URL) {
        otherSource = url
        ImportSources.remember(url)
        listOther()
    }

    private func listOther() {
        guard let s = otherSource else { otherPhotos = []; return }
        otherPhotos = PhotoImporter.photos(in: s, recursive: recursive)
    }

    private func chooseDestination() {
        guard let url = pickFolder(L("Choose where the photos are copied to.", zh: "选择照片复制到哪里。"),
                                   canCreate: true) else { return }
        setDestination(url)
    }

    private func setDestination(_ url: URL) {
        destination = url
        UserDefaults.standard.set(url.path, forKey: Self.destinationKey)
    }

    private func pickFolder(_ message: String, canCreate: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreate
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func start() {
        guard let destination else { return }
        let files = sources, layout = layout
        running = true
        progress.done = 0
        total = files.count
        let progress = progress
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let plan = PhotoImporter.plan(files, into: destination, layout: layout)
                return PhotoImporter.run(plan) { n in
                    Task { @MainActor in progress.done = n }
                }
            }.value
            running = false
            outcome = result
        }
    }
}

@MainActor
@Observable
final class ImportProgress {
    var done = 0
}

/// The import's sources: the last one is offered again when it is there (a
/// card mounts at the same `/Volumes/…` path each time), and the last few are
/// a menu.
enum ImportSources {
    nonisolated static let lastKey = "library.importSource"
    nonisolated static let recentKey = "library.importRecentSources"
    nonisolated static let keep = 6

    static func remember(_ url: URL, in defaults: UserDefaults = .standard) {
        let path = url.standardizedFileURL.path
        var recent = (defaults.stringArray(forKey: recentKey) ?? []).filter { $0 != path }
        recent.insert(path, at: 0)
        defaults.set(Array(recent.prefix(keep)), forKey: recentKey)
        defaults.set(path, forKey: lastKey)
    }

    static func recents(in defaults: UserDefaults = .standard) -> [URL] {
        (defaults.stringArray(forKey: recentKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The last source, if it can be read now.
    static func last(in defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: lastKey) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return isAvailable(url) ? url : nil
    }

    static func isAvailable(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// A card's name rather than `DCIM`: the folder, and its disk when it is
    /// on one.
    static func title(_ url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            return parts.count == 3 ? parts[2] : "\(parts[2]) › \(url.lastPathComponent)"
        }
        return url.lastPathComponent
    }
}
