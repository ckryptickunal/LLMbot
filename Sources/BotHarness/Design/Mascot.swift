import SwiftUI

// Claude's mascot: eleven rectangles, four legs, and a walk.
//
// Ported from Ayotomiwa Wale-Durojaye's SVG-and-GSAP reconstruction, written up on Codrops
// (`reverse-engineering-claude-ais-mascot-animations-with-svg-and-gsap`) and running at
// https://ayotomcs.me/claude-mascot. Nothing here is eyeballed: the rectangles below are that
// page's `<rect>` list verbatim, and `Walk` is its GSAP timeline transcribed tween for tween
// from the shipped bundle, including the beat times that fall out of GSAP's `delay` and `"<"`
// positioning. See `docs/decisions/0009-port-the-mascot-rather-than-run-it.md`.

// MARK: - Geometry

/// The mascot's fixed parts, in the units of the original's `viewBox="0 0 107 86"`.
///
/// Every number in this file is in those units. Points come in once, at the bottom, where the
/// whole thing is scaled — which is what keeps the transcription checkable against the source.
public enum Mascot {

    public static let box = CGSize(width: 107, height: 86)

    /// The ground. In the original this is a `<clipPath>` around the legs, and it is the whole
    /// reason the lean reads as weight rather than as a stretch: a leg that rotates and
    /// stretches has no idea where the floor is, so without this it slides straight through it.
    static let ground = CGRect(x: -20, y: -50, width: 160, height: 136)

    static let legs = [
        CGRect(x: 11, y: 60, width: 11, height: 26),    // leg1
        CGRect(x: 32, y: 60, width: 11, height: 26),    // leg2
        CGRect(x: 64, y: 60, width: 11, height: 26),    // leg3
        CGRect(x: 85, y: 60, width: 11, height: 26),    // leg4
    ]
    static let torso = CGRect(x: 11, y: 0, width: 85, height: 65)
    static let leftHand = CGRect(x: 0, y: 21, width: 22, height: 23)
    static let rightHand = CGRect(x: 85, y: 21, width: 22, height: 23)
    static let eyes = [
        CGRect(x: 21, y: 11, width: 11, height: 11),
        CGRect(x: 75, y: 11, width: 11, height: 11),
    ]

    /// Where a leg turns. The lean bends it about the **foot**, so the leg stays planted and
    /// the body tips over it; the walk lifts it from the **hip**, so squashing the leg raises
    /// the foot off the ground. Same four rectangles, one changed anchor, and the difference
    /// between leaning and stepping.
    static let legPivotX = [16.5, 37.5, 69.5, 90.5]
    static let footY: Double = 86
    static let hipY: Double = 60

    /// The body tips about a point low in the torso rather than its centre, which is what makes
    /// the lean look like a shift of weight instead of a spin.
    static let bodyPivot = CGPoint(x: 53, y: 65)

    /// How high the jump goes, and how far a leaning hand swings outside the box. The stage has
    /// to leave room for both or the drawing gets its corners clipped off.
    static let jumpPeak: Double = 90
    static let bleed: Double = 6

    /// The height the walk needs above the floor, for a mascot drawn this wide.
    public static func stageHeight(width: CGFloat) -> CGFloat {
        (box.height + jumpPeak + bleed) * (width / box.width)
    }

    /// How far the mascot travels, in its own units, rather than however wide its container is.
    ///
    /// This is what makes the size a single number you can change. The walk is a fixed ten
    /// strides in a fixed 2.2 seconds, so if the distance were simply the width of whatever it
    /// is standing on, then a smaller mascot in the same composer would take the same ten
    /// strides across the same distance — each one carrying it several body-lengths, which
    /// reads as skating rather than walking. Pinning the distance to the mascot's own size
    /// keeps one stride at roughly two thirds of a body width whatever `DS.Size.mascot` says.
    ///
    /// Ten strides at 0.6 of a body width is the walking part; the walk is 55% of the journey
    /// and the jump is the rest.
    static let travelDistance: Double = 10 * (0.6 * box.width) / 0.55

    /// The distance actually used: never more than the container can hold.
    static func travel(inStageWidth stage: Double) -> Double {
        min(max(0, stage - box.width - bleed * 2), travelDistance)
    }
}

// MARK: - Easing

