import Testing
@testable import MarqueeCore

@Suite("Browse data shaping")
struct BrowseDataShapingTests {
    private struct Hit: Identifiable, Equatable {
        var id: String
        var title: String
    }

    @Test func shelvesKeepFirstDuplicateAndRespectLimit() {
        let shelf = [Hit(id: "a", title: "First"), Hit(id: "a", title: "Duplicate"), Hit(id: "b", title: "Second")]
        #expect(BrowseDataShaping.unique(shelf, limit: 2, id: \.id) == [shelf[0], shelf[2]])
    }

    @Test func searchMergeRanksMatchesAndPrefersLibraryDuplicates() {
        let local = [Hit(id: "local", title: "Matrix"), Hit(id: "shared", title: "Dune")]
        let catalogue = [Hit(id: "catalogue", title: "Matrix Reloaded"), Hit(id: "shared", title: "Dune (TMDB)")]
        let result = BrowseDataShaping.mergeSearch(library: local, catalogue: catalogue, query: "matrix", id: \.id, title: \.title)
        #expect(result.map(\.id) == ["local", "catalogue", "shared"])
        #expect(result.last?.title == "Dune")
    }
}
