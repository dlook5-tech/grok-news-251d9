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

# ---- Check 2: World/USA must have 3 perspectives per story ----
for tab in ('world', 'usa'):
    for i, s in enumerate(d.get(tab, {}).get('stories', [])):
        valid = [p for p in s.get('perspectives', []) if isinstance(p, dict) and p.get('url')]
        if len(valid) < 3:
            errors.append(f"{tab}[{i}] '{s.get('headline','')[:50]}': {len(valid)}/3 perspectives")

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
    if len(broken) > 5:
        errors.append(f"{len(broken)}/{len(urls)} URLs failed oEmbed check (sample: {broken[:5]})")
    else:
        for url, status in broken:
            errors.append(f"oEmbed FAIL ({status}): {url}")

print(f"[claude-qc] URL verify: {verified}/{len(urls)} passed")

# ---- Report ----
if errors:
    print(f"\n[claude-qc] ABORT — {len(errors)} blocker(s):", file=sys.stderr)
    for e in errors:
        print(f"  ✗ {e}", file=sys.stderr)
    sys.exit(1)

print(f"[claude-qc] ALL CHECKS PASSED — safe to deploy")
sys.exit(0)
PYEOF
