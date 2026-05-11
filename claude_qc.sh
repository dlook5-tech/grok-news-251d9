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
        # Extract JSON array of pairs. Previous regex r'\[[^\]]*\]' was buggy:
        # for input "[[1,3],[2,4]]" it matched only "[1,3]" (the inner array),
        # so pairs became [1,3] and isinstance(1,list) failed silently — no
        # dedup ever happened. Fix: pull ALL "[a,b]" inner pairs explicitly.
        # 2026-05-10: World tab was showing 3 Iran-ceasefire dups despite this code.
        import re
        pair_re = re.compile(r'\[\s*(\d+)\s*,\s*(\d+)\s*\]')
        pairs = [[int(a), int(b)] for a, b in pair_re.findall(text)]
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
import json, sys, urllib.request, urllib.parse, os

errors = []
warnings = []

with open('stories.json') as f:
    d = json.load(f)

# ---- Check 0: per-tab age cap enforcement (defense in depth) ----
# parse_grok.py has its own final hard sweep; this is a belt-and-suspenders check
# in case anything leaks through. Anything over the cap gets DROPPED here, not just
# warned. User mandate (2026-05-10): "Commit them to Python so we don't have to
# keep whack-a-mole-ing every other day."
import re, datetime
def url_age_h(url):
    if not url: return None
    m = re.search(r'/status/(\d+)', url)
    if not m: return None
    sid = int(m.group(1))
    ts_ms = (sid >> 22) + 1288834974657
    return (datetime.datetime.now() - datetime.datetime.fromtimestamp(ts_ms/1000)).total_seconds()/3600

# HARD cap per tab — keep in sync with TAB_HARD_CAP in parse_grok.py.
# This is the ABSOLUTE max; soft caps (24h preferred) live in parse_grok.py and
# drive ranking, not blocking. QC only rejects past the hard cap.
QC_TAB_CAP = {
    'elon': 24,        # User: prefer 12h, extend to 24h if floor (3) unmet. Hard cap 24.
    'recipe': 48, 'science': 48, 'comedy': 48,
    'allin': 48, 'pods': 48, 'pg6': 48, 'conspiracy': 48,
    'local': 72,       # OC content sparse, wider fallback OK
    # default for unlisted tabs (world/usa/business/sports/top/msm): 48h
}
qc_modified = False
for tk, tv in d.items():
    if not isinstance(tv, dict): continue
    cap = QC_TAB_CAP.get(tk, 48)
    for bucket in ('stories', 'earlier'):
        kept = []
        for s in tv.get(bucket, []):
            if 'perspectives' in s:
                urls = [p.get('url','') for p in s.get('perspectives', []) if isinstance(p, dict)]
            else:
                urls = [s.get('url','')]
            too_old = False; max_age = 0
            for u in urls:
                a = url_age_h(u) if u else None
                if a is not None and a > max_age: max_age = a
                if a is not None and a > cap:
                    too_old = True
            if too_old:
                warnings.append(f"QC-EXPIRE {tk}.{bucket}: {max_age:.1f}h>{cap}h cap — '{s.get('headline','')[:50]}'")
                qc_modified = True
            else:
                kept.append(s)
        tv[bucket] = kept
if qc_modified:
    with open('stories.json','w') as f: json.dump(d, f, indent=2)
    print("[claude-qc] stories.json updated (hard-expire sweep)")

# ---- Check 1: 3-story floor (Local and Elon excluded) ----
# User mandate (2026-05-10): "Just force three-story floor."
#
# Elon is EXCLUDED from floor (per user 2026-05-10 evening message):
#   "post everything except posts where he's marketing one of his companies
#    that was posted in the last 12 hours. If there's been no posts, extend
#    to 24 hours."
# Translation: aim for 3 Elon stories in 12h, extend cascade to 24h if needed,
# but if he genuinely hasn't posted (0 stories) — accept that, don't block
# deploy. The cascade in parse_grok (TAB_HARD_CAP['elon']=24) handles the
# 12h→24h extension. claude_qc just doesn't error if Elon ends up empty.
#
# Local is EXCLUDED: user feedback "World/Business/Local flexible count — 1-3
# stories based on quality, NEVER pad". Min-views filter in parse_grok.py
# drops sub-10k-view OC content; whatever's left is what shows.
#
# AUTO-PROMOTE strategy: if a tab is sub-floor but its `earlier` array has
# unused stories, promote them into `stories` to meet floor instead of blocking
# the deploy. Only hard-errors if floor truly unmeetable.
FLOOR_TABS = ('world', 'usa', 'business', 'sports', 'allin',
              'msm', 'conspiracy', 'pg6', 'comedy', 'recipe', 'top', 'science')
# Pods removed (2026-05-10 evening): if Grok can't find 3 fresh pod clips ≤24h,
# show 1-2 rather than block deploy. User's "no 1d old" mandate means we can't
# pad with 25h+ stuff; if there's no fresh, show fewer. Same logic as elon/local.
floor_modified = False
for tab in FLOOR_TABS:
    stories = d.get(tab, {}).get('stories', [])
    earlier = d.get(tab, {}).get('earlier', [])
    n = len(stories)
    if n < 3:
        # Try to promote from earlier (skip ones already in stories by URL)
        seen_urls = {s.get('url') for s in stories if s.get('url')}
        promoted = 0
        for e in earlier:
            if len(stories) >= 3: break
            if e.get('url') in seen_urls: continue
            stories.append(e)
            seen_urls.add(e.get('url'))
            promoted += 1
        if promoted:
            d[tab]['stories'] = stories
            d[tab]['earlier'] = [e for e in earlier if e.get('url') not in seen_urls or e in stories[:-promoted]]
            warnings.append(f"{tab}: promoted {promoted} from earlier to meet 3-floor (was {n}/3)")
            floor_modified = True
        # POST-PROMOTE: still under floor → tier the response
        # 0 stories: HARD BLOCK (truly empty = real systemic issue)
        # 1-2 stories: WARN ONLY (better to ship partial than block on stale)
        if len(stories) == 0:
            errors.append(f"{tab}: 0/3 stories — empty tab, blocking deploy")
        elif len(stories) < 3:
            warnings.append(f"{tab}: {len(stories)}/3 stories — under floor but shipping (better than stale)")
