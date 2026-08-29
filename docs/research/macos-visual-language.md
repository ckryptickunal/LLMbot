# What makes a macOS app look native in 2026: Liquid Glass (macOS 26), exact SwiftUI APIs, measured system colours, type scale and metrics

> Verified 2026-08-30 against live sources.

## Bottom line

Yes — Liquid Glass is the macOS 26 design language, and it is the reason your hand-picked hex greys look wrong. Stop shipping literal greys entirely: macOS semantic label colours are not greys, they are pure black or pure white at fixed alphas (labelColor = 84.7% opacity, secondary 49.8%/54.9%, tertiary 25.9%/24.7%, quaternary and separator both 9.8%), which is what lets them sit correctly on translucent material. I measured every semantic NSColor, the type scale, control heights, toolbar heights and window corner radii directly on this machine (macOS 26.5.2, Xcode SDK 26.5) rather than trusting docs, and two findings will bite you: the system accent colour (#007AFF) is a different colour from systemBlue (#0088FF), and the whole system palette shifted in macOS 26 — systemRed is now #FF383C, not the #FF3B30 everyone has memorised. For a three-pane cockpit the single highest-value change is to stop painting the sidebar and inspector at all and let NavigationSplitView fill them, because Apple's explicit guidance is that custom backgrounds in split views, sidebars and toolbars interfere with Liquid Glass and the scroll edge effect.

## Concrete specifications

========================================================
1. SEMANTIC COLOURS — MEASURED ON macOS 26.5.2 (Build 25F84)
========================================================
Method: compiled an AppKit binary, resolved each NSColor inside
NSAppearance(named:).performAsCurrentDrawingAppearance for .aqua and
.darkAqua, converted usingColorSpace(.sRGB). These are real runtime values.

THE CRITICAL POINT: label/separator colours are NOT greys. They are #000000
or #FFFFFF at a fixed alpha. That is what makes them composite correctly over
material. A hardcoded grey cannot do this.

NAME                                        LIGHT (aqua)              DARK (darkAqua)
labelColor                                  #000000 @ 0.847           #FFFFFF @ 0.847
secondaryLabelColor                         #000000 @ 0.498           #FFFFFF @ 0.549
tertiaryLabelColor                          #000000 @ 0.259           #FFFFFF @ 0.247
quaternaryLabelColor                        #000000 @ 0.098           #FFFFFF @ 0.098
textColor                                   #000000 @ 1.000           #FFFFFF @ 1.000
placeholderTextColor                        #000000 @ 0.247           #FFFFFF @ 0.247
separatorColor                              #000000 @ 0.098           #FFFFFF @ 0.098
controlTextColor                            #000000 @ 0.847           #FFFFFF @ 0.847
disabledControlTextColor                    #000000 @ 0.247           #FFFFFF @ 0.247
headerTextColor                             #000000 @ 0.847           #FFFFFF @ 1.000
controlColor                                #FFFFFF @ 1.000           #FFFFFF @ 0.247

Opaque backgrounds (these ARE concrete colours):
windowBackgroundColor                       #ECECEC                   #323232
underPageBackgroundColor                    #969696 @ 0.898           #282828
controlBackgroundColor                      #FFFFFF                   #1E1E1E
textBackgroundColor                         #FFFFFF                   #1E1E1E
gridColor                                   #E6E6E6                   #1A1A1A
unemphasizedSelectedContentBackgroundColor  #DCDCDC                   #464646
unemphasizedSelectedTextBackgroundColor     #DCDCDC                   #464646
selectedContentBackgroundColor              #0064E1                   #0059D1
selectedTextBackgroundColor                 #B3D7FF                   #3F638B
controlAccentColor                          #007AFF                   #007AFF
linkColor                                   #0068DA                   #419CFF

macOS 26 REFRESHED SYSTEM PALETTE (several of these CHANGED in macOS 26 —
do not use the values you remember from Big Sur/Sonoma):
systemBlue     #0088FF   /  #0091FF     (NOT #007AFF — that is the accent colour)
systemRed      #FF383C   /  #FF4245     (was #FF3B30 / #FF453A)
systemOrange   #FF8D28   /  #FF9230     (was #FF9500)
systemGreen    #34C759   /  #30D158     (unchanged)
systemYellow   #FFCC00   /  #FFD600
systemPurple   #CB30E0   /  #DB34F2     (was #AF52DE)
systemTeal     #00C3D0   /  #00D2E0
systemIndigo   #6155F5   /  #6D7CFF
systemPink     #FF2D55   /  #FF375F
systemBrown    #AC7F5E   /  #B78A66
systemMint     #00C8B3   /  #00DAC3
systemCyan     #00C0E8   /  #3CD3FE
systemGray     #8E8E93   /  #98989D

Do not paste these hexes into the app. They are here to prove the semantic
colours are correct and to let you sanity-check rendering. Reference the
semantic name so the value tracks accent colour, Increase Contrast, desktop
tinting and future OS updates.

CORRECT SwiftUI SPELLINGS (with verified availability):
  ShapeStyle:  .primary .secondary .tertiary .quaternary   (HierarchicalShapeStyle)
               .quinary                     macOS 12.0
               .separator                   (SeparatorShapeStyle)
               .selection                   macOS 12.0
               .fill                        macOS 14.0
               .placeholder                 macOS 14.0
               .windowBackground            macOS 14.0
               .background                  (BackgroundStyle)
               .tint                        (TintShapeStyle)
  Color:       Color.accentColor, Color.primary, Color.secondary
  Anything with no SwiftUI spelling, bridge explicitly and never approximate:
               Color(nsColor: .separatorColor)
               Color(nsColor: .underPageBackgroundColor)
               Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
               Color(nsColor: .controlBackgroundColor)

========================================================
2. TYPOGRAPHY — macOS TYPE SCALE
========================================================
Two independent sources agree exactly: Apple's HIG Typography table for macOS,
and NSFont.preferredFont(forTextStyle:) measured on this machine.

STYLE          SwiftUI          WEIGHT     SIZE   LINE HEIGHT   EMPHASIZED
Large Title    .largeTitle      Regular    26 pt     32 pt      Bold
Title 1        .title           Regular    22 pt     26 pt      Bold
Title 2        .title2          Regular    17 pt     22 pt      Bold
Title 3        .title3          Regular    15 pt     20 pt      Semibold
Headline       .headline        Bold       13 pt     16 pt      Heavy
Body           .body            Regular    13 pt     16 pt      Semibold
Callout        .callout         Regular    12 pt     15 pt      Semibold
Subheadline    .subheadline     Regular    11 pt     14 pt      Semibold
Footnote       .footnote        Regular    10 pt     13 pt      Semibold
Caption 1      .caption         Regular    10 pt     13 pt      Medium
Caption 2      .caption2        Medium     10 pt     13 pt      Semibold

Note macOS Headline is BOLD (13 pt), not Semibold as on iOS. Verified: the
resolved font name is ".SFNS-Bold". Caption 2 resolves to ".SFNS-Medium".

AppKit constants measured:
  NSFont.systemFontSize       = 13.0    (macOS default body size)
  NSFont.smallSystemFontSize  = 11.0
  NSFont.labelFontSize        = 10.0
HIG platform table: macOS default 13 pt, minimum 10 pt.

WHAT TO USE WHERE IN A THREE-PANE COCKPIT:
  Sidebar row label ............ .body (13 pt regular)
  Sidebar section header ....... .subheadline (11 pt) + .foregroundStyle(.secondary),
                                 title-style capitalisation (macOS 26 stopped
                                 rendering section headers in all-caps)
  Pane / window title .......... .headline (13 pt bold) or .title3 (15 pt)
  Secondary / timestamp text ... .caption (10 pt) + .foregroundStyle(.secondary)
  Message body ................. .body (13 pt)
  Trace, tool args, shell ...... .body.monospaced() or
                                 .system(size: 12, design: .monospaced)

Design variants: use design: .monospaced ONLY for machine text — shell
commands, hashes, JSON, trace IDs, file paths. Never use design: .rounded on
macOS; it is a watchOS/iOS-widget idiom and reads as non-native in a Mac
window. There is no rounded system UI on macOS.

========================================================
3. STANDARD METRICS — MEASURED ON macOS 26.5.2
========================================================
WINDOW CORNER RADIUS (probed via themeFrame; radius scales concentrically
with the toolbar, exactly as Apple describes):
  Titled, no toolbar ................. 16 pt
  Titled + .unified toolbar .......... 26 pt
  Titled + .unifiedCompact toolbar ... 20 pt
  Borderless ......................... 0 pt

TITLEBAR + TOOLBAR HEIGHT (frame height minus contentRect height):
  No toolbar ......................... 28 pt
  .unifiedCompact .................... 38 pt
  .expanded .......................... 44 pt
  .unified (the default) ............. 52 pt
  .preference ........................ 80 pt

NSGlassEffectView.cornerRadius default ... 8 pt

SPLIT VIEW (AppKit defaults behind NavigationSplitView):
  Sidebar     minimumThickness = 140 pt, maximumThickness = -1 (unbounded),
              canCollapse = true, holdingPriority = 260, allowsFullHeightLayout = true
  Inspector   minimumThickness = maximumThickness = 270 pt (fixed),
              holdingPriority = 261
  HIG: prefer the thin divider style — "measures one point in width."

ROW METRICS:
  NSTableView.rowHeight = 24 pt for every style (.automatic, .fullWidth,
    .inset, .sourceList, .plain)
  NSOutlineView(.sourceList).indentationPerLevel = 13 pt

CONTROL HEIGHTS by controlSize (measured via sizeToFit, macOS 26 refreshed
dimensions — these are noticeably taller than pre-26 macOS):
  size      push    popup   segmented   bezeled textfield   switch
  .mini      16      16        16             21            42x42x25
  .small     27      22        21             21            42x25
  .regular   32      25        24             21            42x25
  .large     40      40        40             21            42x25

========================================================
4. LIQUID GLASS — WHAT IT ACTUALLY CHANGES
========================================================
Liquid Glass is a distinct FUNCTIONAL LAYER for controls and navigation that
floats above the CONTENT layer. Apple's rule, verbatim from the HIG:
"Don't use Liquid Glass in the content layer." Content-layer surfaces get
standard materials instead. Exception: transient interactive elements
(slider knobs, toggles) take on Liquid Glass while being manipulated.

Two variants only:
  Glass.regular — blurs and adjusts luminosity of background content to keep
    text legible. Use for anything text-heavy: sidebars, popovers, alerts.
    "Most system components use this variant."
  Glass.clear — highly translucent, for components floating over photo/video.
    If the underlying content is bright, add a dark dimming layer at 35%
    opacity. If it is already dark, or you use AVKit playback controls, don't.

Concrete changes when you rebuild against the macOS 26 SDK:
  - Window corners get rounder and vary by toolbar style (16/20/26 pt above),
    shaped to wrap concentrically around the glass toolbar.
  - Controls get rounder and TALLER (table in section 3) and gain an
    extra-large size option.
  - Lists, tables and forms get larger row height and padding; sections get a
    larger corner radius.
  - Section headers switch to title-style capitalisation instead of all-caps.
  - Sheets get an increased corner radius.
  - Toolbars gain grouping via ToolbarSpacer.
  - Scroll views gain a scroll edge effect that obscures content passing under
    bars. System bars adopt it by default.

========================================================
5. EXACT APIs AND AVAILABILITY
========================================================
Verified by reading the .swiftinterface files in
/Applications/Xcode.app/.../MacOSX.sdk (SwiftUI + SwiftUICore), so these
are the shipping signatures, not documentation prose.

REQUIRES macOS 26.0 SDK AND macOS 26.0 RUNTIME
  func glassEffect(_ glass: Glass = .regular,
                   in shape: some Shape = DefaultGlassEffectShape()) -> some View
  struct Glass: Equatable, Sendable
      static var regular: Glass
      static var clear: Glass
      static var identity: Glass
      func tint(_ color: Color?) -> Glass
      func interactive(_ isEnabled: Bool = true) -> Glass
  func glassEffectID(_ id: (some Hashable & Sendable)?, in: Namespace.ID)
  func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID)
  func glassEffectTransition(_ transition: GlassEffectTransition)
  GlassEffectContainer
  .buttonStyle(.glass)            // GlassButtonStyle
  .buttonStyle(.glassProminent)   // GlassProminentButtonStyle
  ConcentricRectangle             // also visionOS 26.0, unlike the glass APIs
      init(corners: Edge.Corner.Style, isUniform: Bool = false)
      Edge.Corner.Style.concentric
      Edge.Corner.Style.concentric(minimum:)
  func backgroundExtensionEffect() -> some View
  func scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set)
  func scrollEdgeEffectHidden(_ hidden: Bool = true, for edges: Edge.Set = .all)
  ToolbarSpacer
  func safeAreaBar(edge:alignment:spacing:content:)
  func toolbarItemHidden(_ hidden: Bool = true)

  Every glass API above is @available(visionOS, unavailable).
  GlassButtonStyle.init(_ glass: Glass) requires macOS 26.1 — the plain
  .glass / .glassProminent statics are 26.0.

  AppKit equivalents, all API_AVAILABLE(macos(26.0)):
    NSGlassEffectView            .contentView, .cornerRadius (default 8),
                                 .tintColor, .style (.regular / .clear)
    NSGlassEffectContainerView   .contentView, .spacing (default 0)
    NSBackgroundExtensionView
    NSButton.BezelStyle.glass

  Escape hatch: Info.plist key UIDesignRequiresCompatibility ships the old
  appearance while building against the new SDK.

