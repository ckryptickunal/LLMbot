# Google Gemini Computer Use — current state as of 2026-08-29 (tool shape, model IDs, safety keys, SDK, desktop support) for the Bot-Harness Mac-native agent

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

Gemini Computer Use is real, actively maintained, and — critically for this project — officially supports a `desktop` environment, not just browser. The user brief was right about `gemini-3.7-flash` (it exists, it is the *recommended* computer-use model, and it is on the public pricing page at $0.75/1M in, $3.75/1M out through 2026-12-31) and right that Gemini 3.5 Flash-Lite supports computer use (`gemini-3.5-flash-lite`, $0.30/$2.50). The single biggest trap: Google now has TWO parallel API surfaces and the docs and the reference repo disagree. The docs teach the new `client.interactions.create(...)` API with plain-dict tools (`{"type": "computer_use", "environment": "desktop"}`), while the official reference repo `google-gemini/computer-use-preview` still runs the older `client.models.generate_content(...)` with typed `types.Tool(computer_use=types.ComputerUse(environment=types.Environment.ENVIRONMENT_BROWSER))`. The second trap is that the reference repo is browser-only — it ships Playwright and Browserbase backends and nothing else — so there is no Google-provided macOS desktop action handler. Kunal has to write the macOS executor (screencapture + CGEvent/Accessibility) himself; the model side is ready, the client side is not.

## Recommendation

Use `gemini-3.7-flash` with `"environment": "desktop"` as the primary computer-use brain for Bot-Harness, and build the macOS executor yourself — Google gives you the model and the protocol but no Mac client.

Concretely, four decisions:

1. Pick the API surface deliberately. Write against the new `client.interactions.create(...)` with plain-dict tools, because that is what the docs describe for desktop and it is the surface Google is actively documenting. But read `agent.py` from the reference repo for the loop structure, because it is the only complete working example — just do not copy its `generate_content` call shape or its `ENVIRONMENT_BROWSER` constant. Budget a spike day to confirm `interactions.create` behaves as documented in google-genai 2.20.0, since the repo's divergence means the new surface has no official end-to-end example yet.

2. Build the Swift executor around the normalized 0-999 coordinate space. This is the detail most likely to cause silent misclicks: the model never learns your real screen size, so your Swift layer owns the transform in both directions — scale 0-999 to actual Retina point coordinates when executing, and downscale screenshots consistently when capturing. Get this wrong on a multi-display or scaled-resolution Mac and every click lands slightly off. The desktop action set is only 17 verbs and maps cleanly onto CGEvent for mouse and keyboard and `CGWindowListCreateImage`/ScreenCaptureKit for screenshots. The macOS permissions you must hold are Screen Recording and Accessibility, both of which need to be requested up front in onboarding.

3. Treat the safety layer as the product's main UI surface, not a checkbox. Every action can carry `safety_decision` with `require_confirmation`, and Google warns explicitly that disabling policies via `disabled_safety_policies` only expresses a preference — the model may still ask. So the confirmation prompt must always be implemented. For a personal Mac agent with real file-system access, keep `DATA_MODIFICATION` and `SENSITIVE_DATA_MODIFICATION` enabled and surface each confirmation in the center conversation pane. Turn on `enable_prompt_injection_detection` from day one, since a desktop agent reads whatever is on screen.

4. The `intent` string on every action is the audit log you were going to have to invent. Google's own guidance already tells you to log prompts, screenshots, `function_call`s, safety responses, and executed actions — that list is essentially your logging schema, and `intent` gives each row a human-readable reason. Persist all five per step.

