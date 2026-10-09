import MarqueeCore
import MarqueeUI
import SwiftUI

struct PersonFilmographySheet: View {
    let person: PersonSummary
    let onOpenTitle: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var details: PersonDetails?
    @State private var credits: PersonCredits = .empty
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: details?.name ?? person.name).font(.title2.bold())
                    if let department = details?.knownForDepartment ?? person.knownForDepartment {
                        Text(verbatim: department).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let biography = details?.biography, !biography.isEmpty {
                        Text(verbatim: biography).font(.body).textSelection(.enabled)
                    }
                    if let error {
                        ErrorBanner(title: "Filmography couldn't load", message: "Check your connection and try again.", details: error)
                    }
                    creditSection("Known For", items: credits.cast.sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) })
                    creditSection("Crew", items: credits.crew.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })
                    if details == nil && error == nil { ShelfSkeleton(count: 5) }
                }.padding(22)
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func creditSection(_ title: String, items: [PersonCredit]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(Tokens.Typography.sectionTitle)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items.prefix(30)) { credit in
                            let item = AppServices.poster(credit)
                            Button {
                                dismiss()
                                onOpenTitle(item.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    ArtworkView(item.poster, targetSize: CGSize(width: 112, height: 168))
                                        .frame(width: 112, height: 168).clipShape(RoundedRectangle(cornerRadius: 9))
                                    Text(verbatim: credit.title).font(.subheadline.weight(.medium)).lineLimit(2).frame(width: 112, alignment: .leading)
                                    Text(verbatim: credit.job ?? credit.character ?? credit.date?.formatted(.dateTime.year()) ?? "")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 112, alignment: .leading)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let services = model.services else { return }
        do {
            let (person, credits) = try await services.personDetails(id: self.person.id)
            self.details = person
            self.credits = credits
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