AVAILABLE ON macOS 14 — use these if you keep a lower deployment target
  Materials (macOS 12.0): .ultraThinMaterial, .thinMaterial, .regularMaterial,
      .thickMaterial, .ultraThickMaterial, and .bar (macOS 12.0, iOS/macOS only)
  .quinary (12.0), .selection (12.0)
  .fill, .placeholder, .windowBackground (all macOS 14.0)
  .containerBackground(_:for:) (macOS 14.0)
  .inspector(isPresented:) and .inspectorColumnWidth(min:ideal:max:) (macOS 14.0)
  NavigationSplitViewColumn.sidebar (macOS 14.0)
  .navigationSplitViewColumnWidth(min:ideal:max:) (macOS 13.0)
  .presentationBackground(_:) (macOS 13.3)
  .listStyle(.sidebar) — SidebarListStyle (macOS 10.15)

========================================================
6. MATERIALS AND VIBRANCY — HOW TO FILL A SIDEBAR
========================================================
SwiftUI's Material type exposes only six values: ultraThin, thin, regular,
thick, ultraThick, bar. There is NO SwiftUI material for a sidebar.

macOS's real materials live in NSVisualEffectView.Material, which has
purpose-named values SwiftUI does not surface (raw values measured):
  .titlebar 3   .selection 4   .menu 5   .popover 6   .sidebar 7
  .headerView 10   .sheet 11   .windowBackground 12   .hudWindow 13
  .fullScreenUI 15   .toolTip 17   .contentBackground 18
  .underWindowBackground 21   .underPageBackground 22