/// GSAP's easing names, kept rather than translated.
///
/// They are power curves under different labels — `power1` is quadratic, `power2` cubic,
/// `power3` quartic — and using the source's names is what lets the timeline below be read
/// side by side with the original instead of trusted.
private enum Ease {
    case linear, power1InOut, power2Out, power2In, power3In, sineOut

    func callAsFunction(_ t: Double) -> Double {
        switch self {
        case .linear:       return t
        case .power1InOut:  return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .power2Out:    return 1 - pow(1 - t, 3)
        case .power2In:     return pow(t, 3)
        case .power3In:     return pow(t, 4)
        case .sineOut:      return sin(t * .pi / 2)
        }
    }
}

// MARK: - Channels

/// One animated number across the whole loop.
///
/// The original is a GSAP timeline, but every value it animates turns out to be strictly
/// sequential — no channel is ever driven by two tweens at once. That collapses the whole
/// thing to a pure function of time: find the last tween that has started, interpolate or
/// hold. No animation state, no `withAnimation`, nothing to get out of sync, and the loop is
/// seamless because second 11.51 and second 0 are the same expression.
private struct Channel {
    struct Step {
        let start: Double, duration: Double, from: Double, to: Double, ease: Ease
    }

    let initial: Double
    let steps: [Step]

    /// Reads the way the source does: a starting value, then "at T, over D seconds, go to V".
    /// Each tween picks up wherever the last one left off, which is GSAP's behaviour and saves
    /// writing every `from` twice — and writing it twice is how they drift apart.
    init(from initial: Double, _ moves: [(at: Double, over: Double, to: Double, ease: Ease)]) {
        self.initial = initial
        var previous = initial
        var built: [Step] = []
        for move in moves {
            built.append(Step(start: move.at, duration: move.over,
                              from: previous, to: move.to, ease: move.ease))
            previous = move.to
        }
        self.steps = built
    }

    func value(at t: Double) -> Double {
        var held = initial
        for step in steps {
            if t <= step.start { break }
            if t >= step.start + step.duration { held = step.to; continue }
            let progress = step.ease((t - step.start) / step.duration)
            return step.from + (step.to - step.from) * progress
        }
        return held
    }
}

// MARK: - A pose

/// Everything animated about the mascot, as one value per frame.
///
/// Routines below are written as scores over these fields, which is what keeps six behaviours
/// from becoming six drawing functions that drift apart. The drawing code reads a `Pose` and
/// knows nothing about which state produced it.
struct Pose {
    /// 0…1 along the stage. Only the walk moves.
    var travel: Double = 0
    var rootY: Double = 0
    /// Squash and stretch, about the floor. Kept as two numbers rather than one with a derived
    /// width, because how much a character widens as it flattens is a decision per routine.
    var squashX: Double = 1
    var squashY: Double = 1

    var bodyX: Double = 0
    var bodyY: Double = 0
    var bodyRotation: Double = 0

    var leftHandY: Double = 0
    var rightHandY: Double = 0

    var eyesX: Double = 0
    var eyesY: Double = 0
    /// 1 open, 0 shut. Scales each eye about its own centre, so a blink reads at any size —
    /// which matters, because at 22 points a two-unit eye movement does not.
    var eyeOpen: Double = 1

    var legRotation: [Double] = [0, 0, 0, 0]
    var legScale: [Double] = [1, 1, 1, 1]
    /// Feet for leaning and hopping, hip for stepping. See `Mascot.footY` / `hipY`.
    var legPivotY: Double = Mascot.footY
}

/// One behaviour: how long it lasts, and the pose at any moment inside it.
struct Routine {
    let loop: Double
    /// True for a routine that plays through once and hands over, rather than repeating.
    /// A celebration on a loop stops reading as a celebration and starts reading as gloating.
    var once: Bool = false
    let pose: (Double) -> Pose
}

// MARK: - What the mascot can be doing

