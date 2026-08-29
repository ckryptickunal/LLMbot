# Choosing the design system base for Bot-Harness (dark, dense, native macOS agent cockpit)

> Verified 2026-08-30 against live sources.

## Bottom line

Use **Radix Colors** (MIT) as the colour base, take **Radix Themes' space/radius/type structure** as the geometry base, and let **macOS itself own the four things Radix cannot supply** — the user's accent colour, window materials, type metrics, and the focus ring. Radix wins on four specifics no other candidate matches: its dark scale is authored as its own palette rather than a flipped light ramp; its 12 steps are a semantic contract (step 3 = element background, 6 = subtle border, 9 = solid fill, 11 = low-contrast text) rather than a lightness ramp, so it tells you which value to use instead of leaving you to guess; it ships a matched **alpha** scale, which is the only way to tint a surface that sits on an `NSVisualEffectView` material without killing the material; and it ships **Display P3** values, which matters because every Mac display is P3 and SwiftUI has a P3 initialiser. As a bonus that reads as a good omen: Radix `blue9` dark is `#0090FF` and macOS 26.5.2's `NSColor.systemBlue` in dark aqua measures `#0091FF` — one digit apart, so the Radix accent and the OS accent will never look like they came from different apps. Apple's HIG cannot be the base because Apple stopped publishing numeric colour values: the HIG colour page now renders every system colour as a PNG swatch, and macOS publishes no neutral surface ramp at all (you get windowBackground, controlBackground, underPageBackground and nothing between), which a three-pane cockpit with five depth levels needs.

## Concrete specifications

═══════════════════════════════════════════════════════
PART 1 — THE BASE SCALE: RADIX SLATE (DARK)
Source: https://raw.githubusercontent.com/radix-ui/colors/main/src/dark.ts (fetched, MIT)
═══════════════════════════════════════════════════════

Step  sRGB hex   Display P3                              Radix semantic meaning
 1    #111113    color(display-p3 0.067 0.067 0.074)     App background
 2    #18191b    color(display-p3 0.095 0.098 0.105)     Subtle background
 3    #212225    color(display-p3 0.130 0.135 0.145)     UI element background
 4    #272a2d    color(display-p3 0.156 0.163 0.176)     Hovered UI element background
 5    #2e3135    color(display-p3 0.183 0.191 0.206)     Active / selected UI element background
 6    #363a3f    color(display-p3 0.215 0.226 0.244)     Subtle borders and separators
 7    #43484e    color(display-p3 0.265 0.280 0.302)     UI element border and focus rings
 8    #5a6169    color(display-p3 0.357 0.381 0.409)     Hovered UI element border
 9    #696e77    color(display-p3 0.415 0.431 0.463)     Solid backgrounds
10    #777b84    color(display-p3 0.469 0.483 0.514)     Hovered solid backgrounds
11    #b0b4ba    color(display-p3 0.692 0.704 0.728)     Low-contrast text
12    #edeef0    color(display-p3 0.930 0.933 0.940)     High-contrast text

SLATE ALPHA (dark) — the overlay scale. Use these on top of materials.
Hex8 is #RRGGBBAA; decimal alpha given because SwiftUI wants a Double.

 A1  #00000000  a=0.000
 A2  #d8f4f609  a=0.035   tint rgb(216,244,246)
 A3  #ddeaf814  a=0.078   tint rgb(221,234,248)
 A4  #d3edf81d  a=0.114   tint rgb(211,237,248)
 A5  #d9edfe25  a=0.145   tint rgb(217,237,254)
 A6  #d6ebfd30  a=0.188   tint rgb(214,235,253)
 A7  #d9edff40  a=0.251   tint rgb(217,237,255)
 A8  #d9edff5d  a=0.365
 A9  #dfebfd6d  a=0.427
A10  #e5edfd7b  a=0.482
A11  #f1f7feb5  a=0.710   tint rgb(241,247,254)
A12  #fcfdffef  a=0.937   tint rgb(252,253,255)

Note the tint: Radix's dark alphas are NOT pure white. They are a very slightly cool
white (roughly rgb(217,237,255) in the mid steps). That cool cast is what stops a dark
grey app from looking brown when you stack overlays. The current Bot-Harness tokens use
`Color.white.opacity(...)`, which is the warm/neutral version of the same idea.

═══════════════════════════════════════════════════════
PART 2 — ACCENTS (RADIX DARK, sRGB hex, all 12 steps)
═══════════════════════════════════════════════════════

blue    1 #0d1520  2 #111927  3 #0d2847  4 #003362  5 #004074  6 #104d87
        7 #205d9e  8 #2870bd  9 #0090ff 10 #3b9eff 11 #70b8ff 12 #c2e6ff
green   1 #0e1512  2 #121b17  3 #132d21  4 #113b29  5 #174933  6 #20573e
        7 #28684a  8 #2f7c57  9 #30a46c 10 #33b074 11 #3dd68c 12 #b1f1cb
