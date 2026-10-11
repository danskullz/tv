import MarqueeCore
import MarqueeUI
import SwiftUI

/// The window that appears for "Check for Updates…" and for a background check that found one.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var updater: AppUpdater { model.updater }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            header
            detail
            Spacer(minLength: 0)
            buttons
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 440)
        .interactiveDismissDisabled(updater.state.isBusy && updater.state != .checking)
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch updater.state {
        case .checking:
            ProgressView().controlSize(.small).padding(.top, Tokens.Spacing.xs)
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                ProgressView(value: fraction) { Text("Downloading…").font(.subheadline) }
                Text(updater.downloadSizeDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, Tokens.Spacing.xs)
        case .preparing:
            Label("Checking the download…", systemImage: "checkmark.shield")
                .font(.subheadline).foregroundStyle(.secondary).padding(.top, Tokens.Spacing.xs)
        case .installing:
            Label("Installing. Marquee will restart.", systemImage: "arrow.down.app")
                .font(.subheadline).foregroundStyle(.secondary).padding(.top, Tokens.Spacing.xs)
        case .available, .downloaded:
            if let notes = updater.releaseNotes {
                ScrollView {
                    Text(notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(.top, Tokens.Spacing.xs)
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(error.userMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DisclosureGroup("Details") {
                    Text(error.technicalDetail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
            .padding(.top, Tokens.Spacing.xs)
        case .idle, .upToDate:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if case .failed = updater.state {
                Button("Try Again") { Task { await updater.checkNow() } }
            }
            if case .downloaded = updater.state {
                Button("Show in Finder") { updater.revealStagedApp() }
            }
            if case .available = updater.state, !updater.state.isBusy {
                Button("Skip This Version") { Task { await updater.skipOfferedVersion() } }
            }
            Spacer()
            if updater.state.isBusy, updater.state != .checking {
                Button("Cancel") { updater.cancelInstall() }
            }
            Button(confirmTitle, action: confirm)
                .keyboardShortcut(.defaultAction)
                .disabled(confirmDisabled)
        }
    }

    private var confirmTitle: String {
        switch updater.state {
        case .available: "Install Update"
        case .downloaded: "Done"
        case .failed: "Close"
        default: "Close"
        }
    }

    private var confirmDisabled: Bool {
        switch updater.state {
        case .checking, .downloading, .preparing, .installing: return true
        case .available: return false
        default: return false
        }
    }

    private func confirm() {
        switch updater.state {
        case .available: Task { await updater.install() }
        default: dismiss()
        }
    }

    private var title: String {
        switch updater.state {
        case .checking: "Checking for Updates…"
        case .upToDate: "Marquee Is Up to Date"
        case .available(let version): "Marquee \(version) Is Available"
        case .downloading, .preparing, .installing: "Updating Marquee"
        case .downloaded: "Update Ready"
        case .failed: "Couldn't Update Marquee"
        case .idle: "Software Update"
        }
    }

    private var subtitle: String {
        switch updater.state {
        case .checking: "One moment."
        case .upToDate: "Version \(updater.currentVersion)."
        case .available: "Version \(updater.release?.version.description ?? "") · \(updater.downloadSizeDescription)"
        case .downloading, .preparing, .installing: "Version \(updater.release?.version.description ?? "")"
        case .downloaded: "This copy of Marquee can't replace itself. Drag the app into Applications to finish."
        case .failed(let error): error.userMessage
        case .idle: ""
        }
    }

    private var icon: String {
        switch updater.state {
        case .upToDate: "checkmark.circle.fill"
        case .available: "arrow.down.circle.fill"
        case .checking, .downloading, .preparing, .installing: "arrow.triangle.2.circlepath"
        case .downloaded: "shippingbox.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "gearshape"
        }
    }

    private var tint: Color {
        switch updater.state {
        case .upToDate, .available, .downloaded: .accentColor
        case .failed: .orange
        default: .secondary
        }
    }
}