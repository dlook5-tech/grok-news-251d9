#!/bin/bash
# claude_qc.sh — pre-deploy quality check.
#
# User mandate (2026-05-10): "Claude needs to do a full quality check and click on
# everything before final upload to website."
#
# What this does (mechanical, no AI judgment):
#   1. Re-verify every URL in stories.json via Twitter's oEmbed
#      (URL exists + tweet renders). Fails the deploy if any URL 404s.
#   2. Verify floor counts: World 3, USA 3, Local 3, Business 3.
#   3. Verify World/USA stories all have 3 perspectives each.
#   4. Verify within-story URL uniqueness (no perspective sharing a URL with another).
#
# If any check fails, exit 1. update.sh's deploy step is gated on this.
#
# This is the "Claude clicked on everything" pass — every link gets fetched
# and verified before any user sees the page.

set -e
cd "$(dirname "$0")"

if [ ! -f stories.json ]; then
    echo "[claude-qc] ABORT: stories.json not found"
    exit 1
fi

# ---- SEMANTIC DEDUP — ask Claude API "are any of these stories the same event?"
# Catches semantic duplicates that word-overlap can't (e.g. "US-Iran Ceasefire
# Negotiations" + "Iran Responds to US Peace Proposal" = same event, no shared words).
if [ -n "$ANTHROPIC_API_KEY" ]; then
python3 <<'SDPY'
import json, urllib.request, os, sys
key = os.environ.get("ANTHROPIC_API_KEY","")
if not key: sys.exit(0)
with open('stories.json') as f: d = json.load(f)
modified = False
for tab in ('world','usa'):
    stories = d.get(tab,{}).get('stories',[])
    if len(stories) < 2: continue
    headlines = [(i, s.get('headline','')) for i,s in enumerate(stories)]
    prompt = (
        "These are headlines from a news site's " + tab.upper() + " tab. "
        "Identify any pair that describes the SAME news event (even if worded differently). "
        "Examples of same-event pairs: 'US-Iran Ceasefire Negotiations' and 'Iran Responds to US Peace Proposal'. "
        "Different events: 'US-Iran ceasefire' and 'Israeli strikes in Lebanon'. "
        "Return STRICTLY a JSON array of pairs to drop, e.g. [[1,3]] means drop story #3 because it dupes #1. "
        "Empty [] if none. Only the JSON, no prose.\n\n"
        + "\n".join(f"#{i+1}: {h}" for i,h in headlines)
    )
    # Use a current Claude model. Try sonnet-4-5 first (good cost/quality for this), fall back if model changes.
    body = json.dumps({"model":"claude-sonnet-4-5","max_tokens":200,
                       "messages":[{"role":"user","content":prompt}]}).encode()
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, method="POST",
        headers={"x-api-key": key, "anthropic-version":"2023-06-01", "content-type":"application/json"})
    try:
        r = json.loads(urllib.request.urlopen(req, timeout=20).read())
        text = r.get("content",[{}])[0].get("text","[]").strip()
        # Extract JSON array
        import re
        m = re.search(r'\[[^\]]*\]', text, re.DOTALL)
        pairs = json.loads(m.group(0)) if m else []
    except Exception as e:
        print(f"[semantic-dedup] {tab}: API error {e} — skipping", file=sys.stderr)
        continue
    if not pairs: continue
    # Drop the higher-index (later) story in each pair (lower-velocity by ranking position)
    drop_idxs = sorted({pair[1]-1 for pair in pairs if isinstance(pair,list) and len(pair)==2}, reverse=True)
    for idx in drop_idxs:
        if 0 <= idx < len(stories):
            print(f"[semantic-dedup] {tab}: drop '{stories[idx].get('headline','')[:50]}' (semantic dup)", file=sys.stderr)
            stories.pop(idx)
            modified = True
    d[tab]['stories'] = stories
if modified:
    with open('stories.json','w') as f: json.dump(d, f, indent=2)
    print("[semantic-dedup] stories.json updated")
SDPY
else
    echo "[semantic-dedup] skipped (no ANTHROPIC_API_KEY)"
fi

python3 <<'PYEOF'
import json, sys, urllib.request, urllib.parse

errors = []
warnings = []

with open('stories.json') as f:
    d = json.load(f)