THE CORRECT ANSWER FOR A SIDEBAR IS TO FILL IT WITH NOTHING.
NavigationSplitView already applies the sidebar material and, on macOS 26,
the Liquid Glass treatment. Apple's adoption guide is explicit: "Reduce your
use of custom backgrounds in controls and navigation elements... Prefer to
remove custom effects and let the system determine the background appearance,
especially for... split views, tab bars, and toolbars."

Only if you need a standalone panel outside a split view, bridge:
  struct VisualEffect: NSViewRepresentable {
      let material: NSVisualEffectView.Material          // .sidebar
      let blending: NSVisualEffectView.BlendingMode      // .behindWindow
      func makeNSView(context: Context) -> NSVisualEffectView {
          let v = NSVisualEffectView()
          v.material = material
          v.blendingMode = blending
          v.state = .followsWindowActiveState
          return v
      }
      func updateNSView(_ v: NSVisualEffectView, context: Context) {
          v.material = material; v.blendingMode = blending
      }
  }
Blending modes: .behindWindow samples the desktop and windows behind (correct
for sidebars, titlebars, HUD panels). .withinWindow samples only your own
window content (correct for an overlay above your own scroll view).
NSVisualEffectView defaults measured: material rawValue 0, blendingMode 0
(.behindWindow), state 0 (.followsWindowActiveState), isEmphasized false.