/// The mascot's states, one per thing the app can be doing.
///
/// These are not decoration with different names. Each maps to something the runner actually
/// reports, so a glance at the mascot answers "is it working, does it need me, did it finish" —
/// which the design system lists as a requirement rather than a feature.
public enum MascotState: String, CaseIterable, Sendable {
    /// Nothing is happening. The ported original: looks around, walks, jumps.
    case walking
    /// A run is in progress. Trots on the spot, so it reads as effort without wandering off.
    case working
    /// A run is blocked on an approval. Hops to get your attention, then waits and blinks.
    case waiting
    /// A run just finished. One celebration jump.
    case pleased
    /// A run failed. Slumps, and sighs.
    case stumped
    /// Nothing selected, nothing to do. Eyes shut, breathing.
    case asleep

    var routine: Routine {
        switch self {
        case .walking: return Routines.walking
        case .working: return Routines.working
        case .waiting: return Routines.waiting
        case .pleased: return Routines.pleased
        case .stumped: return Routines.stumped
        case .asleep:  return Routines.asleep
        }
    }

    /// What the mascot does once a one-shot routine has finished.
    var after: MascotState? { self == .pleased ? .walking : nil }
}

// MARK: - The routines

private enum Routines {

    // Amplitudes here are in the original's units, where the whole mascot is 107 wide. At the
    // size this is drawn in the composer one unit is about a fifth of a point, so anything
    // meant to be *seen* has to move the silhouette: legs, whole-body height, and the eyes
    // opening and shutting. Small eye offsets are for the larger sizes.

    // MARK: Walking — the ported original, unchanged

    /// Look left, look right, look down, hop, walk, look around again, crouch, jump, land,
    /// stand for a beat, start over. Transcribed from the source timeline; see the file header.
    static let walking: Routine = {
        let leanLeft = 0.0, leanRight = 1.9, straighten = 3.5, hop = 3.7
        let step = 4.03, leanAgain = 6.53, lookDown = 7.53, stand = 8.83
        let crouch = 9.43, jump = 9.53, land = 10.13, settle = 10.38
        let planted = 6.23
        let strides = 10, stride = 0.2

        let eyesX = Channel(from: 0, [
            (leanLeft, 0.4, -3, .power2Out), (leanRight, 0.4, 4, .power2Out),
            (straighten, 0.2, 0, .power2Out), (step, 0.2, 4, .power2Out),
            (stand, 0.4, 4, .power2Out),
        ])
        let eyesY = Channel(from: 0, [
            (leanRight, 0.4, 12, .power2Out), (straighten, 0.2, 23, .power2Out),
            (step, 0.2, 0, .power2Out), (leanAgain, 0.4, 12, .power2Out),
            (lookDown, 0.3, 23, .power2Out), (stand, 0.4, 0, .power2Out),
        ])
        let bodyRotation = Channel(from: 0, [
            (leanLeft, 0.4, -3, .power2Out), (leanRight, 0.4, 3, .power2Out),
            (straighten, 0.2, 0, .power2Out), (leanAgain, 0.4, 3, .power2Out),
            (stand, 0.4, 0, .power2Out),
        ])
        let bodyX = Channel(from: 0, [
            (leanLeft, 0.4, -3, .power2Out), (leanRight, 0.4, 3, .power2Out),
            (straighten, 0.2, 0, .power2Out), (leanAgain, 0.4, 3, .power2Out),
            (stand, 0.4, 0, .power2Out),
        ])
        let bodyY = Channel(from: 0, [
            (leanLeft, 0.4, -5, .power2Out), (leanRight, 0.4, -5, .power2Out),
            (straighten, 0.2, 0, .power2Out), (leanAgain, 0.4, -5, .power2Out),
            (stand, 0.4, 0, .power2Out), (crouch, 0.1, 8, .power3In),
            (jump, 0.42, 0, .sineOut),
        ])
        let handY = Channel(from: 0, [
            (crouch, 0.1, 10, .power3In), (jump, 0.42, -12, .sineOut),
            (land, 0.2, 0, .power3In), (settle, 0.05, 6, .power2In),
            (10.43, 0.08, 0, .power2Out),
        ])
        let travel = Channel(from: 0, [
            (step, 2.2, 0.55, .linear), (jump, 0.85, 1.0, .power1InOut),
        ])
        let height = Channel(from: 0, [
            (hop, 0.18, -18, .power2Out), (3.88, 0.15, 0, .power3In),
            (jump, 0.42, -90, .sineOut), (land, 0.2, 0, .power3In),
        ])

        let leanLeftTilt = [-7.0, -8, -8, -9], leanLeftStretch = [1.35, 1.3, 1.2, 1.15]
        let leanRightTilt = [9.0, 8, 8, 7], leanRightStretch = [1.15, 1.2, 1.3, 1.35]

        let legRotation: [Channel] = (0..<4).map { i in
            Channel(from: 0, [
                (leanLeft, 0.4, leanLeftTilt[i], .power2Out),
                (leanRight, 0.4, leanRightTilt[i], .power2Out),
                (straighten, 0.2, 0, .power2Out),
                (leanAgain, 0.4, leanRightTilt[i], .power2Out),
                (stand, 0.4, 0, .power2Out),
            ])
        }
        let legScale: [Channel] = (0..<4).map { i in
            let offset = (i % 2 == 0) ? 0.0 : stride / 2
            var moves: [(at: Double, over: Double, to: Double, ease: Ease)] = [
                (leanLeft, 0.4, leanLeftStretch[i], .power2Out),
                (leanRight, 0.4, leanRightStretch[i], .power2Out),
                (straighten, 0.2, 1, .power2Out),
            ]
            for n in 0..<strides {
                let down = step + offset + Double(n) * stride
                moves.append((down, 0.1, 0.45, .power2Out))
                moves.append((down + 0.1, 0.1, 1, .power2In))
            }
            moves.append((step + 2.1, 0.08, 1, .power2In))
            moves.append((leanAgain, 0.4, leanRightStretch[i], .power2Out))
            moves.append((stand, 0.4, 1, .power2Out))
            return Channel(from: 1, moves)
        }

        return Routine(loop: 11.51) { t in
            var pose = Pose()
            pose.travel = travel.value(at: t)
            pose.rootY = height.value(at: t)
            pose.bodyX = bodyX.value(at: t)
            pose.bodyY = bodyY.value(at: t)
            pose.bodyRotation = bodyRotation.value(at: t)
            pose.leftHandY = handY.value(at: t)
            pose.rightHandY = pose.leftHandY
            pose.eyesX = eyesX.value(at: t)
            pose.eyesY = eyesY.value(at: t)
            pose.legRotation = legRotation.map { $0.value(at: t) }
            pose.legScale = legScale.map { $0.value(at: t) }
            pose.legPivotY = (t >= step && t < planted) ? Mascot.hipY : Mascot.footY
            return pose
        }
    }()