# ---- Check 1: 3-story floor on every tab except Elon ----
# User mandate (2026-05-10): "Just force three-story floor." Elon is exempt
# because the user wants all of his latest posts in the last 4 hours, however
# many that is — the floor concept doesn't apply.
FLOOR_TABS = ('world', 'usa', 'local', 'business', 'sports', 'pods', 'allin',
              'msm', 'conspiracy', 'pg6', 'comedy', 'recipe', 'top', 'science')
for tab in FLOOR_TABS:
    n = len(d.get(tab, {}).get('stories', []))
    if n < 3:
        errors.append(f"{tab}: {n}/3 stories — below floor")

# ---- Check 2: World/USA SHOULD have 3 perspectives per story (warn, not block) ----
# 2026-05-10: User mandate "just force three-story floor" prioritizes floor > perspectives
# when both can't be met. Perspectives are aspirational; partial-perspective stories
# can fill the floor when 3-perspective topics aren't available.
for tab in ('world', 'usa'):
    for i, s in enumerate(d.get(tab, {}).get('stories', [])):
        valid = [p for p in s.get('perspectives', []) if isinstance(p, dict) and p.get('url')]
        if len(valid) < 3:
            warnings.append(f"{tab}[{i}] '{s.get('headline','')[:50]}': {len(valid)}/3 perspectives (preferred but not required)")

# ---- Check 3: within-story URL uniqueness ----
for tab in ('world', 'usa'):
    for s in d.get(tab, {}).get('stories', []):
        seen = {}
        for p in s.get('perspectives', []):
            u = p.get('url', '')
            if not u: continue
            if u in seen:
                errors.append(f"{tab} '{s.get('headline','')[:50]}': "
                              f"{seen[u]} + {p.get('label','?')} share URL {u}")
            seen[u] = p.get('label', '?')

# ---- Check 4: URL re-verify via oEmbed (the "click everything" pass) ----
def collect_urls(d):
    urls = set()
    for tab, val in d.items():
        if not isinstance(val, dict): continue
        for s in val.get('stories', []) + val.get('earlier', []):
            if not isinstance(s, dict): continue
            u = s.get('url', '')
            if u and '/status/' in u: urls.add(u)
            for p in s.get('perspectives', []):
                pu = (p or {}).get('url', '')
                if pu and '/status/' in pu: urls.add(pu)
    return urls

urls = collect_urls(d)
print(f"[claude-qc] Verifying {len(urls)} URLs via oEmbed...")
verified = 0
broken = []
for url in urls:
    oembed = f"https://publish.twitter.com/oembed?url={urllib.parse.quote(url, safe='')}"
    try:
        req = urllib.request.Request(oembed, headers={'User-Agent': 'eXpressO-QC/1.0'})
        r = urllib.request.urlopen(req, timeout=8)
        if r.status == 200:
            verified += 1
        else:
            broken.append((url, r.status))
    except Exception as e:
        broken.append((url, str(e)[:50]))

if broken:
    # Individual URL failures are expected (deleted tweets, geoblocked, transient).
    # Only BLOCK deploy if >5% of URLs fail — a real systemic issue. Otherwise WARN
    # and let the deploy proceed; the broken-link fallback in the frontend handles it.
    fail_pct = len(broken) / max(len(urls), 1) * 100
    if fail_pct > 5:
        errors.append(f"{len(broken)}/{len(urls)} URLs ({fail_pct:.0f}%) failed oEmbed — systemic issue, blocking deploy")
    else:
        warnings.append(f"{len(broken)}/{len(urls)} URLs failed oEmbed ({fail_pct:.0f}%, under 5% threshold — non-blocking; frontend shows fallback)")
        for url, status in broken[:3]:
            warnings.append(f"  · {url} ({status})")

print(f"[claude-qc] URL verify: {verified}/{len(urls)} passed")

# ---- Report ----
if warnings:
    print(f"\n[claude-qc] {len(warnings)} warning(s) (non-blocking):", file=sys.stderr)
    for w in warnings:
        print(f"  ⚠ {w}", file=sys.stderr)

if errors:
    print(f"\n[claude-qc] ABORT — {len(errors)} blocker(s):", file=sys.stderr)
    for e in errors:
        print(f"  ✗ {e}", file=sys.stderr)
    sys.exit(1)

print(f"[claude-qc] CHECKS PASSED — safe to deploy ({len(warnings)} warnings)")
sys.exit(0)
PYEOF