Vibrancy rule from the HIG: "Help ensure legibility by using vibrant colors on
top of materials." Concretely — put ONLY semantic label colours on a material.
The HIG's own worked example is that systemGray3 on a material is a
contrast failure while a vibrant label colour is correct.

========================================================
7. DARK MODE FOR A NEAR-BLACK INTERFACE
========================================================
The single most important correction: the base/elevated background pair is an
iOS and iPadOS mechanism, NOT a macOS one. The HIG describes base/elevated
strictly under "iOS, iPadOS". macOS has no elevated background colour, so do
not invent a ladder of progressively lighter greys to fake depth.

What macOS actually does for depth in dark mode:
  1. MATERIAL, not lightness. Separation comes from a sidebar or popover
     material sampling what is behind the window, plus the Liquid Glass layer
     floating above content. That is the elevation model.
  2. Content surfaces are DARKER than the window chrome, which is the
     opposite of iOS. Measured: windowBackgroundColor #323232 but
     controlBackgroundColor / textBackgroundColor #1E1E1E. The text well
     recedes; the window frame sits above it.
  3. Separators are 9.8% white (#FFFFFF @ 0.098), identical in magnitude to
     light mode's 9.8% black. One hairline value, both modes, no tuning.
  4. Text opacity is a fixed four-step ladder, near-symmetric across modes:
     84.7% / 54.9% / 24.7% / 9.8% in dark, 84.7% / 49.8% / 25.9% / 9.8% in
     light. Only secondary and tertiary differ at all, and only slightly.
     Primary label is NEVER 100% — textColor is 100%, labelColor is 84.7%.
  5. Desktop tinting: when the user picks the graphite accent, macOS pulls
     colour from the desktop picture into window backgrounds. The HIG asks you
     to "include some transparency in custom component backgrounds" so custom
     surfaces pick this up — but only on neutral-state components, never on a
     component currently showing a colour.
  6. The HIG explicitly permits a permanently dark app "in rare cases... for
     an app that supports immersive media viewing," citing Stocks. A bot
     cockpit is arguably in that family, but the same page warns against
     app-specific appearance settings, so pick dark-only or fully adaptive —
     do not build a preference.

Contrast targets from the HIG: minimum 4.5:1, and "strive for a contrast ratio
of 7:1, especially in small text" for custom colours.

Test matrix the HIG calls out by name: Dark Mode with Increase Contrast on,
with Reduce Transparency on, and with both on together. On this machine all
three accessibility flags currently read false
(accessibilityDisplayShouldReduceTransparency / ShouldIncreaseContrast /
ShouldReduceMotion), so none of that is being exercised today.

## Findings

- Liquid Glass is the macOS 26 design language. It is a dynamic material forming "a distinct functional layer for controls and navigation elements — like tab bars and sidebars — that floats above the content layer." Apple's rule is explicit: "Don't use Liquid Glass in the content layer"; content-layer surfaces use standard materials instead.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/materials>
- Liquid Glass has exactly two variants. Glass.regular "blurs and adjusts the luminosity of background content to maintain legibility" and is what "most system components use" — correct for sidebars, popovers and alerts. Glass.clear is for components over photo/video; if the underlying content is bright, "consider adding a dark dimming layer of 35% opacity."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/materials>
- Rebuilding against the macOS 26 SDK changes concrete geometry: windows adopt rounder corners sized to wrap concentrically around the glass toolbar; controls become rounder and taller and gain an extra-large size; lists, tables and forms get larger row height and padding; sections get increased corner radius; sheets get increased corner radius; and section headers switch from all-caps to title-style capitalisation.  
  — **confirmed** · <https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass>
- Apple explicitly instructs removing custom backgrounds from navigation chrome: "Reduce your use of custom backgrounds in controls and navigation elements... Prefer to remove custom effects and let the system determine the background appearance, especially for... split views, tab bars, and toolbars." Custom backgrounds interfere with Liquid Glass and the scroll edge effect.  
  — **confirmed** · <https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass>
- Every Liquid Glass SwiftUI API requires macOS 26.0 and is unavailable on visionOS. Verified signature: `nonisolated public func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View`, annotated @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) + @available(visionOS, unavailable). Same annotation on glassEffectID, glassEffectUnion, glassEffectTransition, GlassButtonStyle and GlassProminentButtonStyle.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)>
- `Glass` is declared in SwiftUICore (not SwiftUI) with exactly five members: static regular, static clear, static identity, func tint(_ color: Color?) -> Glass, and func interactive(_ isEnabled: Bool = true) -> Glass.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/glass>
- `.buttonStyle(.glass)` and `.buttonStyle(.glassProminent)` are macOS 26.0, but the customisable initialiser `GlassButtonStyle.init(_ glass: Glass)` is gated one version later at macOS 26.1.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass>
- ConcentricRectangle is macOS 26.0 but, unlike the glass APIs, IS available on visionOS 26.0. Its corner styles come from Edge.Corner.Style, which provides `.concentric` and `.concentric(minimum:)` so nested elements derive their radius from the container automatically.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/concentricrectangle>
- Measured window corner radii on macOS 26.5.2: titled window with no toolbar = 16 pt; with a .unifiedCompact toolbar = 20 pt; with a .unified toolbar = 26 pt; borderless = 0 pt. The radius scales with the toolbar, matching Apple's description that it wraps concentrically around the glass toolbar.  
  — **confirmed** · <https://developer.apple.com/documentation/appkit/nswindow>