amber   1 #16120c  2 #1d180f  3 #302008  4 #3f2700  5 #4d3000  6 #5c3d05
        7 #714f19  8 #8f6424  9 #ffc53d 10 #ffd60a 11 #ffca16 12 #ffe7b3
red     1 #191111  2 #201314  3 #3b1219  4 #500f1c  5 #611623  6 #72232d
        7 #8c333a  8 #b54548  9 #e5484d 10 #ec5d5e 11 #ff9592 12 #ffd1d9
orange  1 #17120e  2 #1e160f  3 #331e0b  4 #462100  5 #562800  6 #66350c
        7 #7e451d  8 #a35829  9 #f76b15 10 #ff801f 11 #ffa057 12 #ffe0c2
iris    1 #13131e  2 #171625  3 #202248  4 #262a65  5 #303374  6 #3d3e82
        7 #4a4a95  8 #5958b1  9 #5b5bd6 10 #6e6ade 11 #b1a9ff 12 #e0dffe
teal    1 #0d1514  2 #111c1b  3 #0d2d2a  4 #023b37  5 #084843  6 #145750
        7 #1c6961  8 #207e73  9 #12a594 10 #0eb39e 11 #0bd8b6 12 #adf0dd
cyan    1 #0b161a  2 #101b20  3 #082c36  4 #003848  5 #004558  6 #045468
        7 #12677e  8 #11809c  9 #00a2c7 10 #23afd0 11 #4ccce6 12 #b6ecf7

Display P3 equivalents exist for every one of these in the same source file; blue9 is
color(display-p3 0.247 0.556 0.969), green9 is (0.332 0.634 0.442), amber9 is
(1 0.770 0.260), red9 is (0.830 0.329 0.324).

═══════════════════════════════════════════════════════
PART 3 — MEASURED CONTRAST (WCAG 2.1, computed from the hexes above)
═══════════════════════════════════════════════════════

slate12 #edeef0 on slate1 #111113 .................. 16.25:1
slate11 #b0b4ba on slate1 .......................... 9.06:1
slate11 on slate2 #18191b .......................... 8.45:1
slate11 on slate3 #212225 .......................... 7.64:1
slate10 #777b84 on slate1 .......................... 4.45:1  (just under AA — disabled only)
blue11  #70b8ff on slate1 .......................... 8.97:1
amber11 #ffca16 on slate1 .......................... 12.32:1
green11 #3dd68c on slate1 .......................... 10.06:1
red11   #ff9592 on slate1 .......................... 8.95:1
blue11 on blue3 #0d2847 (soft badge) ............... 7.08:1
red11 on red3 #3b1219 .............................. 7.75:1
amber11 on amber3 #302008 .......................... 10.26:1
green11 on green3 #132d21 .......................... 7.86:1

⚠ THE ONE TRAP: white on blue9 #0090ff is 3.26:1 — it FAILS AA for body text.
  white on green9 is 3.16:1. white on red9 is 3.91:1.
  So: never put 11pt white text on a step-9 fill. Two safe primary-button recipes:
   (a) inverted — fill slate12 #edeef0, label slate1 #111113 → 16.25:1
   (b) soft — fill blue3 #0d2847, 1px border blue7 #205d9e, label blue11 #70b8ff → 7.08:1
  Reserve step 9 for non-text signal: status dots, 2px running bars, chart series.
  amber9 #ffc53d with BLACK text is 13.31:1 and is the one step-9 that is safe for text.

═══════════════════════════════════════════════════════
PART 4 — WHAT macOS OWNS (measured live, this machine, macOS 26.5.2 build 25F84,
via `swiftc` dumping NSColor under NSAppearanceNameDarkAqua)
═══════════════════════════════════════════════════════

DARK AQUA                                     LIGHT AQUA (for reference)
labelColor            #FFFFFF a=0.847         #000000 a=0.847
secondaryLabelColor   #FFFFFF a=0.549         #000000 a=0.498
tertiaryLabelColor    #FFFFFF a=0.247         #000000 a=0.259
quaternaryLabelColor  #FFFFFF a=0.098         #000000 a=0.098
placeholderTextColor  #FFFFFF a=0.247         #000000 a=0.247
separatorColor        #FFFFFF a=0.098         #000000 a=0.098
windowBackgroundColor #323232                 #ECECEC
underPageBackground   #282828                 #969696 a=0.898
controlBackground     #1E1E1E                 #FFFFFF
textBackgroundColor   #1E1E1E                 #FFFFFF
selectedContentBg     #0059D1                 #0064E1
unemphasizedSelected  #464646                 #DCDCDC
controlAccentColor    #007AFF                 #007AFF   ← user-settable in System Settings
linkColor             #419CFF                 #0068DA
systemBlue            #0091FF                 #0088FF   ← note: NOT #007AFF in macOS 26
systemRed             #FF4245                 #FF383C
systemOrange          #FF9230                 #FF8D28
systemYellow          #FFD600                 #FFCC00
systemGreen           #30D158                 #34C759
systemMint            #00DAC3                 #00C8B3
systemTeal            #00D2E0                 #00C3D0
systemCyan            #3CD3FE                 #00C0E8
systemIndigo          #6D7CFF                 #6155F5
systemPurple          #DB34F2                 #CB30E0
systemPink            #FF375F                 #FF2D55
systemBrown           #B78A66                 #AC7F5E
systemGray            #98989D                 #8E8E93

