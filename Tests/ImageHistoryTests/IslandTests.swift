import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class IslandTests: HistoryTestCase {
    private struct Contract: Decodable {
        struct Sample: Decodable { let id: String; let index: Int; let size, lean: Double }
        struct Entry: Decodable { let name, svg: String }
        let samples: [Sample]; let hangers: [Entry]
    }
    private func contract() throws -> Contract {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: root.appendingPathComponent("contracts/hangers.json")))
    }

    func testHangerCatalogAndAssignmentMatchSharedContract() throws {
        let c = try contract()
        XCTAssertEqual(c.hangers.count, 30)
        XCTAssertEqual(HangerCatalog.svgs, c.hangers.map(\.svg))
        XCTAssertEqual(HangerCatalog.names, c.hangers.map(\.name))
        for sample in c.samples {
            let hanger = Hanger(seed: try XCTUnwrap(UUID(uuidString: sample.id)))
            XCTAssertEqual(hanger.index, sample.index, sample.id)
            XCTAssertEqual(hanger.size, sample.size, accuracy: 1e-9)
            XCTAssertEqual(hanger.lean, sample.lean, accuracy: 1e-9)
        }
        for index in HangerCatalog.svgs.indices { XCTAssertEqual(Hanger.image(index).size, NSSize(width: 40, height: 40), HangerCatalog.names[index]) }
    }

    func testIslandRopeMergesKindsNewestFirstAndArrowsWalkAcrossThem() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let line = f.line()
        line.setLayoutMode(.island)
        line.texts.add("oldest text")
        f.date = f.date.addingTimeInterval(10)
        let image = try XCTUnwrap(line.hang(try f.image(), quietly: true))
        f.date = f.date.addingTimeInterval(10)
        line.texts.add("newest text")
        let entries = line.islandEntries
        XCTAssertEqual(entries.map(\.shelf), [.texts, .images, .texts])
        XCTAssertEqual(entries[1].id, image)
        XCTAssertEqual(line.islandCount(nil), 3)
        XCTAssertEqual(line.islandCount(.texts), 2)

        line.selectFirstIslandItem()
        XCTAssertEqual(line.activeShelf, .texts)
        XCTAssertEqual(line.texts.focusedID, entries[0].id)
        line.islandStep(1)
        XCTAssertEqual(line.activeShelf, .images)
        XCTAssertEqual(line.focusedID, image)
        XCTAssertTrue(line.texts.selectedIDs.isEmpty, "only the card under the cursor stays selected")
        line.islandStep(1)
        XCTAssertEqual(line.activeShelf, .texts)
        XCTAssertEqual(line.texts.focusedID, entries[2].id)
        XCTAssertTrue(line.selectedIDs.isEmpty)
        line.islandStep(1)
        XCTAssertEqual(line.texts.focusedID, entries[2].id, "the end of the rope clamps")

        XCTAssertEqual(line.searchShelves, Shelf.allCases, "island search covers every kind on the rope")
        line.cycleIslandFilter()
        XCTAssertEqual(line.islandFilter, .images)
        XCTAssertEqual(line.searchShelves, [.images], "and only the filtered kind")
        XCTAssertEqual(line.islandEntries.map(\.id), [image])
        XCTAssertEqual(line.focusedID, image)
        line.setIslandFilter(nil)
        line.setLayoutMode(.classic)
        XCTAssertEqual(f.line().layoutMode, .classic, "the layout choice persists")
    }
}
