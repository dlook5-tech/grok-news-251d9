#!/bin/bash
# claude_critic.sh — Round-trip QC pipeline using Claude (Sonnet 4.5) as the editor.
#
# Flow:
#   1. Read stories.json (Grok's picks) + CLAUDE.md (full curation rules)
#   2. Send all picks + rules to Claude in ONE batched call (cheaper than per-pick)
#   3. Claude returns per-pick verdict: keep | drop | replace + reasoning + replacement criteria
#   4. For replace verdicts: call Grok with Claude's specific replacement criteria
#   5. Claude re-grades replacements
#   6. Apply final decisions back to stories.json
#
# Replaces qc_critic.sh in the pipeline. Logs every decision to /tmp/expresso_claude_critic.log.

set -e
MAIN="$(cd "$(dirname "$0")" && pwd)"
cd "$MAIN"

if [ -f .env ]; then source .env; fi
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY required (.env on Mac, GitHub Secrets in CI)}"
: "${XAI_API_KEY:?XAI_API_KEY required (Grok replacement searches)}"

LOG=/tmp/expresso_claude_critic.log
echo "=== Claude critic pass — $(date) ===" > "$LOG"

# ============================================================
# STEP 1: Build the batched Claude prompt
# ============================================================
MAIN="$MAIN" python3 <<'PYEOF' > /tmp/claude_critic_prompt.json
import json, os, sys
MAIN = os.environ['MAIN']

# Load CLAUDE.md as the rules context (auto-loads project memory)
with open(os.path.join(MAIN, 'CLAUDE.md')) as f:
    rules = f.read()

# Load current stories
with open(os.path.join(MAIN, 'stories.json')) as f:
    stories = json.load(f)

# Build a compact picks digest
picks = []
SCORED_TABS = ['world','usa','business','top','msm','elon','allin','pods','sports','pg6','science','conspiracy','comedy','recipe','local']
for tab in SCORED_TABS:
    container = stories.get(tab, {})
    if not isinstance(container, dict): continue
    items = container.get('stories', [])
    for idx, s in enumerate(items):
        if not isinstance(s, dict): continue
        # Multi-perspective story (world/usa)
        if s.get('perspectives'):
            for pidx, p in enumerate(s.get('perspectives', [])):
                picks.append({
                    'tab': tab,
                    'idx': idx,
                    'perspective_idx': pidx,
                    'side': p.get('side', '?'),
                    'handle': p.get('handle', '?'),
                    'headline': s.get('headline', '')[:120],
                    'body': (p.get('body') or p.get('quote') or '')[:300],
                    'engagement': p.get('engagement', ''),
                    'honesty': p.get('honesty', ''),
                    'url': p.get('url', ''),
                })
        else:
            picks.append({
                'tab': tab,
                'idx': idx,
                'perspective_idx': None,
                'handle': s.get('handle', '?'),
                'headline': s.get('headline', '')[:120],
                'body': (s.get('body') or s.get('quote') or '')[:300],
                'engagement': s.get('engagement', ''),
                'honesty': s.get('honesty', ''),
                'url': s.get('url', ''),
            })

