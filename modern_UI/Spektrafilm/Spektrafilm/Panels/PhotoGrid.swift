//  PhotoGrid.swift — the folder as a grid, and the bar that switches the
//  centre column between it and the single frame.
//
//  The grid lies over the canvas rather than replacing it: the Metal view
//  and its renderer stay alive, so going back to the single frame (E, a
//  double-click, the bar's button) shows the developed print at once instead
//  of building the view again. It shows what the filmstrip shows
//  (`Session.visibleFrames`, so the flag filter applies), marks the open and
//  picked frames with `Session.framing(of:)` as the strip does, and a click
//  is the strip's click.

import AppKit
import SwiftUI

enum ViewMode: String, CaseIterable {
    case single, grid
}

struct PhotoGrid: View {
    @Bindable var session: Session

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: session.gridCellWidth,
                                                       maximum: session.gridCellWidth * 1.6),
                                             spacing: 12)],
                          spacing: 12) {
                    ForEach(session.visibleFrames) { frame in
                        GridCell(frame: frame,
                                 geometry: session.thumbnailGeometry(for: frame.id),
                                 framing: session.framing(of: frame.id),
                                 flag: session.flag(of: frame.id),
                                 width: session.gridCellWidth)
                            .id(frame.id)
                            // Double first: SwiftUI waits out a double-click
                            // before it hands over the single one.
                            .onTapGesture(count: 2) {
                                if session.selection != frame.id { session.click(frame.id) }
                                session.viewMode = .single
                            }
                            .onTapGesture {
                                session.click(frame.id, command: NSEvent.modifierFlags.contains(.command))
                            }
                            .contextMenu { FrameContextMenu(session: session, frame: frame.id) }
                    }
                }
                .padding(16)
            }
            .onAppear {
                if let s = session.selection { proxy.scrollTo(s, anchor: .center) }
            }
            .onChange(of: session.selection) { _, new in
                if let new { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new) } }
            }
        }
        .background(Theme.ground)
        .overlay {
            Text(session.frames.isEmpty ? L(.statusEmptyFilmstrip)
                                        : L("No photos match the filter", zh: "没有符合筛选条件的照片"))
                .font(Theme.Font.label).foregroundStyle(Theme.dim)
                .opacity(session.visibleFrames.isEmpty ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

private struct GridCell: View {
    let frame: Frame
    let geometry: Geometry
    let framing: FrameFraming
    let flag: FrameFlag?
    let width: Double

    var body: some View {
        VStack(spacing: 5) {
            CropMaskedThumbnail(url: frame.id, geometry: geometry) { image in
                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                            .aspectRatio(3 / 2, contentMode: .fit)
                            .overlay(Image(systemName: "photo").foregroundStyle(Theme.dim))
                    }
                }
                .opacity(flag == .rejected ? 0.4 : 1)
                .overlay(alignment: .topLeading) {
                    if let flag {
                        Image(systemName: flag == .flagged ? "flag.fill" : "xmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(flag == .flagged ? Theme.accent : Theme.text)
                            .shadow(color: .black.opacity(0.7), radius: 1.5)
                            .padding(5)
                    }
                }
            }
            .frame(height: width * 0.72)
            Text(frame.name)
                .font(Theme.Font.small)
                .foregroundStyle(framing == .none ? Theme.dim : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 4).fill(framing == .none ? Color.clear : Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(Theme.selectionFrame, lineWidth: framing.lineWidth)
            .opacity(framing.opacity))
        .contentShape(Rectangle())
        .help(frame.name)
    }
}

/// The strip between the canvas and the filmstrip: single frame or grid, and
/// the grid's thumbnail size.
struct ViewModeBar: View {
    @Bindable var session: Session

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.single, "rectangle", L("Single Photo (E)", zh: "单张 (E)"))
            modeButton(.grid, "square.grid.3x3", L("Grid (G)", zh: "网格 (G)"))
            Spacer(minLength: 8)
            Text(countText)
                .font(Theme.Font.small).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer(minLength: 8)
            if session.viewMode == .grid {
                Image(systemName: "photo").font(.system(size: 8)).foregroundStyle(Theme.dim)
                Slider(value: $session.gridCellWidth, in: 110...320)
                    .controlSize(.mini)
                    .frame(width: 90)
                Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Metric.viewModeBarHeight)
        .railCard()
    }

    private var countText: String {
        let shown = session.visibleFrames.count, all = session.frames.count
        guard all > 0 else { return "" }
        let picked = session.selectedFrames.count
        var parts = [shown == all ? L("\(all) photos", zh: "\(all) 张")
                                  : L("\(shown) of \(all) photos", zh: "\(shown) / \(all) 张")]
        if picked > 1 { parts.append(L("\(picked) selected", zh: "已选 \(picked) 张")) }
        return parts.joined(separator: " · ")
    }

    private func modeButton(_ mode: ViewMode, _ symbol: String, _ help: String) -> some View {
        Button { session.viewMode = mode } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(session.viewMode == mode ? Theme.accent : Theme.text)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A frame's menu, in the filmstrip and in the grid: on the frame under the
/// pointer, or on the whole picked set when it is in it.
struct FrameContextMenu: View {
    @Bindable var session: Session
    let frame: URL

    var body: some View {
        let targets = session.isPicked(frame) ? session.selectedFrames : [frame]
        Button(L("Flag (P)", zh: "标为留用 (P)")) { session.setFlag(.flagged, for: targets) }
        Button(L("Reject (X)", zh: "标为排除 (X)")) { session.setFlag(.rejected, for: targets) }
        Button(L("Clear Flag (U)", zh: "清除旗标 (U)")) { session.setFlag(nil, for: targets) }
        Divider()
        Button(L(.helpRevealInFinder)) { NSWorkspace.shared.activateFileViewerSelecting([frame]) }
        if HalfFramePair.isPair(frame) {
            Button(L("Delete Pair", zh: "删除半格拼接")) { session.deletePair(frame) }
        } else {
            Button(L("New Half-Frame Pair", zh: "新建半格拼接")) {
                if !session.isPicked(frame) { session.click(frame) }
                session.newPair()
            }
            .disabled(!session.canMakePair)
        }
        Button(L(.helpResetDefaults)) {
            if frame == session.selection { session.resetParams(); session.resetAdjustments() }
            else { Sidecar.remove(for: frame); session.refreshState(for: frame) }
        }
    }
}
