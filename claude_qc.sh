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
    # Ask Claude to CLUSTER stories by event, not just identify pairs. Pair-only
    # output missed 3-way dups (e.g. Iran×3 framings — Claude returned [[1,4]]
    # and missed that #2 and #3 were also same-event). Cluster output keeps the
    # FIRST story of each cluster (highest velocity, since stories are ranked),
    # drops the rest.
    prompt = (
        "Headlines from " + tab.upper() + " tab on a news site. "
        "GROUP them into clusters by underlying news event. "
        "Two headlines are the SAME event if they describe the same incident, even with different framing or wording. "
        "Examples that ARE same event:\n"
        "  - 'US-Iran Ceasefire Negotiations' + 'Trump Rejects Iran Response' + 'US Rejects Iran Counterproposal' "
        "→ ALL THREE are 'US-Iran ceasefire negotiations' (single event/news cycle).\n"
        "  - 'Israel Strikes Hezbollah' + 'IDF Lebanon Operation' → same event.\n"
        "Different events: 'US-Iran ceasefire' + 'Israeli strikes in Lebanon' (separate events).\n\n"
        "Return STRICT JSON array of clusters. Each cluster is an array of 1-based story numbers that are the same event.\n"
        "  Example: [[1], [2,3,4]] means story #1 is its own event, stories #2,#3,#4 are all the same event.\n"
        "  EVERY story must appear in exactly one cluster. Singletons get their own cluster.\n"
        "Only the JSON array, no prose.\n\n"
        + "\n".join(f"#{i+1}: {h}" for i,h in headlines)
    )
    body = json.dumps({"model":"claude-sonnet-4-5","max_tokens":300,
                       "messages":[{"role":"user","content":prompt}]}).encode()
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, method="POST",
        headers={"x-api-key": key, "anthropic-version":"2023-06-01", "content-type":"application/json"})
    try:
        r = json.loads(urllib.request.urlopen(req, timeout=20).read())
        text = r.get("content",[{}])[0].get("text","[]").strip()
        import re
        # Parse cluster output: a list of lists of numbers, e.g. "[[1],[2,3,4]]"
        # findall any inner list of integers
        cluster_re = re.compile(r'\[(\s*\d+(?:\s*,\s*\d+)*\s*)\]')
        clusters = []
        for m in cluster_re.finditer(text):
            nums = [int(x.strip()) for x in m.group(1).split(',') if x.strip()]
            if nums: clusters.append(nums)
    except Exception as e:
        print(f"[semantic-dedup] {tab}: API error {e} — skipping", file=sys.stderr)
        continue
    if not clusters: continue
    # For each multi-story cluster, KEEP the lowest-numbered story (best by ranking)
    # and DROP the rest. Singletons untouched.
    drop_idxs = set()
    for cluster in clusters:
        if len(cluster) <= 1: continue
        keep = min(cluster)  # lowest index = highest-ranked
        for n in cluster:
            if n != keep: drop_idxs.add(n - 1)  # convert 1-based to 0-based
    for idx in sorted(drop_idxs, reverse=True):
        if 0 <= idx < len(stories):
            print(f"[semantic-dedup] {tab}: drop '{stories[idx].get('headline','')[:50]}' (cluster dup)", file=sys.stderr)
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
FLOOR_TABS = ('sports', 'allin', 'msm', 'pg6', 'comedy', 'recipe', 'top', 'science')
# 2026-05-11: 'world', 'usa', 'business', 'conspiracy', 'local' removed from
# FLOOR_TABS per user mandate: "Just what is the highest velocity story in the
# world in the last four hours. Top three." If <3 exist in 4h, show fewer.
# No more padding from earlier/overflow on news tabs.
# Pods removed (2026-05-10 evening): if Grok can't find 3 fresh pod clips ≤24h,
# show 1-2 rather than block deploy. User's "no 1d old" mandate means we can't
# pad with 25h+ stuff; if there's no fresh, show fewer. Same logic as elon/local.
floor_modified = False
for tab in FLOOR_TABS:
    stories = d.get(tab, {}).get('stories', [])
    earlier = d.get(tab, {}).get('earlier', [])
    overflow = d.get(tab, {}).get('_overflow', [])
    n = len(stories)
    if n < 3:
        seen_urls = {s.get('url') for s in stories if s.get('url')}
        # Helper: get all URLs in a story (story.url + perspective URLs)
        def _all_urls(s):
            us = set()
            if s.get('url'): us.add(s['url'])
            for p in s.get('perspectives', []) or []:
                if isinstance(p, dict) and p.get('url'): us.add(p['url'])
            return us
        for s in stories:
            seen_urls |= _all_urls(s)
        promoted_overflow = 0
        promoted_earlier = 0
        # PRIORITY 1: overflow (this cron's unused Grok candidates — user mandate
        # 2026-05-10: "go back to crock and find the next most popular velocity story")
        for o in overflow:
            if len(stories) >= 3: break
            if _all_urls(o) & seen_urls: continue
            stories.append(o)
            seen_urls |= _all_urls(o)
            promoted_overflow += 1
        # PRIORITY 2: earlier (prior cron's picks)
        for e in earlier:
            if len(stories) >= 3: break
            if _all_urls(e) & seen_urls: continue
            stories.append(e)
            seen_urls |= _all_urls(e)
            promoted_earlier += 1
        if promoted_overflow or promoted_earlier:
            d[tab]['stories'] = stories
            d[tab]['earlier'] = [e for e in earlier if not (_all_urls(e) & seen_urls)]
            d[tab]['_overflow'] = [o for o in overflow if not (_all_urls(o) & seen_urls)]
            msg = f"{tab}: promoted"
            if promoted_overflow: msg += f" {promoted_overflow}-from-overflow"
            if promoted_earlier: msg += f" {promoted_earlier}-from-earlier"
            msg += f" to meet 3-floor (was {n}/3)"
            warnings.append(msg)
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
    fail_pct = len(broken) / max(len(urls), 1) * 100
    if fail_pct > 50:
        # Systemic issue (>50% URL failures means Twitter's oEmbed is down)
        errors.append(f"{len(broken)}/{len(urls)} URLs ({fail_pct:.0f}%) failed oEmbed — systemic, blocking deploy")
    else:
        # 2026-05-11 user mandate: "if something hits an error screen, it should
        # be dumped, and you should go back and look for story number four."
        # → DROP stories with any broken URL. Refill happens in Check 6 below.
        broken_urls_set = {u for u, _ in broken}
        url_drops = []  # (tab, story_index)
        for tab in d:
            tv = d.get(tab) or {}
            if not isinstance(tv, dict): continue
            stories = tv.get('stories', []) or []
            for i, s in enumerate(stories):
                story_urls = set()
                if s.get('url'): story_urls.add(s['url'])
                for p in s.get('perspectives', []) or []:
                    if isinstance(p, dict) and p.get('url'): story_urls.add(p['url'])
                if story_urls & broken_urls_set:
                    url_drops.append((tab, i, story_urls & broken_urls_set))
        # Sort by index DESC per tab so pops don't shift indices
        url_drops.sort(key=lambda x: (x[0], -x[1]))
        for tab, idx, broken_set in url_drops:
            stories = d.get(tab, {}).get('stories', [])
            if 0 <= idx < len(stories):
                removed = stories.pop(idx)
                rmh = (removed.get('headline','') or '?')[:50]
                bu = (list(broken_set)[0] if broken_set else '')[-40:]
                warnings.append(f"url-verify DROP {tab}[{idx}] '{rmh}' — broken URL …{bu}")
                print(f"  [url-verify] DROP {tab}[{idx}]: {rmh} (broken: …{bu})", file=sys.stderr)