user_msg = f"""You are the QC editor for eXpressO News. You're reviewing Grok's curation picks before they ship to the live site.

Your job: read each pick against the curation rules below, score insight quality 0-10, and either KEEP, DROP, or REPLACE each one. For REPLACE verdicts, write a SPECIFIC complaint and replacement criteria that I'll send back to Grok to find a better post.

# CURATION RULES (the project CLAUDE.md — read this carefully, this IS the editorial standard)

{rules}

# PICKS TO REVIEW

{json.dumps(picks, indent=1)}

# YOUR TASK

For each pick, return a verdict object. Be ruthless about insight quality — the user is sick of bare announcements, MSM-quote bait, endorsement boilerplate, and one-sided political content in non-political tabs.

USER PRIME DIRECTIVE (2026-05-02 — REVISED) — WORLD AND USA: PREFER 3 PERSPECTIVES, BUT NEVER LEAVE TAB EMPTY:
Strong PREFERENCE for stories with all 3 perspectives (Conservative + Democrat + Independent) — that completeness IS the test of importance. BUT user also rules: tabs must never be empty. So:
- If a story has 3 perspectives → KEEP (preferred)
- If 2 perspectives → KEEP unless one is also low-quality (bare announcement, off-topic)
- If only 1 perspective → KEEP if it's a strong substantive take on a real story; DROP only if also weak content
- The earlier strict "drop if <3" was too aggressive and made World/USA empty. User wants tiered: prefer 3, accept 2, accept 1 if substantive — but NEVER zero.

Reconcile by judgment: the perspective count alone shouldn't drop a story; combine it with content quality. A 1-perspective story with sharp reporting beats an empty tab.

Specifically REJECT (drop or replace):
- Bare announcements ("AMERICANS ARE WORKING AGAIN!", "JUST IN: stat", "BREAKING: <fact>")
- Pure endorsements ("Congrats to X, fighting for Y", "REAL change")
- MSM amplification ("per TIME", "per WaPo" — quoted articles with no original take from the handle)
- One-sided political content on business/top/msm/local/etc (those should be in USA tab with 3 perspectives)
- Context-less replies (no parent visible, just "Might actually happen", "Per month??", "Exactly", "True")
- HARD RULE — DROP if body starts with "Responding to" or "Replying to" or headline starts with same. Twitter oEmbed will NOT show the parent tweet for pure replies — the reader sees just the reply text floating with no context. This is Q1 priority drop, no exceptions. (Chamath "Per month??" replying to @signulll about $10M wealth shipped today; this rule prevents recurrence.)
- Generic holiday wishes / press releases
- Off-topic perspectives in world/usa (perspective tweet about a different event than the headline)
- Off-Newport-Beach content in local (LA County wide ≠ local)
- DEAD posts: more than 6 hours old AND engagement is no longer rising (likes/comments stalled)

KEEP if (insight 6+):
- Has specific data + interpretation OR contrarian take OR "here's why this matters" framing
- Multi-sentence with reasoning markers ("because", "however", "actually", "watch", "the real story")
- Genuinely unique citizen voice that mainstream wouldn't surface
- Self-contained — reader gets the full point without clicking out
- STILL VIRAL: even if older than 6h, if comments/retweets/likes are STILL flowing, it's alive — keep it. Use the engagement field as your signal — high numbers + recent post date = clearly still hot.

ON AGE/FRESHNESS — USER EXPLICIT (May 2026):
"If a story continues to be the most viral, it should stay if it's still eliciting comments and retweets. So a tab should never be empty. Use AI-superintelligent logic to fill the right story, not just an if-then filter."

Translation for you: don't apply a hard 6h rule. Look at the engagement vitality. A 12h-old post with 50K likes and 5K replies is still ALIVE — keep it. A 3h-old post with 100 likes and 5 replies is DEAD — drop it. Default toward keeping a borderline pick rather than leaving the tab empty.

NEVER LEAVE A TAB EMPTY. If you're tempted to drop the only pick on a tab, score it generously (6+) unless it's actively offensive (libtard/conservative one-sider, MSM bait, crime blotter).

Return ONLY this JSON, no prose:

{{
  "decisions": [
    {{
      "tab": "...",
      "idx": <int>,
      "perspective_idx": <int or null>,
      "score": <0-10 int>,
      "verdict": "keep" | "drop" | "replace",
      "reasoning": "1 sentence why",
      "replacement_criteria": "<only if verdict=replace> Specific instructions to give Grok for finding a better post (e.g. 'Find a post from approved business handle with actual analysis on Trump's tariffs — not a TIME article quote. Looking for someone explaining the second-order effects with numbers.')"
    }},
    ... one per pick
  ]
}}"""

payload = {
    "model": "claude-sonnet-4-5-20250929",
    "max_tokens": 8000,
    "messages": [{"role": "user", "content": user_msg}]
}

with open('/tmp/claude_critic_prompt.json', 'w') as f:
    json.dump(payload, f)
print(f"  Built prompt: {len(picks)} picks, ~{len(user_msg)} chars", file=sys.stderr)
PYEOF

# ============================================================
# STEP 2: Call Claude
# ============================================================
echo "[claude] sending $(python3 -c "import json; d=json.load(open('/tmp/claude_critic_prompt.json')); print(len(d['messages'][0]['content']))") chars to Sonnet 4.5..." | tee -a "$LOG"

curl -s --max-time 240 https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d @/tmp/claude_critic_prompt.json > /tmp/claude_critic_response.json

