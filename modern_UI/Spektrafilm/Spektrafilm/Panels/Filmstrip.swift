//  Filmstrip.swift — the library. Thumbnails at one height, a white frame on
//  the open frame and a weaker one on the rest of the picked set, chevrons at
//  both ends, and the folder name with a count at the far left when there is
//  room.
//
//  Selection is the white frame and **nothing else** (PRD §5): the open
//  frame is marked by the strongest frame and a picked one by the same frame
//  held back, and no cell carries a state pip next to it.
//
//  Which frame a cell gets is `Session.framing(of:)`, not a comparison made
//  here — the Browse grid asks the same function, so the two surfaces cannot
//  draw a different set from the same state.
//
//  `LazyHStack` so a 500-image folder builds only what is visible; thumbnails
//  come from ImageIO off the main actor and are replaced by the rendered print
//  once a frame has been through the engine.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Filmstrip: View {
    @Bindable var session: Session

    var body: some View {
        HStack(spacing: 0) {
            edgeButton("chevron.left") { session.selectRelative(-1) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        // The strip as filtered by flag (`Session.visibleFrames`).
                        ForEach(session.visibleFrames) { frame in
                            FilmstripCell(frame: frame,
                                          geometry: session.thumbnailGeometry(for: frame.id),
                                          framing: session.framing(of: frame.id),
                                          state: session.frameStates[frame.id] ?? .unprocessed,
                                          flag: session.flag(of: frame.id))
                                .id(frame.id)
                                // Dragged along the strip a frame is moved
                                // (`FrameReorder`); onto a pair's hole on the
                                // canvas it goes into it (`PairDrop`).
                                .onDrag {
                                    session.draggedFrame = frame.id
                                    return NSItemProvider(object: frame.id as NSURL)
                                }
                                .onDrop(of: [.fileURL], delegate: FrameReorder(session: session, target: frame.id))
                                // The modifier is read here rather than
                                // declared as a second gesture: a plain
                                // `TapGesture` on macOS matches a ⌘-click too,
                                // so stacking one would fire both and a
                                // ⌘-click would collapse the set as well.
                                .onTapGesture {
                                    session.click(frame.id,
                                                  command: NSEvent.modifierFlags.contains(.command))
                                }
                                .contextMenu {
                                    // On the frame under the pointer, or on
                                    // the whole picked set when it is in it.
                                    let targets = session.isPicked(frame.id) ? session.selectedFrames : [frame.id]
                                    Button(L("Flag (P)", zh: "标为留用 (P)")) { session.setFlag(.flagged, for: targets) }
                                    Button(L("Reject (X)", zh: "标为排除 (X)")) { session.setFlag(.rejected, for: targets) }
                                    Button(L("Clear Flag (U)", zh: "清除旗标 (U)")) { session.setFlag(nil, for: targets) }
                                    Divider()
                                    Button(L(.helpRevealInFinder)) { NSWorkspace.shared.activateFileViewerSelecting([frame.id]) }
                                    if HalfFramePair.isPair(frame.id) {
                                        Button(L("Delete Pair", zh: "删除半格拼接")) { session.deletePair(frame.id) }
                                    } else {
                                        Button(L("New Half-Frame Pair", zh: "新建半格拼接")) {
                                            if !session.isPicked(frame.id) { session.click(frame.id) }
                                            session.newPair()
                                        }
                                        .disabled(!session.canMakePair)
                                    }
                                    Button(L(.helpResetDefaults)) {
                                        if frame.id == session.selection { session.resetParams(); session.resetAdjustments() }
                                        else { Sidecar.remove(for: frame.id); session.refreshState(for: frame.id) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Theme.Metric.filmstripHeight)
                }
                .onChange(of: session.selection) { _, new in
                    if let new { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) } }
                }
            }
            edgeButton("chevron.right") { session.selectRelative(1) }
        }
        .overlay(alignment: .center) {
            // Always in the tree, hidden by opacity. As a `if
            // frames.isEmpty { … }` inside an overlay builder it was observed
            // still on screen next to a loaded thumbnail: the branch had been
            // taken when the strip was empty and was not re-evaluated when it
            // filled. Opacity depends on the same value every pass, so it
            // cannot go stale.
            Text(L(.statusEmptyFilmstrip))
                .font(Theme.Font.label).foregroundStyle(Theme.dim)
                .opacity(session.frames.isEmpty ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .center) {
            // A folder whose frames the flag filter hides, every one.
            Text(L("No photos match the filter", zh: "没有符合筛选条件的照片"))
                .font(Theme.Font.label).foregroundStyle(Theme.dim)
                .opacity(!session.frames.isEmpty && session.visibleFrames.isEmpty ? 1 : 0)
                .allowsHitTesting(false)
        }
        .railCard()
    }

    private func edgeButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                .frame(width: 18, height: Theme.Metric.filmstripHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.frames.isEmpty)
    }
}

/// A thumbnail dragged over another takes its place, there and then, so the
/// strip shows the order the drop will leave. Let go, the order is kept for
/// the folder. A file from outside dropped on a cell is the window's drop.
private struct FrameReorder: DropDelegate {
    let session: Session
    let target: URL

    func dropEntered(info: DropInfo) {
        guard let dragged = session.draggedFrame, dragged != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { session.moveFrame(dragged, onto: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: session.draggedFrame != nil ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        if session.draggedFrame != nil { session.frameOrderChanged(); return true }
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let url = URL(dataRepresentation: u, relativeTo: nil) { urls.append(url) }
            }
            session.dropped(files: urls)
        }
        return true
    }
}

struct FilmstripCell: View {
    let frame: Frame
    /// The frame's crop, turn and flips, drawn over its thumbnail.
    var geometry: Geometry = .default
    /// Whether this cell is on the canvas, in the picked set, or neither —
    /// one value from `Session.framing(of:)` rather than two booleans, so the
    /// strip and the grid cannot spell the same state two ways.
    let framing: FrameFraming
    /// Unread by this cell; kept as the guard test's construction seam.
    let state: FrameState
    /// The cull mark: a flag in the corner for a keeper, and a rejected frame
    /// held back under a cross.
    var flag: FrameFlag? = nil
    var body: some View {
        CropMaskedThumbnail(url: frame.id, geometry: geometry) { image in
            cell(image)
        }
        .help(frame.name)
    }

    private func cell(_ image: CGImage?) -> some View {
        ZStack {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                        .aspectRatio(3 / 2, contentMode: .fit)
                        .overlay(Image(systemName: "photo").foregroundStyle(Theme.dim))
                }
            }
            .frame(height: Theme.Metric.thumbHeight)
            .opacity(flag == .rejected ? 0.4 : 1)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .stroke(Theme.selectionFrame, lineWidth: framing.lineWidth)
                .opacity(framing.opacity))
            .overlay(alignment: .topLeading) {
                if let flag {
                    Image(systemName: flag == .flagged ? "flag.fill" : "xmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(flag == .flagged ? Theme.accent : Theme.text)
                        .shadow(color: .black.opacity(0.7), radius: 1.5)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
        }
    }

}
