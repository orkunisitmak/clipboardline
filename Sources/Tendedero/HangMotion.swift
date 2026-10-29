import AppKit
import SwiftUI

/// The rope reacts to weight: a card that arrives pulls it down, one that
/// leaves lets it spring back, and the ripple runs out to its neighbours.
/// A closed-form damped wave (contracts/hang-motion.json) keeps macOS and
/// Windows identical and costs nothing once it has settled.
@MainActor
final class HangMotion: ObservableObject {
    struct Pluck: Equatable { var x: CGFloat; var time: TimeInterval; var amplitude: CGFloat }

    nonisolated static let arrivalAmplitude: CGFloat = 6, removalAmplitude: CGFloat = -4
    nonisolated static let falloff: CGFloat = 260, waveSpeed: CGFloat = 1100
    nonisolated static let frequency = 2.0, decay = 5.5, lifetime: TimeInterval = 1.2
    nonisolated static let maximumDip: CGFloat = 10, maximumChanges = 3

    /// True only while a ripple is alive, so views animate on demand.
    @Published private(set) var running = false
    private(set) var plucks: [Pluck] = []
    private var stopGeneration = 0
    private let clock: () -> TimeInterval
    private let reduceMotion: () -> Bool

    init(clock: @escaping () -> TimeInterval = { Date.timeIntervalSinceReferenceDate },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.clock = clock
        self.reduceMotion = reduceMotion
    }

    func pluck(at x: CGFloat, amplitude: CGFloat) {
        guard !reduceMotion() else { return }
        let now = clock()
        plucks.removeAll { now - $0.time > Self.lifetime }
        plucks.append(Pluck(x: x, time: now, amplitude: amplitude))
        running = true
        stopGeneration += 1
        let generation = stopGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime) { [weak self] in
            guard let self, self.stopGeneration == generation else { return }
            self.plucks.removeAll()
            self.running = false
        }
    }

    /// Small, local changes pluck the rope; a search or filter that swaps the
    /// whole row does not.
    func react(from old: [UUID], to new: [UUID], x: (Int) -> CGFloat) {
        let before = Set(old), after = Set(new)
        let added = new.enumerated().filter { !before.contains($0.element) }
        let removed = old.enumerated().filter { !after.contains($0.element) }
        guard !old.isEmpty || !new.isEmpty, added.count + removed.count <= Self.maximumChanges else { return }
        for item in added { pluck(at: x(item.offset), amplitude: Self.arrivalAmplitude) }
        for item in removed { pluck(at: x(item.offset), amplitude: Self.removalAmplitude) }
    }

    func dip(at x: CGFloat, time: TimeInterval) -> CGFloat {
        Self.dip(at: x, time: time, plucks: plucks)
    }

    nonisolated static func dip(at x: CGFloat, time: TimeInterval, plucks: [Pluck]) -> CGFloat {
        var total: CGFloat = 0
        for pluck in plucks {
            let distance = abs(x - pluck.x)
            let age = time - pluck.time
            let tau = age - Double(distance / waveSpeed)
            guard tau > 0, age <= lifetime else { continue }
            total += pluck.amplitude * CGFloat(exp(-Double(distance / falloff)) * exp(-decay * tau) * sin(2 * .pi * frequency * tau))
        }
        return max(-maximumDip, min(maximumDip, total))
    }
}

/// Hangs a card from the moving rope: it follows the dip under its clip.
struct RopeHung: ViewModifier {
    @ObservedObject var motion: HangMotion
    let x: CGFloat
    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !motion.running)) { context in
            content.offset(y: motion.running ? motion.dip(at: x, time: context.date.timeIntervalSinceReferenceDate) : 0)
        }
    }
}

extension View {
    func hung(on motion: HangMotion, x: CGFloat) -> some View { modifier(RopeHung(motion: motion, x: x)) }
}

/// Calm, mostly-damped springs: the card settles in about a second with one
/// visible overshoot, the way system motion does.
enum Swing {
    static let arrivalDegrees = 10.0
    static let spring = Animation.interpolatingSpring(stiffness: 70, damping: 7)
    static let breezeSpeed = 1800.0, breezeMaximumDelay = 0.6
    /// The breeze travels left to right, so a card's turn comes with its place.
    static func breezeDelay(x: CGFloat) -> Double { max(0, min(breezeMaximumDelay, Double(x) / breezeSpeed)) }
}
