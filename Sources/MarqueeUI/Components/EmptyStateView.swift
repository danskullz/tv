import SwiftUI

/// An empty state that teaches what the screen is for and offers the next action.
public struct EmptyStateView: View {
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey
    private let systemImage: String
    private let tips: [LocalizedStringKey]
    private let actionTitle: LocalizedStringKey?
    private let action: (() -> Void)?

    public init(
        title: LocalizedStringKey, message: LocalizedStringKey, systemImage: String,
        tips: [LocalizedStringKey] = [], actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tips = tips
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if !tips.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                        Label { Text(tip) } icon: {
                            Image(systemName: "lightbulb").foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
            if let actionTitle, let action {
                Button(action: action) { Text(actionTitle) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, Tokens.Spacing.s)
            }
        }
        .padding(Tokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