# Quick sanity check
ERR=$(python3 -c "import json; d=json.load(open('/tmp/claude_critic_response.json')); print(d.get('error',{}).get('message','') if 'error' in d else '')" 2>/dev/null)
if [ -n "$ERR" ]; then
    echo "[claude] ERROR: $ERR" | tee -a "$LOG"
    exit 0  # don't break the pipeline; just skip the QC pass
fi

# ============================================================
# STEP 3: Parse Claude's verdicts and apply drops + queue replacements
# ============================================================
MAIN="$MAIN" python3 <<'PYEOF' >> "$LOG" 2>&1
import json, os, re, sys
MAIN = os.environ['MAIN']

with open('/tmp/claude_critic_response.json') as f:
    resp = json.load(f)

# Extract Claude's text response
text = ''
for block in resp.get('content', []):
    if block.get('type') == 'text':
        text += block.get('text', '')

# Find JSON in response (Claude sometimes wraps in markdown)
m = re.search(r'\{[\s\S]*\}', text)
if not m:
    print(f"  [claude] could not find JSON in response: {text[:300]}")
    sys.exit(0)

try:
    decisions = json.loads(m.group(0)).get('decisions', [])
except Exception as e:
    print(f"  [claude] JSON parse failed: {e}")
    print(f"  raw: {text[:500]}")
    sys.exit(0)

usage = resp.get('usage', {})
print(f"  [claude] verdicts: {len(decisions)}, tokens: in={usage.get('input_tokens','?')} out={usage.get('output_tokens','?')}")

# Tally
counts = {'keep': 0, 'drop': 0, 'replace': 0}
for d in decisions:
    counts[d.get('verdict','keep')] = counts.get(d.get('verdict','keep'),0) + 1
print(f"  [claude] keep={counts['keep']} drop={counts['drop']} replace={counts['replace']}")

# Save decisions for step 4 (Grok replacement search)
with open('/tmp/claude_critic_decisions.json', 'w') as f:
    json.dump(decisions, f, indent=2)

# Apply DROPS immediately (replace = pending Grok lookup)
with open(os.path.join(MAIN, 'stories.json')) as f:
    stories = json.load(f)

drops_by_tab = {}
for d in decisions:
    if d.get('verdict') != 'drop': continue
    tab = d.get('tab')
    drops_by_tab.setdefault(tab, []).append(d)

for tab, drops in drops_by_tab.items():
    container = stories.get(tab, {})
    if not isinstance(container, dict): continue
    # Drop perspectives first (idx + perspective_idx specified)
    persp_drops = sorted([d for d in drops if d.get('perspective_idx') is not None],
                         key=lambda x: (x['idx'], -x['perspective_idx']))  # delete from end
    for d in persp_drops:
        try:
            story = container['stories'][d['idx']]
            removed = story['perspectives'].pop(d['perspective_idx'])
            print(f"  [drop] {tab}[{d['idx']}].P{d['perspective_idx']} @{removed.get('handle','?')} — {d.get('reasoning','')[:100]}")
        except (IndexError, KeyError, TypeError):
            pass
    # Then drop whole stories (no perspective_idx)
    story_drops = sorted([d for d in drops if d.get('perspective_idx') is None],
                         key=lambda x: -x['idx'])
    for d in story_drops:
        try:
            removed = container['stories'].pop(d['idx'])
            print(f"  [drop] {tab}[{d['idx']}] @{removed.get('handle','?')} — {d.get('reasoning','')[:100]}")
        except (IndexError, KeyError):
            pass
    # If a 3-perspective story now has 0 perspectives, drop the story
    container['stories'] = [s for s in container.get('stories', [])
                            if not (isinstance(s.get('perspectives'), list) and len(s['perspectives']) == 0)]

# ---- POST-CRITIC FLOOR ENFORCEMENT ----
# Per-tab minimum after drops. If a drop took a tab below its floor, backfill from
# the tab's `earlier` list (history). Local has user-explicit floor of 2.
# CRITICAL: NEVER backfill a story that Claude just dropped — track drop URLs.
TAB_FLOORS = {'local': 2, 'world': 3, 'usa': 3}  # never empty — World/USA get 3 minimum from history if needed

# Collect URLs that Claude dropped, so floor backfill doesn't re-introduce them
just_dropped_urls = set()
for d in decisions:
    if d.get('verdict') != 'drop': continue
    # Walk the original stories to find the URL of the dropped item
    tab = d.get('tab')
    idx = d.get('idx')
    pidx = d.get('perspective_idx')
    # We need to look at the BEFORE-drops state, but we already mutated stories.
    # Workaround: also collect from picks list we built earlier