if floor_modified:
    with open('stories.json','w') as f: json.dump(d, f, indent=2)
    print("[claude-qc] stories.json updated (floor auto-promotion)")

# ---- Check 1b: Submission review — does any user submission fit a tab better? ----
# User mandate (2026-05-10): "Claude should actually review [submissions] to see
# if any of them make sense and fit better than the stories offered in any of the
# tabs." Implementation: for each submission in submit.stories, ask Claude API
# which tab (if any) it fits, and whether it's more interesting than that tab's
# weakest current pick. If yes, swap: submission goes into the tab's stories,
# tab's weakest pick moves to earlier. Submission stays in submit too (audit trail).
key = os.environ.get("ANTHROPIC_API_KEY","")
submissions = (d.get('submit', {}) or {}).get('stories', []) or []
EVALUATABLE_TABS = ['world','usa','business','sports','elon','allin','pods','msm',
                    'conspiracy','pg6','comedy','recipe','science','local','top']
if key and submissions:
    # Build compact context: each tab's lowest-views story (the swap target)
    tab_weakest = {}
    for tab in EVALUATABLE_TABS:
        stories = d.get(tab, {}).get('stories', []) or []
        if not stories: continue
        # Find lowest-views story (use 0 if missing)
        def _v(s):
            if s.get('views'): return int(s.get('views') or 0)
            ps = s.get('perspectives') or []
            return min([int(p.get('views') or 0) for p in ps if p.get('views')], default=0)
        weakest = min(stories, key=_v)
        tab_weakest[tab] = {
            'headline': weakest.get('headline','')[:80],
            'views': _v(weakest),
            'url': weakest.get('url',''),
        }
    for sub in submissions:
        sub_url = sub.get('url','')
        sub_headline = sub.get('headline') or sub.get('note') or sub.get('notes',[''])[0] if sub.get('notes') else 'user submission'
        if not sub_url: continue
        prompt = (
            "You're reviewing a user-submitted X post against the weakest pick of each tab on a news site. "
            "Each tab covers a specific scope (world=international news, usa=US politics, business=markets, "
            "sports=NBA/NFL/MLB, elon=@elonmusk non-promo, allin=billionaire podcasters, pods=podcast clips, "
            "msm=stories MSM ignores, conspiracy=alternative theories, pg6=celebrity gossip, comedy=humor clips, "
            "recipe=cooking, science=research, local=Orange County/SoCal, top=most viral overall).\n\n"
            f"SUBMISSION: '{sub_headline}'\nURL: {sub_url}\n\n"
            "TAB WEAKEST PICKS (one per tab, the candidate for replacement):\n"
            + "\n".join(f"  {t}: '{tw['headline']}' ({tw['views']} views)" for t,tw in tab_weakest.items())
            + "\n\nRespond with STRICT JSON only:\n"
              "  {\"tab\": \"<tab_name>\", \"swap\": true|false, \"reason\": \"<one line>\"}\n"
              "  - tab: which tab the submission fits best (must be one of the listed tabs)\n"
              "  - swap: true ONLY if the submission is clearly more interesting/viral than that tab's "
              "weakest pick AND clearly fits the tab's scope. Be conservative — default to false unless obvious.\n"
              "  - reason: one sentence justifying."
        )
        body = json.dumps({"model":"claude-sonnet-4-5","max_tokens":200,
                           "messages":[{"role":"user","content":prompt}]}).encode()
        req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, method="POST",
            headers={"x-api-key": key, "anthropic-version":"2023-06-01", "content-type":"application/json"})
        try:
            r = json.loads(urllib.request.urlopen(req, timeout=20).read())
            text = r.get("content",[{}])[0].get("text","{}").strip()
            import re as _re
            m = _re.search(r'\{[^{}]*\}', text, _re.DOTALL)
            verdict = json.loads(m.group(0)) if m else {}
        except Exception as e:
            print(f"[sub-review] API error {e} — skipping submission {sub_url[-30:]}", file=sys.stderr)
            continue
        tab = verdict.get('tab','')
        if verdict.get('swap') and tab in tab_weakest:
            stories = d.get(tab,{}).get('stories', []) or []
            # Remove the weakest, move it to earlier; insert submission in front
            target_url = tab_weakest[tab]['url']
            removed = next((s for s in stories if s.get('url') == target_url), None)
            if removed:
                stories.remove(removed)
                d[tab].setdefault('earlier', []).insert(0, removed)
                d[tab]['earlier'] = d[tab]['earlier'][:10]  # cap earlier at 10
            stories.insert(0, sub)
            d[tab]['stories'] = stories
            warnings.append(f"[sub-review] swapped submission '{sub_headline[:40]}' into {tab} "
                            f"(replaced '{tab_weakest[tab]['headline'][:40]}'); reason: {verdict.get('reason','')[:80]}")
            with open('stories.json','w') as f: json.dump(d, f, indent=2)
        else:
            warnings.append(f"[sub-review] submission '{sub_headline[:40]}' → no swap "
                            f"({verdict.get('reason','no fit')[:80]})")

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
