import SwiftUI
import AppKit

/// Plain-language problem report with a fix button. Technical details are one click deeper and copyable.
public struct ErrorBanner: View {
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey
    private let details: String?
    private let fixTitle: LocalizedStringKey?
    private let onFix: (() -> Void)?
    private let onDismiss: (() -> Void)?

    @State private var showDetails = false

    public init(
        title: LocalizedStringKey, message: LocalizedStringKey, details: String? = nil,
        fixTitle: LocalizedStringKey? = nil, onFix: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.details = details
        self.fixTitle = fixTitle
        self.onFix = onFix
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .top, spacing: Tokens.Spacing.m - 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: Tokens.Spacing.m)
                if let fixTitle, let onFix {
                    Button(action: onFix) { Text(fixTitle) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Dismiss"))
                    .help(Text("Dismiss"))
                }
            }
            if let details {
                DisclosureGroup(isExpanded: $showDetails) {
                    HStack(alignment: .top) {
                        Text(verbatim: details)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(details, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Details").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                .padding(.leading, 34)
            }
        }
        .padding(Tokens.Spacing.m)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Tokens.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.l, style: .continuous).strokeBorder(Color.orange.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