    // MARK: Working — a trot on the spot

    /// Twelve strides in place, with the body rocking over them and one blink.
    ///
    /// It deliberately does not travel. A run can last minutes, and something crossing the
    /// composer over and over is a thing you end up watching instead of the work.
    static let working: Routine = {
        let loop = 2.4, stride = 0.2, strides = 12

        let legScale: [Channel] = (0..<4).map { i in
            let offset = (i % 2 == 0) ? 0.0 : stride / 2
            var moves: [(at: Double, over: Double, to: Double, ease: Ease)] = []
            for n in 0..<strides {
                let down = offset + Double(n) * stride
                guard down + 0.2 <= loop else { break }
                moves.append((down, 0.1, 0.5, .power2Out))
                moves.append((down + 0.1, 0.1, 1, .power2In))
            }
            return Channel(from: 1, moves)
        }
        // A trot bounces once per stride pair, which is what stops the legs looking detached
        // from the body.
        let bounce = Channel(from: 0, {
            var moves: [(at: Double, over: Double, to: Double, ease: Ease)] = []
            var t = 0.0
            while t + stride <= loop {
                moves.append((t, stride / 2, -7, .sineOut))
                moves.append((t + stride / 2, stride / 2, 0, .power2In))
                t += stride
            }
            return moves
        }())
        let rock = Channel(from: -5, [
            (0.0, 1.2, 5, .power1InOut), (1.2, 1.2, -5, .power1InOut),
        ])
        let blink = Channel(from: 1, [
            (1.0, 0.07, 0.05, .power2In), (1.07, 0.09, 1, .power2Out),
        ])

        return Routine(loop: loop) { t in
            var pose = Pose()
            pose.rootY = bounce.value(at: t)
            pose.bodyRotation = rock.value(at: t)
            pose.eyeOpen = blink.value(at: t)
            pose.legScale = legScale.map { $0.value(at: t) }
            pose.legPivotY = Mascot.hipY          // stepping, so the foot leaves the ground
            return pose
        }
    }()