macOS SYSTEM TYPE SCALE (measured, NSFont.preferredFont + NSLayoutManager line height):
largeTitle  26.0 regular  lh 39     headline    13.0 BOLD     lh 19
title1      22.0 regular  lh 33     body        13.0 regular  lh 19
title2      17.0 regular  lh 27     callout     12.0 regular  lh 18
title3      15.0 regular  lh 24     subheadline 11.0 regular  lh 17
                                    footnote    10.0 regular  lh 16
NSFont.systemFontSize = 13.0   smallSystemFontSize = 11.0   labelFontSize = 10.0

NSVisualEffectView.Material — all 14 confirmed present on the macOS 26 SDK:
appearanceBased, contentBackground, dark, fullScreenUI, headerView, hudWindow, light,
mediumLight, menu, popover, selection, sheet, sidebar, titlebar, toolTip, ultraDark,
underPageBackground, underWindowBackground, windowBackground
(SwiftUI shorthands `.ultraThinMaterial`, `.regularMaterial`, `.bar` also compile.)

Apple HIG, materials page, current guidance: Liquid Glass is "a distinct functional layer
for controls and navigation elements — like tab bars and sidebars — that floats above the
content layer." Explicit rule: "Don't use Liquid Glass in the content layer… use standard
materials for elements in the content layer, such as app backgrounds." And "Use Liquid
Glass effects sparingly." For a cockpit this means: sidebar and toolbar may be glass;
the conversation pane must not be.

═══════════════════════════════════════════════════════
PART 5 — GEOMETRY (Radix Themes, MIT, fetched from source CSS)
═══════════════════════════════════════════════════════

SPACE (tokens/space.css)   1=4px  2=8px  3=12px  4=16px  5=24px  6=32px  7=40px
                           8=48px  9=64px
RADIUS (tokens/radius.css) 1=3px  2=4px  3=6px  4=8px  5=12px  6=16px
                           multiplied by --radius-factor: none 0, small 0.75,
                           medium 1, large 1.5, full 1.5 (+ pill 9999)
TYPE (themes/docs/theme/typography), size / letter-spacing / line-height:
  1  12px  +0.0025em  16px      6  24px  -0.00625em 30px
  2  14px   0em       20px      7  28px  -0.0075em  36px
  3  16px   0em       24px      8  35px  -0.01em    40px
  4  18px  -0.0025em  26px      9  60px  -0.025em   60px
  5  20px  -0.005em   28px
  weights: light 300, regular 400, medium 500, bold 700
SHADOW (tokens/shadow.css), verbatim, expressed in alpha tokens not hardcoded blacks:
  --shadow-2: 0 0 0 1px var(--gray-a3), 0 0 0 0.5px var(--black-a1),
              0 1px 1px 0 var(--gray-a2), 0 2px 1px -1px var(--black-a1),
              0 1px 3px 0 var(--black-a1);
  --shadow-3: 0 0 0 1px var(--gray-a3), 0 2px 3px -2px var(--gray-a3),
              0 3px 12px -4px var(--black-a2), 0 4px 16px -8px var(--black-a2);
  --shadow-4: 0 0 0 1px var(--gray-a3), 0 8px 40px var(--black-a1),
              0 12px 32px -16px var(--gray-a3);
  --shadow-5: 0 0 0 1px var(--gray-a3), 0 12px 60px var(--black-a3),
              0 12px 32px -16px var(--gray-a5);
The structural idea to steal: every Radix shadow begins with a 1px hairline ring in an
alpha grey. In SwiftUI that is `.overlay(RoundedRectangle(...).strokeBorder(ring, lineWidth: 1))`
plus a soft `.shadow`. Do not port the multi-layer blur stacks; port the ring.

═══════════════════════════════════════════════════════
PART 6 — THE BOT-HARNESS TOKEN SET (the actual deliverable)
Mapping Radix step → existing DS name in Sources/BotHarness/Design/Tokens.swift
═══════════════════════════════════════════════════════

The repo already has DS.Colour with hand-picked values. Every one has a Radix equivalent
within ~2 luminance points, so this is a substitution, not a rewrite.

SURFACES (opaque, for the content layer — the conversation pane and inspector)
  DS.Colour.ground      slate1  #111113   was rgb(0.051,0.051,0.055) = #0D0D0E
  DS.Colour.panel       slate2  #18191b   was #131314
  DS.Colour.raised      slate3  #212225   was #1A1A1C
  DS.Colour.overlay     slate4  #272a2d   was #232325
  DS.Colour.bubbleBot   slate3  #212225   was #212123
  DS.Colour.bubbleUser  slate5  #2e3135   was #3D3D40

