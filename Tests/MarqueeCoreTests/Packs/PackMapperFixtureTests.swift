import Foundation
import Testing
@testable import MarqueeCore

@Suite("Pack mapper corpus")
struct PackMapperFixtureTests {
    @Test("Corpus has at least 40 layouts", arguments: [0])
    func corpusSize(_: Int) throws {
        let n = try packsGroups.reduce(0) { $0 + (try packsLoadLayouts($1)).count }
        #expect(n >= 40)
    }

    @Test("Every layout maps as expected", arguments: packsGroups)
    func group(_ group: String) throws {
        let layouts = try packsLoadLayouts(group)
        var bad: [String] = []
        for l in layouts { bad += packsEvaluate(l).mismatches }
        if !bad.isEmpty { print("PACK MISMATCHES in \(group):\n" + bad.joined(separator: "\n")) }
        #expect(bad.isEmpty, "\(bad.count) mismatches in \(group); see printed list")
    }

    @Test("Corpus accuracy")
    func accuracy() throws {
        var total = 0, ok = 0, layouts = 0, perfect = 0
        for g in packsGroups {
            for l in try packsLoadLayouts(g) {
                let o = packsEvaluate(l)
                total += o.fileTotal
                ok += o.fileMatches
                layouts += 1
                if o.mismatches.isEmpty { perfect += 1 }
            }
        }
        print("PACK CORPUS: \(layouts) layouts (\(perfect) fully correct), \(ok)/\(total) checks = \(Double(ok) / Double(total) * 100)%")
        #expect(ok == total)
    }
}
