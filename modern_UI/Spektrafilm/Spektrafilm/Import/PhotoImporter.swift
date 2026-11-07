//  PhotoImporter.swift — copying photographs into a library folder, filed by
//  the day they were taken.
//
//  **Copy only.** Nothing is moved and nothing at the source is changed or
//  deleted: a card is emptied in the camera or in Finder, by the person, once
//  they have seen the copies. A file already at the destination with the same
//  name and size is skipped, so importing the same card twice copies only
//  what is new; a different file with the same name gets a `-1`, `-2` suffix.
//
//  The day is the EXIF capture date (`DateTimeOriginal`, the TIFF
//  `DateTime` failing that), read as written — the camera's local time, with
//  no time zone applied — and the file's creation date only when the
//  photograph carries none. The layouts are Lightroom's.

import Foundation
import ImageIO

enum DateFolderLayout: String, CaseIterable, Identifiable, Sendable {
    /// Everything straight into the destination.
    case none
    /// `2026/2026-11-07`
    case yearThenDay
    /// `2026-11-07`
    case day
    /// `2026/11/07`
    case yearMonthDay
    /// `2026/2026-11`
    case yearThenMonth

    var id: String { rawValue }

    /// The folder a day goes in, under the destination; nil for `.none`.
    func subpath(year: Int, month: Int, day: Int) -> String? {
        let y = String(format: "%04d", year), m = String(format: "%02d", month), d = String(format: "%02d", day)
        switch self {
        case .none: return nil
        case .yearThenDay: return "\(y)/\(y)-\(m)-\(d)"
        case .day: return "\(y)-\(m)-\(d)"
        case .yearMonthDay: return "\(y)/\(m)/\(d)"
        case .yearThenMonth: return "\(y)/\(y)-\(m)"
        }
    }

    /// The layout shown with an example date, for the picker.
    var example: String { subpath(year: 2026, month: 11, day: 7) ?? "" }
}

enum PhotoImporter {
    struct Item: Equatable, Sendable {
        let source: URL
        let destination: URL
        /// The same file is already there.
        let skip: Bool
    }

    struct Outcome: Equatable, Sendable {
        var copied: [URL] = []
        var skipped = 0
        var failed: [String] = []
        /// The folders photographs went into, shallowest first.
        var folders: [URL] = []
    }

    static func isPhoto(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ImageDecoder.rawExtensions.contains(ext) || ImageDecoder.flatExtensions.contains(ext)
    }

    /// The photographs in a folder, by name; in its subfolders too when
    /// `recursive` (a card's `DCIM/100MSDCF`, `101MSDCF` …).
    static func photos(in folder: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        if recursive {
            let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let u = e?.nextObject() as? URL { if isPhoto(u) { out.append(u) } }
        } else {
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
            out = items.filter(isPhoto)
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Year, month and day the photograph was taken.
    static func captureDay(of url: URL) -> (year: Int, month: Int, day: Int)? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            for case let s as String in [exif?[kCGImagePropertyExifDateTimeOriginal],
                                         exif?[kCGImagePropertyExifDateTimeDigitized],
                                         tiff?[kCGImagePropertyTIFFDateTime]] {
                if let day = parseExifDay(s) { return day }
            }
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        guard let date = values?.creationDate ?? values?.contentModificationDate else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return (y, m, d)
    }

    /// `2026:11:07 14:03:22` → (2026, 11, 7). Cameras write zeros for an
    /// unset clock; those are not a day.
    static func parseExifDay(_ s: String) -> (year: Int, month: Int, day: Int)? {
        let parts = s.prefix(10).split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 1900, (1...12).contains(parts[1]), (1...31).contains(parts[2])
        else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// Where each photograph goes. `day` is a seam for tests.
    static func plan(_ sources: [URL], into destination: URL, layout: DateFolderLayout,
                     day: (URL) -> (year: Int, month: Int, day: Int)? = captureDay(of:)) -> [Item] {
        let fm = FileManager.default
        var claimed = Set<String>()
        var items: [Item] = []
        for src in sources {
            var folder = destination
            if layout != .none, let d = day(src), let sub = layout.subpath(year: d.year, month: d.month, day: d.day) {
                folder = destination.appending(path: sub, directoryHint: .isDirectory)
            }
            let name = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
            var target = folder.appending(path: src.lastPathComponent)
            var skip = false
            var n = 0
            while true {
                if claimed.contains(target.path) {
                    // Two sources with one name, both new: the second is renamed.
                } else if fm.fileExists(atPath: target.path) {
                    if sameFile(src, target) { skip = true; break }
                } else {
                    break
                }
                n += 1
                target = folder.appending(path: ext.isEmpty ? "\(name)-\(n)" : "\(name)-\(n).\(ext)")
            }
            claimed.insert(target.path)
            items.append(Item(source: src, destination: target, skip: skip))
        }
        return items
    }

    /// Same size and same modification date: a copy made by this importer
    /// (which keeps the date) or by Finder.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let va = try? a.resourceValues(forKeys: keys), let vb = try? b.resourceValues(forKeys: keys),
              va.fileSize == vb.fileSize else { return false }
        guard let da = va.contentModificationDate, let db = vb.contentModificationDate else { return true }
        return abs(da.timeIntervalSince(db)) < 2
    }

    /// Copies the plan, reporting each file done.
    static func run(_ items: [Item], progress: @Sendable (Int) -> Void = { _ in }) -> Outcome {
        let fm = FileManager.default
        var out = Outcome()
        var folders = Set<String>()
        for (i, item) in items.enumerated() {
            defer { progress(i + 1) }
            let folder = item.destination.deletingLastPathComponent()
            folders.insert(folder.path)
            if item.skip { out.skipped += 1; continue }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.copyItem(at: item.source, to: item.destination)
                out.copied.append(item.destination)
            } catch {
                out.failed.append("\(item.source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        out.folders = folders.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
        return out
    }
}