On cost, note the 3.7 Flash price doubles on January 1 2027. Computer-use loops are screenshot-heavy and therefore input-token-heavy, so a long session is meaningfully cheaper this year than next. Wire the model ID into config so you can drop to `gemini-3.5-flash-lite` (roughly 2.5x cheaper on input, and cheaper still relative to 3.7's 2027 price) for routine tasks, and keep 3.7 for hard ones.

## Risks

- Two divergent API surfaces. The docs teach client.interactions.create with dict tools; the official reference repo still runs client.models.generate_content with typed types.ComputerUse. There is no official end-to-end example of the new surface driving a desktop environment, so you are partly writing against documentation rather than working code. Spike this before committing architecture.
- Even the safety_acknowledgement type differs between the two surfaces: the docs set action_result["safety_acknowledgement"] = True (Python bool), while agent.py sets extra_fr_fields["safety_acknowledgement"] = "true" (string). Guessing wrong may silently fail to acknowledge and stall the loop.
- No Google-provided macOS desktop executor exists. The reference repo has only Playwright and Browserbase backends. All CGEvent synthesis, screenshot capture, coordinate scaling, and display handling is net-new code you own and must test yourself.
- Computer Use remains a Preview capability, and Google explicitly warns of errors and security vulnerabilities and advises against tasks involving critical decisions, sensitive data, or uncorrectable actions. A personal agent with full Mac access is exactly the scenario Google is cautioning about — the sandboxing advice (VM/container) does not translate to an app driving the user's real desktop.
- Normalized 0-999 coordinates are lossy. On a 1440-point-wide display each unit is ~1.44 points, so precision is roughly a point and a half — fine for buttons, risky for small hit targets, dense menus, or Retina-scaled multi-display setups.
- gemini-3.7-flash pricing doubles on 2027-01-01 ($0.75 to $1.50 input, $3.75 to $7.50 output). Any cost model built on today's numbers is only valid for four more months.
- Python 3.10 on the machine is exactly google-genai's minimum (requires_python >=3.10) with no headroom. The SDK shipped 12 releases between 2026-07-09 and 2026-08-25 — a fast cadence that could drop 3.10 support. Pin the version and plan a Python upgrade.
- The docs claim the reference implementation "includes a ready-to-use Docker-based sandbox", but the repo file tree contains no Dockerfile. That sandbox guidance appears to be stale or the asset was removed — do not plan on it existing.
- Official docs still link to github.com/google/computer-use-preview, which works only via a GitHub 301 redirect to the google-gemini org. Pin the canonical google-gemini/ URL in any clone script.
- Desktop environment has no navigate/go_back/go_forward actions. Any browser-style task on macOS must be driven through the OS-level verbs (clicking the address bar, hotkey) rather than direct navigation — expect more steps, more screenshots, and higher cost per browser task than the browser environment.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- BRIEF PARTIALLY WRONG, IN YOUR FAVOR: the brief flagged 'gemini-3.7-flash' and 'Gemini 3.5 Flash-Lite' as claims needing verification. Both are REAL. gemini-3.7-flash is the docs-recommended computer-use model and appears ~30 times on the computer-use page and on the pricing page. The exact model ID for the second is gemini-3.5-flash-lite (lowercase, hyphenated) — 'Gemini 3.5 Flash-Lite' is only the display name.
- REPO README IS STALE relative to the docs. https://raw.githubusercontent.com/google-gemini/computer-use-preview/main/README.md lists its default model as gemini-3.6-flash and does not mention gemini-3.7-flash at all. Its 'Available Models' list is: gemini-3.6-flash (default), gemini-3.5-flash-lite, gemini-3.5-flash, gemini-2.5-computer-use-preview-10-2025, gemini-3-flash-preview. The last push was 2026-07-28 and the docs were updated 2026-08-26, so the repo trails by about a month.
- COULD NOT VERIFY gemini-3.6-flash. It appears in the reference repo README as the default model but does NOT appear anywhere in the official computer-use docs model list or on the pricing page I fetched. It may be an unlisted intermediate release, deprecated, or a README error. Do not build against this ID without checking the live models endpoint with a real API key.
- COULD NOT VERIFY whether gemini-3.7-flash computer use is GA or Preview at the model level. The Computer Use capability as a whole is explicitly labelled Preview, and gemini-3.7-flash lacks a '-preview' suffix and has published paid pricing (both GA signals), but no page I fetched states its status for computer use specifically.
- COULD NOT VERIFY the live model list via generativelanguage.googleapis.com/v1beta/models — requires an API key I do not have in this session. All model IDs come from documentation pages, not from the API itself.
- COULD NOT VERIFY the exact google-genai symbol names for the new interactions surface (e.g. whether types.Environment.ENVIRONMENT_DESKTOP exists as a typed constant alongside the documented plain string "desktop"). I read only the docs and the repo's agent.py, not the SDK source. Confirm by inspecting the installed package.
- COULD NOT VERIFY any Google blog post or release note announcing desktop-environment computer use. Perplexity MCP returned HTTP 401 insufficient_quota, and my WebSearch surfaced only the consumer-facing Gemini Mac app and Gemini Spark, which are separate products from the Computer Use API and should not be confused with it.
- DOCS INTERNALLY INCONSISTENT on the example in section D of the code shape: the safety_decision sample response uses the LEGACY action name click_at (a Gemini 2.5 verb) even though it appears in the Gemini 3.x safety documentation. The 3.x equivalent is click. Treat that sample as illustrative of the safety envelope only, not of current action naming.
- COULD NOT VERIFY the practical accuracy or reliability of the desktop environment on macOS specifically. All documented examples and the entire reference implementation target browsers; no macOS benchmark, demo, or known-issues section exists. Whether the model reliably recognizes macOS-native chrome (menu bar, Dock, traffic lights, sheets) is genuinely unknown and should be your first empirical test.
- COULD NOT VERIFY rate limits, per-minute request quotas, or screenshot size limits for computer-use requests — not present on the pages fetched.

## Verified facts

- The Computer Use tool is enabled with tool type string "computer_use" and an "environment" key. Gemini 3.x supports three environments: browser (ENVIRONMENT_BROWSER), mobile (ENVIRONMENT_MOBILE), and desktop (ENVIRONMENT_DESKTOP). Docs page last updated 2026-08-26 UTC.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- gemini-3.7-flash EXISTS and is documented as "The recommended model for computer use, featuring streamlined actions with intents, support for browser, mobile, and desktop environments, configurable safety policies, and prompt injection detection." The user brief's claim about this model ID is correct.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- Full documented model list supporting Computer Use: gemini-3.7-flash (recommended), gemini-3.5-flash-lite (low-latency, cost-effective), gemini-3.5-flash (previous stable), gemini-3-flash-preview (preview), gemini-2.5-computer-use-preview-10-2025 (legacy preview, browser-only).  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- gemini-3.7-flash paid pricing: input $0.75/1M tokens and output (incl. thinking) $3.75/1M through December 31 2026, then doubling to $1.50/$7.50 on January 1 2027. Context caching $0.075/1M. Batch tier is half: $0.375/$1.875.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/pricing>
- gemini-3.5-flash-lite paid pricing: input $0.30/1M (text/image/video/audio), output $2.50/1M, context caching $0.03/1M. No scheduled 2027 price increase listed, unlike 3.7 Flash.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/pricing>
- The safety mechanism is a safety_decision object returned inside function_call arguments, with keys "decision" and "explanation". Decision values are regular/allowed, require_confirmation, and blocked. When the user approves a require_confirmation action, the client sets "safety_acknowledgement" in the function_result.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- Prompt-injection detection is an opt-in boolean tool key named exactly enable_prompt_injection_detection, described as screenshot scanning to detect hidden adversarial instructions. The user brief's guess at this key name is exactly correct.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- Seven built-in safety policy categories exist and can be selectively turned off via the disabled_safety_policies tool key: FINANCIAL_TRANSACTIONS, SENSITIVE_DATA_MODIFICATION, COMMUNICATION_TOOL, ACCOUNT_CREATION, DATA_MODIFICATION, USER_CONSENT_MANAGEMENT, LEGAL_TERMS_AND_AGREEMENTS. Docs warn overrides are only a preference — the model may still return require_confirmation, so handling is always required.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- All coordinates are NORMALIZED integers 0-999, not pixels, for both browser and desktop environments. Docs state there is no need to specify display size in the request; the client must scale normalized coordinates to its own viewport before executing.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- Every Gemini 3.x action carries an "intent": str argument — the model's stated reasoning for that specific step. This is a per-action audit string, directly useful for the project's decision-logging requirement.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- The desktop environment (ENVIRONMENT_DESKTOP) supports these OS-level actions: click, double_click, triple_click, middle_click, right_click, mouse_down, mouse_up, move, type, drag_and_drop, wait, press_key, key_down, key_up, hotkey, take_screenshot, scroll. It notably does NOT include the browser-only navigate, go_back, go_forward.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- The repo google-gemini/computer-use-preview is live and active: 3,184 stars, 403 forks, Apache-2.0 license, last push 2026-07-28T14:08:36Z, created 2025-05-06, not archived, Python, 34 open issues, default branch main.  
  — **confirmed** · <https://api.github.com/repos/google-gemini/computer-use-preview>
- The reference repo is BROWSER-ONLY. Its complete file tree contains exactly two environment backends — computers/playwright/playwright.py and computers/browserbase/browserbase.py — plus computers/computer.py. There is no desktop, macOS, or OS-level executor, and no Dockerfile despite the docs referring to a "ready-to-use Docker-based sandbox".  
  — **confirmed** · <https://api.github.com/repos/google-gemini/computer-use-preview/git/trees/main?recursive=1>
- The reference repo's agent.py uses the OLDER API surface: self._client.models.generate_content(...) with GenerateContentConfig(tools=[types.Tool(computer_use=types.ComputerUse(environment=types.Environment.ENVIRONMENT_BROWSER, excluded_predefined_functions=excluded_predefined_functions))], thinking_config=types.ThinkingConfig(include_thoughts=True)). It does NOT use client.interactions.create that the docs now teach.  
  — **confirmed** · <https://raw.githubusercontent.com/google-gemini/computer-use-preview/main/agent.py>
- In the reference repo agent.py, the safety flow reads function_call.args.get("safety_decision"), raises unless safety["decision"] == "require_confirmation", and on approval sets extra_fr_fields["safety_acknowledgement"] = "true" — note the STRING "true", not a Python bool, in this older generate_content path.  
  — **confirmed** · <https://raw.githubusercontent.com/google-gemini/computer-use-preview/main/agent.py>
- The google-genai Python SDK is at version 2.20.0, published 2026-08-25, requires_python >=3.10. Docs require version 2.7.0 or higher for the Gemini 3.x computer-use configuration, so current PyPI is well past the floor. Python 3.10 on the target machine meets the minimum exactly.  
  — **confirmed** · <https://pypi.org/pypi/google-genai/json>
- The REST endpoint for the new interactions API is POST https://generativelanguage.googleapis.com/v1beta/interactions with the API key passed as ?key=$GEMINI_API_KEY, body containing model, input, and tools.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- The repo was renamed at the org level: github.com/google/computer-use-preview issues an HTTP 301 redirect to repository id 978411532, which resolves to full_name google-gemini/computer-use-preview. The official docs still link to the old google/ path, which works only via that redirect.  
  — **confirmed** · <https://api.github.com/repos/google/computer-use-preview>
- Computer Use is still formally a Preview capability. Docs carry the warning that it "may contain errors and security vulnerabilities" and recommend close supervision plus avoiding tasks involving critical decisions, sensitive data, or uncorrectable actions.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- Google explicitly recommends observability practices matching this project's audit requirement: "Your client should log prompts, screenshots, model-suggested actions (function_call), safety responses, and all actions ultimately executed by the client."  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>
- The agent loop is client-driven: send prompt + screenshot + tool config, receive a function_call (plus intent and possibly safety_decision), scale coordinates and execute client-side, capture a fresh screenshot, return it in a function_result, repeat until done.  
  — **confirmed** · <https://ai.google.dev/gemini-api/docs/computer-use>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [google-gemini/computer-use-preview](https://github.com/google-gemini/computer-use-preview) | reference-only — copy the agent loop, action dispatch table and safety_decision handling verbatim, but you must write the macOS desktop executor yourself; its Playwright backend is useless for a Mac-native app and its API call pattern is the older generate_content one. | Google's official reference implementation of the Computer Use agent loop in Python. Ships main.py CLI, agent.py (the loop, action dispatch, safety confirmation), and two environment backends: local Playwright Chrome and hosted Browserbase. Browser-only — no desktop/macOS executor. | 3,184 (403 forks) | Apache-2.0 | pushed 2026-07-28T14:08:36Z; repo metadata updated 2026-08-29; not archived; 34 open issues |
| [google/computer-use-preview (legacy path)](https://github.com/google/computer-use-preview) | reject — do not clone this path in scripts or CI; pin the google-gemini/ URL so a future redirect removal cannot break the build. | Old org path still linked from the official docs. Not a separate project — GitHub 301-redirects it to repository id 978411532 = google-gemini/computer-use-preview. | n/a (redirect) | n/a (redirect) | n/a — resolves to the same repo |
| [google-genai (PyPI)](https://pypi.org/project/google-genai/) | adopt — this is the SDK. Version 2.20.0 is current and far exceeds the documented 2.7.0 floor for Gemini 3.x computer use. requires_python >=3.10 matches the machine's Python 3.10 exactly, with zero headroom. | The official unified Google Gen AI Python SDK. Provides both client.models.generate_content with types.ComputerUse/types.Environment, and the newer client.interactions.create surface. Supports both the Gemini Developer API and Vertex AI from the same client. | n/a (package) | Apache-2.0 (per repo googleapis/python-genai) | 2.20.0 published 2026-08-25; releases roughly weekly through Jul–Aug 2026 |

## API and code shape

All snippets copied verbatim from primary sources.

=== A. NEW surface — what the docs teach (google-genai >= 2.7.0) ===
Source: https://ai.google.dev/gemini-api/docs/computer-use

from google import genai

client = genai.Client()

interaction = client.interactions.create(
    model='gemini-3.7-flash',
    input="Find a flight from SF to Hawaii on Jun 30th, coming back on Jul 6th",
    tools=[
        {
            "type": "computer_use",
            "environment": "browser",
            "enable_prompt_injection_detection": True
        }
    ]
)
print(interaction)

=== B. DESKTOP environment + safety override (the shape Bot-Harness needs) ===
interaction = client.interactions.create(
    model="gemini-3.7-flash",
    input="Clean up the local folder by archiving old logs.",
    tools=[
        {
            "type": "computer_use",
            "environment": "desktop",
            "disabled_safety_policies": ["data_modification"]
        }
    ]
)

=== C. REST endpoint (desktop env) ===
curl "https://generativelanguage.googleapis.com/v1beta/interactions?key=${GEMINI_API_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{
        "model": "gemini-3.5-flash",
        "input": "Search for flight deals and summarize top results.",
        "tools": [
          {
            "type": "computer_use",
            "environment": "desktop",
            "enable_prompt_injection_detection": true
          }
        ]
      }'

=== D. safety_decision as it arrives in the response ===
{ "steps" : [ { "type" : "function_call" , "name" : "click_at" , "arguments" : {
  "x" : 60 , "y" : 100 ,
  "safety_decision" : {
      "explanation" : "Must check check-box" ,
      "decision" : "require_confirmation"
  } } } ] }

=== E. Confirmation handling (docs version) ===
def get_safety_confirmation(safety_decision):
    # Prompt user for confirmation
    print(f"Safety confirmation required: {safety_decision.get('explanation', '')}")
    return "CONTINUE"  # Or TERMINATE

# Inside execute_function_calls, check for safety_decision:
if 'safety_decision' in function_call.arguments:
    decision = get_safety_confirmation(function_call.arguments['safety_decision'])
    if decision == "TERMINATE":
        break
    # Include safety_acknowledgement inside the action result
    action_result["safety_acknowledgement"] = True

=== F. OLD surface — what the reference repo actually runs ===
Source: https://raw.githubusercontent.com/google-gemini/computer-use-preview/main/agent.py

self._generate_content_config = GenerateContentConfig(
    temperature=1,
    top_p=0.95,
    top_k=40,
    max_output_tokens=8192,
    tools=[
        types.Tool(
            computer_use=types.ComputerUse(
                environment=types.Environment.ENVIRONMENT_BROWSER,
                excluded_predefined_functions=excluded_predefined_functions,
            ),
        ),
        types.Tool(function_declarations=custom_functions),
    ],
    thinking_config=types.ThinkingConfig(include_thoughts=True),
)
# ... call site:
response = self._client.models.generate_content(
    model=self._model_name,
    config=self._generate_content_config,
)
# ... safety handling in this path uses a STRING, not a bool:
safety := function_call.args.get("safety_decision")
extra_fr_fields["safety_acknowledgement"] = "true"

=== G. Client construction supporting both Developer API and Vertex ===
self._client = genai.Client(
    api_key=os.environ.get("GEMINI_API_KEY"),
    vertexai=os.environ.get("USE_VERTEXAI", "0").lower() in ["true", "1"],
    project=os.environ.get("VERTEXAI_PROJECT"),
    location=os.environ.get("VERTEXAI_LOCATION"),
)

=== H. DESKTOP action set — implement exactly these in Swift ===
All coordinates are int 0-999 NORMALIZED, plus intent: str on every action.
  click / double_click / triple_click / middle_click / right_click  -> y:int, x:int, intent:str
  mouse_down / mouse_up / move                                      -> y:int, x:int, intent:str
  type                        -> text:str, press_enter:bool (optional, default false), intent:str
  drag_and_drop               -> start_y, start_x, end_y, end_x (all int 0-999), intent:str
  wait                        -> seconds:int (optional, default 1), intent:str
  press_key / key_down / key_up -> key:str, intent:str
  hotkey                      -> keys:List[str], intent:str
  take_screenshot             -> intent:str
  scroll                      -> y:int, x:int, direction:str ("up"|"down"|"left"|"right"),
                                 magnitude_in_pixels:int (0-999, optional, default 300), intent:str
Browser env adds go_back, navigate(url:str), go_forward. Desktop has none of those.

=== I. Safety policy category identifiers ===
FINANCIAL_TRANSACTIONS, SENSITIVE_DATA_MODIFICATION, COMMUNICATION_TOOL,
ACCOUNT_CREATION, DATA_MODIFICATION, USER_CONSENT_MANAGEMENT, LEGAL_TERMS_AND_AGREEMENTS

=== J. Reference repo quickstart (browser only) ===
git clone https://github.com/google-gemini/computer-use-preview.git
cd computer-use-preview
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
playwright install-deps chrome
playwright install chrome
export GEMINI_API_KEY="YOUR_GEMINI_API_KEY"
python main.py --query "Go to Google and type 'Hello World' into the search bar"
# flags: --query (required), --env {playwright|browserbase}, --initial_url,
#        --highlight_mouse, --model
# docs quickstart alternative: pip install google-genai playwright && playwright install chromium