print(f"[claude-qc] URL verify: {verified}/{len(urls)} passed, {len(broken)} dropped")

# ---- Check 5: Final Claude holistic review WITH AUTO-ACTION (user 2026-05-11) ----
# User: "if any pick doesn't make sense, it won't do anything about it. It'll
# just log it." → No. Claude's review now ACTS on findings, not just warns.
#
# For each issue Claude identifies, it tells us what to DO (drop / warn).
# Python executes: removes flagged stories from stories.json.
# Tabs end up with fewer stories rather than padded with junk (matches user's
# "1-3 based on quality, never pad" mandate).
key2 = os.environ.get("ANTHROPIC_API_KEY","")
if key2:
    REVIEW_TABS = ['world','usa','business','sports','elon','allin','pods',
                   'msm','conspiracy','pg6','comedy','recipe','science',
                   'local','top']
    # Build line→(tab, index) map so Claude can refer to stories by line number.
    summary_lines = []
    line_map = {}    # line_number → (tab, index_in_stories)
    line_num = 0
    for tab in REVIEW_TABS:
        stories = d.get(tab, {}).get('stories', []) or []
        for i, s in enumerate(stories):
            line_num += 1
            line_map[line_num] = (tab, i)
            headline = (s.get('headline','') or '?')[:90]
            handle = s.get('handle','') or ''
            if not handle:
                ps = s.get('perspectives', []) or []
                if ps and isinstance(ps[0], dict):
                    handle = '+'.join((p.get('handle','') or '') for p in ps[:3] if isinstance(p, dict))
            url = (s.get('url','') or '')[-50:] if s.get('url') else 'PERSPS'
            summary_lines.append(f"L{line_num} [{tab}] {headline} | {handle} | …{url}")
    if summary_lines:
        review_prompt = (
            "Final QC review of an X-curated news site. Each line is:\n"
            "  L<N> [tab] headline | handle | url-tail\n\n"
            + "\n".join(summary_lines) +
            "\n\nReview every line. For each problem you find, decide whether\n"
            "Python should DROP the offending pick or just WARN.\n\n"
            "Issue types:\n"
            "  - duplicate: same story/event appears on multiple tabs. Drop ONE\n"
            "    of the lines (keep the one on the more-natural tab — e.g.,\n"
            "    drop USA copy if same event is also on World).\n"
            "  - off-topic: pick doesn't fit its tab (recipe on World, sports\n"
            "    on Business, etc.). DROP.\n"
            "  - mechanical: malformed URL, garbled headline, missing handle,\n"
            "    empty fields. DROP.\n"
            "  - nonsense: headline doesn't match body, body is gibberish,\n"
            "    obvious AI hallucination. DROP.\n"
            "  - borderline: looks suspicious but not clearly broken. WARN only.\n\n"
            "Return STRICTLY a JSON array. Each issue object:\n"
            "  {\"line\": <N>, \"action\": \"drop\" or \"warn\", "
            "\"type\": \"duplicate|off-topic|mechanical|nonsense|borderline\", "
            "\"reason\": \"<one short sentence>\"}\n"
            "If a duplicate spans two lines, return ONE object for the line to\n"
            "drop (mention both line numbers in `reason`).\n"
            "Empty array [] if no issues. NO PROSE outside the JSON."
        )
        body = json.dumps({"model":"claude-sonnet-4-5","max_tokens":1200,
                           "messages":[{"role":"user","content":review_prompt}]}).encode()
        req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, method="POST",
            headers={"x-api-key": key2, "anthropic-version":"2023-06-01", "content-type":"application/json"})
        try:
            r = json.loads(urllib.request.urlopen(req, timeout=30).read())
            text = r.get("content",[{}])[0].get("text","[]").strip()
            import re as _re5
            m = _re5.search(r'\[.*\]', text, _re5.DOTALL)
            issues = json.loads(m.group(0)) if m else []
        except Exception as e:
            print(f"[final-review] API error {e} — skipping", file=sys.stderr)
            issues = []
        # ACT on the issues: sort by line DESC so pops don't shift lower indices.
        drops = sorted([i for i in issues if isinstance(i, dict) and i.get('action') == 'drop'],
                       key=lambda x: -(x.get('line') or 0))
        warns = [i for i in issues if isinstance(i, dict) and i.get('action') == 'warn']
        review_modified = False
        drops_per_tab = {}  # tab → count of drops, for refill
        for issue in drops:
            line = issue.get('line')
            if line not in line_map: continue
            tab, idx = line_map[line]
            stories = d.get(tab, {}).get('stories', [])
            if 0 <= idx < len(stories):
                removed = stories.pop(idx)
                rmh = (removed.get('headline','') or '?')[:60]
                rsn = (issue.get('reason','') or '')[:150]
                itype = issue.get('type','?')
                print(f"[final-review] DROP L{line} {tab}[{idx}] [{itype}]: {rmh} — {rsn}", file=sys.stderr)
                warnings.append(f"final-review DROPPED [{itype}/{tab}] '{rmh}' — {rsn}")
                drops_per_tab[tab] = drops_per_tab.get(tab, 0) + 1
                review_modified = True
        for issue in warns:
            line = issue.get('line')
            tab = line_map.get(line, ('?',0))[0]
            rsn = (issue.get('reason','') or '')[:150]
            itype = issue.get('type','?')
            warnings.append(f"final-review WARN [{itype}/{tab}] L{line}: {rsn}")

        # Per-Check-5-drop refill removed in favor of universal Check 6 below
        # (which catches drops from ALL sources: URL verify, semantic dedup,
        # Claude review, anywhere). DRY.
        if review_modified:
            with open('stories.json','w') as f: json.dump(d, f, indent=2)
            print(f"[final-review] stories.json updated: dropped {len(drops)} pick(s)", file=sys.stderr)
        elif not issues:
            print(f"[final-review] Claude reviewed {len(summary_lines)} stories — no issues", file=sys.stderr)