    // MARK: Waiting — two hops, then patience

    /// The one state that has to be noticed. Two hops in the first second, then it stands and
    /// blinks. An animation that keeps hopping forever is one people learn to ignore; two hops
    /// and stillness is a thing that asked once and is now waiting for you.
    static let waiting: Routine = {
        let loop = 3.4
        func hop(at t: Double) -> [(at: Double, over: Double, to: Double, ease: Ease)] {
            [(t, 0.2, -16, .sineOut), (t + 0.2, 0.16, 0, .power3In)]
        }
        let height = Channel(from: 0, hop(at: 0.0) + hop(at: 0.5))
        let crouch = Channel(from: 1, [
            (0.36, 0.06, 0.86, .power2In), (0.42, 0.08, 1, .power2Out),
            (0.86, 0.06, 0.86, .power2In), (0.92, 0.08, 1, .power2Out),
        ])
        let hands = Channel(from: 0, [
            (0.0, 0.2, -7, .sineOut), (0.2, 0.16, 0, .power3In),
            (0.5, 0.2, -7, .sineOut), (0.7, 0.16, 0, .power3In),
        ])
        // Looking up at you, and blinking twice while it waits.
        let blink = Channel(from: 1, [
            (1.6, 0.07, 0.05, .power2In), (1.67, 0.09, 1, .power2Out),
            (2.7, 0.07, 0.05, .power2In), (2.77, 0.09, 1, .power2Out),
        ])
        let legs = Channel(from: 1, [
            (0.0, 0.2, 1.12, .sineOut), (0.2, 0.16, 1, .power3In),
            (0.5, 0.2, 1.12, .sineOut), (0.7, 0.16, 1, .power3In),
        ])

        return Routine(loop: loop) { t in
            var pose = Pose()
            pose.rootY = height.value(at: t)
            pose.squashY = crouch.value(at: t)
            pose.squashX = 1 + (1 - pose.squashY) * 0.5
            pose.leftHandY = hands.value(at: t)
            pose.rightHandY = pose.leftHandY
            pose.eyesY = -3
            pose.eyeOpen = blink.value(at: t)
            pose.legScale = Array(repeating: legs.value(at: t), count: 4)
            return pose
        }
    }()

    // MARK: Pleased — it finished

    /// One big jump with a squint, a small second bounce, then still. Two beats, because one
    /// reads as a glitch and three reads as gloating.
    static let pleased: Routine = {
        let loop = 2.8
        let height = Channel(from: 0, [
            (0.14, 0.32, -42, .sineOut), (0.46, 0.26, 0, .power3In),
            (0.86, 0.18, -15, .sineOut), (1.04, 0.16, 0, .power3In),
        ])
        let squash = Channel(from: 1, [
            (0.0, 0.14, 0.78, .power3In),      // gather
            (0.14, 0.2, 1.12, .power2Out),     // stretch off the ground
            (0.46, 0.26, 1, .power2In),
            (0.72, 0.08, 0.84, .power2In),     // land
            (0.8, 0.14, 1, .power2Out),
        ])
        let hands = Channel(from: 0, [
            (0.0, 0.14, 8, .power3In), (0.14, 0.32, -18, .sineOut),
            (0.46, 0.26, 0, .power3In), (0.86, 0.18, -8, .sineOut),
            (1.04, 0.16, 0, .power3In),
        ])
        // Eyes shut at the top of the jump. A squint is the whole expression, and it is the
        // only part of this that survives being drawn 22 points wide.
        let squint = Channel(from: 1, [
            (0.16, 0.1, 0.1, .power2Out), (0.62, 0.14, 1, .power2Out),
        ])
        let legs = Channel(from: 1, [
            (0.0, 0.14, 0.7, .power3In), (0.14, 0.24, 1.1, .sineOut),
            (0.46, 0.26, 1, .power2In),
        ])

        return Routine(loop: loop, once: true) { t in
            var pose = Pose()
            pose.rootY = height.value(at: t)
            pose.squashY = squash.value(at: t)
            pose.squashX = 1 + (1 - pose.squashY) * 0.6
            pose.leftHandY = hands.value(at: t)
            pose.rightHandY = pose.leftHandY
            pose.eyeOpen = squint.value(at: t)
            pose.legScale = Array(repeating: legs.value(at: t), count: 4)
            return pose
        }
    }()

