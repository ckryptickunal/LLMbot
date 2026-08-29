# The design system

One namespace, `DS`, holds every value the interface may use. Nothing in a view contains a raw
number or a raw colour. If a view needs a value that is not in the system, the answer is to add
it to the system and say what it is for — never to write `14` inline.

That single rule is the whole mechanism. **A design system is not a palette; it is the absence
of exceptions.** Two panels that are almost the same grey, or a button that is 24 points here
and 26 there, are the kind of defect nobody files and everybody feels.

Implemented in [`Sources/BotHarness/Design/Tokens.swift`](../Sources/BotHarness/Design/Tokens.swift)
and [`Primitives.swift`](../Sources/BotHarness/Design/Primitives.swift).

---

## What this app is, before what it looks like

Design decisions only make sense against a brief, so:

- **A tool, not a document.** It sits open beside a terminal and an editor for hours. Dense,
  quiet, fast. Nothing performs.
- **One window, one mode.** A Mac window, dark. No light theme, no phone layout. Every value
  below is tuned for that and would need re-tuning for anything else.
- **The conversation is the product.** Everything else gets out of its way. Chrome is quiet
  enough that a message bubble is the brightest thing on screen.
- **Watchable.** The user should be able to see what the agent is doing at a glance and stop
  it in one click. That is a design requirement, not a feature.

---

## 1. Space

A 4-point base. Every padding, gap, inset and margin comes from here, which is what makes
unrelated parts of the app line up without anyone measuring.

| Token | Value | Used for |
|---|---|---|
| `hair` | 2 | Optical nudges only |
| `xs` | 4 | Between an icon and its label |
| `sm` | 6 | Inside dense chips |
| `md` | 8 | Default gap between siblings |
| `lg` | 12 | Inside cards |
| `xl` | 16 | Between groups |
| `xxl` | 24 | Between sections |
| `xxxl` | 40 | Page margins, empty states |

**Rule of thumb.** If you are unsure, `md` between things and `lg` inside things. The gap
between two elements should be smaller than the padding of whatever contains them, or the
container stops reading as a container.

## 2. Radius

| Token | Value | Used for |
|---|---|---|
| `xs` | 4 | Inline code, tiny tags |
| `sm` | 6 | Fields inside cards |
| `md` | 8 | Rows, small cards |
| `lg` | 10 | Cards |
| `xl` | 14 | Message bubbles |
| `pill` | 999 | Chips, status pills, the composer |

**Nested corners must differ.** An inner radius should be roughly the outer radius minus the
padding between them. A card at `lg` with `lg` padding wants its inner field at `sm`. Equal
nested radii look subtly wrong in a way most people cannot name.

## 3. Type

Six steps, tight, because this is a dense tool rather than a document. Half-points appear where
the optical difference earns it: at this density 12.5 genuinely reads better than either 12 or
13 for supporting text.

| Token | Size | Weight | Used for |
|---|---|---|---|
| `display` | 15 | semibold | Empty-state titles, and nothing else |
| `title` | 13.5 | semibold | Pane and section titles |
| `body` | 13 | regular | The default: message bodies, list rows |
| `secondary` | 12 | regular | Supporting text beside a body line |
| `caption` | 11.5 | regular | Labels, chips, metadata |
| `micro` | 10.5 | regular | Timestamps, counters — the smallest readable thing |
| `mono(size)` | 11.5 | regular | **Anything the machine wrote**: commands, paths, arguments, output |

Body text gets 2.5 points of extra line spacing. Multi-line prose is unreadable at this size
without it, and single lines are unaffected.

**The monospace rule matters more than it looks.** Every command, path, argument and piece of
tool output is monospaced. It is how a reader knows instantly whether they are looking at
something a person wrote or something a machine did — which, in an app that runs commands on
your Mac, is the most important distinction on screen.

## 4. Colour

Dark and near-black. Surfaces are separated by luminance alone; borders appear only where
something must read as interactive or as containing something consequential.

**Every surface is opaque**, not a white overlay. Stacking two translucent surfaces produces a
third unintended shade, and once that happens the system has quietly stopped being a system.

### Surfaces, darkest to lightest

| Token | Used for |
|---|---|
| `ground` | The window itself, and the conversation column |
| `panel` | Sidebar and inspector |
| `raised` | Cards: tool activity, approvals, connection rows |
| `overlay` | Menus and sheets above everything else |

Not pure black. On a modern display, pure black makes the seams between panels vanish and the
layout stops reading as layered.

### Bubbles

`bubbleBot` and `bubbleUser` are a deliberate step apart. Authorship should be legible without
reading a word — the user's messages are lighter, and hug their content; the bot's are darker
and run wider.

### Text, by importance

| Token | Opacity | Used for |
|---|---|---|
| `ink` | 93% | Anything the user actually reads |
| `inkSecondary` | 58% | Supporting text, labels |
| `inkTertiary` | 34% | Timestamps, hints, placeholders |
| `inkDisabled` | 20% | Unavailable controls |

Four levels, not five. A fifth always becomes indistinguishable from one of its neighbours.

### Status

`running` amber · `done` green · `failed` red · `waiting` blue

**Only ever used for dots, pills and icons — never for large areas.** A red panel is alarming;
a red dot is informative. The app runs commands on a real machine, so it must be able to say
"this failed" without making the user's chest tighten.

