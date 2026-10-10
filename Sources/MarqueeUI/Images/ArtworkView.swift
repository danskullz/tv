import SwiftUI

/// Procedural poster / backdrop stand-in: hue gradient, soft highlight and an SF Symbol.
/// Layout-free (no GeometryReader) so it is cheap inside large lazy grids.
struct PlaceholderArtView: View {
    let art: PlaceholderArt

    var body: some View {
        let h = art.hue.truncatingRemainder(dividingBy: 1)
        let h2 = (h + 0.06 + Double(art.variant % 5) * 0.012).truncatingRemainder(dividingBy: 1)
        let flip = art.variant % 2 == 0
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: h, saturation: 0.55, brightness: 0.86),
                    Color(hue: h2, saturation: 0.80, brightness: 0.36),
                ],
                startPoint: flip ? .topLeading : .topTrailing,
                endPoint: flip ? .bottomTrailing : .bottomLeading
            )
            RadialGradient(
                colors: [.white.opacity(0.28), .clear],
                center: flip ? .topLeading : .topTrailing, startRadius: 0, endRadius: 220
            )
            if !art.symbol.isEmpty {
                Image(systemName: art.symbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(0.55)
                    .foregroundStyle(.white.opacity(0.30))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .center, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// Artwork with a generated placeholder underneath and, for remote art, a progressive load: a tiny
/// blurred preview first, then the sharp image downsampled to the displayed size (via `ImagePipeline`).
/// Pass `targetSize` (points) when the parent already knows it; otherwise the view measures itself.
public struct ArtworkView: View {
    private let artwork: Artwork
    private let targetSize: CGSize?

    public init(_ artwork: Artwork, targetSize: CGSize? = nil) {
        self.artwork = artwork
        self.targetSize = targetSize
    }

    public var body: some View {
        if let url = artwork.url {
            // The placeholder is drawn *behind* the remote image only while it is missing. Keeping
            // it permanently underneath cost three gradient layers plus a shadowed SF Symbol for
            // every card in the grid, on every render, and CoreAnimation had to walk all of them —
            // which is where tab-switch layout time was going.
            RemoteImageLayer(url: url, placeholder: artwork.placeholder, targetSize: targetSize)
                .clipped()
        } else {
            PlaceholderArtView(art: artwork.placeholder)
        }
    }
}

private struct RemoteImageLayer: View {
    let url: URL
    let placeholder: PlaceholderArt
    let targetSize: CGSize?

    @Environment(\.displayScale) private var displayScale
    @Environment(AppLifecycle.self) private var lifecycle: AppLifecycle?
    @State private var measured: CGSize = .zero
    @State private var image: CGImage?
    @State private var preview: CGImage?

    private struct LoadKey: Equatable {
        var url: URL
        var side: Int
        var resident: Bool
    }

    private var pixelSize: CGSize {
        let size = targetSize ?? measured
        return CGSize(width: size.width * displayScale, height: size.height * displayScale)
    }

    private var loadKey: LoadKey {
        LoadKey(url: url, side: ImagePipeline.bucketed(max(pixelSize.width, pixelSize.height)),
                resident: lifecycle?.imagesResident ?? true)
    }

    var body: some View {
        ZStack {
            if image == nil { PlaceholderArtView(art: placeholder) }
            if let preview, image == nil {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 12)
            }
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
            if targetSize == nil { measured = newSize }
        }
        .task(id: loadKey) { await load() }
    }

    private func load() async {
        guard lifecycle?.imagesResident ?? true else {
            image = nil
            preview = nil
            return
        }
        let px = pixelSize
        guard px.width > 1, px.height > 1 else { return }
        let pipeline = ImagePipeline.shared
        if let hit = pipeline.cachedImage(for: url, pixelSize: px) {
            image = hit
            return
        }
        // Request the sharp image and the tiny preview together rather than one after the other.
        // Serially, the sharp image could not start until the preview had finished reading and
        // decoding the same file, so every cold artwork paid for the file twice.
        async let tiny: CGImage? = image == nil && preview == nil
            ? pipeline.image(for: url, pixelSize: CGSize(width: 48, height: 48))
            : nil
        async let full: CGImage? = pipeline.image(for: url, pixelSize: px)
        if let first = await tiny, image == nil, preview == nil, !Task.isCancelled {
            preview = first
        }
        guard !Task.isCancelled else { return }
        if let sharp = await full, !Task.isCancelled {
            image = sharp
        }
    }
}