    // MARK: Stumped — it failed

    /// Sinks, splays its legs, half-closes its eyes, and sighs once. Nothing about this asks
    /// for attention: the error message is doing that job, and a mascot competing with it would
    /// be the wrong kind of charming.
    static let stumped: Routine = {
        let loop = 3.2
        let sink = Channel(from: 0, [
            (0.0, 0.5, 9, .power2Out),
            (1.2, 0.7, 12, .power1InOut), (1.9, 0.8, 9, .power1InOut),   // the sigh
        ])
        let legs = Channel(from: 1, [(0.0, 0.5, 0.72, .power2Out)])
        let splay = [-7.0, -3, 3, 7]
        let splayIn = Channel(from: 0, [(0.0, 0.5, 1, .power2Out)])
        let droop = Channel(from: 1, [(0.0, 0.4, 0.45, .power2Out)])
        let hands = Channel(from: 0, [(0.0, 0.5, 7, .power2Out)])

        return Routine(loop: loop) { t in
            var pose = Pose()
            pose.bodyY = sink.value(at: t)
            pose.leftHandY = hands.value(at: t)
            pose.rightHandY = pose.leftHandY
            pose.eyesY = 4
            pose.eyeOpen = droop.value(at: t)
            let amount = splayIn.value(at: t)
            pose.legRotation = splay.map { $0 * amount }
            pose.legScale = Array(repeating: legs.value(at: t), count: 4)
            return pose
        }
    }()

    // MARK: Asleep — nothing to do

    /// Eyes shut, and the whole body breathing. Slow enough that it is not something you catch
    /// out of the corner of your eye while reading.
    static let asleep: Routine = {
        let loop = 4.0
        let breathe = Channel(from: 0, [
            (0.0, 2.0, -4, .power1InOut), (2.0, 2.0, 0, .power1InOut),
        ])
        let legs = Channel(from: 1, [
            (0.0, 2.0, 1.05, .power1InOut), (2.0, 2.0, 1, .power1InOut),
        ])
        return Routine(loop: loop) { t in
            var pose = Pose()
            pose.bodyY = breathe.value(at: t)
            pose.leftHandY = -breathe.value(at: t) * 0.4
            pose.rightHandY = pose.leftHandY
            pose.eyeOpen = 0.1
            pose.eyesY = 3
            pose.legScale = Array(repeating: legs.value(at: t), count: 4)
            return pose
        }
    }()
}

// MARK: - The view

/// The mascot, doing whatever the app is doing.
///
/// It wants the full width of its container; the floor is the bottom edge and the height comes
/// from `Mascot.stageHeight(width:)`. Under Reduce Motion it holds a still pose, because for
/// these routines there is no version of the movement that is safe to keep — the movement is
/// the whole thing.
public struct MascotView: View {
    private let state: MascotState
    private let width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var windowState
    @State private var began = Date()

    public init(_ state: MascotState = .walking, width: CGFloat = DS.Size.mascot) {
        self.state = state
        self.width = width
    }

    public var body: some View {
        Group {
            if reduceMotion {
                // Not frame zero of the loop but a moment into it, so a state that begins by
                // settling into a pose — stumped, asleep — shows the pose rather than the
                // neutral stance it happens to start from.
                canvas(state, at: min(1.0, state.routine.loop))
            } else {
                // A timeline rather than repeating animations: the pose is a function of the
                // clock, so there is no animation state to fall out of step and the loop closes
                // exactly. Paused when Bot-Harness is not the front app — this sits above the
                // composer and is therefore on screen for as long as the app is.
                TimelineView(.animation(paused: windowState == .inactive)) { timeline in
                    let (playing, t) = phase(at: timeline.date)
                    canvas(playing, at: t)
                }
            }
        }
        .frame(height: Mascot.stageHeight(width: width))
        .accessibilityHidden(true)
        // Restart the clock on a change of state, so each routine plays from its first frame
        // rather than being joined halfway through.
        .onChange(of: state) { began = Date() }
    }

