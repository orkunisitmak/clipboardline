import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class HangMotionTests: HistoryTestCase {
    private struct Contract: Decodable {
        struct Rope: Decodable {
            let arrivalAmplitude, removalAmplitude, falloff, waveSpeed, frequency, decay, lifetime, maximumDip: Double
            let maximumChanges: Int
        }
        struct Sample: Decodable {
            struct Pluck: Decodable { let x, time, amplitude: Double }
            let plucks: [Pluck]; let x, time, dip: Double
        }
        let rope: Rope; let samples: [Sample]
    }
    private func contract() throws -> Contract {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: root.appendingPathComponent("contracts/hang-motion.json")))
    }

    func testRopeConstantsAndSamplesMatchSharedContract() throws {
        let c = try contract()
        XCTAssertEqual(Double(HangMotion.arrivalAmplitude), c.rope.arrivalAmplitude)
        XCTAssertEqual(Double(HangMotion.removalAmplitude), c.rope.removalAmplitude)
        XCTAssertEqual(Double(HangMotion.falloff), c.rope.falloff)
        XCTAssertEqual(Double(HangMotion.waveSpeed), c.rope.waveSpeed)
        XCTAssertEqual(HangMotion.frequency, c.rope.frequency)
        XCTAssertEqual(HangMotion.decay, c.rope.decay)
        XCTAssertEqual(HangMotion.lifetime, c.rope.lifetime)
        XCTAssertEqual(Double(HangMotion.maximumDip), c.rope.maximumDip)
        XCTAssertEqual(HangMotion.maximumChanges, c.rope.maximumChanges)
        for sample in c.samples {
            let plucks = sample.plucks.map { HangMotion.Pluck(x: $0.x, time: $0.time, amplitude: $0.amplitude) }
            XCTAssertEqual(Double(HangMotion.dip(at: sample.x, time: sample.time, plucks: plucks)), sample.dip, accuracy: 0.0005)
        }
    }

    func testSmallChangesPluckButRowSwapsAndReduceMotionDoNot() {
        var now: TimeInterval = 100, reduce = false
        let motion = HangMotion(clock: { now }, reduceMotion: { reduce })
        let a = UUID(), b = UUID(), c = UUID()
        motion.react(from: [a, b], to: [c, a, b]) { CGFloat($0) * 100 }
        XCTAssertEqual(motion.plucks, [.init(x: 0, time: 100, amplitude: HangMotion.arrivalAmplitude)])
        XCTAssertTrue(motion.running)
        now = 100.125
        XCTAssertGreaterThan(motion.dip(at: 0, time: now), 0)
        motion.react(from: [c, a, b], to: [c, b]) { CGFloat($0) * 100 }
        XCTAssertEqual(motion.plucks.last, .init(x: 100, time: 100.125, amplitude: HangMotion.removalAmplitude))
        let count = motion.plucks.count
        motion.react(from: [a, b, c], to: (0..<5).map { _ in UUID() }) { CGFloat($0) }
        XCTAssertEqual(motion.plucks.count, count, "a filter swapping the row leaves the rope alone")
        reduce = true
        motion.pluck(at: 0, amplitude: 6)
        XCTAssertEqual(motion.plucks.count, count)
    }

    func testBreezeTravelsLeftToRightWithinItsLimit() {
        XCTAssertEqual(Swing.breezeDelay(x: -50), 0)
        XCTAssertLessThan(Swing.breezeDelay(x: 200), Swing.breezeDelay(x: 600))
        XCTAssertEqual(Swing.breezeDelay(x: 50_000), Swing.breezeMaximumDelay)
    }
}
