# Interaction and motion specifics for a dense macOS agent cockpit (press/hover/focus, disclosure, streaming text, live status, list insertion, empty/loading/error/permission states, keyboard, reduced motion)

> Verified 2026-08-30 against live sources.

## Bottom line

The single organizing rule, and it comes from both Apple and Emil Kowalski independently, is frequency-gating: how often a control is touched decides whether it animates at all. Apple's HIG says outright to "generally avoid adding motion to UI interactions that occur frequently," and Kowalski's standards make it a table — 100+ times/day gets no animation ever, which specifically means every keyboard-triggered action in your cockpit (send, stop, new chat, command palette) must be instant. Below that line the numbers are small and settled: press feedback 100–160ms, tooltips 125–200ms, disclosures 150–250ms, panels 200–500ms, and a hard ceiling of 300ms on anything in the UI proper. Two macOS-specific facts change your implementation: SwiftUI's `hoverEffect(_:isEnabled:)` is not available on macOS at all (Apple's platform list is iOS/iPadOS/Mac Catalyst/tvOS/visionOS), so every hover state in this app must be hand-built on `onHover`; and `Animation.default` is no longer a timing curve — since macOS 14 it is `spring(response: 0.55, dampingFraction: 1.0, blendDuration: 0.0)`, which is far too slow for a dense cockpit and should never be the default you reach for. Your existing `DS.Motion` tokens are already very close to correct (the curves match Kowalski's recommended `cubic-bezier(0.23, 1, 0.32, 1)` and `cubic-bezier(0.77, 0, 0.175, 1)`); the gaps are reduced-motion gating, hover tokens, and a streaming-text cadence layer.

## Concrete specifications

MOTION TABLE — cubic-bezier and SwiftUI, per interaction class. Your existing DS.Motion in Sources/BotHarness/Design/Tokens.swift already matches rows 2 and 4; the rest are additions.

| Class | Duration | cubic-bezier | SwiftUI |
|---|---|---|---|
| Press down / release | 100ms | (0.23, 1, 0.32, 1) | `.timingCurve(0.23, 1, 0.32, 1, duration: 0.10)` |
| Hover in | 0ms (instant) | none | no animation — set value directly |
| Hover out | 120ms | (0.23, 1, 0.32, 1) | `.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)` |
| Status pill / token count change | 120ms | (0.23, 1, 0.32, 1) | `DS.Motion.instant` (already correct) |
| Disclosure expand/collapse | 180ms | (0.23, 1, 0.32, 1) | `DS.Motion.surface` (already correct) |
| Row insertion | 200ms | (0.23, 1, 0.32, 1) | `.timingCurve(0.23, 1, 0.32, 1, duration: 0.20)` |
| Panel slide (right pane) | 240ms | (0.77, 0, 0.175, 1) | `DS.Motion.easeInOut` (already correct) |
| Sheet / modal | 280ms | (0.32, 0.72, 0, 1) | `.timingCurve(0.32, 0.72, 0, 1, duration: 0.28)` |
| Drag / interruptible | n/a | n/a | `.interactiveSpring` (response 0.15, damping 0.86) |
| First-run / rare delight | n/a | n/a | `.snappy(duration: 0.4)` (base bounce 0.15) |

Never `ease-in` on UI. Never `Animation.default` — since macOS 14 it is `spring(response: 0.55, dampingFraction: 1.0)`, roughly 3x too slow for this app.

PRESS. `scale 0.96–0.97` on `configuration.isPressed`, 100ms ease-out both directions. Never fade opacity on press instead of scaling — scale scales the label and icon too, which is what makes it read as physical. Your Composer.swift:315 already does `.easeOut(duration: 0.12)` on `isPressed`; tighten to 0.10 and route through `DS.Motion.press`. Destructive buttons (Stop, Revoke) get asymmetric timing: slow on press (a deliberate hold), fast on release.

HOVER — macOS rules.
- `hoverEffect` does not exist on macOS. Build on `.onHover { hovering in ... }`.
- Hover in is instant, hover out is 120ms ease-out. Asymmetry is the point: responding immediately proves the app is alive, easing out prevents snap.
- Never animate scale on a table/list row — a row cannot grow without overlapping its neighbours. Use background tint only. Apple's own guidance: "reserve scaling for elements that can increase in size without crowding nearby elements."
- Background tint on hover: `Color.primary.opacity(0.04)` light / `Color.white.opacity(0.05)` dark. Selected row is `.selection` / accent at 0.14, and hover on an already-selected row must not change anything.
- Hover-reveal of secondary controls (a copy button on a message, a re-run button on an activity row) is a legitimate Mac pattern, but the control must also be reachable from the row's context menu and from Full Keyboard Access. Hover must never be the only path to an action.
- No hover state on: static text, timestamps, the streaming message itself, status pills, anything non-interactive. A hover state is a promise that clicking does something.
- Hover on a row must not start on mouse-enter of a moving cursor passing through. Gate with a 60–80ms enter delay on rows only (not buttons) if the sidebar feels twitchy during fast traversal.

FOCUS.
- Do not draw custom focus rings. Use the system ring; it is accent-tinted and tuned. Suppress only where genuinely decorative with `.focusEffectDisabled()`.
- Focus ring must never animate — it is keyboard-driven and appears hundreds of times per session.
- Composer border on focus: change color instantly (0ms), do not animate. Composer.swift:59 currently animates `focused` through `DS.Motion.instant`; drop that to zero.
- Never move focus programmatically except when the focused element disappears.

DISCLOSURE / EXPAND.
- 180ms, `cubic-bezier(0.23, 1, 0.32, 1)`.
- Animate height, but only via SwiftUI's layout system reacting to a state change wrapped in `withAnimation` — do not animate a manual `frame(height:)`. In SwiftUI on macOS the cost is acceptable at cockpit row counts; the CSS-world "never animate height" rule is about layout/paint on the main thread and does not transfer directly. What does transfer: never animate height on more than a handful of rows at once.
- Chevron rotates 90° over the same 180ms with the same curve. Rotate, do not swap glyphs.
- Content inside fades in over the last 120ms (`opacity` only), so text does not appear stretched mid-expand.
- Under reduced motion: no height animation at all, snap open, fade the content in over 150ms.

STREAMING TEXT. Three independent problems; solve them separately.
1. Arrival cadence. Do not render every token as it lands from the model. Buffer, and flush on a display-linked timer. Two shipped shapes: Vercel's `smoothStream` releases one word every 10ms (defaults `delayInMs: 10`, `chunking: "word"`); Upstash's reveals one character every 5ms (~200 chars/sec) on a `requestAnimationFrame` loop. For SwiftUI, use a `CADisplayLink`-equivalent or a `Timer` at 60Hz and drain the buffer once per frame — never once per token. Word-chunking at 10ms is the better default for an agent cockpit because it reads as thinking rather than typing.
2. Layout thrash. Render the streaming message as a single `Text` with an accumulated `String`, not a `VStack` of per-token views. Do not re-parse markdown on every flush — parse only on completed block boundaries (a blank line, a closed fence), and render the trailing incomplete block as plain monospaced text until it closes. This is the single biggest source of visible flicker in LLM chat UIs: a half-typed ``` turns the rest of the message into a code block for one frame.
3. Scroll jitter. Use `.defaultScrollAnchor(.bottom)` on the transcript `ScrollView` and let SwiftUI reposition on content-size change. Do not call `proxy.scrollTo` on every flush — that is what causes the over-scroll-then-bounce-back jitter. ConversationView.swift:104 currently does `withAnimation(DS.Motion.instant) { proxy.scrollTo(...) }` on message change; keep that for a *new message* insertion but not for streaming growth of the last message. Auto-scroll must also disengage the moment the user scrolls up, and re-engage only when they return within ~40pt of the bottom.
4. The caret. A 2pt-wide block caret at the end of streaming text, blinking at 1.06s period (530ms on, 530ms off — the macOS text caret rate), communicates "still producing" better than any spinner. Remove it the instant the stream ends. Under reduced motion, show it solid, not blinking.

LIVE STATUS — which indicator says what.
- Indeterminate spinner (`ProgressView().controlSize(.small)`): "a request is in flight and I cannot estimate it." Correct for a model call. Apple: "Avoid labeling a spinning progress indicator." Show it only after 400ms of waiting — below Nielsen's 1.0s flow limit, a spinner that flashes for 200ms is worse than nothing.
- Determinate bar: only when you genuinely have a denominator — step 3 of 7 in a routine, 4.2MB of 11MB downloaded. Never fake it.
- Pulsing dot: a *persistent* state, not a transient operation. Green steady = connected. Amber pulsing (opacity 0.45→1.0, 1.6s, ease-in-out, autoreverse) = degraded/reconnecting. Red steady = failed. A dot pulses to say "this condition is ongoing"; a spinner spins to say "I am working on your request right now." Do not use them interchangeably.
- Never transition from circular spinner to progress bar. Apple: "Don't switch from the circular style to the bar style... transitioning between them can disrupt your interface and confuse people." If you might learn the denominator later, start with a determinate bar in indeterminate mode.
- Above 10 seconds you owe the user two things: a percent-done indicator and a Cancel.
- Status copy: never "Loading…" or "Working…". Apple explicitly: "Avoid vague terms like loading or authenticating because they seldom add value." Say "Reading 4 files", "Waiting on Gemini", "Asking permission to run `rm`".

LIST INSERTION.
- A new message or activity row enters with `opacity 0 → 1` plus `translateY(6pt) → 0` over 200ms, `cubic-bezier(0.23, 1, 0.32, 1)`. Never scale a row. Never slide horizontally.
- Stagger only applies when several rows arrive in the same frame — a routine emitting five tool calls at once. 35ms between items, cap total stagger at 5 items / 175ms; item six onward gets zero delay. Your `DS.Motion.stagger = 0.035` is already right; add the cap. Kowalski's range is 30–80ms and the explicit warning is that stagger is decorative and must never block interaction.
- A single row arriving alone gets no stagger.
- Removal is faster than insertion: 120ms opacity-only, no translate. Things should leave quicker than they arrive.
- Use `.transition(.opacity.combined(with: .offset(y: 6)))` with an explicit `.animation(_:value:)` keyed on the collection's count, not `.default`.

EMPTY / LOADING / ERROR / PERMISSION-NEEDED.
Empty state (three required parts, per NN/g): (1) why it is empty, (2) what would appear here and how it gets here, (3) a button that starts that. For an empty bot roster: "No bots yet. A bot is a name, a model, and a set of permissions it's allowed to use on this Mac." + [New Bot ⌘N]. Never a bare illustration with a one-word label.
Loading state: show structure immediately. Skeleton rows for the transcript (2–10s window), spinner for a single module. Under 1s show neither. Never a blank pane.
Error state: name the operation, quote the actual failure, offer the next action, preserve the user's input. "Gemini returned 429 rate_limit_exceeded after 3 retries. Your message is still in the composer." + [Retry] [Open Settings]. Never "An error occurred." Never blame words. Place it adjacent to the thing that failed — an inline row in the transcript, not a modal — unless it is destructive or blocking.
Permission-needed state: this is the most important state in this app and deserves the most design. It must state (a) exactly which capability, (b) exactly why this bot needs it right now, (c) what will happen if granted, (d) that macOS will not re-ask. Copy in the house voice: "Kepler needs Screen Recording to see the window it's about to click. macOS won't ask again — this has to be granted in System Settings, and the app must be relaunched afterward." + [Open System Settings] which fires `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`. Follow Apple's purpose-string rules for the TCC prompt itself: brief complete sentence, sentence case, active voice, ends with a period, states the why.

KEYBOARD — the expected set for a Mac app of this kind. Apple-reserved meanings first (do not redefine these):
- ⌘. — Cancel an operation. This is Apple's documented meaning and is the correct Stop-the-agent shortcut.
- Esc — Cancel the current action or process. Dismiss the panel/sheet; second press stops the run.
- ⌘, — Settings. ⌘? — Help. ⌘W — Close window. ⌘N — New (chat). ⌘F — Find in transcript. ⌘G / ⇧⌘G — next/previous match. ⌘` — cycle app windows (the Activity window). ⌥⌘T — show/hide toolbar. ⌘A / ⌘C / ⌘Z as normal.
App-specific, non-conflicting:
- ⌘↩ — Send. ⇧↩ — newline in composer.
- ⌘K — command palette / bot switcher (not Apple-reserved; universal convention).
- ⌘1…⌘9 — jump to Nth bot in the roster.
- ⌘⌥→ / ⌘⌥← — next/previous chat.
- ⌘0 — toggle the right panel. ⌘⌃S — toggle sidebar (matches system sidebar convention).
- ⌘⇧A — open the Activity window.
Avoid Control as a modifier: Apple says "The system uses Control in many systemwide features and shortcuts."
Actions that must NEVER animate because they are keyboard-triggered: send, stop, new chat, command palette open/close, bot switching via ⌘1–9, panel toggle, sidebar toggle, find-next. These fire dozens to hundreds of times a day. Animation here reads as lag. State changes instantly; only the *content* that arrives afterward animates.

REDUCED MOTION — exactly what to drop and what to keep.
Read once and observe changes: SwiftUI `@Environment(\.accessibilityReduceMotion)`, or AppKit `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` plus its change notification.
DROP: all `offset`/`translateY` on row insertion; the panel slide (replace with crossfade); the disclosure height animation (snap); scale on press (replace with a background tint change); the pulsing status dot (make it solid); the blinking stream caret (make it solid); all springs and all bounce; any stagger (everything arrives at once); the chevron rotation (swap the glyph).
KEEP: every opacity crossfade; every color change; the streaming text cadence itself (it is content pacing, not motion); the spinner (it is essential status — its removal would, in WCAG's words, "fundamentally change the information"); focus rings; the progress bar fill.
The legal line is WCAG 2.3.3's own exemption: "changes in color, opacity alone, or blurring that don't affect perceived size, shape, or position" are not motion animation. If it does not change perceived size, shape, or position, keep it.
Apple's own five techniques, applied here: tighten springs to zero bounce; track drags directly; no z-axis depth animation; replace x/y transitions with fades; never animate into or out of a blur (this matters for your material/vibrancy panels).
Implementation shape: a single `DS.Motion.gated(_:)` helper that returns `nil` (or `.linear(duration: 0)`) when reduce-motion is on, so every call site is `withAnimation(DS.Motion.gated(.surface))` and there is exactly one place the policy lives.

## Findings

- Apple's HIG on motion states directly: "In apps, generally avoid adding motion to UI interactions that occur frequently. The system already provides subtle animations for interactions with standard interface elements." It also says "Let people cancel motion. As much as possible, don't make people wait for an animation to complete before they can do anything, especially if they have to experience the animation more than once." and "Aim for brevity and precision in feedback animations."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/motion>
- Apple's accessibility HIG names five concrete techniques for Reduce Motion, verbatim: "Tightening animation springs to reduce bounce effects", "Tracking animations directly with people's gestures", "Avoiding animating depth changes in z-axis layers", "Replacing transitions in x-, y-, and z-axes with fades to avoid motion", "Avoiding animating into and out of blurs". It also says to reduce "automatic and repetitive animations, including zooming, scaling, and peripheral motion."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/accessibility>
- SwiftUI's `Animation.default` is documented as being a spring "with `response` equal to `0.55`, `dampingFraction` equal to `1.0`, `blendDuration` equal to `0.0`". Prior to iOS 17 / macOS 14 it was a timing curve. This is a behavioral change that silently slows any code relying on `.default`.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/animation/default>
- `Animation.easeOut` and `Animation.easeInOut` both have a documented default duration of 0.35 seconds. `Animation.timingCurve(_:_:_:_:duration:)` also defaults to `duration: TimeInterval = 0.35`.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/animation/easeout>
- The SwiftUI spring presets all share `duration: TimeInterval = 0.5` and differ only in base bounce: `smooth` has a base bounce of 0, `snappy` a base bounce of 0.15, and `bouncy` a base bounce of 0.3. The docs define duration as "the perceptual duration, which defines the pace of the spring... approximately equal to the settling duration."  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/animation/snappy(duration:extrabounce:)>
- `Animation.interactiveSpring` defaults are `response: Double = 0.15, dampingFraction: Double = 0.86, blendDuration: TimeInterval = 0.25` — described as "a convenience for a `spring` animation with a lower `response` value, intended for driving interactive animations."  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/animation/interactivespring(response:dampingfraction:blendduration:)>
- `hoverEffect(_ effect: HoverEffect = .automatic, isEnabled: Bool = true)` lists its platforms as iOS, iPadOS, Mac Catalyst, tvOS, visionOS — macOS is absent. By contrast `onHover(perform:)` explicitly includes macOS. Therefore every hover state in a native macOS SwiftUI app must be built manually on `onHover`.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/view/hovereffect(_:isenabled:)>
- Kowalski's animation standards give a frequency table with an explicit rule: "Never animate keyboard-initiated actions — they repeat hundreds of times daily; animation makes them feel slow and disconnected. (Raycast has no open/close animation — correct for something used hundreds of times a day.)" 100+ times/day gets "No animation. Ever."  
  — **confirmed** · <https://github.com/emilkowalski/skills/blob/main/skills/review-animations/STANDARDS.md>
- The same source gives a duration table: button press feedback 100–160ms; tooltips and small popovers 125–200ms; dropdowns and selects 150–250ms; modals and drawers 200–500ms. Hard rule: "UI animations stay under 300ms." And named curves: `--ease-out: cubic-bezier(0.23, 1, 0.32, 1)`, `--ease-in-out: cubic-bezier(0.77, 0, 0.175, 1)`, `--ease-drawer: cubic-bezier(0.32, 0.72, 0, 1)`.  
  — **confirmed** · <https://github.com/emilkowalski/skills/blob/main/skills/review-animations/STANDARDS.md>
- Press feedback spec: `transform: scale(0.97)` on `:active` with `transition: transform 160ms ease-out`, subtle range 0.95–0.98, applying to any pressable element. Enter animations must never start from `scale(0)` — start from `scale(0.9–0.97)` plus `opacity: 0`. Never use `ease-in` on UI: "It starts slow, delaying the exact moment the user is watching."  
  — **confirmed** · <https://github.com/emilkowalski/skills/blob/main/skills/review-animations/STANDARDS.md>
- Stagger guidance is 30–80ms between items; "Longer delays feel slow. Stagger is decorative — never block interaction while it plays." Under reduced motion the rule is "keep opacity/color, drop transform-based motion" and "Reduced motion means fewer and gentler animations, not zero."  
  — **confirmed** · <https://github.com/emilkowalski/skills/blob/main/skills/review-animations/STANDARDS.md>
- WCAG 2.3.3 (Level AAA) reads: "Motion animation triggered by interaction can be disabled, unless the animation is essential to the functionality or the information being conveyed." Critically, the criterion excludes "changes in color, opacity alone, or blurring that don't affect perceived size, shape, or position" — this is the precise legal line for what you keep under reduced motion.  
  — **confirmed** · <https://www.w3.org/WAI/WCAG21/Understanding/animation-from-interactions.html>
- The CSS Easing Functions Level 1 spec defines the keywords exactly: ease = cubic-bezier(0.25, 0.1, 0.25, 1); ease-in = cubic-bezier(0.42, 0, 1, 1); ease-out = cubic-bezier(0, 0, 0.58, 1); ease-in-out = cubic-bezier(0.42, 0, 0.58, 1); linear is an identity function with no bezier equivalent.  
  — **confirmed** · <https://www.w3.org/TR/css-easing-1/>
- Nielsen's three response-time limits: 0.1 second is "reacting instantaneously" and needs no feedback; 1.0 second is the limit for uninterrupted flow and still needs no special feedback; 10 seconds is the limit for keeping attention on the task. "Percent-done progress indicators should be used for operations taking more than about 10 seconds," together with a way to interrupt.  
  — **confirmed** · <https://www.nngroup.com/articles/response-times-3-important-limits/>
- NN/g on loading indicators: under 1 second, neither skeleton nor spinner is necessary; 2–10 seconds, both work, with skeletons preferred for full-page loads (they communicate final layout) and spinners for individual modules or cards; over 10 seconds a progress bar becomes essential. Frame-only skeletons that show headers and footers without content placeholders should be avoided entirely.  
  — **confirmed** · <https://www.nngroup.com/articles/skeleton-screens/>
- Apple's progress-indicator HIG, macOS section: "Prefer an activity indicator (spinner) to communicate the status of a background operation or when space is constrained... Spinners are also good for communicating progress within a small area, such as within a text field or next to a specific control, such as a button." And: "Avoid labeling a spinning progress indicator." Also "Don't switch from the circular style to the bar style," "Keep progress indicators moving so people know something is continuing to happen," and "Avoid vague terms like loading or authenticating because they seldom add value."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/progress-indicators>
- Apple's loading HIG: "Show something as soon as possible. If you make people wait for loading to complete before displaying anything, they can interpret the lack of content as a problem with your app... Instead, consider showing placeholder text, graphics, or animations as content loads, replacing these elements as content becomes available."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/loading>
- Apple's reserved-shortcut table defines Command-Period as "Cancel an operation" and Esc as "Cancel the current action or process." Command-Comma is "Open the app's settings window"; Command-Question mark is "Open the app's Help menu"; Command-F "Open a Find window"; Command-N "Open a new document"; Command-W "Close the active window"; Option-Command-T "Show or hide a toolbar"; Command-Grave accent "Activate the next open window in the frontmost app."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/keyboards>
- Apple's modifier-key guidance in the same table: prefer Command as the main modifier; Shift as "a secondary modifier that complements a related shortcut"; use Option "sparingly for less-common commands or power features"; and "Avoid using the Control key as a modifier. The system uses Control in many systemwide features and shortcuts, like moving focus or capturing screenshots."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/keyboards>
- Vercel's AI SDK ships a dedicated smoothing transform: `smoothStream(options?: { delayInMs?: number | null, chunking?: "word" | "line" | RegExp | Intl.Segmenter | (buffer: string) => string })` with `delayInMs` defaulting to 10ms and `chunking` defaulting to `"word"`. It exists specifically to buffer and release complete chunks "for a more natural reading experience when streaming text."  
  — **confirmed** · <https://ai-sdk.dev/docs/reference/ai-sdk-core/smooth-stream>
- Upstash's shipped implementation decouples network streaming from visual streaming: raw chunks accumulate in a buffer, and a separate `requestAnimationFrame` loop reveals one character every 5ms (~200 chars/sec) at 60fps. Their framing of the problem: "text appears in bursts as we get the chunks from the server, so the reading experience feels more unnatural."  
  — **confirmed** · <https://upstash.com/blog/smooth-streaming>
- SwiftUI provides `defaultScrollAnchor(_ anchor: UnitPoint?)` on macOS, which "associates an anchor to control which part of the scroll view's content should be rendered by default" and, importantly, "When the content size of the scroll view changes, it may consult the anchor to know how to reposition the content." This is the built-in fix for a chat transcript that must stay pinned to the bottom while streaming text grows the content height.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor(_:)>
- `focusEffectDisabled(_ disabled: Bool = true)` is available on macOS and "adds a condition that controls whether this view can display focus effects, such as a default focus ring or hover effect." Higher views in the hierarchy override lower ones. This is the correct lever for suppressing focus rings on decorative rows without breaking Full Keyboard Access elsewhere.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/view/focuseffectdisabled(_:)>
- Apple's focus HIG: "Rely on system-provided focus effects. System-defined focus effects are precisely tuned... Consider creating custom focus effects only if it's absolutely necessary." And: "Avoid changing focus without people's interaction... it's generally best to simply hide the focus indicator when the focused object disappears."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/focus-and-selection>
- NN/g's empty-state requirements are three: communicate system status (say why it is empty), give contextual help explaining what would appear and how to populate it, and provide a direct action pathway (a button or link that starts the task). Explicit rules: "Avoid totally empty states" and never show a misleading "no records" message that is later replaced by content.  
  — **confirmed** · <https://www.nngroup.com/articles/empty-state-interface-design/>
- NN/g's error-message rules: describe the problem concisely and precisely; offer constructive advice, not just identification; use human-readable language without jargon; avoid blame words like "invalid", "illegal", "incorrect"; skip humor; position the message adjacent to the error source; use redundant indicators (not color alone); match prominence to severity (toast for minor, modal for severe); and preserve the user's original input for editing.  
  — **confirmed** · <https://www.nngroup.com/articles/error-message-guidelines/>
- Apple's privacy HIG on permission copy: "Aim for a brief, complete sentence that's straightforward, specific, and easy to understand. Use sentence case, avoid passive voice, and include a period at the end." Its own worked examples mark "Microphone access is needed for a better experience." as bad (passive, vague) and "Turn on microphone access." as bad (imperative, no justification). Also: "Request permission only when your app clearly needs access" and "Avoid requesting permission at launch unless the data or resource is required for your app to function."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/privacy>
- On macOS the URL scheme to deep-link into a specific privacy pane still uses the legacy name, e.g. `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`. Screen Recording and Accessibility cannot be re-prompted programmatically after a denial; the app must send the user to System Settings.  
  — likely · <https://gist.github.com/rmcdongit/f66ff91e0dad78d4d6346a75ded4b751>
- The AppKit animator proxy plays back over 0.25 seconds by default, adjustable via `NSAnimationContext`. Apple's own `NSAnimationContext.duration` documentation confirms the property governs animation length but does not state the default value.  
  — likely · <https://jwilling.com/blog/osx-animations/>
- Apple's `NSWorkspace.accessibilityDisplayShouldReduceMotion` documentation says: "If this property's value is true, avoid large animations, especially those that simulate the third dimension," and instructs registering for a notification to receive updates when the setting changes. The SwiftUI mirror is the `accessibilityReduceMotion` environment value with identical wording.  
  — **confirmed** · <https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion>

## What to build

- Add a reduced-motion gate to DS.Motion as a single chokepoint. `@Environment(\.accessibilityReduceMotion)` read once at RootView, published into an ObservableObject, and a `DS.Motion.gated(_ a: Animation) -> Animation?` that returns nil when on. Then sweep every `withAnimation(DS.Motion.X)` call site in ConversationView, RootView, MessageRow, ActivityWindow, LibrarySheet, ContextPanelView, Composer and SettingsView through it. Right now the app has zero reduced-motion handling — grep found no reference to accessibilityReduceMotion anywhere in Sources/BotHarness/UI/. This is the largest single gap.
- Fix the streaming auto-scroll. ConversationView.swift:104 animates `proxy.scrollTo(last.id, anchor: .bottom)` on message change. Add `.defaultScrollAnchor(.bottom)` to the ScrollView and restrict the explicit scrollTo to genuine message *insertion*, not to content growth of the streaming last message. Add a user-scroll disengage: once the user scrolls more than ~40pt off the bottom, stop auto-scrolling until they come back.
- Build a streaming cadence buffer in BotRunner. Tokens from Gemini land in a buffer; a 60Hz drain flushes whole words to the published transcript string. Target one word per ~10ms (Vercel's smoothStream default). This removes burst-jitter and is a prerequisite for the caret and for not re-parsing markdown per token.
- Add incremental-markdown safety: parse only closed blocks, render the trailing incomplete block as plain monospaced text. Without this, an unclosed ``` fence reformats the whole tail of a message for a frame every time one arrives.
- Add hover tokens to DS and a `.rowHover()` view modifier built on `onHover`. Instant in, 120ms ease-out out, background tint only (0.04 light / 0.05 dark), no scale on rows, no-op when the row is already selected. `hoverEffect` is unavailable on macOS so this must be hand-built. The Sidebar and the activity rows both need it.
- Tighten press feedback: DS.Motion.press to 0.10s (already correct) and pressScale to 0.97 (currently 0.96 — Kowalski's documented subtle range is 0.95–0.98 with 0.97 as the specific recommendation). Update Composer.swift:315 from `.easeOut(duration: 0.12)` to `DS.Motion.press` so there is one source of truth.
- Stop animating focus. Composer.swift:59 has `.animation(DS.Motion.instant, value: focused)`. Focus is keyboard-driven and must be instant. Remove it.
- Cap the stagger. DS.Motion.stagger = 0.035 is correct, but add a rule that only the first 5 items get a delay and everything after is zero — a routine that emits twelve tool calls at once should not take 420ms to finish appearing.
- Add a blinking stream caret at 530ms on / 530ms off, solid under reduced motion, removed the instant the stream ends. This replaces a spinner for the 'model is still producing' state and reads far better in a transcript.
- Gate every spinner behind a 400ms delay. Composer.swift:136, ActivityInspector.swift:61 and LibrarySheet.swift:128 all show ProgressView immediately. A spinner that appears and vanishes inside 200ms is visual noise; Nielsen's 1.0s flow limit means nothing is owed to the user below it.
- Build the permission-needed state as a first-class inline row in the transcript, not an alert. Name the capability, name the bot, say why it is needed now, say that macOS will not ask again, and give an [Open System Settings] button firing the `x-apple.systempreferences:` deep link for the specific pane. This is the safety spine of the product surfacing in the UI and currently has no designed state.
- Write the three empty states properly (empty roster, empty chat, empty activity log) with all three NN/g parts: why it is empty, what would appear, and the button that starts it. Currently these are the states a first-run user sees most and they carry the whole first impression.
- Add the missing keyboard shortcuts and wire ⌘. to Stop. ⌘. is Apple's documented 'Cancel an operation' and is the single most important shortcut in an app that runs shell commands on a real Mac. Also ⌘⇧A for the Activity window, ⌘1–9 for bot switching, ⌘0 for the panel, ⌘K for the palette. Ensure none of them animate.
- Replace any vague status copy with the operation being performed. Apple explicitly names 'loading' and 'authenticating' as terms that seldom add value. The house voice already demands this — 'Reading 4 files', 'Waiting on Gemini', not 'Working…'.
- Add an ADR in docs/decisions/ recording the motion policy: the frequency table, the 300ms ceiling, the never-animate-keyboard-actions rule, and the reduced-motion drop/keep list. The falsifier: if a user reports the app feeling laggy on a specific interaction, that interaction was animated when it should not have been.

## Could not verify

- The exact control points behind CAMediaTimingFunction's named constants (kCAMediaTimingFunctionEaseInEaseOut etc.). Apple's own documentation describes the curves qualitatively and documents the functionWithControlPoints:::: creation method, but does not publish the control points for the named constants. The widely-repeated values (easeInEaseOut = 0.42, 0, 0.58, 1; default = 0.25, 0.1, 0.25, 1) match the CSS keyword definitions exactly, which is suggestive but not proof. I have given you the CSS values from the W3C spec instead, which are authoritative for those keywords; do not cite them as Apple's.
- The 0.25-second default duration of the AppKit animator proxy. This is stated by a well-regarded third-party source (jwilling.com) and by Microsoft's Xamarin binding docs, but Apple's own NSAnimationContext.duration page only says the property governs how long animations run and never states the default. Treat as strong convention, not documented fact. It matters little for you since the app is SwiftUI.
- The 530ms macOS text caret blink interval. This is the long-standing Cocoa value and matches NSTextView behavior, but I did not find an Apple document stating it. If exactness matters, read it at runtime rather than hardcoding.
- Whether macOS 26 changed the Screen Recording periodic re-authorization cadence. Reporting from 2024 says macOS 15 Sequoia introduced a 30-day re-prompt and that Apple subsequently relaxed it, but I could not find a current primary source stating the present behavior. Since the app's bundle.sh already signs with a stable designated requirement specifically to preserve these grants, verify the current cadence on the machine before writing user-facing copy that promises anything about how often macOS will ask.
- How specific shipped chat apps (ChatGPT, Claude's own desktop app, Cursor) render streaming text internally. I sourced the technique from Vercel's and Upstash's published implementations, which are real shipped code with documented numbers, but I did not reverse-engineer any closed desktop client and you should not cite one as precedent.
- SwiftUI-specific cost of animating disclosure height on macOS at cockpit row counts. The CSS-world rule against animating height is well established and well sourced; SwiftUI's layout system is different enough that I am extrapolating rather than citing a measurement. Profile it with the Activity window open and many rows expanded before trusting the 180ms figure at scale.
- Whether a 60-80ms hover-enter delay on sidebar rows actually improves the feel here. That is a judgment call from the general pattern, not a sourced value. Build it behind a constant and try it both ways.