    /// Which routine is playing and how far into it, given that a one-shot hands over to
    /// whatever follows it once it has run through.
    private func phase(at now: Date) -> (MascotState, Double) {
        let elapsed = max(0, now.timeIntervalSince(began))
        let routine = state.routine
        if routine.once, elapsed >= routine.loop, let after = state.after {
            return (after, (elapsed - routine.loop).truncatingRemainder(dividingBy: after.routine.loop))
        }
        return (state, elapsed.truncatingRemainder(dividingBy: routine.loop))
    }

    private func canvas(_ playing: MascotState, at t: Double) -> some View {
        let pose = playing.routine.pose(t)
        return Canvas { context, size in draw(pose, &context, in: size) }
    }

    private func draw(_ pose: Pose, _ context: inout GraphicsContext, in size: CGSize) {
        let scale = width / Mascot.box.width
        guard scale > 0 else { return }

        // From here down everything is in the original's units, with the mascot's feet on the
        // bottom edge of the stage.
        context.translateBy(x: 0, y: size.height - Mascot.box.height * scale)
        context.scaleBy(x: scale, y: scale)

        // The walk is centred in whatever it is standing on, rather than starting hard against
        // the left edge. At rest — which is most of the time, and all of the time in the states
        // that do not travel — a character parked in the corner above the field's rounded
        // shoulder reads as a layout mistake rather than as a character.
        let stage = size.width / scale
        let distance = Mascot.travel(inStageWidth: stage)
        let start = max(Mascot.bleed, (stage - distance - Mascot.box.width) / 2)
        context.translateBy(x: start + pose.travel * distance, y: pose.rootY)

        // Squash and stretch happen about the floor, so a flattened mascot stays on the ground
        // instead of sinking through it.
        context.translateBy(x: Mascot.box.width / 2, y: Mascot.box.height)
        context.scaleBy(x: pose.squashX, y: pose.squashY)
        context.translateBy(x: -Mascot.box.width / 2, y: -Mascot.box.height)

        drawLegs(pose, &context)
        drawBody(pose, &context)
    }

    private func drawLegs(_ pose: Pose, _ context: inout GraphicsContext) {
        context.drawLayer { legs in
            legs.clip(to: Path(Mascot.ground))
            for (i, leg) in Mascot.legs.enumerated() {
                legs.drawLayer { limb in
                    limb.translateBy(x: Mascot.legPivotX[i], y: pose.legPivotY)
                    limb.rotate(by: .degrees(pose.legRotation[i]))
                    limb.scaleBy(x: 1, y: pose.legScale[i])
                    limb.translateBy(x: -Mascot.legPivotX[i], y: -pose.legPivotY)
                    limb.fill(Path(leg), with: .color(DS.Brand.mascot))
                }
            }
        }
    }

    private func drawBody(_ pose: Pose, _ context: inout GraphicsContext) {
        context.drawLayer { body in
            body.translateBy(x: pose.bodyX, y: pose.bodyY)
            body.translateBy(x: Mascot.bodyPivot.x, y: Mascot.bodyPivot.y)
            body.rotate(by: .degrees(pose.bodyRotation))
            body.translateBy(x: -Mascot.bodyPivot.x, y: -Mascot.bodyPivot.y)

            body.fill(Path(Mascot.torso), with: .color(DS.Brand.mascot))

            body.drawLayer { hand in
                hand.translateBy(x: 0, y: pose.leftHandY)
                hand.fill(Path(Mascot.leftHand), with: .color(DS.Brand.mascot))
            }
            body.drawLayer { hand in
                hand.translateBy(x: 0, y: pose.rightHandY)
                hand.fill(Path(Mascot.rightHand), with: .color(DS.Brand.mascot))
            }

            body.drawLayer { eyes in
                eyes.translateBy(x: pose.eyesX, y: pose.eyesY)
                for eye in Mascot.eyes {
                    eyes.drawLayer { lid in
                        // Each eye closes about its own middle, so a blink shuts rather than
                        // shrinks.
                        let centre = eye.midY
                        lid.translateBy(x: 0, y: centre)
                        lid.scaleBy(x: 1, y: max(0.02, pose.eyeOpen))
                        lid.translateBy(x: 0, y: -centre)
                        lid.fill(Path(eye), with: .color(DS.Brand.mascotEye))
                    }
                }
            }
        }
    }
}