# Simpler: collect URLs from the picks digest sent to Claude
try:
    with open('/tmp/claude_critic_prompt.json') as f:
        prompt_data = json.load(f)
    msg_text = prompt_data['messages'][0]['content']
    # Extract URLs from picks JSON inside the prompt
    url_pattern = re.compile(r'"url":\s*"(https://[^"]+/status/\d+)"')
    all_pick_urls = set(url_pattern.findall(msg_text))
    # For each drop decision, find its url by matching tab+idx+perspective_idx in the picks list
    picks_json_match = re.search(r'\[\s*\{[^]]*?"tab"', msg_text)
    if picks_json_match:
        # Parse the full picks array from the prompt text (rough but works)
        bracket = msg_text.find('[', picks_json_match.start())
        depth = 0; end = bracket
        for i, c in enumerate(msg_text[bracket:], bracket):
            if c == '[': depth += 1
            elif c == ']':
                depth -= 1
                if depth == 0: end = i+1; break
        try:
            picks_arr = json.loads(msg_text[bracket:end])
            for d in decisions:
                if d.get('verdict') != 'drop': continue
                for p in picks_arr:
                    if p.get('tab') == d.get('tab') and p.get('idx') == d.get('idx') and p.get('perspective_idx') == d.get('perspective_idx'):
                        if p.get('url'): just_dropped_urls.add(p['url'])
                        break
        except Exception: pass
except Exception: pass

if just_dropped_urls:
    print(f"  [floor] tracking {len(just_dropped_urls)} URLs Claude just dropped — won't re-backfill them")

for tab_key, floor in TAB_FLOORS.items():
    container = stories.get(tab_key)
    if not isinstance(container, dict): continue
    current = container.get('stories', [])
    if len(current) >= floor: continue
    earlier_pool = container.get('earlier', [])
    # 2026-05-04 BUG FIX: World/USA stories have URLs at PERSPECTIVE level not story level.
    # Old code only checked s.get('url') so duplicates slipped in (User saw same
    # "US-Iran War Peace Proposal" twice). Now collect URLs from BOTH places + headlines.
    def _all_urls(s):
        urls = set()
        if s.get('url'): urls.add(s['url'])
        for p in s.get('perspectives', []) or []:
            if p.get('url'): urls.add(p['url'])
        return urls
    def _norm_headline(s):
        h = (s.get('headline','') or '').lower().strip()
        return ''.join(c for c in h if c.isalnum() or c == ' ').strip()
    seen_urls = set()
    seen_headlines = set()
    for s in current:
        seen_urls.update(_all_urls(s))
        seen_headlines.add(_norm_headline(s))
    seen_urls.update(just_dropped_urls)
    # AGE GATE for backfill — match the per-tab cap from parse_grok._max_age_for_tab
    # 2026-05-04: bug found where USA backfill brought back 84h-old @Patz_i story.
    NEWS_TABS_AGE = {'world','usa','top','msm','elon','allin','business','sports','pods','pg6','conspiracy'}
    REFERENCE_TABS_AGE = {'recipe','science','comedy','tiktok','local'}  # local 72h — sparse OC content
    if tab_key in NEWS_TABS_AGE: backfill_max_age = 24
    elif tab_key in REFERENCE_TABS_AGE: backfill_max_age = 72
    elif tab_key == 'freespeech': backfill_max_age = 1000000
    else: backfill_max_age = 24

    def _max_age_in_story(s):
        urls = _all_urls(s)
        if not urls: return 0
        ages = [url_age_hours(u) for u in urls if u]
        ages = [a for a in ages if a is not None]
        return max(ages) if ages else 0

    backfilled = 0
    for s in earlier_pool:
        if len(current) >= floor: break
        s_urls = _all_urls(s)
        if s_urls & seen_urls: continue
        if _norm_headline(s) in seen_headlines: continue
        # NEW: skip if any URL in story is older than tab cap
        story_age = _max_age_in_story(s)
        if story_age > backfill_max_age:
            continue
        s_copy = dict(s)
        s_copy['carried_over'] = True
        current.append(s_copy)
        seen_urls.update(s_urls)
        seen_headlines.add(_norm_headline(s))
        backfilled += 1
    container['stories'] = current
    if backfilled:
        print(f"  [floor] {tab_key}: backfilled {backfilled} from earlier history (had {len(current)-backfilled}/{floor}, now at floor)")
    elif len(current) < floor:
        print(f"  [floor] {tab_key}: still below floor ({len(current)}/{floor}) — earlier pool exhausted or all matched Claude drops")

