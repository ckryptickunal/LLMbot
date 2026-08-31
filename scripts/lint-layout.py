#!/usr/bin/env python3
"""Layout lint.

Finds the spacing and sizing defects that are invisible in a screenshot but obvious in a diff:
arithmetic on tokens, raw numbers, components with no size floor, and inconsistent insets.

Run: python3 scripts/lint-layout.py
"""
import pathlib, re, sys, collections

# Mascot.swift is sprite geometry — pixel coordinates in a drawing, not layout. Linting it
# for "raw numbers" would be like linting an icon's bezier handles.
EXCLUDE = {"Mascot.swift"}
UI = [p for p in pathlib.Path("Sources/BotHarness").rglob("*.swift")
      if p.name not in EXCLUDE]
TOKENS = pathlib.Path("Sources/BotHarness/Design/Tokens.swift")

findings = collections.defaultdict(list)

for path in UI:
    if path == TOKENS:
        continue
    rel = str(path).replace("Sources/BotHarness/", "")
    for n, line in enumerate(path.read_text().split("\n"), 1):
        code = line.split("//")[0]
        if not code.strip():
            continue

        # Arithmetic on a token is a literal wearing a token's clothes.
        for m in re.finditer(r'DS\.(Space|Radius|Size)\.\w+\s*[-+]\s*\d', code):
            findings["arithmetic on tokens"].append(f"{rel}:{n}  {m.group(0)}")

        # Raw numeric padding / spacing / frame.
        for m in re.finditer(r'\.padding\(\s*(?:\.\w+,\s*)?(\d+(?:\.\d+)?)\s*\)', code):
            if m.group(1) == "0":
                continue
            findings["raw padding"].append(f"{rel}:{n}  {m.group(0)}")
        # 0 is "no gap" and 1 is a hairline. Neither is a spacing decision, so neither wants
        # a token — a DS.Space.none would be ceremony, not clarity.
        for m in re.finditer(r'spacing:\s*(\d+(?:\.\d+)?)', code):
            if m.group(1) in {"0", "1"}:
                continue
            findings["raw spacing"].append(f"{rel}:{n}  {m.group(0)}")
        for m in re.finditer(r'(?:min|max|ideal)?[Ww]idth:\s*(\d{2,}(?:\.\d+)?)', code):
            findings["raw width"].append(f"{rel}:{n}  {m.group(0)}")
        for m in re.finditer(r'(?:min|max|ideal)?[Hh]eight:\s*(\d{2,}(?:\.\d+)?)', code):
            findings["raw height"].append(f"{rel}:{n}  {m.group(0)}")

        # Raw colour.
        if re.search(r'Color\.(white|black|primary|secondary|gray)\.opacity', code):
            findings["raw colour"].append(f"{rel}:{n}  {code.strip()[:70]}")

        # A maxHeight on a container claims space rather than capping it — the composer bug.
        # A deliberate cap is marked `// cap:` on the same line so it is a decision on the
        # record rather than something the lint quietly tolerates.
        # The lookahead has to sit before the whitespace, not after it. Written as
        # `maxHeight:\s*(?!\.infinity)` the `\s*` backtracks to zero width, the lookahead then
        # sees a space rather than `.infinity`, and every `maxHeight: .infinity` written with a
        # space was flagged. A lint that cries wolf is one people stop running.
        if (re.search(r'\.frame\([^)]*maxHeight:(?!\s*\.infinity)', code)
                and "Skeleton" not in code and "// cap:" not in line):
            findings["maxHeight claims space"].append(f"{rel}:{n}  {code.strip()[:70]}")

# Components that should declare a size floor.
prims = pathlib.Path("Sources/BotHarness/Design/Primitives.swift").read_text()
# Split on the *next* declaration of any kind, not just the next struct, or a component
# followed by an extension absorbs the extension's frames and looks constrained when it is not.
BOUNDARY = re.compile(r'\n(?:public |private |internal )?(?:struct|enum|extension|final class) ')
for name in re.findall(r'public struct (\w+)(?:<[^>]*>)?: View', prims):
    after = prims.split(f"public struct {name}", 1)[1]
    block = BOUNDARY.split(after, 1)[0]
    if ".frame(" not in block:
        findings["component with no size constraint"].append(name)

total = 0
for kind in sorted(findings):
    items = findings[kind]
    total += len(items)
    print(f"\n{kind}  ({len(items)})")
    for item in items[:14]:
        print("   ", item)
    if len(items) > 14:
        print(f"    … and {len(items) - 14} more")

print(f"\nTOTAL: {total}")
sys.exit(1 if total else 0)
