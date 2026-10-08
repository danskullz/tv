import SwiftUI

public enum StatusKind: Sendable {
    case neutral, info, success, warning, danger

    var tint: Color {
        switch self {
        case .neutral: .secondary
        case .info: .accentColor
        case .success: .green
        case .warning: .orange
        case .danger: .red
        }
    }
}

/// Small capsule that states a status in words (never color alone).
public struct StatusPill: View {
    private let text: Text
    private let systemImage: String?
    private let kind: StatusKind

    public init(_ title: LocalizedStringKey, systemImage: String? = nil, kind: StatusKind = .neutral) {
        self.text = Text(title)
        self.systemImage = systemImage
        self.kind = kind
    }

    public init(verbatim title: String, systemImage: String? = nil, kind: StatusKind = .neutral) {
        self.text = Text(verbatim: title)
        self.systemImage = systemImage
        self.kind = kind
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            text
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(kind == .neutral ? Color.secondary : kind.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(kind.tint.opacity(kind == .neutral ? 0.14 : 0.16), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// "1080p", "4K HDR", "REMUX" outline badge.
public struct QualityBadge: View {
    private let quality: Quality

    public init(_ quality: Quality) { self.quality = quality }

    private var label: String {
        var parts = [quality.resolution == .uhd ? "4K" : "\(quality.resolution.rawValue)p"]
        if quality.hdr { parts.append("HDR") }
        if quality.remux { parts.append("REMUX") }
        return parts.joined(separator: " ")
    }

    public var body: some View {
        Text(verbatim: label)
            .font(Tokens.Typography.badge)
            .foregroundStyle(quality.resolution == .uhd ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(quality.resolution == .uhd ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.55), lineWidth: 1)
            )
            .fixedSize()
            .accessibilityLabel(Text(Self.spoken(quality)))
    }

    static func spoken(_ q: Quality) -> String {
        var s = q.resolution == .uhd ? String(localized: "4K") : String(localized: "\(q.resolution.rawValue)p")
        if q.hdr { s += " " + String(localized: "HDR") }
        if q.remux { s += " " + String(localized: "remux") }
        return s
    }
}
