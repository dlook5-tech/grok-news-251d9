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

# ---- Check 3: within-story URL uniqueness — drop dup perspective (not abort) ----
# Was: errors.append → deploy blocker. User 2026-05-13: cron failed for 8h
# because of this. Now: DROP the duplicate perspective in-place, warn only.
check3_modified = False
for tab in ('world', 'usa'):
    for s in d.get(tab, {}).get('stories', []):
        seen = {}
        kept_persps = []
        for p in s.get('perspectives', []) or []:
            u = p.get('url', '')
            if u and u in seen:
                warnings.append(f"{tab} '{s.get('headline','')[:50]}': "
                                f"{seen[u]} + {p.get('label','?')} share URL — dropped {p.get('label','?')}")
                check3_modified = True
                continue
            if u: seen[u] = p.get('label', '?')
            kept_persps.append(p)
        if len(kept_persps) != len(s.get('perspectives', []) or []):
            s['perspectives'] = kept_persps
if check3_modified:
    with open('stories.json','w') as f: json.dump(d, f, indent=2)

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
    # 2026-05-13: include perspective BODIES so Claude can check that each
    # perspective post actually matches the story's headline event (user
    # caught: World "Trump Deportation" story had @EndWokeness post about
    # DR-Haiti deportation — different event, just shared keyword).
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
            persps = s.get('perspectives', []) or []
            if persps:
                # World/USA: include each perspective's body so Claude can
                # detect off-topic posts (body doesn't match headline event).
                summary_lines.append(f"L{line_num} [{tab}] HEADLINE: {headline}")
                for p in persps[:3]:
                    if not isinstance(p, dict): continue
                    plbl = p.get('label','?')
                    ph = p.get('handle','?')
                    pb = (p.get('text') or p.get('quote') or p.get('body') or '')[:140]
                    summary_lines.append(f"     [{plbl}] @{ph}: \"{pb}\"")
            else:
                body = (s.get('body','') or '')[:140]
                url = (s.get('url','') or '')[-40:]
                summary_lines.append(f"L{line_num} [{tab}] {headline} | @{handle}: \"{body}\" | …{url}")
    if summary_lines:
        review_prompt = (
            "Final QC review of an X-curated news site. Lines:\n"
            "  L<N> [tab] HEADLINE: <text>      (for World/USA, then 3 persps follow)\n"
            "       [Conservative/Indep/Dem] @handle: \"<body>\"\n"
            "  L<N> [tab] headline | @handle: \"<body>\" | …<url>   (single-post tabs)\n\n"
            + "\n".join(summary_lines) +
            "\n\nReview every line. For each problem found, decide whether\n"
            "Python should DROP the pick or just WARN.\n\n"
            "Issue types:\n"
            "  - duplicate: same story/event on multiple tabs. Drop ONE.\n"
            "  - off-topic-tab: pick doesn't fit its tab (recipe on World,\n"
            "    sports on Business). DROP.\n"
            "  - off-topic-perspective: PERSPECTIVE POST'S BODY doesn't match\n"
            "    its story's HEADLINE EVENT. EXAMPLES:\n"
            "      • Story 'Trump Deportation Policies' headline + perspective\n"
            "        body about Dominican Republic deporting Haitians → DIFFERENT\n"
            "        event (shared keyword, not same event). DROP perspective.\n"
            "      • Story 'Iran Ceasefire' + perspective body about Russia\n"
            "        sanctions → DIFFERENT event. DROP perspective.\n"
            "    The perspective tweet must clearly reference the SAME event\n"
            "    the headline describes. Keyword overlap is NOT enough.\n"
            "    For this issue: action='drop_perspective', specify which\n"
            "    perspective label (Conservative/Independent/Democrat).\n"
            "  - mechanical: malformed URL, garbled headline, missing handle.\n"
            "    DROP.\n"
            "  - nonsense: headline doesn't match body, gibberish. DROP.\n"
            "  - borderline: suspicious but not clearly broken. WARN only.\n\n"
            "Return STRICTLY a JSON array. Each issue object:\n"
            "  {\"line\": <N>, \"action\": \"drop\"|\"drop_perspective\"|\"warn\",\n"
            "   \"type\": \"<one of above types>\",\n"
            "   \"perspective\": \"Conservative|Independent|Democrat\" (only for\n"
            "      drop_perspective),\n"
            "   \"reason\": \"<one short sentence>\"}\n"
            "Empty array [] if no issues. NO PROSE outside the JSON."
        )
        body = json.dumps({"model":"claude-sonnet-4-5","max_tokens":2500,
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
        # ACT on the issues. Order matters: handle drop_perspective first
        # (mutates story in place), then drops (pop, sorted DESC by line so
        # pops don't shift lower indices).
        persp_drops = [i for i in issues if isinstance(i, dict) and i.get('action') == 'drop_perspective']
        drops = sorted([i for i in issues if isinstance(i, dict) and i.get('action') == 'drop'],
                       key=lambda x: -(x.get('line') or 0))
        warns = [i for i in issues if isinstance(i, dict) and i.get('action') == 'warn']
        review_modified = False
        drops_per_tab = {}  # tab → count of drops, for refill
        # 1) perspective drops first (don't remove the story, just the bad persp)
        for issue in persp_drops:
            line = issue.get('line')
            if line not in line_map: continue
            tab, idx = line_map[line]
            target_label = (issue.get('perspective','') or '').lower()
            stories = d.get(tab, {}).get('stories', [])
            if not (0 <= idx < len(stories)): continue
            story = stories[idx]
            persps = story.get('perspectives', []) or []
            before = len(persps)
            persps = [p for p in persps
                      if not (isinstance(p, dict) and (p.get('label','') or '').lower() == target_label)]
            if len(persps) != before:
                story['perspectives'] = persps
                rmh = (story.get('headline','') or '?')[:50]
                rsn = (issue.get('reason','') or '')[:150]
                print(f"[final-review] DROP-PERSP {tab}[{idx}] {target_label} from '{rmh}' — {rsn}",
                      file=sys.stderr)
                warnings.append(f"final-review DROP-PERSP [{tab}/{target_label}] '{rmh}' — {rsn}")
                review_modified = True
        # 2) full-story drops
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

        # ---- Check 5b: REPLACE DROPPED PERSPECTIVES VIA LIVE GROK ----
        # User mandate 2026-05-13: "shouldn't you, if you drop a story, go
        # back to Grok and look for another perspective that does fit rather
        # than just dropping it?" Yes. For each off-topic perspective drop,
        # ask Grok for a replacement on the same side, on the same event.
        xai_key_p = os.environ.get("XAI_API_KEY","")
        if xai_key_p and persp_drops:
            for issue in persp_drops:
                line = issue.get('line')
                if line not in line_map: continue
                tab, idx = line_map[line]
                target_label = (issue.get('perspective','') or '').lower()
                stories = d.get(tab, {}).get('stories', [])
                if not (0 <= idx < len(stories)): continue
                story = stories[idx]
                # Skip if perspective got re-added already (e.g., via earlier issue)
                if any((p.get('label','') or '').lower() == target_label for p in story.get('perspectives', []) if isinstance(p, dict)):
                    continue
                headline = story.get('headline','')
                # Exclude already-used URLs for this story
                used_urls = []
                for p in story.get('perspectives', []) or []:
                    if isinstance(p, dict) and p.get('url'): used_urls.append(p['url'])
                side_keywords = {
                    'conservative': '(republican OR conservative OR maga OR right OR trump OR gop)',
                    'democrat':     '(democrat OR liberal OR progressive OR left OR aoc OR berniesanders)',
                    'independent':  '(analysis OR analyst OR independent OR centrist OR nonpartisan)',
                }.get(target_label, '')
                if not side_keywords: continue
                grok_p_prompt = (
                    f"Find ONE post that is a genuine {target_label.upper()}-LEANING reaction "
                    f"to this exact news event:\n"
                    f"  HEADLINE: {headline}\n\n"
                    f"x_search query:\n"
                    f"  \"{headline[:60]} {side_keywords} min_faves:1 lang:en\" "
                    f"mode:\"Top\" limit:30\n"
                    f"Sort by views, pick highest. Post body MUST clearly reference THIS "
                    f"event (not just share keywords). EXCLUDE these URLs: {used_urls}.\n\n"
                    f"Return STRICT JSON: {{\"url\":\"...\",\"handle\":\"@...\","
                    f"\"quote\":\"...\",\"views\":N,\"honesty\":\"X/10\",\"notes\":\"...\"}}\n"
                    f"Empty {{}} if no qualifying post found. NO PROSE outside JSON."
                )
                body_p = json.dumps({
                    "model": "grok-4.3",
                    "input": [{"role":"user","content":grok_p_prompt}],
                    "tools": [{"type":"x_search"}],
                    "max_output_tokens": 2000,
                    "temperature": 0.0,
                }).encode()
                req_p = urllib.request.Request("https://api.x.ai/v1/responses",
                    data=body_p, method="POST",
                    headers={"Authorization": f"Bearer {xai_key_p}", "Content-Type": "application/json"})
                try:
                    r_p = json.loads(urllib.request.urlopen(req_p, timeout=90).read())
                    msg_p = ''
                    for item in r_p.get('output', []):
                        if item.get('type') == 'message':
                            for c in item.get('content', []):
                                if c.get('type') == 'output_text':
                                    msg_p = c.get('text',''); break
                            if msg_p: break
                    import re as _rp
                    msg_p = _rp.sub(r'^```(?:json)?\s*|\s*```$', '', (msg_p or '').strip(), flags=_rp.MULTILINE).strip()
                    m_p = _rp.search(r'\{.*\}', msg_p, _rp.DOTALL)
                    new_persp = json.loads(m_p.group(0)) if m_p else {}
                except Exception as e:
                    print(f"[persp-refill] {tab}[{idx}] {target_label}: API error {e}", file=sys.stderr)
                    continue
                if not new_persp.get('url') or '/status/' not in new_persp.get('url',''):
                    print(f"[persp-refill] {tab}[{idx}] {target_label}: no replacement found", file=sys.stderr)
                    continue
                # Build the perspective object and insert
                label_proper = target_label.capitalize()
                story.setdefault('perspectives', []).append({
                    'label': label_proper,
                    'handle': new_persp.get('handle',''),
                    'url': new_persp['url'],
                    'text': (new_persp.get('quote') or new_persp.get('body') or '')[:200],
                    'views': new_persp.get('views', 0),
                    'honesty': str(new_persp.get('honesty','7/10')),
                    'engagement': str(new_persp.get('engagement','')),
                    'notes': str(new_persp.get('notes','')),
                })
                review_modified = True
                rh = new_persp.get('handle','?')
                warnings.append(f"persp-refill [{tab}/{target_label}] @{rh} replaced off-topic via live Grok")
                print(f"[persp-refill] {tab}[{idx}] {target_label}: ADDED @{rh}", file=sys.stderr)

        if review_modified:
            with open('stories.json','w') as f: json.dump(d, f, indent=2)
            print(f"[final-review] stories.json updated: dropped {len(drops)} pick(s)", file=sys.stderr)
        elif not issues:
            print(f"[final-review] Claude reviewed {len(summary_lines)} stories — no issues", file=sys.stderr)

# ---- Check 5c: PYTHON-SIDE QT SEARCH for every pick lacking QT enrichment ----
# User mandate 2026-05-13: "Prompts alone don't fix anything. You've got to
# enter it into the python." Grok was skipping QT search in its prompt path.
# Now we ENFORCE it in Python: for each pick without qt_views/original_url
# (meaning Grok didn't do QT enrichment), call xAI directly to search for QTs.
# Batched into one Grok call per ~15 picks to keep latency reasonable.
xai_key_qt = os.environ.get("XAI_API_KEY","")
if xai_key_qt:
    targets = []  # list of (tab, idx, persp_idx_or_None, url, headline)
    for tab in REVIEW_TABS:
        if tab == 'elon': continue  # rolling list, no QT swap
        stories = d.get(tab, {}).get('stories', []) or []
        for si, s in enumerate(stories):
            persps = s.get('perspectives', []) or []
            if persps:
                for pi, p in enumerate(persps):
                    if not isinstance(p, dict): continue
                    if p.get('qt_views') or p.get('original_url'): continue  # already enriched
                    url = p.get('url','')
                    if not url or '/status/' not in url: continue
                    targets.append((tab, si, pi, url, s.get('headline','')))
            else:
                if s.get('qt_views') or s.get('original_url'): continue
                url = s.get('url','')
                if not url or '/status/' not in url: continue
                targets.append((tab, si, None, url, s.get('headline','')))
    qt_modified = False
    BATCH_SIZE = 8  # 8 URLs per Grok call ≈ 5-10s; total batches manageable
    for batch_start in range(0, len(targets), BATCH_SIZE):
        batch = targets[batch_start:batch_start+BATCH_SIZE]
        url_list = "\n".join(f"{i+1}. URL: {t[3]}\n   EVENT: {t[4]}" for i, t in enumerate(batch))
        qt_prompt = (
            "For each of these X posts, find the top viral quote-tweet (QT)/"
            "retweet-with-comment that REFERENCES the original. Look for "
            "pile-on patterns: contrarian predictions get 'wrong N times' "
            "snark, politician claims get opposition QTs with receipts, "
            "celebrity statements get fact-checker QTs, etc.\n\n"
            "POSTS:\n" + url_list + "\n\n"
            "For each post, run:\n"
            "  x_search \"<post_url>\" mode:\"Top\" limit:20 lang:en\n"
            "  x_search \"<status_id_from_url>\" mode:\"Top\" limit:20 lang:en\n\n"
            "A QT qualifies if it:\n"
            "  - References the original (mentions URL, embeds it, screenshots it)\n"
            "  - Has substantive body (≥10 chars, not bare emoji)\n"
            "  - Has ≥1000 views (or ≥10K if body <30 chars)\n\n"
            "Return STRICT JSON array, same order as POSTS:\n"
            "[\n"
            "  {\"index\": 1, \"qt_url\": \"https://x.com/...\", "
            "\"qt_handle\": \"@x\", \"qt_body\": \"verbatim\", "
            "\"qt_views\": N, \"original_views\": N},\n"
            "  {\"index\": 2, \"qt_url\": null},   // no qualifying QT found\n"
            "  ...\n"
            "]\n"
            "NO PROSE outside JSON."
        )
        body_qt = json.dumps({
            "model": "grok-4.3",
            "input": [{"role":"user","content":qt_prompt}],
            "tools": [{"type":"x_search"}],
            "max_output_tokens": 3000,
            "temperature": 0.0,
        }).encode()
        req_qt = urllib.request.Request("https://api.x.ai/v1/responses",
            data=body_qt, method="POST",
            headers={"Authorization": f"Bearer {xai_key_qt}", "Content-Type": "application/json"})
        try:
            r_qt = json.loads(urllib.request.urlopen(req_qt, timeout=120).read())
            msg_qt = ''
            for item in r_qt.get('output', []):
                if item.get('type') == 'message':
                    for c in item.get('content', []):
                        if c.get('type') == 'output_text':
                            msg_qt = c.get('text',''); break
                    if msg_qt: break
            import re as _rqt
            msg_qt = _rqt.sub(r'^```(?:json)?\s*|\s*```$', '', (msg_qt or '').strip(), flags=_rqt.MULTILINE).strip()
            m_qt = _rqt.search(r'\[.*\]', msg_qt, _rqt.DOTALL)
            qts = json.loads(m_qt.group(0)) if m_qt else []
        except Exception as e:
            print(f"[qt-enrich] batch error {e}", file=sys.stderr)
            continue
        for qt_obj in qts:
            if not isinstance(qt_obj, dict): continue
            i = qt_obj.get('index', 0) - 1
            if not (0 <= i < len(batch)): continue
            if not qt_obj.get('qt_url') or '/status/' not in qt_obj.get('qt_url',''): continue
            tab, si, pi, orig_url, _ = batch[i]
            stories = d.get(tab, {}).get('stories', [])
            if not (0 <= si < len(stories)): continue
            target = stories[si]
            qt_views = int(qt_obj.get('qt_views', 0) or 0)
            orig_views = int(qt_obj.get('original_views', 0) or 0)
            new_views = orig_views + qt_views
            qt_url = qt_obj['qt_url']
            qt_handle = qt_obj.get('qt_handle','')
            qt_body = (qt_obj.get('qt_body','') or '')[:200]
            if pi is None:
                target['original_url'] = orig_url
                target['original_handle'] = target.get('handle','')
                target['original_views'] = orig_views
                target['url'] = qt_url
                target['handle'] = qt_handle
                target['body'] = qt_body
                target['views'] = new_views
                target['qt_views'] = qt_views
            else:
                persp = target.get('perspectives', [])[pi]
                persp['original_url'] = orig_url
                persp['original_handle'] = persp.get('handle','')
                persp['original_views'] = orig_views
                persp['url'] = qt_url
                persp['handle'] = qt_handle
                persp['text'] = qt_body
                persp['views'] = new_views
                persp['qt_views'] = qt_views
            qt_modified = True
            print(f"[qt-enrich] {tab}[{si}]"
                  f"{'/persp'+str(pi) if pi is not None else ''}: "
                  f"swapped to @{qt_handle} (orig {orig_views} + qt {qt_views} = {new_views})",
                  file=sys.stderr)
            warnings.append(f"qt-enrich {tab}: swapped to @{qt_handle} (+{qt_views} views)")
    if qt_modified:
        with open('stories.json','w') as f: json.dump(d, f, indent=2)

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

# ---- Check 6b: LIVE GROK REFILL when overflow exhausted (user 2026-05-11) ----
# "You're looking at five to eight, even if there's a duplicate or maybe five
# duplicates, then you go back out and you find another story."
# When overflow ran dry and tab is still < target, hit Grok API for a fresh
# refill. Excludes URLs + headlines already on the tab.
xai_key = os.environ.get("XAI_API_KEY","")
SCOPE_BLURB = {
    'world':     'international/foreign news event (NOT US domestic)',
    'usa':       'US national news event (domestic politics, SCOTUS, federal)',
    'business':  'business/finance/markets story',
    'top':       'most viral post on X overall',
    'msm':       'story mainstream media is underreporting',
    'conspiracy':'alternative-theory or unverified-claim story',
    'sports':    'sports headline (NBA/NFL/MLB/etc.)',
    'allin':     'billionaire/VC podcaster take',
    'pods':      'podcast clip moment',
    'pg6':       'celebrity gossip / pop culture',
    'comedy':    'humor clip',
    'recipe':    'viral recipe',
    'science':   'science/research finding',
    'local':     'Orange County / SoCal local story',
}
NEEDS_PERSPECTIVES = {'world', 'usa'}
grok_refill_modified = False
for tab, target in REFILL_TARGETS.items():
    stories = d.get(tab, {}).get('stories', []) or []
    if len(stories) >= target: continue
    if not xai_key:
        warnings.append(f"refill {tab}: SHORT {len(stories)}/{target} (XAI_API_KEY missing, can't refill)")
        continue
    short_by = target - len(stories)
    # Build exclusion list: existing URLs + headlines on this tab
    excl_urls, excl_headlines = [], []
    for s in stories:
        if s.get('url'): excl_urls.append(s['url'])
        for p in s.get('perspectives', []) or []:
            if isinstance(p, dict) and p.get('url'): excl_urls.append(p['url'])
        if s.get('headline'): excl_headlines.append(s.get('headline'))
    scope = SCOPE_BLURB.get(tab, tab)
    needs_persp = tab in NEEDS_PERSPECTIVES
    persp_clause = (" Each story must include 3 perspectives: conservative, "
                    "independent, democrat. Each perspective has url, handle, "
                    "quote, views.") if needs_persp else (
                    " Single post per story (url, handle, body, views, "
                    "engagement, honesty, notes).")
    grok_prompt = (
        f"Find {short_by} more {scope}(s) from the last 24 hours. "
        f"x_search mode:Top, lang:en, since:24h ago, limit:20. "
        f"Sort by views, highest first. "
        f"EXCLUDE these URLs (already used): {excl_urls[:10]}. "
        f"EXCLUDE these topics/headlines (already covered): {excl_headlines}. "
        f"Different event from each excluded headline.{persp_clause} "
        f"Reject: bare announcements (BREAKING:/JUST IN:/NEW: prefix with <60 char body), "
        f"video-with-few-words (<25 char body). "
        f"Return STRICT JSON: {{\"{tab}\": [...]}} with {short_by} entries. "
        f"NO PROSE outside the JSON."
    )
    body = json.dumps({
        "model": "grok-4.3",
        "input": [{"role":"user", "content": grok_prompt}],
        "tools": [{"type":"x_search"}],
        "max_output_tokens": 4000,
        "temperature": 0.0,
    }).encode()
    req = urllib.request.Request(
        "https://api.x.ai/v1/responses",
        data=body, method="POST",
        headers={"Authorization": f"Bearer {xai_key}", "Content-Type": "application/json"})
    try:
        r = json.loads(urllib.request.urlopen(req, timeout=120).read())
        # /v1/responses returns output array with content items
        msg = ''
        for item in r.get('output', []):
            if item.get('type') == 'message':
                for c in item.get('content', []):
                    if c.get('type') == 'output_text':
                        msg = c.get('text', '')
                        break
                if msg: break
        if not msg:
            msg = r.get('output_text', '') or '{}'
        msg = msg.strip()
        # Strip markdown fences if present
        import re as _rg
        msg = _rg.sub(r'^```(?:json)?\s*|\s*```$', '', msg, flags=_rg.MULTILINE).strip()
        # Extract first JSON object
        m = _rg.search(r'\{.*\}', msg, _rg.DOTALL)
        parsed = json.loads(m.group(0)) if m else {}
        new_stories = parsed.get(tab, []) or []
    except Exception as e:
        warnings.append(f"grok-refill {tab}: API error {str(e)[:80]} — accepting {len(stories)}/{target}")
        print(f"[grok-refill] {tab}: API error {e}", file=sys.stderr)
        continue
    added = 0
    for ns in new_stories[:short_by]:
        if not isinstance(ns, dict): continue
        # Basic validate: must have URL with /status/ (or perspectives w/ URLs)
        if needs_persp:
            persps = []
            for k, label in [('conservative','Conservative'),('democrat','Democrat'),('independent','Independent')]:
                p = ns.get(k) or {}
                if isinstance(p, dict) and p.get('url') and '/status/' in p.get('url',''):
                    persps.append({'label': label, 'handle': p.get('handle',''), 'url': p['url'],
                                   'text': (p.get('quote') or p.get('body') or p.get('text') or '')[:200],
                                   'views': p.get('views',0), 'honesty': str(p.get('honesty','8/10')),
                                   'engagement': str(p.get('engagement',''))})
            if len(persps) < 3: continue
            new_obj = {'headline': ns.get('headline','?'), 'perspectives': persps,
                       'honesty': str(ns.get('honesty','8/10')), 'notes': ns.get('notes',''),
                       'footnotes': [], 'body': '3-perspective coverage.'}
        else:
            if not ns.get('url') or '/status/' not in ns.get('url',''): continue
            new_obj = ns
        stories.append(new_obj)
        added += 1
    if added:
        d[tab]['stories'] = stories
        print(f"[grok-refill] {tab}: live Grok call added {added} more story/ies ({len(stories)}/{target})", file=sys.stderr)
        warnings.append(f"grok-refill {tab}: live Grok added {added} ({len(stories)}/{target})")
        grok_refill_modified = True
if grok_refill_modified:
    with open('stories.json','w') as f: json.dump(d, f, indent=2)

# ---- Check 6c: HONESTY SANITY CHECK (user 2026-05-12) ----
# User: "How did 2/10 come to be?... I want some common sense, some AI looking
# at these things, not just making up a score."
# Send Claude every honesty score + the post body. Claude flags scores that
# look wrong (e.g., "fabricated 2/10" when post has a video clip showing the
# person actually saying it). Python overrides flagged scores.
if key2:
    # Collect every (tab, story_index, persp_label or '', body, score, notes)
    scored = []
    for tab in REVIEW_TABS:
        stories = d.get(tab, {}).get('stories', []) or []
        for i, s in enumerate(stories):
            if 'perspectives' in s and s.get('perspectives'):
                for j, p in enumerate(s.get('perspectives', []) or []):
                    if isinstance(p, dict) and p.get('honesty'):
                        body = (p.get('text') or p.get('quote') or p.get('body') or '')[:200]
                        scored.append({'tab': tab, 'idx': i, 'persp': j,
                                       'label': p.get('label',''), 'handle': p.get('handle',''),
                                       'body': body, 'honesty': p.get('honesty',''),
                                       'notes': p.get('notes','')[:200]})
            elif s.get('honesty'):
                body = (s.get('body') or '')[:200]
                scored.append({'tab': tab, 'idx': i, 'persp': None,
                               'label': '', 'handle': s.get('handle',''),
                               'body': body, 'honesty': s.get('honesty',''),
                               'notes': s.get('notes','')[:200]})
    if scored:
        # Format for Claude
        lines = []
        for k, sc in enumerate(scored):
            label = f"/{sc['label']}" if sc['label'] else ''
            lines.append(f"S{k} [{sc['tab']}{label}] @{sc['handle']} score={sc['honesty']} "
                         f"notes='{sc['notes']}' body='{sc['body']}'")
        prompt = (
            "Honesty-score sanity check. Each line is a story/perspective with "
            "a score Grok assigned (0-10). Flag any that look wrong using THIS RUBRIC:\n\n"
            "  10 = VERIFIED FACT only (court record, scoreboard, official stat,\n"
            "       election result, raw video of exactly what's claimed)\n"
            "   9 = factual core with minor editorializing\n"
            "   8 = analysis/commentary/'expert take' — INCLUDES think tanks\n"
            "       (CSIS, Brookings, Heritage, AEI, RAND, Atlantic Council, etc.)\n"
            "       Institutional perspective = NEVER 10.\n"
            "   7 = opinion / prediction / hot take\n"
            "   6 = contains a specific misleading claim\n"
            "   5 = demonstrably false\n"
            "  ≤4 = serial misrepresentation / conspiracy without specifics\n\n"
            "ATTRIBUTION: video/audio clip of speaker → attribution VERIFIED;\n"
            "score content, NOT 'fabricated.'\n\n"
            "USER CAUGHT THESE WRONG SCORES — flag the pattern:\n"
            "- @CSIS think tank piece scored 10/10 → should be 8/10 max.\n"
            "- Trump video clip scored 2/10 'fabricated' → should be 7/10.\n\n"
            + "\n".join(lines) +
            "\n\nReturn JSON array of fixes:\n"
            "  {\"id\": <S_number>, \"new_score\": \"X/10\", \"new_notes\": \"why\"}\n"
            "Only entries that need fixing. Empty [] if all reasonable. "
            "NO PROSE outside JSON."
        )
        body_h = json.dumps({"model":"claude-sonnet-4-5","max_tokens":1500,
                             "messages":[{"role":"user","content":prompt}]}).encode()
        req_h = urllib.request.Request("https://api.anthropic.com/v1/messages",
            data=body_h, method="POST",
            headers={"x-api-key": key2, "anthropic-version":"2023-06-01",
                     "content-type":"application/json"})
        try:
            r_h = json.loads(urllib.request.urlopen(req_h, timeout=45).read())
            text_h = r_h.get("content",[{}])[0].get("text","[]").strip()
            import re as _rh
            m_h = _rh.search(r'\[.*\]', text_h, _rh.DOTALL)
            fixes = json.loads(m_h.group(0)) if m_h else []
        except Exception as e:
            print(f"[honesty-qc] API error {e}", file=sys.stderr)
            fixes = []
        honesty_modified = False
        # User mandate (2026-05-12): "let me know every time Claude overrides a
        # Grok score and why. Keep a running log of it."
        # Append each override to honesty_overrides.csv at repo root. Cron
        # auto-commits the file, daily_backup syncs it to Desktop.
        import csv as _csv_h, os as _os_h, datetime as _dt_h
        _override_log = 'honesty_overrides.csv'
        _need_header = not _os_h.path.exists(_override_log)
        _log_rows = []
        for fix in fixes:
            if not isinstance(fix, dict): continue
            sid = fix.get('id')
            if not isinstance(sid, int) or sid < 0 or sid >= len(scored): continue
            sc = scored[sid]
            new_score = fix.get('new_score', '')
            new_notes = fix.get('new_notes', '')
            if not new_score: continue
            stories = d.get(sc['tab'], {}).get('stories', [])
            if not (0 <= sc['idx'] < len(stories)): continue
            target = stories[sc['idx']]
            if sc['persp'] is not None:
                persps = target.get('perspectives', []) or []
                if 0 <= sc['persp'] < len(persps):
                    persps[sc['persp']]['honesty'] = new_score
                    if new_notes: persps[sc['persp']]['notes'] = new_notes
                    honesty_modified = True
                    print(f"[honesty-qc] {sc['tab']}/{sc['label']} @{sc['handle']}: "
                          f"{sc['honesty']} → {new_score} ({new_notes[:80]})", file=sys.stderr)
            else:
                target['honesty'] = new_score
                if new_notes: target['notes'] = new_notes
                honesty_modified = True
                print(f"[honesty-qc] {sc['tab']} @{sc['handle']}: "
                      f"{sc['honesty']} → {new_score} ({new_notes[:80]})", file=sys.stderr)
            warnings.append(f"honesty-qc {sc['tab']} @{sc['handle']}: {sc['honesty']}→{new_score}")
            _log_rows.append({
                'timestamp': _dt_h.datetime.now().astimezone().strftime('%Y-%m-%d %I:%M %p'),
                'tab': sc['tab'],
                'perspective': sc['label'] or '',
                'handle': sc['handle'],
                'grok_score': sc['honesty'],
                'grok_notes': sc['notes'],
                'claude_score': new_score,
                'claude_notes': new_notes,
                'body_preview': sc['body'][:200],
            })
        if _log_rows:
            with open(_override_log, 'a', newline='', encoding='utf-8') as _lf:
                _w = _csv_h.DictWriter(_lf, fieldnames=['timestamp','tab','perspective','handle','grok_score','claude_score','grok_notes','claude_notes','body_preview'])
                if _need_header: _w.writeheader()
                for _row in _log_rows: _w.writerow(_row)
            print(f"[honesty-qc] logged {len(_log_rows)} override(s) to {_override_log}", file=sys.stderr)
        if honesty_modified:
            with open('stories.json','w') as f: json.dump(d, f, indent=2)
            print(f"[honesty-qc] stories.json updated with score corrections", file=sys.stderr)

# ---- Check 7: same-headline dedup (last-resort safety net) ----
# User caught (2026-05-11): deployed World tab had "US-Iran Ceasefire Tensions"
# TWICE with different URL sets. Cluster dedup ran but didn't catch it because
# Claude returned them as one pair, dropping one — yet a second copy remained
# (hold rule + fresh both kept different URL-sets for same event).
# This last-pass dedup catches simple identical/near-identical headlines that
# slipped through the LLM cluster check. Per-tab. Drops later occurrence.
def _norm_headline(h):
    import re as _r7
    if not h: return ''
    # Lowercase + collapse whitespace + strip punctuation
    t = (h or '').lower()
    t = _r7.sub(r'[^\w\s]', ' ', t)
    t = _r7.sub(r'\s+', ' ', t).strip()
    return t

dedup_modified = False
for tab in list(d.keys()):
    if tab == 'elon': continue  # rolling list, dup-headlines unlikely
    tv = d.get(tab) or {}
    if not isinstance(tv, dict): continue
    stories = tv.get('stories', []) or []
    if len(stories) < 2: continue
    seen_headlines = {}
    kept = []
    for i, s in enumerate(stories):
        nh = _norm_headline(s.get('headline',''))
        if nh and nh in seen_headlines:
            print(f"[same-headline-dedup] {tab}[{i}] '{s.get('headline','')[:50]}' duplicates [{seen_headlines[nh]}], drop", file=sys.stderr)
            warnings.append(f"same-headline-dedup DROP {tab}[{i}] '{s.get('headline','')[:50]}'")
            dedup_modified = True
            continue
        if nh: seen_headlines[nh] = i
        kept.append(s)
    if len(kept) != len(stories):
        d[tab]['stories'] = kept
if dedup_modified:
    with open('stories.json','w') as f: json.dump(d, f, indent=2)
    print(f"[same-headline-dedup] stories.json updated", file=sys.stderr)

# ---- Check 8: Final-sweep ALL TABS — drop "?" / empty headlines ----
# User mandate (2026-05-19/22): "no ? marks." Applies to every tab.
sweep_modified = False
_SWEEP_TABS = ('world','usa','top','business','msm','sports','pods','allin',
               'pg6','recipe','science','local','conspiracy','comedy','elon')
for _tab in _SWEEP_TABS:
    _container = d.get(_tab)
    if not isinstance(_container, dict): continue
    _kept = []
    for _s in _container.get('stories', []):
        _h = (_s.get('headline') or '').strip()
        if not _h or _h in ('?', '...', 'Untitled', '?.', '? ', '. ?'):
            print(f"[final-sweep] {_tab}: drop story with empty/'?' headline", file=sys.stderr)
            warnings.append(f"final-sweep DROP {_tab} '?' headline")
            sweep_modified = True
            continue
        _kept.append(_s)
    _container['stories'] = _kept
if sweep_modified:
    with open('stories.json','w') as f: json.dump(d, f, indent=2)
    print("[final-sweep] stories.json updated", file=sys.stderr)

# NOTE (2026-05-22): the old "ristretto-pull" Check 9 was removed because
# parse_grok.py now natively runs the Ristretto-style World/USA pipeline
# (100K view floor, no cap, no hold). No more cross-site fetch needed.

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
