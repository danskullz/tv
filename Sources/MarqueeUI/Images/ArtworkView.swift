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
            Image(systemName: art.symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(0.55)
                .foregroundStyle(.white.opacity(0.30))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
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
        PlaceholderArtView(art: artwork.placeholder)
            .overlay {
                if let url = artwork.url {
                    RemoteImageLayer(url: url, targetSize: targetSize)
                }
            }
            .clipped()
    }
}

private struct RemoteImageLayer: View {
    let url: URL
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
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .motion(Tokens.Motion.fade, value: image != nil)
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
        if image == nil, preview == nil {
            preview = await pipeline.image(for: url, pixelSize: CGSize(width: 48, height: 48))
        }
        guard !Task.isCancelled else { return }
        if let full = await pipeline.image(for: url, pixelSize: px), !Task.isCancelled {
            image = full
        }
    }
}