### Two special colours

- `literal` — a salmon, for paths, addresses and inline code *inside prose*. It says "this is a
  literal value" without shouting.
- `accent` — white, and there is exactly one meaning: this is the primary action. If two things
  on screen are white-filled, one of them is wrong.

## 5. Size

Named because they recur, and because a control that is one size here and another there is a
bug nobody reports.

| Token | Value |
|---|---|
| `iconButton` / `iconButtonLarge` | 24 / 28 |
| `glyph` / `glyphSmall` | 12 / 10 |
| `avatar` / `avatarLarge` | 30 / 56 |
| `statusDot` | 6.5 |
| `rowHeight` | 44 |
| `sidebar` / `inspector` | 310 / 340 |
| `bubbleMax` / `cardMax` | 620 |
| `hairline` | 1 |

620 for bubbles is not arbitrary: beyond roughly 90 characters, line length stops being
comfortable to read, and a wide window would otherwise stretch prose across the whole screen.

## 6. Motion

**How often a surface appears decides how much animation it earns.** Things seen constantly must
not perform; things seen rarely may.

| Frequency | Treatment | Token |
|---|---|---|
| Hundreds of times a day (keyboard actions) | None, ever | — |
| Constantly (message arriving, status changing) | 120 ms, barely noticed | `instant` |
| Occasionally (disclosure, panel, sheet) | 180 ms | `surface` |
| Rarely (first run, empty state) | Spring, may delight | `rare` |
| Press feedback | 100 ms, scale 0.96 | `press` |

### Curves

```
easeOut     cubic-bezier(0.23, 1, 0.32, 1)     entering, appearing, responding
easeInOut   cubic-bezier(0.77, 0, 0.175, 1)    moving or morphing on screen
```

**No `ease-in` anywhere.** It delays the first frame — the exact moment the eye is on it — and
makes an interface feel slower at identical duration. The built-in CSS-style easings are also
too weak to read as deliberate, which is why both curves above are custom.

### Rules

- Animate `transform` and `opacity` only. Both skip layout and paint.
- Never enter from `scale(0)`. Nothing in the real world appears from nothing; start at 0.95.
- Transitions, not keyframes, for anything that can be interrupted. A keyframe restarts from
  zero when retriggered; a transition retargets from where it is.
- Exit faster than enter. The user has already decided.
- Stagger entering lists by 35 ms. Longer reads as slowness.

### Reduced motion

Respected through `dsAnimation`, and it does not mean *no* animation — it means no *movement*.
Opacity and colour still carry meaning; sliding and scaling are what cause harm.

---

## 7. Components

Each of these exists as a type rather than a pile of repeated modifiers for one reason: **a
state implemented only where someone remembered it is a state that is wrong somewhere.**

| Component | States it handles |
|---|---|
| `IconButton` | default · hover · pressed · loading · disabled |
| `PrimaryButton` | default · hover · pressed · loading · disabled |
| `SecondaryButton` | default · hover · pressed · destructive |
| `Surface` | with or without hairline, any fill |
| `Chip` | with or without icon, with or without chevron |
| `StatusPill` | running · done · failed · waiting · idle |
| `Spinner` | one size parameter, one tint |
| `Skeleton` / `SkeletonBlock` | shaped like what it replaces |
| `EmptyState` | icon · title · explanation · optional action |
| `ErrorState` | message · retry |
| `SectionLabel`, `Hairline`, `Disclosure` | — |

### Loading, specifically

Three kinds, and choosing the wrong one is what makes an app feel cheap:

1. **Skeleton** — when the *shape* of what is coming is known. Message lists, connection rows,
   screenshots. Shaped like the real content so nothing jumps when it lands.
2. **Spinner** — when the shape is unknown or the wait is inside a control. Deliberately faster
   than the system default: a quicker spin makes an identical wait feel shorter.
3. **Nothing** — when the wait is under about 100 ms. A flash of loading state is worse than no
   loading state, and most local work is faster than the eye.

Never a full-screen spinner. If the whole window is blocked, the design is wrong somewhere else.

### Empty states

Every one has an icon, a title, a sentence explaining what will put something here, and — where
one exists — the action that would. **An empty state without a next step is a dead end that
happens to be polite.**

---

## 8. Writing

The interface is mostly words, so they are part of the system.

- **Sentence case.** Not Title Case. "Share as template", not "Share As Template".
- **Say what will happen**, not what the thing is. "Grant" beats "Permissions".
- **No jargon in the interface.** The user reads "Connections", not "MCP servers"; "This Mac",
  not "host environment". The vocabulary of the implementation stays in the implementation.
- **Errors say what to do**, not what failed. "Not reachable — is the app running?" beats
  "ECONNREFUSED 127.0.0.1:3845".
- **Never claim a state that is not true.** The brain chip reads "Claude Code → Gemini" when
  Claude Code is selected but has no adapter, because showing a name that is not the one
  answering is worse than showing an awkward one that is.

---

## 9. Adding to the system

1. Look for a token that already fits. Usually one does.
2. If nothing fits, add a token — do not write the literal at the call site.
3. Name it for **what it is for**, not what it is. `bubbleMax`, not `width620`.
4. If a component needs a new state, add it to the component so every use gets it.
5. Update this document in the same change.