- Measured titlebar+toolbar heights on macOS 26.5.2 (window frame height minus contentRect height): no toolbar 28 pt, .unifiedCompact 38 pt, .expanded 44 pt, .unified 52 pt, .preference 80 pt.  
  — **confirmed** · <https://developer.apple.com/documentation/appkit/nswindow/toolbarstyle>
- macOS semantic label colours are pure black or pure white at fixed alpha, never grey. Measured: labelColor #000000/#FFFFFF @ 0.847; secondaryLabelColor @ 0.498 light / 0.549 dark; tertiaryLabelColor @ 0.259 / 0.247; quaternaryLabelColor @ 0.098 both; separatorColor @ 0.098 both. This is why a hardcoded hex grey cannot composite correctly over a material.  
  — **confirmed** · <https://developer.apple.com/documentation/appkit/nscolor/labelcolor>
- In macOS dark mode the content surface is DARKER than the window chrome — the inverse of iOS. Measured: windowBackgroundColor #323232 but controlBackgroundColor and textBackgroundColor both #1E1E1E, underPageBackgroundColor #282828, gridColor #1A1A1A.  
  — **confirmed** · <https://developer.apple.com/documentation/appkit/nscolor/windowbackgroundcolor>
- The base/elevated dark-mode background pair is iOS and iPadOS only. The HIG documents it strictly under the "iOS, iPadOS" platform heading; the macOS section instead covers desktop tinting, where windows pick up colour from the desktop picture when the accent is graphite. macOS has no elevated background colour.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/dark-mode>
- The system palette changed in macOS 26. Measured light-mode values: systemRed #FF383C (was #FF3B30), systemOrange #FF8D28 (was #FF9500), systemPurple #CB30E0 (was #AF52DE), systemBlue #0088FF, systemTeal #00C3D0, systemIndigo #6155F5, systemCyan #00C0E8, systemMint #00C8B3. systemGreen #34C759 and systemPink #FF2D55 are unchanged.  
  — **confirmed** · <https://developer.apple.com/documentation/appkit/nscolor/systemred>
