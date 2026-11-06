//  FolderRecord.swift — one file in the photographs' own folder that holds the
//  folder's culling and every frame's edits, so that choosing the folder again
//  — on this Mac, on another one, from a disk that was unplugged in between —
//  brings back everything that was done in it.
//
//  `SpektraLab.folder.json`, beside the photographs:
//
//      {
//        "format": "spektralab.folder", "version": 1,
//        "updated": "2026-11-06T12:00:00Z",
//        "filter": "all",                    the filmstrip's flag filter
//        "current": "_DSC2949.NEF",          the frame that was on the canvas
//        "order": ["_DSC2951.NEF", …],        the dragged order, when there is one
//        "photos": {
//          "_DSC2949.NEF": { "flag": "flagged", "edited": "…", "sidecar": { … } }
//        },
//        "history": [ { "time": "…", "file": "_DSC2949.NEF", "action": "flag" }, … ]
//      }
//
//  **This is the one exception to trap 35** ("sidecars are not beside the
//  photograph"), and it is the person's to make: Settings ▸ Library ▸ "Keep a
//  record in each folder" (`FolderRecordStore.enabledKey`, on by default). The
//  application store under Application Support is unchanged and still written
//  on every save; the folder's record is a second copy that travels with the
//  photographs. Whichever of the two was written last wins on load
//  (`Sidecar.load`), so a read-only folder — a card, a locked share — loses
//  nothing: its record just stops being newer.
//
//  A photograph is named by its file name, not its path. That is what makes
//  the record survive the folder being moved, renamed or copied to another
//  disk — and it is also why a **copy** of a folder carries its edits with it,
//  which for a record that lives in the folder is the point.

import Foundation

/// A frame's cull mark. Absent is "unflagged".
enum FrameFlag: String, Codable, Sendable, CaseIterable {
    /// A keeper (P).
    case flagged
    /// Out (X).
    case rejected
}

/// Which frames the filmstrip shows.
enum FlagFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case all, flagged, unflagged, rejected
    var id: String { rawValue }

    func admits(_ flag: FrameFlag?) -> Bool {
        switch self {
        case .all: true
        case .flagged: flag == .flagged
        case .unflagged: flag == nil
        case .rejected: flag == .rejected
        }
    }
}

struct FolderRecord: Codable, Equatable, Sendable {
    static let fileName = "SpektraLab.folder.json"
    static let formatName = "spektralab.folder"
    /// The history is a log for a person to read, not a database; the oldest
    /// entries go first once it is this long.
    static let historyLimit = 2000

    struct Photo: Codable, Equatable, Sendable {
        var flag: FrameFlag?
        /// When `sidecar` was last written here. Compared with the store's
        /// copy on load: the newer of the two is the frame's edit.
        var edited: Date?
        var sidecar: Sidecar?

        var isEmpty: Bool { flag == nil && sidecar == nil }
    }

    struct Event: Codable, Equatable, Sendable {
        var time: Date
        var file: String
        /// `flag`, `reject`, `unflag`, `edit`, `reset`.
        var action: String
    }

    var format = FolderRecord.formatName
    var version = 1
    var updated: Date?
    var filter: FlagFilter = .all
    var current: String?
    var order: [String]?
    var photos: [String: Photo] = [:]
    var history: [Event] = []

    init() {}