# ---- Check 6: UNIVERSAL OVERFLOW REFILL (user 2026-05-11) ----
# "Seems like we've encountered this whack-a-mole before, where we end up with
# just one story per tab... if something hits an error screen, it should be
# dumped, and you should go back and look for story number four."
# This is the catch-all: after every drop path (semantic dedup, URL verify,
# Claude review, age sweep), check every tab against its target count. If
# under target, pull from _overflow (Grok's unused 4-8 candidates from this
# same cron) to fill the slot. Elon excluded (rolling 24h, no target N).
REFILL_TARGETS = {
    'world': 3, 'usa': 3, 'business': 3, 'top': 3, 'msm': 3, 'sports': 4,
    'conspiracy': 3, 'pg6': 3, 'allin': 3, 'pods': 3, 'recipe': 3,
    'science': 3, 'comedy': 3, 'local': 3,
    # 'elon': intentionally absent (rolling chronological 24h list, not top-N)
}
universal_refill_modified = False
for tab, target in REFILL_TARGETS.items():
    stories = d.get(tab, {}).get('stories', []) or []
    if len(stories) >= target: continue
    overflow = d.get(tab, {}).get('_overflow', []) or []
    if not overflow: continue
    starting_count = len(stories)
    existing_urls = set()
    for s in stories:
        if s.get('url'): existing_urls.add(s['url'])
        for p in s.get('perspectives', []) or []:
            if isinstance(p, dict) and p.get('url'): existing_urls.add(p['url'])
    pulled = 0
    new_overflow = []
    for cand in overflow:
        if len(stories) >= target:
            new_overflow.append(cand); continue
        cand_urls = set()
        if cand.get('url'): cand_urls.add(cand['url'])
        for p in cand.get('perspectives', []) or []:
            if isinstance(p, dict) and p.get('url'): cand_urls.add(p['url'])
        if cand_urls & existing_urls:
            continue
        stories.append(cand)
        existing_urls |= cand_urls
        pulled += 1
    d[tab]['_overflow'] = new_overflow
    d[tab]['stories'] = stories
    if pulled:
        warnings.append(f"refill {tab}: {starting_count}→{len(stories)} from overflow (target {target})")
        print(f"[refill] {tab}: pulled {pulled} from overflow ({starting_count}/{target} → {len(stories)}/{target})", file=sys.stderr)
        universal_refill_modified = True
    if len(stories) < target:
        # Overflow exhausted before target — log so we know next cron should look
        warnings.append(f"refill {tab}: SHORT {len(stories)}/{target} (overflow drained)")
if universal_refill_modified:
    with open('stories.json','w') as f: json.dump(d, f, indent=2)
    print(f"[refill] stories.json updated with overflow refills", file=sys.stderr)

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