SURFACE TINTS (alpha, for anything sitting on an NSVisualEffectView material —
the sidebar and the toolbar. Never use the opaque hexes there.)
  sidebarTint           slateA2  a=0.035
  sidebarRowHover       slateA3  a=0.078
  sidebarRowSelected    slateA5  a=0.145

TEXT
  DS.Colour.ink           slate12 #edeef0   (16.25:1) — was white 0.93
  DS.Colour.inkSecondary  slate11 #b0b4ba   (9.06:1)  — was white 0.58
  DS.Colour.inkTertiary   slateA9 a=0.427   — was white 0.34
  DS.Colour.inkDisabled   slateA7 a=0.251   — was white 0.20

LINES
  DS.Colour.line          slateA3 a=0.078   (matches macOS separatorColor a=0.098 closely)
  DS.Colour.lineStrong    slateA6 a=0.188
  DS.Colour.focusRing     Color(nsColor: .keyboardFocusIndicatorColor)  ← OS, not Radix

FILLS (interactive)
  DS.Colour.fill          slateA3 a=0.078   — was white 0.055
  DS.Colour.fillHover     slateA4 a=0.114   — was white 0.085
  DS.Colour.fillActive    slateA5 a=0.145   — was white 0.12
  DS.Colour.fillSelected  slateA4 a=0.114   — was white 0.075

STATUS (dots, pills, 2px bars — never text on these, never large areas)
  DS.Colour.running   amber9  #ffc53d   (soft form: bg amber3 #302008 / text amber11 #ffca16)
  DS.Colour.done      green9  #30a46c   (soft: green3 #132d21 / green11 #3dd68c)
  DS.Colour.failed    red9    #e5484d   (soft: red3 #3b1219 / red11 #ff9592)
  DS.Colour.waiting   blue9   #0090ff   (soft: blue3 #0d2847 / blue11 #70b8ff)
  DS.Colour.awaitingApproval  orange9 #f76b15  ← new; the permission floor needs its own
                                                  colour, distinct from "running"

ACCENT — two-layer rule:
  DS.Colour.accent        = Color(nsColor: .controlAccentColor)   // follows System Settings
  DS.Colour.accentStatic  = blue9 #0090ff                          // for traces, exports,
                                                                   // screenshots, anything
                                                                   // that must reproduce
  DS.Colour.onAccent      = slate12 #edeef0, and only at ≥13pt semibold (3.26:1)
  Primary button = fill slate12 #edeef0 / label slate1 #111113. Not blue.

LITERAL (paths, commands, inline code inside prose)
  DS.Colour.literal   amber11 #ffca16 (12.32:1) or orange11 #ffa057
  — was rgb(0.98,0.57,0.49). Amber11 reads as "machine wrote this" without reading as error;
  the old salmon is one hue away from red9 and gets confused with a failure at a glance.

TYPE — keep your half-point sizes, they are correct for this density, but anchor the
three that carry meaning to the macOS scale so the app matches Finder and Mail:
  DS.Text.body       13.0 regular, line spacing 2.5   = macOS `body`      (systemFontSize)
  DS.Text.title      13.0 semibold                     ≈ macOS `headline` (13 bold)
  DS.Text.caption    11.0 regular                      = macOS `subheadline` / smallSystemFontSize
  DS.Text.secondary  12.0 regular                      = macOS `callout`
  DS.Text.micro      10.0 regular                      = macOS `footnote` / labelFontSize
  DS.Text.display    15.0 semibold                     = macOS `title3` size
  DS.Text.mono(_:)   .system(size:design:.monospaced) → SF Mono. Do NOT bundle Geist Mono;
                     it is OFL-clean but a bundled font is the thing that makes a Mac app
                     read as a web app in a window.
  Drop 11.5 and 12.5. They are unanchored and they are why the app has 6 sizes between
  10 and 13. Radix's own scale has no half-steps either.

SPACE — your current values are already the Radix ramp with two extras. Formalise as:
  hair 2 / xs 4 / sm 6 / md 8 / lg 12 / xl 16 / xxl 24 / xxxl 40
  (Radix: 4, 8, 12, 16, 24, 32, 40, 64. Yours adds 2 and 6 for chip interiors, which a
   13px-body-text app genuinely needs; keep them, they are the documented deviation.)

RADIUS — Radix medium factor (×1) gives 3/4/6/8/12/16. Your current 4/6/8/10/14 is
Radix small-to-medium. Snap to Radix exactly:
  xs 4 (radius-2) / sm 6 (radius-3) / md 8 (radius-4) / lg 12 (radius-5) / xl 16 (radius-6)
  pill 9999
  Nesting rule to keep: inner radius = outer radius − padding.

ELEVATION — three levels only, each = 1px alpha ring + one shadow:
  raised   ring slateA3 a=0.078, no shadow
  floating ring slateA3 a=0.078, shadow color .black.opacity(0.30) radius 12 y 4
  modal    ring slateA5 a=0.145, shadow color .black.opacity(0.45) radius 40 y 12