with open(os.path.join(MAIN, 'stories.json'), 'w') as f:
    json.dump(stories, f, indent=2)

print(f"  [claude] applied {sum(len(v) for v in drops_by_tab.values())} drops to stories.json")
print(f"  [claude] {counts['replace']} replacements queued for Grok lookup (next step)")
PYEOF

# ============================================================
# STEP 4: For each REPLACE verdict, ask Grok to find a better post
# ============================================================
REPLACE_COUNT=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/claude_critic_decisions.json'))
    print(sum(1 for x in d if x.get('verdict')=='replace'))
except: print(0)
")

if [ "$REPLACE_COUNT" -gt 0 ]; then
    echo "[claude] Asking Grok to find replacements for $REPLACE_COUNT picks..." | tee -a "$LOG"

    # Build a single Grok prompt with all replacement requests
    MAIN="$MAIN" python3 <<'PYEOF' > /tmp/grok_replacement_prompt.txt
import json, os
MAIN = os.environ['MAIN']
with open('/tmp/claude_critic_decisions.json') as f:
    decisions = json.load(f)
replacements_needed = [d for d in decisions if d.get('verdict') == 'replace' and d.get('replacement_criteria')]
if not replacements_needed:
    print("# No replacements needed")
else:
    parts = ["You are searching X for replacement posts to fix QC failures from the first curation pass."]
    parts.append("For EACH item below, use x_search to find ONE replacement post that meets the criteria. Return JSON only.\n")
    parts.append("HARD AGE RULE: replacement post MUST be ≤6 hours old. Use `since_time:` operator or check the timestamp. We will reject any replacement older than 6 hours. If no fresh option exists, return null for that idx — do NOT submit an old post.\n")
    parts.append("HARD URL RULE: URL must be a real x.com/HANDLE/status/NUMERIC_ID returned by your x_search. Do NOT fabricate. We oEmbed-verify every URL — fakes get dropped.\n")
    for i, d in enumerate(replacements_needed):
        parts.append(f"REPLACEMENT {i}:")
        parts.append(f"  Tab: {d['tab']}")
        parts.append(f"  Original problem: {d.get('reasoning','')}")
        parts.append(f"  Find a post that: {d['replacement_criteria']}")
        parts.append("")
    parts.append("Return JSON: {\"replacements\":[{\"idx\":0,\"handle\":\"@x\",\"headline\":\"...\",\"body\":\"...\",\"url\":\"https://x.com/...status/...\",\"engagement\":\"X likes\",\"honesty\":\"X/10\",\"notes\":\"why this score\"} or {\"idx\":N, \"url\":null} if no fresh option,...]}")
    print('\n'.join(parts))
PYEOF

    # Only call Grok if we actually have something to find
    if [ -s /tmp/grok_replacement_prompt.txt ] && ! grep -q "^# No replacements needed" /tmp/grok_replacement_prompt.txt; then
        python3 /tmp/grok_build_payload.py /tmp/grok_replacement_prompt.txt /tmp/grok_replacement_payload.json grok-4.3
        # Bump max_tokens — 18 replacement objects need ~12K out tokens, default 8K truncates
        python3 -c "
import json
with open('/tmp/grok_replacement_payload.json') as f: p = json.load(f)
p['max_output_tokens'] = 16000
with open('/tmp/grok_replacement_payload.json', 'w') as f: json.dump(p, f)
"
        curl -s --max-time 240 https://api.x.ai/v1/responses \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $XAI_API_KEY" \
          -d @/tmp/grok_replacement_payload.json > /tmp/grok_replacement_response.json

        # Apply replacements (with oEmbed verification)
        MAIN="$MAIN" python3 <<'PYEOF' >> "$LOG" 2>&1
import json, os, re, sys, urllib.request, urllib.parse
MAIN = os.environ['MAIN']

# Load original decisions to map idx -> (tab, story_idx, perspective_idx)
with open('/tmp/claude_critic_decisions.json') as f:
    decisions = json.load(f)