- controlAccentColor (#007AFF in both appearances, default blue) is a DIFFERENT colour from systemBlue (#0088FF light / #0091FF dark). Using systemBlue where the accent belongs both mismatches the system and ignores the user's chosen accent.  
  — **confirmed** · <https://developer.apple.com/documentation/appkit/nscolor/controlaccentcolor>
- macOS type scale, confirmed by two independent sources — Apple's HIG table and NSFont.preferredFont measured on this machine: Large Title 26/32, Title 1 22/26, Title 2 17/22, Title 3 15/20, Headline 13/16 Bold, Body 13/16, Callout 12/15, Subheadline 11/14, Footnote 10/13, Caption 1 10/13, Caption 2 10/13 Medium. macOS Headline is Bold, not Semibold as on iOS — the resolved font name is ".SFNS-Bold".  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/typography>
- macOS system font default size is 13 pt with a 10 pt minimum. Measured AppKit constants agree: NSFont.systemFontSize = 13.0, smallSystemFontSize = 11.0, labelFontSize = 10.0.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/typography>
- SwiftUI's Material type exposes only ultraThin, thin, regular, thick, ultraThick (macOS 12.0) and bar (macOS 12.0). There is no SwiftUI material for a sidebar; macOS's purpose-named materials exist only on NSVisualEffectView.Material, which includes .sidebar (raw 7), .headerView (10), .contentBackground (18), .underWindowBackground (21), .popover (6), .titlebar (3) and .sheet (11).  
  — **confirmed** · <https://developer.apple.com/documentation/appkit/nsvisualeffectview/material>
- Measured AppKit split view defaults: a sidebar NSSplitViewItem has minimumThickness 140 pt, unbounded maximum, canCollapse true, holdingPriority 260, allowsFullHeightLayout true. An inspector item is fixed at minimumThickness = maximumThickness = 270 pt with holdingPriority 261.  
  — **confirmed** · <https://developer.apple.com/documentation/appkit/nssplitviewitem>
- Measured NSTableView.rowHeight is 24 pt for every style (.automatic, .fullWidth, .inset, .sourceList, .plain), and NSOutlineView in .sourceList style uses indentationPerLevel 13 pt.  
  — **confirmed** · <https://developer.apple.com/documentation/appkit/nstableview/rowheight>
- Measured control heights on macOS 26.5 are substantially taller than pre-26 macOS. At .regular: push button 32 pt, popup 25 pt, segmented 24 pt, bezeled text field 21 pt, switch 42x25. At .large: push, popup and segmented are all 40 pt. This matches Apple's statement that controls adopt rounder forms and gain an extra-large size.  
  — **confirmed** · <https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass>
- AppKit's Liquid Glass surface is NSGlassEffectView, API_AVAILABLE(macos(26.0)), with properties contentView, cornerRadius, tintColor and style (NSGlassEffectViewStyleRegular / NSGlassEffectViewStyleClear). Measured default cornerRadius is 8.0 and default style is regular with nil tint. NSGlassEffectContainerView batches nearby glass views via a `spacing` property defaulting to zero.  
  — **confirmed** · <https://developer.apple.com/documentation/appkit/nsglasseffectview>
- An app can ship the pre-26 appearance while building against the new SDK by setting the Info.plist key UIDesignRequiresCompatibility.  
  — **confirmed** · <https://developer.apple.com/documentation/BundleResources/Information-Property-List/UIDesignRequiresCompatibility>
- These APIs are available at a macOS 14 deployment target, so a non-26 baseline still has semantic styling: .fill, .placeholder and .windowBackground (macOS 14.0); .containerBackground(_:for:) (macOS 14.0); .inspector(isPresented:) and .inspectorColumnWidth (macOS 14.0); .quinary and .selection (macOS 12.0); .navigationSplitViewColumnWidth (macOS 13.0); .presentationBackground (macOS 13.3); .listStyle(.sidebar) (macOS 10.15).  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/shapestyle/windowbackground>
- Vibrancy guidance is specific: put only system-defined vibrant colours on a material. The HIG's worked contrast example shows a systemGray3 label on a material as the failure case and a vibrant label colour as correct — "Regardless of the material you choose, use vibrant colors on top of it."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/materials>
- Contrast targets: minimum 4.5:1 for all appearances, and "strive for a contrast ratio of 7:1, especially in small text" for custom foreground/background colours. Apple names the specific test matrix as Dark Mode with Increase Contrast and Reduce Transparency, both separately and together.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/dark-mode>
- macOS split views should use the thin divider: "The thin divider measures one point in width, giving you maximum space for content while remaining easy for people to use." The HIG also warns against putting critical information or actions at the bottom of a sidebar or window, because people often position windows so the bottom edge is offscreen.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/split-views>
- A permanently dark interface is explicitly sanctioned in narrow cases — "it can make sense for an app that supports immersive media viewing to use a permanently dark appearance that lets the UI recede" (Apple cites Stocks) — but the same page advises against offering an app-specific appearance setting, since users expect the systemwide choice to be respected.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/dark-mode>
- Sidebar icons should follow the app's accent colour by default: "By default, sidebar icons use your app's accent color. In macOS, people can change the system accent color... they expect all sidebar icons to appear in that color." Fixed colours are permitted only sparingly, to clarify meaning or draw attention.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/sidebars>
- Sidebar row height, text and glyph size on macOS are driven by a small/medium/large sidebar size that the user controls in General settings, not by the app: "You can set the size programmatically, but people can also change it by selecting a different sidebar icon size in General settings."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/sidebars>
- macOS 26 provides a background extension effect that "mirrors adjacent content to give the impression of stretching it under the sidebar, and applies a blur to maintain legibility." SwiftUI: .backgroundExtensionEffect() (macOS 26.0); AppKit: NSBackgroundExtensionView.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect()>
- Custom bars that have content scrolling beneath them must opt into the scroll edge effect or they will lose legibility; system toolbars get it by default. SwiftUI: .scrollEdgeEffectStyle(_:for:) and .scrollEdgeEffectHidden(_:for:), both macOS 26.0.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:)>
- Toolbar item grouping in macOS 26 is done with ToolbarSpacer (macOS 26.0), and Apple warns not to mix text and icons across items that share a background. Hiding a toolbar item must hide the item itself via .toolbarItemHidden(_:), not the view inside it, or an empty glass capsule remains visible.  
  — **confirmed** · <https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass>
