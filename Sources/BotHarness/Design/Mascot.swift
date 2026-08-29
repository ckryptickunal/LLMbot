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

// MARK: - The walk

/// The timeline: look left, look right, look down, hop, walk, look around again, crouch, jump,
/// land, stand for a beat, start over.
private enum Walk {

    /// Beats, in seconds from the top of the loop. These are not round numbers because they are
    /// not chosen — they are the running sum of the source's durations and `delay`s, so any one
    /// of them can be checked against it.
    private static let leanLeft = 0.0
    private static let leanRight = 1.9
    private static let straighten = 3.5
    private static let hop = 3.7
    private static let step = 4.03           // legs switch to the hip pivot here
    private static let planted = 6.23        // and back to the foot pivot here
    private static let leanAgain = 6.53
    private static let lookDown = 7.53
    private static let stand = 8.83
    private static let crouch = 9.43
    private static let jump = 9.53
    private static let land = 10.13
    private static let settle = 10.38

    /// The last second is the mascot standing still at the far side before the whole thing
    /// snaps back and starts over. That snap is in the original too.
    static let loop = 11.51

    /// Ten steps of the walk cycle. Legs 1 and 3 lift together, then legs 2 and 4, every
    /// 0.2 seconds — the diagonal gait of something with four legs and no knees.
    private static let strides = 10
    private static let stride = 0.2

    // MARK: Eyes

    static let eyesX = Channel(from: 0, [
        (leanLeft,   0.4, -3, .power2Out),
        (leanRight,  0.4,  4, .power2Out),
        (straighten, 0.2,  0, .power2Out),
        (step,       0.2,  4, .power2Out),
        (stand,      0.4,  4, .power2Out),
    ])

    static let eyesY = Channel(from: 0, [
        (leanRight,  0.4, 12, .power2Out),
        (straighten, 0.2, 23, .power2Out),   // looking at its own feet
        (step,       0.2,  0, .power2Out),
        (leanAgain,  0.4, 12, .power2Out),
        (lookDown,   0.3, 23, .power2Out),   // checking the drop before the jump
        (stand,      0.4,  0, .power2Out),
    ])

    // MARK: Body

    static let bodyRotation = Channel(from: 0, [
        (leanLeft,   0.4, -3, .power2Out),
        (leanRight,  0.4,  3, .power2Out),
        (straighten, 0.2,  0, .power2Out),
        (leanAgain,  0.4,  3, .power2Out),
        (stand,      0.4,  0, .power2Out),
    ])

    static let bodyX = Channel(from: 0, [
        (leanLeft,   0.4, -3, .power2Out),
        (leanRight,  0.4,  3, .power2Out),
        (straighten, 0.2,  0, .power2Out),
        (leanAgain,  0.4,  3, .power2Out),
        (stand,      0.4,  0, .power2Out),
    ])

    static let bodyY = Channel(from: 0, [
        (leanLeft,   0.4, -5, .power2Out),
        (leanRight,  0.4, -5, .power2Out),
        (straighten, 0.2,  0, .power2Out),
        (leanAgain,  0.4, -5, .power2Out),
        (stand,      0.4,  0, .power2Out),
        (crouch,     0.1,  8, .power3In),    // the dip that gathers the jump
        (jump,      0.42,  0, .sineOut),
    ])

    // MARK: Hands

    static let handY = Channel(from: 0, [
        (crouch,  0.1,  10, .power3In),
        (jump,   0.42, -12, .sineOut),
        (land,    0.2,   0, .power3In),
        (settle, 0.05,   6, .power2In),      // overshoot on landing; without it the jump ends stiff
        (10.43,  0.08,   0, .power2Out),
    ])

    // MARK: The whole character

    /// How far along the stage the mascot is, 0 to 1. It walks a bit over half the way, then
    /// jumps the rest — so the walk and the jump together cross exactly one screen's worth.
    static let travel = Channel(from: 0, [
        (step, 2.2, 0.55, .linear),
        (jump, 0.85, 1.0, .power1InOut),
    ])

    /// Vertical. The small hop before the walk, then the jump: `sineOut` up and `power3In`
    /// down, because equal easing in both directions reads as floating rather than falling.
    static let height = Channel(from: 0, [
        (hop,  0.18, -18, .power2Out),
        (3.88, 0.15,   0, .power3In),
        (jump, 0.42, -90, .sineOut),
        (land,  0.2,   0, .power3In),
    ])

    // MARK: Legs

    /// Each leg gets its own tilt and stretch, and the ones nearest the direction of the lean
    /// take more of it. That asymmetry is most of what sells the weight.
    private static let leanLeftTilt = [-7.0, -8, -8, -9]
    private static let leanLeftStretch = [1.35, 1.3, 1.2, 1.15]
    private static let leanRightTilt = [9.0, 8, 8, 7]
    private static let leanRightStretch = [1.15, 1.2, 1.3, 1.35]

    static let legRotation: [Channel] = (0..<4).map { i in
        Channel(from: 0, [
            (leanLeft,   0.4, leanLeftTilt[i],  .power2Out),
            (leanRight,  0.4, leanRightTilt[i], .power2Out),
            (straighten, 0.2, 0,                .power2Out),
            (leanAgain,  0.4, leanRightTilt[i], .power2Out),
            (stand,      0.4, 0,                .power2Out),
        ])
    }