replace_decisions = [d for d in decisions if d.get('verdict') == 'replace' and d.get('replacement_criteria')]

# Load Grok's replacement response
with open('/tmp/grok_replacement_response.json') as f:
    raw = json.load(f)
text = ''
for item in raw.get('output', []):
    if item.get('type') == 'message':
        for c in item.get('content', []):
            if c.get('type') == 'output_text':
                text = c['text']
m = re.search(r'\{[\s\S]*\}', text)
if not m:
    print(f"  [grok-replace] no JSON in response: {text[:200]}")
    sys.exit(0)
try:
    grok_replacements = json.loads(m.group(0)).get('replacements', [])
except Exception as e:
    print(f"  [grok-replace] parse failed: {e}")
    sys.exit(0)

# oEmbed verify + AGE CHECK each replacement URL before applying
import re as _re_age, datetime as _dt_age
def url_age_hours(url):
    if not url: return None
    m = _re_age.search(r'/status/(\d+)', url)
    if not m: return None
    try:
        sid = int(m.group(1))
        ts_ms = (sid >> 22) + 1288834974657
        post_time = _dt_age.datetime.fromtimestamp(ts_ms / 1000, _dt_age.timezone.utc)
        return (_dt_age.datetime.now(_dt_age.timezone.utc) - post_time).total_seconds() / 3600
    except Exception:
        return None

def _max_age_for_tab(tab):
    if tab == 'freespeech': return 8760  # 1 year
    return 168  # 1 week safety net — Claude judges vitality within this window

def verify_url(url, tab=None, timeout=8):
    if not url or '/status/' not in url: return False
    max_age = _max_age_for_tab(tab) if tab else 168
    age = url_age_hours(url)
    if age is not None and age > max_age:
        return False
    try:
        oe = 'https://publish.twitter.com/oembed?url=' + urllib.parse.quote(url, safe='')
        req = urllib.request.Request(oe, headers={'User-Agent': 'eXpressO/1.0'})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status == 200
    except Exception:
        return False

# Apply replacements
with open(os.path.join(MAIN, 'stories.json')) as f:
    stories = json.load(f)

applied = 0
for r in grok_replacements:
    rep_idx = r.get('idx')
    if rep_idx is None or rep_idx >= len(replace_decisions): continue
    target = replace_decisions[rep_idx]
    rep_url = r.get('url')
    rep_tab = target.get('tab')
    if not verify_url(rep_url, tab=rep_tab):
        rep_age = url_age_hours(rep_url) or -1
        max_a = _max_age_for_tab(rep_tab)
        reason = f"too old ({rep_age:.1f}h > {max_a}h cap)" if rep_age > max_a else "oEmbed failed"
        print(f"  [grok-replace] SKIP {rep_tab}[{target['idx']}] — {reason} — {rep_url}")
        continue
    container = stories.get(target['tab'], {})
    try:
        if target.get('perspective_idx') is not None:
            container['stories'][target['idx']]['perspectives'][target['perspective_idx']] = {
                'side': container['stories'][target['idx']]['perspectives'][target['perspective_idx']].get('side','?'),
                'handle': r.get('handle'),
                'body': r.get('body','')[:280],
                'quote': r.get('body','')[:280],
                'url': r.get('url'),
                'engagement': r.get('engagement',''),
                'honesty': r.get('honesty',''),
                'notes': r.get('notes',''),
            }
        else:
            container['stories'][target['idx']] = {
                'handle': r.get('handle'),
                'headline': r.get('headline','')[:140],
                'body': r.get('body','')[:280],
                'url': r.get('url'),
                'engagement': r.get('engagement',''),
                'honesty': r.get('honesty',''),
                'notes': r.get('notes',''),
            }
        applied += 1
        print(f"  [grok-replace] APPLY {target['tab']}[{target['idx']}] @{r.get('handle')} — {(r.get('headline') or r.get('body',''))[:70]}")
    except (IndexError, KeyError, TypeError) as e:
        print(f"  [grok-replace] APPLY-FAIL {target['tab']}[{target['idx']}]: {e}")

with open(os.path.join(MAIN, 'stories.json'), 'w') as f:
    json.dump(stories, f, indent=2)
print(f"  [claude] {applied} replacements applied to stories.json")
PYEOF
    fi
fi

echo "=== Claude critic done — $(date) ===" | tee -a "$LOG"