- Custom Liquid Glass elements must be wrapped in a GlassEffectContainer when there is more than one: it "helps optimize performance while fluidly morphing Liquid Glass shapes into each other," and the AppKit equivalent reduces the number of render passes.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/glasseffectcontainer>

## What to build

- Delete every hardcoded hex grey and replace with semantic styles. Text: .foregroundStyle(.primary) for message body and sidebar row labels, .secondary for timestamps/subtitles/section headers, .tertiary for disabled and placeholder-adjacent text. Hairlines: Divider() or .separator, never a grey rectangle. The measured proof this matters: labelColor is #000000/#FFFFFF at 84.7% alpha, not a grey — an opaque grey cannot composite correctly over the sidebar material, which is exactly why the current panes look flat.
- Stop painting the sidebar and inspector entirely. Remove any .background(Color(...)) on the roster column and the screen/settings column and let NavigationSplitView supply the material. Apple's adoption guide names split views, tab bars and toolbars as the specific places to remove custom backgrounds because they interfere with Liquid Glass and the scroll edge effect. This is the single highest-value change for a three-pane cockpit and it is a net deletion of code.
- Decide the deployment target explicitly and write an ADR, because it is a door-closing choice. Given the app is single-user and local-first on a machine already running macOS 26.5, targeting macOS 26.0 unlocks glassEffect, ConcentricRectangle, ToolbarSpacer, backgroundExtensionEffect and the scroll edge effect. The falsifier to record: if anyone needs to run Bot-Harness on macOS 14 or 15, every glass API becomes an #available branch and ConcentricRectangle needs a RoundedRectangle fallback.
- Set the window to .unified toolbar style and size the three panes around the measured numbers: 52 pt titlebar+toolbar, 26 pt window corner radius. Give the bot roster .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320) — AppKit's own sidebar minimum is 140 pt, which is too tight for a bot name plus a status glyph. Use .inspectorColumnWidth for the right pane; AppKit's fixed inspector default is 270 pt.
- Adopt the macOS type scale verbatim in the conversation pane: .body (13 pt) for message text, .caption (10 pt) with .secondary for timestamps, .subheadline (11 pt) with .secondary for section headers in title-style capitalisation (macOS 26 stopped auto-capitalising these). Use .body.monospaced() for shell commands, tool arguments, file paths and trace hashes — that is the one place a monospaced design is correct. Never use design: .rounded anywhere; it has no macOS system precedent and reads instantly as a non-native app.
- Use the accent colour, not systemBlue, for selection and active states, and bridge the ones SwiftUI lacks: Color.accentColor for selected roster rows and primary actions, Color(nsColor: .unemphasizedSelectedContentBackgroundColor) for the selected-but-unfocused row (#DCDCDC light / #464646 dark). These are different colours — controlAccentColor is #007AFF while systemBlue is #0088FF — and only the accent tracks the user's System Settings choice.
- Rebuild the permission-prompt and confirmation sheets against the system rather than custom chrome. Sheets get an increased corner radius in macOS 26 automatically; remove any custom visual effect view from popover content, which Apple calls out by name as something to audit and delete. For the permission floor specifically this matters beyond looks: a prompt that renders as system-native is harder to mistake for app content, which is the correct property for the safety-critical surface.
- Give the ActivityInspector and the trace list a 24 pt row height to match NSTableView's measured default across every style, and use .listStyle(.sidebar) for the roster so it picks up source-list behaviour. Do not hardcode row heights elsewhere — macOS 26 increased list and form row height and padding, and hardcoded metrics are exactly what Apple warns will look wrong after the rebuild.
- Apply .glassEffect() to at most one or two custom elements — realistically the run/stop control and nothing else. Apple's guidance is that overusing it on custom controls 'can provide a subpar user experience by distracting from that content.' If you end up with more than one, wrap them in a GlassEffectContainer, which both merges them correctly and cuts render passes.
- Add a screenshot-based check to the existing eval suite that captures the window by window ID (per the repo's own note about not stealing focus) in four configurations: light, dark, dark with Increase Contrast, and dark with Reduce Transparency. Apple names that exact matrix, and it is the configuration where translucent chrome most often produces dark text on a dark background. Capturing it is cheap given the harness already does window-ID capture.
- Drop any notion of a per-app appearance preference and any ladder of progressively lighter greys for elevation. Base/elevated is an iOS mechanism with no macOS equivalent; macOS conveys depth through material and through content surfaces being darker than window chrome (measured #1E1E1E content against #323232 window). If you want the cockpit permanently dark, the HIG permits that for immersive apps — but make it unconditional, not a setting.

## Could not verify

- Exact corner radius in points for sheets and popovers on macOS 26. Apple's adoption guide says sheets 'feature an increased corner radius' but publishes no number, and I did not present a real sheet to measure it. The 16/20/26 pt window radii I did measure are windows, not sheets — do not assume they transfer.
- The default ideal sidebar width SwiftUI's NavigationSplitView uses on macOS. I measured AppKit's NSSplitViewItem sidebar minimumThickness at 140 pt, but that is the floor, not the default width, and SwiftUI may not use the AppKit default. My 180/220/320 recommendation is a judgement call sized to the content, not a measured system value.
- Whether the measured control heights (regular push button 32 pt, popup 25 pt, segmented 24 pt) are the shipping layout metrics or an artifact of calling sizeToFit on a detached, unhosted NSButton with bezelStyle .push. The relative jump versus pre-26 macOS is consistent with Apple's documented control refresh, but I did not verify these against a control inside a live rendered window.
- Which of the HIG typography page's tracking tables applies to macOS. The page carries several near-identical tracking tables across platforms and text styles, and I could not reliably attach one to the macOS heading from the JSON structure. I have therefore given no tracking values; if you need them, do not guess from the numbers in that page without re-checking which table is which.
- The exact name and location of the macOS 26 System Settings control for the Liquid Glass 'preferred look'. The HIG refers to people choosing 'a preferred look for Liquid Glass in their device's settings' and notes that it changes how the regular and clear variants render, but I did not confirm the setting's label or where it lives in System Settings.
- Whether NSVisualEffectView.Material.sidebar on macOS 26 renders as legacy vibrancy or has been rebased onto Liquid Glass. I confirmed the enum still exists with raw value 7, but I did not visually compare a bridged NSVisualEffectView sidebar against a system NavigationSplitView sidebar. This is worth checking before you rely on the NSViewRepresentable bridge rather than the split view.
- macOS 26.5 running here is ahead of the 26.0 that most availability annotations name. Everything I measured is from 26.5.2 with the 26.5 SDK, so a value could in principle differ on 26.0 — most plausibly the refreshed control heights and the window corner radii, which are the numbers Apple was actively tuning across the 26 cycle.
