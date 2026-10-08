import SwiftUI

/// A titled horizontal shelf of cards for Home. Cards are real buttons (Tab / Full Keyboard Access
/// reach them), the row scrolls with trackpad or the paging chevrons, and cells are created lazily.
public struct ShelfRow: View {
    private let shelf: ShelfModel
    private let actions: ((PosterItem) -> [PosterAction])?
    private let onOpen: (PosterItem) -> Void
    private let onSeeAll: (() -> Void)?

    @State private var position: PosterItem.ID?
    @State private var visibleWidth: CGFloat = 0
    @State private var hovering = false

    public init(
        _ shelf: ShelfModel,
        actions: ((PosterItem) -> [PosterAction])? = nil,
        onOpen: @escaping (PosterItem) -> Void,
        onSeeAll: (() -> Void)? = nil
    ) {
        self.shelf = shelf
        self.actions = actions
        self.onOpen = onOpen
        self.onSeeAll = onSeeAll
    }

    private var cardWidth: CGFloat {
        shelf.style == .poster ? Tokens.PosterSize.shelfPoster : Tokens.PosterSize.shelfWide
    }

    private var pageSize: Int {
        max(1, Int((visibleWidth + Tokens.Spacing.cardGap) / (cardWidth + Tokens.Spacing.cardGap)) - 1)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s + 2) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Tokens.Spacing.cardGap) {
                    ForEach(shelf.items) { item in
                        Button { onOpen(item) } label: {
                            PosterCard(item, width: cardWidth, style: shelf.style, actions: actions)
                        }
                        .buttonStyle(.poster)
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Tokens.Spacing.gutter)
                .padding(.vertical, 6)
            }
            .scrollPosition(id: $position, anchor: .leading)
            .scrollClipDisabled()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: shelf.title))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Text(verbatim: shelf.title)
                .font(Tokens.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            if let subtitle = shelf.subtitle {
                Text(verbatim: subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if shelf.items.count > pageSize {
                HStack(spacing: 2) {
                    pageButton("chevron.left", label: "Scroll left", delta: -pageSize)
                    pageButton("chevron.right", label: "Scroll right", delta: pageSize)
                }
                .opacity(hovering ? 1 : 0)
                .motion(Tokens.Motion.fade, value: hovering)
            }
            if shelf.showsSeeAll, let onSeeAll {
                Button(action: onSeeAll) {
                    HStack(spacing: 3) {
                        Text("See All")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, Tokens.Spacing.gutter)
    }

    private func pageButton(_ symbol: String, label: LocalizedStringKey, delta: Int) -> some View {
        Button {
            let current = shelf.items.firstIndex { $0.id == position } ?? 0
            let target = max(0, min(shelf.items.count - 1, current + delta))
            withMotion(Tokens.Motion.smooth) { position = shelf.items[target].id }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text(label))
    }
}
