import SwiftUI

/// Lazy poster grid with Finder-style keyboard navigation:
/// arrows move the selection, Return plays, Space previews, ⌘↓ opens details, Home/End jump.
///
/// The grid is a single focus target that owns a `selection`, so it works with lazily created cells,
/// costs one focus region instead of thousands, and scrolls the selection into view. VoiceOver still
/// sees every card as its own button.
public struct PosterGrid: View {
    private let items: [PosterItem]
    @Binding private var posterWidth: Double
    @Binding private var selection: PosterItem.ID?
    private let actions: ((PosterItem) -> [PosterAction])?
    private let onOpen: (PosterItem) -> Void
    private let onPlay: (PosterItem) -> Void
    private let onPreview: (PosterItem) -> Void
    private let onCancel: (() -> Void)?

    @FocusState private var focused: Bool
    @State private var containerWidth: CGFloat = 0

    public init(
        items: [PosterItem],
        posterWidth: Binding<Double>,
        selection: Binding<PosterItem.ID?>,
        actions: ((PosterItem) -> [PosterAction])? = nil,
        onOpen: @escaping (PosterItem) -> Void,
        onPlay: @escaping (PosterItem) -> Void,
        onPreview: @escaping (PosterItem) -> Void = { _ in },
        onCancel: (() -> Void)? = nil
    ) {
        self.items = items
        self._posterWidth = posterWidth
        self._selection = selection
        self.actions = actions
        self.onOpen = onOpen
        self.onPlay = onPlay
        self.onPreview = onPreview
        self.onCancel = onCancel
    }

    private var gap: CGFloat { Tokens.Spacing.cardGap }
    private var inner: CGFloat { max(0, containerWidth - Tokens.Spacing.gutter * 2) }

    private var columnCount: Int {
        max(1, Int((inner + gap) / (CGFloat(posterWidth) + gap)))
    }

    private var cardWidth: CGFloat {
        let n = CGFloat(columnCount)
        return max(60, ((inner - gap * (n - 1)) / n).rounded(.down))
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: gap, alignment: .top), count: columnCount),
                    alignment: .leading, spacing: 26
                ) {
                    ForEach(items) { item in
                        PosterCard(item, width: cardWidth, selection: cardSelection(item), actions: actions)
                            .id(item.id)
                            .onTapGesture {
                                selection = item.id
                                focused = true
                                onOpen(item)
                            }
                    }
                }
                .padding(.horizontal, Tokens.Spacing.gutter)
                .padding(.vertical, Tokens.Spacing.l)
            }
            .onChange(of: selection) { _, new in
                if let new { proxy.scrollTo(new) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat], action: handleKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Posters"))
    }

    private func cardSelection(_ item: PosterItem) -> CardSelection {
        guard selection == item.id else { return .none }
        return focused ? .focused : .inactive
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let cols = columnCount
        let current = selection.flatMap { id in items.firstIndex { $0.id == id } }

        func move(to index: Int) -> KeyPress.Result {
            selection = items[max(0, min(items.count - 1, index))].id
            return .handled
        }

        if press.modifiers == .command, press.key == .downArrow, let current {
            onOpen(items[current])
            return .handled
        }
        guard press.modifiers.isEmpty else { return .ignored }

        switch press.key {
        case .leftArrow: return move(to: (current ?? 1) - 1)
        case .rightArrow: return move(to: (current ?? -1) + 1)
        case .upArrow:
            guard let current else { return move(to: 0) }
            return current - cols >= 0 ? move(to: current - cols) : .handled
        case .downArrow:
            guard let current else { return move(to: 0) }
            // Last partial row: land on the final item rather than doing nothing.
            if current + cols < items.count { return move(to: current + cols) }
            return current / cols < (items.count - 1) / cols ? move(to: items.count - 1) : .handled
        case .home: return move(to: 0)
        case .end: return move(to: items.count - 1)
        case .pageDown: return move(to: (current ?? 0) + cols * 3)
        case .pageUp: return move(to: (current ?? 0) - cols * 3)
        case .return:
            guard let current else { return .ignored }
            onPlay(items[current])
            return .handled
        case .escape:
            guard let onCancel else { return .ignored }
            onCancel()
            return .handled
        case .space:
            guard let current else { return .ignored }
            onPreview(items[current])
            return .handled
        default: return .ignored
        }
    }
}