    /// Every field optional on the way in: a record written by a later build,
    /// or edited by hand, opens with what it has.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? FolderRecord.formatName
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        updated = try c.decodeIfPresent(Date.self, forKey: .updated)
        filter = (try? c.decodeIfPresent(FlagFilter.self, forKey: .filter)) ?? .all
        current = try c.decodeIfPresent(String.self, forKey: .current)
        order = try c.decodeIfPresent([String].self, forKey: .order)
        photos = (try? c.decodeIfPresent([String: Photo].self, forKey: .photos)) ?? [:]
        history = (try? c.decodeIfPresent([Event].self, forKey: .history)) ?? []
    }

    func flag(of name: String) -> FrameFlag? { photos[name]?.flag }

    /// Append to the history. Edits are many per minute while a slider moves;
    /// a run of them on one frame is one entry, stamped with the latest.
    mutating func log(_ action: String, file: String, at time: Date = Date()) {
        if action == "edit", let last = history.last, last.action == "edit", last.file == file,
           time.timeIntervalSince(last.time) < 120 {
            history[history.count - 1].time = time
        } else {
            history.append(Event(time: time, file: file, action: action))
        }
        if history.count > FolderRecord.historyLimit {
            history.removeFirst(history.count - FolderRecord.historyLimit)
        }
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Reads and writes `SpektraLab.folder.json`, keeping each folder's record in
/// memory between reads. Nonisolated and lock-guarded: `Sidecar.save` reaches
/// it from the window, the CLI and the MCP server alike.
enum FolderRecordStore {
    /// `UserDefaults` key for Settings ▸ Library ▸ "Keep a record in each folder".
    static let enabledKey = "library.folderRecord"

    /// On unless the person turned it off. **Off under XCTest** unless a test
    /// asks for it (`useForTests`): the suite opens copies of its fixtures in
    /// temporary folders and asserts on what lands there.
    static var enabled: Bool {
        if let forced = testOverride.value { return forced }
        if isTesting { return false }
        return UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let testOverride = Guarded<Bool?>(nil)

    /// Turn the record on or off for a test, or back to the default with nil.
    static func useForTests(_ on: Bool?) {
        testOverride.value = on
        cache.value = [:]
    }

    private struct Cached {
        var record: FolderRecord
        /// The file's modification date when it was read or written: another
        /// process (the CLI, a second window) writing the file changes it,
        /// and the next read goes back to disk.
        var stamp: Date?
    }

    private static let cache = Guarded<[String: Cached]>([:])
    /// One writer at a time within this process; the file write itself is
    /// atomic, so a reader in another process sees the old or the new record.
    private static let writeLock = NSLock()

    static func url(for folder: URL) -> URL { folder.appending(path: FolderRecord.fileName) }

    /// The folder whose record holds this frame, or nil for a frame that has
    /// none: a half-frame pair is a file in the application's store, not a
    /// photograph in a folder.
    static func folder(of image: URL) -> URL? {
        guard !HalfFramePair.isPair(image) else { return nil }
        let folder = image.standardizedFileURL.deletingLastPathComponent()
        guard !folder.path.hasPrefix(Sidecar.storeDirectory.standardizedFileURL.path) else { return nil }
        return folder
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The folder's record, or nil when it has none (or the record is off).
    static func read(_ folder: URL) -> FolderRecord? {
        guard enabled else { return nil }
        let key = folder.standardizedFileURL.path
        let file = url(for: folder)
        let stamp = modificationDate(of: file)
        guard let stamp else {
            cache.withLock { $0[key] = nil }
            return nil
        }
        if let hit = cache.value[key], hit.stamp == stamp { return hit.record }
        guard let data = try? Data(contentsOf: file),
              let record = try? FolderRecord.decoder().decode(FolderRecord.self, from: data),
              record.format == FolderRecord.formatName else { return nil }
        cache.withLock { $0[key] = Cached(record: record, stamp: stamp) }
        return record
    }

    /// Whether the folder has a record file at all.
    static func exists(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(for: folder).path)
    }

    /// Change a folder's record and write it. `create` false leaves a folder
    /// without a record alone — reading state back (the filter, the open
    /// frame) is not a reason to start littering a folder nobody edited in.
    /// Failures are not thrown: the application store still holds every edit,
    /// and a read-only folder is an ordinary place to keep photographs.
    @discardableResult
    static func update(_ folder: URL, create: Bool = true, _ change: (inout FolderRecord) -> Void) -> Bool {
        guard enabled else { return false }
        writeLock.lock(); defer { writeLock.unlock() }
        let existing = read(folder)
        guard existing != nil || create else { return false }
        var record = existing ?? FolderRecord()
        let before = record
        change(&record)
        guard record != before else { return true }
        record.updated = Date()
        let file = url(for: folder)
        guard let data = try? FolderRecord.encoder().encode(record),
              (try? data.write(to: file, options: .atomic)) != nil else { return false }
        let key = folder.standardizedFileURL.path
        cache.withLock { $0[key] = Cached(record: record, stamp: modificationDate(of: file)) }
        return true
    }

    // MARK: - the frame's side

    /// A frame's entry, when its folder has a record.
    static func photo(for image: URL) -> FolderRecord.Photo? {
        guard let folder = folder(of: image) else { return nil }
        return read(folder)?.photos[image.lastPathComponent]
    }

    /// Mirror a sidecar save into the folder.
    static func noteSave(_ sidecar: Sidecar, for image: URL) {
        guard let folder = folder(of: image) else { return }
        let name = image.lastPathComponent
        update(folder) { record in
            var photo = record.photos[name] ?? .init()
            // `source` is this Mac's path and inode, which mean nothing once
            // the folder is somewhere else. The store stamps it on its own copy.
            var stored = sidecar
            stored.source = nil
            guard photo.sidecar != stored else { return }
            photo.sidecar = stored
            photo.edited = Date()
            record.photos[name] = photo
            record.log("edit", file: name)
        }
    }

    /// Mirror a reset: the frame's edits go, its flag stays.
    static func noteRemoval(for image: URL) {
        guard let folder = folder(of: image) else { return }
        let name = image.lastPathComponent
        update(folder, create: false) { record in
            guard var photo = record.photos[name], photo.sidecar != nil else { return }
            photo.sidecar = nil
            photo.edited = nil
            record.photos[name] = photo.isEmpty ? nil : photo
            record.log("reset", file: name)
        }
    }

    /// Set or clear a frame's flag.
    static func setFlag(_ flag: FrameFlag?, for image: URL) {
        guard let folder = folder(of: image) else { return }
        let name = image.lastPathComponent
        update(folder, create: flag != nil) { record in
            var photo = record.photos[name] ?? .init()
            guard photo.flag != flag else { return }
            photo.flag = flag
            record.photos[name] = photo.isEmpty ? nil : photo
            record.log(flag == .flagged ? "flag" : flag == .rejected ? "reject" : "unflag", file: name)
        }
    }
}
