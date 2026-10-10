import SwiftUI

/// A scale control — poster width, download limit.
///
/// Wraps the stock macOS `Slider` rather than drawing our own, so AppKit's track, knob, drag,
/// arrow-key stepping and VoiceOver adjustable actions all keep working. Two things the wrapper
/// adds, both measured against Apple's own rendering rather than assumed:
///
/// - **Control size.** Left at the default inside a toolbar item, `Slider` draws a 24 × 20 pt knob,
///   which is *larger* than the 20 × 16 pt AppKit uses in a form. That knob fills the ~28 pt item,
///   so the control reads as a half-open toggle rather than a slider. `.compact` uses the
///   18 × 14 pt knob Apple draws for compact controls; `.regular` keeps the 20 × 16 pt form knob.
/// - **Optional visible label.** Pass no label where the surrounding row already names the
///   control — a `LabeledContent` that says "Download limit" does not also need the word "Limit"
///   floating next to its own slider.
public struct MarqueeSlider<Label: View>: View {
    /// Which size of stock control to draw.
    public enum Scale {
        /// Toolbar-sized: 18 × 14 pt knob on a 4 pt track.
        case compact
        /// Form-sized: 20 × 16 pt knob on a 6 pt track.
        case regular
    }

    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let width: CGFloat
    private let scale: Scale
    private let label: Label

    /// A labelled slider. `width` is the control's frame, not the visible track: AppKit reserves
    /// room for the knob on each side, so the track renders shorter inside toolbars and forms.
    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        width: CGFloat,
        scale: Scale = .regular,
        @ViewBuilder label: () -> Label
    ) {
        self._value = value
        self.range = range
        self.width = width
        self.scale = scale
        self.label = label()
    }

    public var body: some View {
        Slider(value: $value, in: range) { label }
            .controlSize(scale == .compact ? .small : .regular)
            .frame(width: width)
    }
}

public extension MarqueeSlider where Label == EmptyView {
    /// An unlabelled slider. The caller is responsible for an accessibility label.
    init(value: Binding<Double>, in range: ClosedRange<Double>, width: CGFloat, scale: Scale = .regular) {
        self.init(value: value, in: range, width: width, scale: scale) { EmptyView() }
    }
}