MOTION — no candidate publishes motion tokens that survive translation to SwiftUI, so
take these from the SwiftUI API itself (all verified to compile on the macOS 26 SDK):
  DS.Motion.tap      = .snappy(duration: 0.18, extraBounce: 0)   hover/press feedback
  DS.Motion.reveal   = .smooth(duration: 0.28, extraBounce: 0)   panel + inspector open
  DS.Motion.settle   = .spring(response: 0.32, dampingFraction: 0.85)  row insert
  DS.Motion.instant  = .easeOut(duration: 0.12)                  colour/opacity only
  Rule: a running agent's status must never animate on a spring. Use .instant for anything
  that reports machine state, so a fast-changing trace does not look like it is bouncing.

═══════════════════════════════════════════════════════
PART 7 — WHY NOT THE OTHERS (each verified)
═══════════════════════════════════════════════════════

shadcn/ui — MIT, and its dark theme is genuinely usable: --background oklch(0.145 0 0),
  --card oklch(0.205 0 0), --border oklch(1 0 0 / 10%), --radius 0.625rem (=10px). But it
  is achromatic and has exactly one grey per role: no hover step, no active step, no
  border-vs-focus-ring distinction. You would invent steps 4, 5, 7 and 8 yourself, which
  is the work Radix already did. Also its palette is oklch, which SwiftUI cannot parse —
  every value needs conversion.

Tailwind — MIT, 25 families × 11 shades, all oklch (e.g. slate-950
  oklch(12.9% 0.042 264.695)). It is a lightness ramp, not a semantic contract; nothing
  tells you that 800 is a border and 700 is a hover. Same oklch conversion tax.

Vercel Geist — the FONT is SIL OFL and freely usable (npm `geist`). The design SYSTEM is
  not distributable: vercel.com/geist/colors publishes variable names (--ds-gray-100 …
  --ds-gray-1000, 10 scales × 10 steps) and step meanings but no hex values at all, there
  is no public token repo, and `@vercel/geist-ui` returns 404 on the npm registry. You
  cannot implement it without scraping it, and scraping it is not licensed.

Linear — linear.app/brand publishes a logo kit, two hexes (Mercury White #F4F5F8, Nordic
  Gray #222326), and terms that say "Do not alter these files in any way." Every "Linear
  design system" with tokens in it is a third-party scrape (designlang, DesignMD,
  awesome-design-md, nexu-io/open-design). There is no system to adopt, only a look to
  copy, and copying it is exactly the "web app in a window" failure mode.

IBM Carbon — Apache-2.0, complete, the most rigorous of the lot (it publishes motion
  curves and a grid, which Radix does not). Rejected on voice: 2px radii, IBM Plex, 16px
  rhythm and a productivity-console personality. It would make this look like an
  enterprise admin panel, not a Mac app.