    static let legScale: [Channel] = (0..<4).map { i in
        // Legs 1 and 3 lead; legs 2 and 4 come half a stride later.
        let offset = (i % 2 == 0) ? 0.0 : stride / 2
        var moves: [(at: Double, over: Double, to: Double, ease: Ease)] = [
            (leanLeft,   0.4, leanLeftStretch[i],  .power2Out),
            (leanRight,  0.4, leanRightStretch[i], .power2Out),
            (straighten, 0.2, 1,                   .power2Out),
        ]
        for n in 0..<strides {
            let down = step + offset + Double(n) * stride
            moves.append((down, 0.1, 0.45, .power2Out))     // foot lifts toward the hip
            moves.append((down + 0.1, 0.1, 1, .power2In))   // and plants again
        }
        moves.append((step + 2.1, 0.08, 1, .power2In))
        moves.append((leanAgain, 0.4, leanRightStretch[i], .power2Out))
        moves.append((stand, 0.4, 1, .power2Out))
        return Channel(from: 1, moves)
    }

    /// The anchor swap, which is a `.call()` in the original rather than a tween.
    static func legPivotY(at t: Double) -> Double {
        (t >= step && t < planted) ? Mascot.hipY : Mascot.footY
    }
}

// MARK: - The view

/// The mascot, walking across whatever width it is given.
///
/// It wants the full width of its container and `Mascot.stageHeight(width:)` of height; the
/// floor is the bottom edge. Under Reduce Motion it stands still, because for a walk there is
/// no version of the movement that is safe to keep — the movement is the whole thing.
public struct WalkingMascot: View {
    private let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var windowState
    @State private var began = Date()

    /// The default is the size it takes on the strip above the composer.
    public init(width: CGFloat = DS.Size.mascot) {
        self.width = width
    }

    public var body: some View {
        Group {
            if reduceMotion {
                canvas(at: 0)
            } else {
                // A timeline rather than repeating animations: the pose is a function of the
                // clock, so there is no animation state to fall out of step, and the loop
                // closes exactly.
                //
                // Paused when the window is not the front one. This sits above the composer
                // and is therefore on screen for as long as the app is, which in this app
                // means all day — redrawing it at the display's refresh rate behind someone
                // else's window is spending a laptop's battery on a picture nobody is looking
                // at. Because the pose is computed from the clock rather than accumulated,
                // resuming lands on the right frame with no visible seam.
                TimelineView(.animation(paused: windowState == .inactive)) { timeline in
                    canvas(at: timeline.date.timeIntervalSince(began)
                        .truncatingRemainder(dividingBy: Walk.loop))
                }
            }
        }
        .frame(height: Mascot.stageHeight(width: width))
        .accessibilityHidden(true)
    }

    private func canvas(at t: Double) -> some View {
        Canvas { context, size in draw(&context, in: size, at: t) }
    }

    private func draw(_ context: inout GraphicsContext, in size: CGSize, at t: Double) {
        let scale = width / Mascot.box.width
        guard scale > 0 else { return }

        // From here down everything is in the original's units, with the mascot's feet on the
        // bottom edge of the stage.
        context.translateBy(x: 0, y: size.height - Mascot.box.height * scale)
        context.scaleBy(x: scale, y: scale)

        let stage = size.width / scale
        let distance = max(0, stage - Mascot.box.width - Mascot.bleed * 2)

        context.translateBy(x: Mascot.bleed + Walk.travel.value(at: t) * distance,
                            y: Walk.height.value(at: t))

        drawLegs(&context, at: t)
        drawBody(&context, at: t)
    }

    private func drawLegs(_ context: inout GraphicsContext, at t: Double) {
        let pivotY = Walk.legPivotY(at: t)
        context.drawLayer { legs in
            legs.clip(to: Path(Mascot.ground))
            for (i, leg) in Mascot.legs.enumerated() {
                legs.drawLayer { limb in
                    limb.translateBy(x: Mascot.legPivotX[i], y: pivotY)
                    limb.rotate(by: .degrees(Walk.legRotation[i].value(at: t)))
                    limb.scaleBy(x: 1, y: Walk.legScale[i].value(at: t))
                    limb.translateBy(x: -Mascot.legPivotX[i], y: -pivotY)
                    limb.fill(Path(leg), with: .color(DS.Brand.mascot))
                }
            }
        }
    }

    private func drawBody(_ context: inout GraphicsContext, at t: Double) {
        context.drawLayer { body in
            body.translateBy(x: Walk.bodyX.value(at: t), y: Walk.bodyY.value(at: t))
            body.translateBy(x: Mascot.bodyPivot.x, y: Mascot.bodyPivot.y)
            body.rotate(by: .degrees(Walk.bodyRotation.value(at: t)))
            body.translateBy(x: -Mascot.bodyPivot.x, y: -Mascot.bodyPivot.y)

            body.fill(Path(Mascot.torso), with: .color(DS.Brand.mascot))

            body.drawLayer { hands in
                hands.translateBy(x: 0, y: Walk.handY.value(at: t))
                hands.fill(Path(Mascot.leftHand), with: .color(DS.Brand.mascot))
                hands.fill(Path(Mascot.rightHand), with: .color(DS.Brand.mascot))
            }

            body.drawLayer { eyes in
                eyes.translateBy(x: Walk.eyesX.value(at: t), y: Walk.eyesY.value(at: t))
                for eye in Mascot.eyes {
                    eyes.fill(Path(eye), with: .color(DS.Brand.mascotEye))
                }
            }
        }
    }
}
