//  LeftPanel.swift — the material rail (v4, 2026-09-26): **Film and Print**.
//
//  v4 made this rail the choices of *material* and nothing else: the
//  film, the paper, the crop and the enlarger.
//  Everything that is a *parameter* of those choices — Camera, Film Format,
//  Scene Placement, the Tone Mask — moved to the Parameters rail.
//
//  The rail has two pages, Folders (`FolderBrowser`) and Film and Print, and
//  its header holds their tabs after the window buttons' clearance. Import,
//  export and `sidebar.left` moved to the top bar, which is on screen whether
//  or not this rail is, so the PRD's "on screen at any given time" holds
//  without the bar having to take them over when the rail folds.
//
//  Sections are separated by `SectionDivider`: drag one to give the section
//  above it more or less of the rail. To add a section, write a view in
//  Panels/Sections and add one line to the list.

import SwiftUI

/// The left rail's two pages. The tabs in its header switch them; ⇧⌘L goes
/// to the folders and back.
enum LeftRailPage: String, CaseIterable, Identifiable {
    case folders, material
    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .folders: L("Folders", zh: "文件夹")
        case .material: L(.railFilmAndPrint)
        }
    }
}

struct LeftPanel: View {
    @Bindable var session: Session
    @Bindable var tree: FolderTree

    /// The rail's sections, in order. A statement at a time, so the type
    /// checker has no long expression to solve.
    private var sections: [(String, AnyView)] {
        var s: [(String, AnyView)] = []
        // A pair's own tool heads the rail, and it has no crop section: each
        // picture is cropped under its own hole. The Navigator is not listed
        // (2026-11-07): the canvas pans with Space-drag and H, and the rail's
        // height is worth more to the film and the paper. `NavigatorSection`
        // stays for its drawing, which the thumbnails use.
        let isPair = session.pair != nil
        if isPair { s.append((PairSection.key, AnyView(PairSection(session: session)))) }
        s.append(("clipboard", AnyView(ClipboardSection(session: session))))
        s.append(("film", AnyView(FilmSection(session: session))))
        // Under Film, before Print: both belong to the film and depend on
        // neither the paper nor the DI (2026-10-01 drawings).
        s.append((FilmEdgeSection.key, AnyView(FilmEdgeSection(session: session))))
        s.append((DateBackSection.key, AnyView(DateBackSection(session: session))))
        s.append(("print", AnyView(PrintProfileSection(session: session))))
        if !isPair { s.append(("crop", AnyView(CropSection(session: session)))) }
        s.append(("enlarger", AnyView(EnlargerSection(session: session))))
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if session.showsFolderBrowser {
                FolderBrowser(session: session, tree: tree)
            } else {
                materialPage
            }
        }
        .railCard()
    }

    /// Film and Print: the film, the paper, the crop and the enlarger.
    private var materialPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                let sections = sections
                // A divider **between** sections, never after the last:
                // a rule under the final section is a bottom border
                // against empty rail, not a separator.
                ForEach(Array(sections.enumerated()), id: \.element.0) { index, entry in
                    if index > 0 { SectionDivider(above: sections[index - 1].0) }
                    entry.1
                }
            }
        }
    }

    /// A snapshot capture shows Film and Print only, as the drawing does.
    private var pages: [LeftRailPage] { session.snapshotPanelWidths ? [.material] : LeftRailPage.allCases }
    private var currentPage: LeftRailPage { session.showsFolderBrowser ? .folders : .material }

    private var header: some View {
        HStack(spacing: 0) {
            // The three window buttons live here (Windows/TrafficLights.swift).
            // They are *placed* in window coordinates, so this is a reservation
            // and not a container.
            Spacer().frame(width: Theme.Metric.trafficLightClearance)
            // The page tabs, in the place of the rail's name. Selection tints
            // the title, as it tints a selected tool's glyph (TopBar).
            HStack(spacing: 14) {
                ForEach(pages) { page in
                    let on = currentPage == page
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) { session.leftRailPage = page }
                    } label: {
                        Text(page.title)
                            .font(Theme.Font.railTitle)
                            // One tab is a title, drawn as the rail's name was.
                            .foregroundStyle(pages.count == 1 ? Theme.text
                                             : on ? Theme.accent : Theme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(height: Theme.Metric.panelHeaderHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(page == .folders ? L("Folders (⇧⌘L)", zh: "文件夹（⇧⌘L）") : page.title)
                }
            }
            .padding(.trailing, Theme.Metric.panelHeaderTrailing)
            Spacer(minLength: 0)
        }
        .frame(height: Theme.Metric.panelHeaderHeight)
        // The header row is the window's drag surface, as a sidebar header is
        // in Xcode.
        .background(WindowDragHandle())
    }
}

/// `sidebar.left` / `sidebar.right` — the two buttons that fold a rail.
///
/// The PRD's requirement is that they are on screen *at every moment*, which
/// is why this is one view used in three places rather than a button drawn in
/// each: a rail's header holds its own while the rail is open, and the bar
/// holds it while the rail is folded. The glyph never changes — `sidebar.left`
/// always means "the left rail", open or shut.
///
/// **It does not tint.** It used to go `Theme.accent` while its rail was
/// folded, on the reasoning that a selected control tints its glyph. That was
/// the wrong category: this is not a mode you are in, it is a door you push,
/// and the state it would be reporting — whether a whole rail is on screen —
/// is not something you need a 6 pt orange glyph to tell you. The accent is
/// the one colour in the palette that means "look here", and spending it on
/// a fact already filling half the window devalues it everywhere else.
struct SidebarToggle: View {
    enum Edge { case leading, trailing }
    let edge: Edge
    @Binding var collapsed: Bool

    private var symbol: String { edge == .leading ? "sidebar.left" : "sidebar.right" }
    private var help: String {
        switch (edge, collapsed) {
        case (.leading, false): L(.helpDevelopRailHide)
        case (.leading, true): L(.helpDevelopRailShow)
        case (.trailing, false): L(.helpEditRailHide)
        case (.trailing, true): L(.helpEditRailShow)
        }
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { collapsed.toggle() } } label: {
            Image(systemName: symbol)
                .font(.system(size: Theme.Metric.sidebarIcon, weight: .regular))
                .foregroundStyle(Theme.text)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PanelIconButton: View {
    let systemImage: String
    var help: String = ""
    var active = false
    /// A glyph that cannot be used is greyed, like every other non-selectable
    /// control in the app (PRD; `View.rowEnabled(_:)`).
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.Metric.panelIcon, weight: .regular))
                .foregroundStyle(active ? Theme.accent : Theme.text)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowEnabled(enabled)
        .help(help)
    }
}

struct VerticalEllipsis: View {
    var body: some View {
        VStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.text).frame(width: 3, height: 3) } }
    }
}

extension View {
    // `panelCard()` — a rounded card on a visible ground — used to live here
    // for the export page and the Browse grid. Both are gone: the grid was
    // removed with the import page, and the export page is three flush rails
    // like the editor. Nothing in the app is a floating card now, so the
    // modifier is not kept "just in case" — a second surface treatment that
    // nothing uses is how the two pages drifted apart in the first place.

    /// A rail, or the filmstrip: flush with the window and square, because
    /// the 2026-09-17 drawing separates regions with a hairline rather than
    /// with a gap and a radius.
    func railCard() -> some View {
        self.background(Theme.card)
    }

    /// The one thing that still floats: the tool bar's pill.
    func barCard() -> some View {
        self.background(Theme.card,
                        in: RoundedRectangle(cornerRadius: Theme.Metric.barRadius, style: .continuous))
    }
}