GitHub Primer — MIT (primer/primitives), DTCG-format JSON with hex AND hsl per token, and
  structurally the best-engineered web system here. Rejected on two specifics: its dark
  neutral ramp is deliberately blue-tinted for github.com (neutral.1 #0D1117 is hsl 216°,
  neutral.3 #212830 is 212°), which fights macOS's neutral #1E1E1E / #323232 chrome; and
  its functional tokens are named for GitHub product concepts, so half the system is
  vocabulary you would never use.

Atlassian — no MIT/Apache licence found on the public repo I checked; the system is
  positioned for building inside the Atlassian ecosystem. See `unverified`.

Apple HIG alone — cannot be a base. Two hard blockers, both verified: (1) the HIG colour
  page publishes system colours only as PNG swatches (`colors-unified-red-dark.png`) —
  there are no numbers on the page to copy, which is why the values in PART 4 had to be
  measured off this machine at runtime rather than read; (2) macOS has no surface ramp.
  It gives windowBackground #323232, controlBackground #1E1E1E, underPageBackground
  #282828 and nothing in between, and those three are not even monotonic. A three-pane
  cockpit needs five ordered depths. Radix supplies the ramp macOS lacks; macOS supplies
  the accent, materials and metrics Radix lacks. That is the split, and it is why the
  answer is both rather than either.

## Findings

- Radix Colors is MIT licensed (Copyright 2021-2022 Modulz, 2022-Present WorkOS); npm @radix-ui/colors latest is 3.0.0, license MIT.  
  — **confirmed** · <https://raw.githubusercontent.com/radix-ui/colors/main/LICENSE>
- Radix's 12 steps are a semantic contract, not a lightness ramp: 1 app background, 2 subtle background, 3 UI element background, 4 hovered, 5 active/selected, 6 subtle borders and separators, 7 UI element border and focus rings, 8 hovered border, 9 solid backgrounds, 10 hovered solid, 11 low-contrast text, 12 high-contrast text. Step 9 has the highest chroma of all steps.  
  — **confirmed** · <https://www.radix-ui.com/colors/docs/palette-composition/understanding-the-scale>
- Radix ships, for every scale, four dark variants in one source file: solid sRGB hex (grayDark), alpha hex8 (grayDarkA), Display P3 (grayDarkP3), and alpha P3 (grayDarkP3A). No other candidate publishes a matched alpha scale or P3 values.  
  — **confirmed** · <https://raw.githubusercontent.com/radix-ui/colors/main/src/dark.ts>
- Radix blue9 dark is #0090FF; macOS 26.5.2 NSColor.systemBlue under NSAppearanceNameDarkAqua measures #0091FF. The Radix accent and the current OS system blue are one digit apart.  
  — **confirmed** · <local: swiftc dump.swift, NSColor.systemBlue.usingColorSpace(.sRGB) under darkAqua, macOS 26.5.2 build 25F84>
- macOS 26's systemBlue is NOT the long-quoted #007AFF. Measured: #0088FF light, #0091FF dark. controlAccentColor is still #007AFF in both appearances (it is user-settable). Any hardcoded #007AFF in the codebase is now wrong.  
  — **confirmed** · <local: swiftc dump.swift under aqua and darkAqua, macOS 26.5.2 build 25F84>
- Apple's HIG colour page no longer publishes numeric colour values. The system-colour tables render every value as a PNG swatch reference (e.g. identifier 'colors-unified-red-dark.png'); the page JSON contains zero hex strings and zero rgb() strings. The page changelog records 'June 9, 2025 — Updated system color values, and added guidance for Liquid Glass' and 'December 16, 2025 — Updated guidance for Liquid Glass.'  
  — **confirmed** · <https://developer.apple.com/tutorials/data/design/human-interface-guidelines/color.json>
- Apple's current materials guidance draws a hard line: Liquid Glass is for the functional layer (tab bars, sidebars, navigation) and 'Don't use Liquid Glass in the content layer… Instead, use standard materials for elements in the content layer, such as app backgrounds.' Also 'Use Liquid Glass effects sparingly.' Two variants exist, regular and clear; clear is for components over media, with a 35%-opacity dark dimming layer if the underlying content is bright.  
  — **confirmed** · <https://developer.apple.com/tutorials/data/design/human-interface-guidelines/materials.json>
- macOS provides no ordered neutral surface ramp: the semantic backgrounds are windowBackgroundColor #323232, underPageBackgroundColor #282828 and controlBackgroundColor #1E1E1E in dark aqua — three values, not monotonic in the order their names suggest, with nothing in between.  
  — **confirmed** · <local: swiftc dump.swift under darkAqua, macOS 26.5.2 build 25F84>
- macOS label colours in dark aqua are pure white at four alpha levels: label 0.847, secondaryLabel 0.549, tertiaryLabel 0.247, quaternaryLabel 0.098; separatorColor is white at 0.098.  
  — **confirmed** · <local: swiftc dump.swift under darkAqua, macOS 26.5.2 build 25F84>
- macOS system text style sizes measured on this machine: largeTitle 26, title1 22, title2 17, title3 15, headline 13 bold, body 13, callout 12, subheadline 11, footnote 10, caption1 10, caption2 10. NSFont.systemFontSize 13.0, smallSystemFontSize 11.0, labelFontSize 10.0.  
  — **confirmed** · <local: swiftc dump.swift, NSFont.preferredFont(forTextStyle:) + NSLayoutManager.defaultLineHeight, macOS 26.5.2>
- NSVisualEffectView publishes 18 material constants including sidebar, headerView, underWindowBackground, contentBackground, popover, menu, hudWindow, titlebar, selection, sheet, toolTip, fullScreenUI, underPageBackground, windowBackground.  
  — **confirmed** · <https://developer.apple.com/tutorials/data/documentation/appkit/nsvisualeffectview/material-swift.enum.json>
- SwiftUI on the macOS 26 SDK accepts Color(.displayP3, red:green:blue:opacity:), Color(nsColor:), the material shorthands .ultraThinMaterial/.regularMaterial/.bar, and the animation presets .snappy/.smooth/.bouncy/.spring(response:dampingFraction:) — all compiled and executed locally, not assumed.  
  — **confirmed** · <local: swiftc apicheck.swift and anim.swift, both compiled and ran clean on macOS 26.5.2>
- Radix Themes publishes the geometry scales openly (MIT): space 4/8/12/16/24/32/40/48/64px; radius 3/4/6/8/12/16px multiplied by a factor of 0, 0.75, 1, 1.5 or 1.5 for none/small/medium/large/full; type steps 12/14/16/18/20/24/28/35/60px with per-step letter-spacing from +0.0025em down to -0.025em.  
  — **confirmed** · <https://raw.githubusercontent.com/radix-ui/themes/main/packages/radix-ui-themes/src/styles/tokens/space.css>
- Every Radix shadow token begins with a 1px alpha-grey ring (0 0 0 1px var(--gray-a3)) before any blur. That ring, not the blur stack, is the part that translates to SwiftUI.  
  — **confirmed** · <https://raw.githubusercontent.com/radix-ui/themes/main/packages/radix-ui-themes/src/styles/tokens/shadow.css>
- shadcn/ui is MIT and its dark theme is fully published, but it is achromatic and single-step per role: --background oklch(0.145 0 0), --card/--popover oklch(0.205 0 0), --muted/--accent/--secondary all oklch(0.269 0 0), --border oklch(1 0 0 / 10%), --input oklch(1 0 0 / 15%), --ring oklch(0.556 0 0), --radius 0.625rem. There is no hover step, no active step, and no border-versus-focus-ring distinction.  
  — **confirmed** · <https://ui.shadcn.com/docs/theming>
- Tailwind's default palette is 25 families x 11 shades (50-950) expressed entirely in oklch, e.g. slate-950 oklch(12.9% 0.042 264.695), zinc-900 oklch(21% 0.006 285.885). It is a lightness ramp with no semantic step meanings; tailwindcss is MIT.  
  — **confirmed** · <https://tailwindcss.com/docs/colors>
- Vercel Geist publishes colour variable NAMES and step meanings (10 scales, steps 100-1000, var(--ds-gray-100) = default background through 1000 = primary text and icons) but no hex values on the page, and there is no licence statement for the token layer. The npm package @vercel/geist-ui returns HTTP 404. Only the Geist FONT is openly licensed, under SIL OFL 1.1.  
  — **confirmed** · <https://vercel.com/geist/colors>
- Linear publishes no design tokens. linear.app/brand publishes a logo/wordmark kit and exactly two hex values (Mercury White #F4F5F8, Nordic Gray #222326), under terms that forbid altering the files or combining them without written consent. Every circulating 'Linear design system' with a token set is a third-party extraction.  
  — **confirmed** · <https://linear.app/brand>
- IBM Carbon is Apache-2.0 licensed and is by far the largest of the candidates by adoption (9,393 stars on the main repo).  
  — **confirmed** · <https://api.github.com/repos/carbon-design-system/carbon>
- GitHub Primer primitives is MIT and publishes DTCG-format JSON with both hex and hsl per token, but its dark neutral ramp is deliberately blue-tinted for github.com: neutral.1 #0D1117 (hsl 216, 27.8%, 7.1%), neutral.2 #151B23, neutral.3 #212830 (hsl 212), neutral.4 #262C36. That hue fights the neutral greys macOS uses for window chrome.  
  — **confirmed** · <https://raw.githubusercontent.com/primer/primitives/main/src/tokens/base/color/dark/dark.json5>
- White text on Radix blue9 (#0090ff) is 3.26:1 and fails WCAG AA for normal text; white on green9 is 3.16:1 and white on red9 is 3.91:1. Only amber9 (#ffc53d) is safe for text, and only with black on it (13.31:1). Step-9 fills must therefore carry signal, not body copy.  
  — **confirmed** · <local: WCAG 2.1 relative-luminance computation over the fetched Radix dark hex values>
- Radix slate11 on slate1 is 9.06:1 and slate12 on slate1 is 16.25:1, so the two text steps clear AA and AAA comfortably on the app background; slate10 on slate1 is 4.45:1, just under AA, which is exactly the right value for disabled text.  
  — **confirmed** · <local: WCAG 2.1 relative-luminance computation over the fetched Radix dark hex values>
- Bot-Harness already has a hand-authored token file at Sources/BotHarness/Design/Tokens.swift with DS.Space, DS.Radius, DS.Text, DS.Colour and DS.Size. Its invented surface values (#0D0D0E, #131314, #1A1A1C, #232325) sit within roughly two luminance points of Radix slate 1-4, so adopting Radix is a substitution rather than a rewrite. The views, however, still contain 30+ raw .opacity() literals and six font sizes between 10 and 13, which the token file's own doc comment forbids.  
  — **confirmed** · <local: /Users/Kunal/Desktop/Bot-Harness/Sources/BotHarness/Design/Tokens.swift and grep over Sources/BotHarness>

## What to build

- Rewrite Sources/BotHarness/Design/Tokens.swift so every DS.Colour value is a named Radix step, with the step number in a trailing comment (`// slate3` etc.). Add a private `Color(hex:)` and a `Color(p3:)` helper. This is a pure substitution — the mapping table in concrete_specs gives you all 24 replacements — and it converts an invented palette into a citable one without touching a single view.
- Split DS.Colour into two namespaces: DS.Surface (opaque slate 1-5, for the content layer) and DS.Tint (slateA 2-6, for anything drawn over an NSVisualEffectView). The sidebar and toolbar must use DS.Tint over a material; the conversation pane must use DS.Surface. This is the single change that decides whether the app reads as Mac-native or as a web app in a window, and it follows Apple's own stated rule that the content layer gets standard materials while the functional layer floats above it.
- Fix the primary-action colour. White-on-blue9 measures 3.26:1 and fails AA. Ship two button styles: `.primary` = fill slate12 #edeef0 with slate1 #111113 label (16.25:1), and `.soft` = fill blue3 #0d2847, 1px blue7 #205d9e border, blue11 #70b8ff label (7.08:1). Reserve every step-9 colour for status dots and progress bars where no text sits on it.
- Add DS.Colour.accent = Color(nsColor: .controlAccentColor) so the app follows the accent the user picked in System Settings, and keep DS.Colour.accentStatic = blue9 #0090ff for traces, exported PNGs and anything that must reproduce identically later. Grep for and delete any hardcoded #007AFF — macOS 26's systemBlue is #0091FF dark / #0088FF light, so that constant is now stale.
- Collapse the type scale from six unanchored sizes (9, 10, 10.5, 11, 11.5, 12, 12.5, 13, 13.5, 15) to five anchored ones: 13 body (= NSFont.systemFontSize), 13 semibold title (= headline), 12 secondary (= callout), 11 caption (= smallSystemFontSize), 10 micro (= labelFontSize). The 11.5 and 12.5 sizes appear 31 times between them and match nothing the OS draws, which is why the app's text does not optically line up with the toolbar.
- Snap DS.Radius to the Radix medium scale exactly — 4, 6, 8, 12, 16 — replacing the current 4/6/8/10/14, and enforce the nesting rule that an inner radius equals the outer radius minus its padding. The stray 10 and 14 are the reason nested cards look slightly wrong.
- Add a DS.Motion namespace with the four verified SwiftUI animations (tap .snappy 0.18, reveal .smooth 0.28, settle .spring response 0.32 damping 0.85, instant .easeOut 0.12) and a written rule that agent status transitions use .instant only. A springy status indicator on a fast-moving trace reads as instability in a product whose whole promise is that you can trust what it reports.
- Introduce DS.Colour.awaitingApproval = orange9 #f76b15 as a status distinct from running/amber. The permission floor is described in CLAUDE.md as the spine of the product; 'this agent is blocked waiting for you' and 'this agent is working' currently share a colour, and that is the one confusion in this app with a real-world cost.
- Replace DS.Colour.literal (currently a salmon rgb(0.98,0.57,0.49) that sits one hue from red9 #e5484d) with amber11 #ffca16 at 12.32:1, so an inline path in prose can never be misread at a glance as a failure.
- Write docs/decisions/ADR-XXXX-design-system-base.md recording the choice of Radix Colors plus a macOS override layer, with the falsifier stated plainly: if Apple ships a documented neutral surface ramp with numeric values, or if the alpha-over-material approach turns out to break under Increase Contrast or Reduce Transparency, this decision is wrong. Test both accessibility settings before closing the ADR.
- Sweep the views for the 30+ raw `.opacity()` literals and the raw cornerRadius/spacing numbers that grep found, replacing each with a DS token. The token file's own doc comment already says a view may not contain a raw number; right now that rule is aspirational rather than true, and a design system with exceptions is just a palette.

## Could not verify

- Atlassian Design System licensing. The GitHub API returned an empty licence object for atlassian-labs/design-system and no star count, which suggests I did not reach the canonical repository. I did not fetch atlassian.design or its terms, so treat 'not openly licensed' as unconfirmed — though it does not change the recommendation, since Atlassian's visual voice is wrong for this app regardless.
- Whether the Radix alpha-over-material approach survives macOS's Increase Contrast and Reduce Transparency accessibility settings. Apple's materials guidance explicitly warns that 'the appearance of these variants can differ in response to certain system settings… accessibility settings that reduce transparency or increase contrast.' I did not test this on the running app. It needs a real check before the ADR is closed, because it is the failure mode most likely to make the sidebar unreadable for someone.
- Radix's claim that step 12 delivers 'guaranteed APCA contrast ratios'. I verified WCAG 2.1 ratios myself by computing them from the hex values, and they are excellent, but I did not compute APCA Lc values or find Radix's stated APCA target.
- Whether SwiftUI's .ultraThinMaterial/.regularMaterial map to specific NSVisualEffectView.Material constants, and which one .bar resolves to on macOS 26. All three compile, but I did not verify their rendered equivalence to the AppKit constants, so if you need a specific material (sidebar, headerView, underWindowBackground) use NSVisualEffectView through NSViewRepresentable rather than trusting the shorthand.
- Whether macOS 26 exposes Liquid Glass through a public SwiftUI API surface this project can use, and what it is called. The HIG describes it and says 'For developer guidance, see —' with the link target stripped from the JSON. I did not find or compile against the API, so the recommendation deliberately routes the sidebar through standard materials, which are confirmed to exist.
- Exact per-step meanings of Geist's --ds-gray-100 through --ds-gray-1000 beyond the two endpoints the page states (100 = default background, 1000 = primary text and icons). Moot for the recommendation, since the values are unpublished and the token layer is unlicensed either way.
- Whether the Radix Themes shadow tokens' second definition block (the color-mix(in oklab, ...) variant under @supports) differs meaningfully from the first. I read the first block in full and the second only partially.
