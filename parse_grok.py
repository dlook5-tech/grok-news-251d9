#!/usr/bin/env python3
"""
parse_grok.py — Ristretto's exact pipeline (verbatim from /Users/lookhome/ristretto-news/parse_grok.py),
with ONLY the user-authorized deltas:

  DELTA #1: World/USA — 100K view floor, no top_n cap
  DELTA #2: Sports   — guarantee SAS + Cowherd posts at the bottom
                       (pulled from extra `sas_cowherd` Grok call)
  DELTA #3: Elon     — keep ALL 24h posts; only filter company promo;
                       no top_n cap
  DELTA #4: World←USA — if World < 3 stories, promote international USA
                        stories (≥100K views) into World

Plus a body→text field rename so the existing eXpressO frontend can render
the perspective text without a frontend change.

EVERYTHING ELSE is Ristretto verbatim. No editorial filters, no honesty
scoring, no wire-copy rejection, no parent-context requirements, no
hardcoded handle lists, no clean_story validators, no claude_qc dependency.
"""
import sys, json, re, datetime
import curation


# eXpressO's stories.json is shaped as TOP-LEVEL tab keys (different from
# Ristretto which nests under `stories`). Load previous picks accordingly.
def load_previous_stories():
    try:
        with open('stories.json', 'r') as f:
            data = json.load(f)
            return {tab: t.get('stories', []) for tab, t in data.items()
                    if isinstance(t, dict) and 'stories' in t}
    except:
        return {}


def load_existing_full():
    """Load full existing stories.json so we can preserve manual tabs
    (freespeech, submit) the user maintains by hand."""
    try:
        with open('stories.json', 'r') as f:
            return json.load(f)
    except:
        return {}


# ---- DELTA #3: Elon company-promo keyword filter ----
_ELON_PROMO_KEYWORDS = {
    'preorder', 'pre-order', 'pre order',
    'available now', 'in stock', 'now shipping', 'ships in',
    'launching today', 'launches today',
    'on sale', 'limited time', 'limited edition',
    'subscribe to',
    'try x premium', 'try x pro',
    'order yours', 'buy now', 'get yours',
    'starting at $',
}

def _is_elon_promo(s):
    text = ((s.get('headline', '') or '') + ' ' + (s.get('body', '') or '')).lower()
    return any(kw in text for kw in _ELON_PROMO_KEYWORDS)


# ---- DELTA #1: World/USA 100K view floor ----
WU_VIEW_FLOOR = 100_000


# ---- DELTA #4: International keywords for World←USA promotion ----
INTL_KW = {
    'iran', 'china', 'russia', 'ukraine', 'israel', 'gaza', 'palestin',
    'nato', 'unsc', 'foreign', 'embassy', 'summit', 'diplomat', 'sanction',
    'war', 'military', 'treaty', 'geopolit', 'abroad', 'overseas',
    'putin', 'xi jinping', 'netanyahu', 'zelensky', 'tehran', 'beijing',
    'moscow', 'kremlin', 'europe', 'asia', 'africa', 'middle east',
    'nuclear', 'icbm', 'missile', 'tariff', 'foreign policy',
    'strait of hormuz', 'red sea',
}

def _has_intl_signal(s):
    t = ((s.get('headline', '') or '') + ' ' + (s.get('body', '') or '')).lower()
    for p in s.get('perspectives', []) or []:
        if isinstance(p, dict):
            t += ' ' + (p.get('text', '') or '').lower() + ' ' + (p.get('body', '') or '').lower()
    return any(k in t for k in INTL_KW)


# ---- DELTA #2: SAS / Cowherd handle checks ----
def _is_sas(s):
    h = (s.get('handle', '') or '').lower().lstrip('@')
    return h in ('stephenasmith', 'firsttake')

def _is_cow(s):
    h = (s.get('handle', '') or '').lower().lstrip('@')
    return h in ('colincowherd', 'theherd')


# ============================================================
# PYTHON ENFORCEMENT for prompt-only features (user mandate 2026-05-22:
# "yes python" — make the parent-embed and QT/RT-boost enforced, not relying
# on Grok to volunteer them). Each helper makes a targeted xAI call only when
# the data is missing.
# ============================================================
import os as _os
import urllib.request as _urlreq

def _xai_call(prompt, timeout=45, max_tokens=800):
    """One-shot xAI call. Returns parsed JSON object from Grok's text, or None."""
    api_key = _os.environ.get('XAI_API_KEY', '')
    if not api_key:
        return None
    payload = {
        "model": "grok-4.3",
        "input": [{"role": "user", "content": prompt}],
        "tools": [{"type": "x_search"}],
        "max_output_tokens": max_tokens,
    }
    try:
        req = _urlreq.Request(
            'https://api.x.ai/v1/responses',
            data=json.dumps(payload).encode(),
            headers={'Content-Type': 'application/json',
                     'Authorization': f'Bearer {api_key}'},
        )
        with _urlreq.urlopen(req, timeout=timeout) as r:
            resp = json.load(r)
        text = ''
        for o in resp.get('output', []):
            for c in o.get('content', []) or []:
                if isinstance(c, dict) and c.get('text'):
                    text += c['text']
        text = re.sub(r'^```[a-zA-Z]*\s*', '', text.strip())
        text = re.sub(r'\s*```\s*$', '', text)
        m = re.search(r'\{[^{}]*\}', text, re.DOTALL)
        if not m: return None
        return json.loads(m.group(0))
    except Exception as e:
        print(f"[xai-call] failed: {e}", file=sys.stderr)
        return None


def fetch_parent(url):
    """For a post URL, find the tweet it's replying to or quote-tweeting.
    Returns {parent_url, parent_handle, parent_text} or None if original/not-found."""
    if not url or '/status/' not in url:
        return None
    prompt = (
        f"For the X post at {url}, find the tweet it is replying to OR quote-tweeting. "
        f"Return ONLY a JSON object: "
        f'{{"parent_url":"https://x.com/<handle>/status/<id>","parent_handle":"@<handle>","parent_text":"verbatim text of the parent tweet (≤280 chars)"}}. '
        f"If the post is original (not a reply, not a QT), return an empty object {{}}."
    )
    result = _xai_call(prompt, timeout=30, max_tokens=400)
    if not result or not result.get('parent_url'):
        return None
    if '/status/' not in (result.get('parent_url') or ''):
        return None
    return {
        'parent_url': result['parent_url'],
        'parent_handle': result.get('parent_handle', ''),
        'parent_text': (result.get('parent_text') or '')[:280],
    }


def fetch_top_qt(url):
    """Find the highest-view QT/RT of a given post URL.
    Returns {qt_url, qt_handle, qt_views} or None if no notable QT exists."""
    if not url or '/status/' not in url:
        return None
    prompt = (
        f"Find the highest-view quote-tweet or retweet (with commentary) of the X post {url}. "
        f"Use x_search to find QTs/RTs that reference this URL. "
        f"Return ONLY a JSON object: "
        f'{{"qt_url":"https://x.com/<handle>/status/<id>","qt_handle":"@<handle>","qt_views":<integer>}}. '
        f"If no notable QT exists with at least 5,000 views, return an empty object {{}}."
    )
    result = _xai_call(prompt, timeout=45, max_tokens=400)
    if not result or not result.get('qt_url'):
        return None
    try:
        qt_views = int(result.get('qt_views') or 0)
    except (TypeError, ValueError):
        return None
    if qt_views < 5000:
        return None
    return {
        'qt_url': result['qt_url'],
        'qt_handle': result.get('qt_handle', ''),
        'qt_views': qt_views,
    }


# ---- body→text rename for eXpressO frontend compat ----
def _body_to_text(s):
    out = dict(s)
    persps = []
    for p in s.get('perspectives', []) or []:
        if not isinstance(p, dict):
            continue
        pp = dict(p)
        if 'body' in pp and 'text' not in pp:
            pp['text'] = pp['body']
        persps.append(pp)
    if persps:
        out['perspectives'] = persps
    return out


# ============================================================
# Ristretto's exact main loop (verbatim from ristretto/parse_grok.py)
# with the 4 deltas inserted at the appropriate tabs.
# ============================================================
raw = sys.stdin.read().strip()

if raw.startswith('```'):
    raw = re.sub(r'^```json?\s*|\s*```$', '', raw, flags=re.MULTILINE)

try:
    start = raw.find('{')
    data = json.loads(raw[start:] if start != -1 else raw)
except Exception as e:
    print(f"JSON parse failed: {e}", file=sys.stderr)
    sys.exit(1)

output = {}
previous = load_previous_stories()
existing_full = load_existing_full()

tabs = ['world', 'usa', 'business', 'top', 'msm', 'sports', 'elon', 'pods',
        'pg6', 'recipe', 'science', 'local', 'conspiracy', 'comedy', 'allin']


def _candidate_dump(cleaned, n=8):
    """Top N candidates with QT-boost audit: original_views + qt_views = combined.
    Lets the user verify the algorithm: see the raw Grok view count, the biggest
    QT/RT views found, and what the combined total is that competes for the 100K
    floor. For tabs without perspectives, original = combined and qt_views = 0."""
    sorted_c = sorted(cleaned, key=curation.story_views, reverse=True)[:n]
    out = []
    for c in sorted_c:
        persps = c.get('perspectives', []) or []
        if persps:
            # Find the highest-view perspective (which is what's compared to the 100K floor)
            top_p = max((p for p in persps if isinstance(p, dict)),
                        key=lambda p: int(p.get('views', 0) or 0), default={})
            original = int(top_p.get('original_views') or top_p.get('views', 0) or 0)
            qt_views = int(top_p.get('qt_views', 0) or 0)
            combined = int(top_p.get('views', 0) or 0)
        else:
            original = curation.story_views(c)
            qt_views = 0
            combined = original
        out.append({
            'handle': (c.get('handle') or '').lstrip('@'),
            'url': c.get('url'),
            'headline': (c.get('headline') or c.get('body','') or '')[:100],
            'original_views': original,
            'qt_views': qt_views,
            'combined_views': combined,
            'views': combined,
        })
    return out


for tab in tabs:
    items = data.get(tab, [])
    if not isinstance(items, list):
        items = [items] if items else []

    cleaned = []
    for item in items:
        if isinstance(item, dict):
            if item.get('handle') and item.get('url'):
                cleaned.append(item)

    # Always save the candidate dump for diagnostic visibility.
    tab_candidates = _candidate_dump(cleaned)

    # --- DELTA #3: ELON ---
    if tab == 'elon':
        elon_kept = [c for c in cleaned if not _is_elon_promo(c)]
        output[tab] = {'stories': [_body_to_text(s) for s in elon_kept],
                       '_candidates': tab_candidates}
        print(f"[elon] {len(elon_kept)} posts (no top_n cap, promo filtered)", file=sys.stderr)
        continue

    # --- DELTA #1: WORLD/USA — 100K floor + QT/RT view boost ---
    if tab in ('world', 'usa'):
        # QT/RT BOOST (Python enforcement): for any item where the top
        # perspective view is below 100K, fire a targeted xAI call to find
        # the highest-view QT/RT of that perspective. If found, add qt_views
        # to the perspective.views and store original_views + qt_views fields
        # so the math is auditable. This can push a borderline story over the
        # 100K floor that would otherwise be dropped.
        for c in cleaned:
            if not isinstance(c, dict): continue
            if curation.story_views(c) >= WU_VIEW_FLOOR:
                continue  # already over floor — no boost needed
            for p in c.get('perspectives', []) or []:
                if not isinstance(p, dict): continue
                try: cur_views = int(p.get('views', 0) or 0)
                except: cur_views = 0
                # Skip if perspective already has qt boost recorded
                if p.get('qt_views'): continue
                # Skip if no useful URL
                if not p.get('url') or '/status/' not in p['url']: continue
                qt = fetch_top_qt(p['url'])
                if qt:
                    p['original_views'] = cur_views
                    p['original_url'] = p['url']
                    p['original_handle'] = p.get('handle', '')
                    p['qt_views'] = qt['qt_views']
                    p['qt_url'] = qt['qt_url']
                    p['qt_handle'] = qt['qt_handle']
                    p['views'] = cur_views + qt['qt_views']  # COMBINED
                    print(f"[qt-boost {tab}] @{p.get('handle')} {cur_views:,} + QT {qt['qt_views']:,} = {p['views']:,}", file=sys.stderr)

        # Re-dump candidates AFTER QT boost so the audit numbers reflect the
        # post-boost state (original_views, qt_views, combined_views).
        tab_candidates_after_boost = _candidate_dump(cleaned)

        cleaned_100k = [c for c in cleaned if curation.story_views(c) >= WU_VIEW_FLOOR]
        held = previous.get(tab, [])
        held_100k = [h for h in held if curation.story_views(h) >= WU_VIEW_FLOOR]
        # Ristretto's apply_hold but with no top_n cap (use very large top_n)
        chosen = curation.apply_hold(held_100k, cleaned_100k, top_n=999,
                                     sort_key=curation.story_velocity)
        chosen = [s for s in chosen if curation.story_views(s) >= WU_VIEW_FLOOR]
        output[tab] = {'stories': [_body_to_text(s) for s in chosen],
                       '_candidates': tab_candidates_after_boost}
        print(f"[{tab}] {len(chosen)} events cleared {WU_VIEW_FLOOR:,} view floor (after QT boost)", file=sys.stderr)
        continue

    # --- DELTA #2: SPORTS — Ristretto picks + SAS/Cowherd guarantee at end ---
    if tab == 'sports':
        chosen = curation.curate(tab, previous.get(tab, []), cleaned, top_n=3)
        has_sas = any(_is_sas(s) for s in chosen)
        has_cow = any(_is_cow(s) for s in chosen)
        # Pool to look in: extra sas_cowherd Grok call + candidates + previous
        sas_pool = data.get('sas_cowherd', []) or []
        if not isinstance(sas_pool, list):
            sas_pool = [sas_pool] if sas_pool else []
        pool = list(sas_pool) + list(cleaned) + list(previous.get('sports', []))
        if not has_sas:
            sas_post = next((s for s in pool
                             if isinstance(s, dict) and _is_sas(s) and s.get('url')), None)
            if sas_post:
                chosen.append(sas_post)
                print("[sports] appended SAS at bottom", file=sys.stderr)
        if not has_cow:
            cow_post = next((s for s in pool
                             if isinstance(s, dict) and _is_cow(s) and s.get('url')), None)
            if cow_post:
                chosen.append(cow_post)
                print("[sports] appended Cowherd at bottom", file=sys.stderr)

        # PARENT CONTEXT (Python enforcement): for SAS/Cowherd posts that look
        # like replies/QTs but don't have parent_url populated, fire xAI lookup
        # to fetch the parent tweet so the frontend can embed it.
        for s in chosen:
            if not isinstance(s, dict): continue
            if not _is_sas(s) and not _is_cow(s): continue  # only enforce on SAS/Cowherd
            if s.get('parent_url'): continue  # already populated
            body = (s.get('body') or '').strip()
            # Heuristic for "looks like a reply/QT": starts with @, or short comment-like
            looks_like_reply = body.startswith('@') or (body and len(body) < 60 and body[0] in '"“"')
            if not looks_like_reply:
                # Even if heuristic says no, fetch anyway since SAS/Cowherd often QT
                pass
            parent = fetch_parent(s.get('url', ''))
            if parent:
                s['parent_url'] = parent['parent_url']
                s['parent_handle'] = parent['parent_handle']
                s['parent_text'] = parent['parent_text']
                print(f"[parent-fetch] @{s.get('handle')}: found parent @{parent['parent_handle']}", file=sys.stderr)

        output[tab] = {'stories': [_body_to_text(s) for s in chosen],
                       '_candidates': tab_candidates}
        continue

    # --- All other tabs: Ristretto verbatim ---
    chosen = curation.curate(tab, previous.get(tab, []), cleaned, top_n=3)
    output[tab] = {'stories': [_body_to_text(s) for s in chosen],
                   '_candidates': tab_candidates}


# ---- DELTA #4: World←USA cross-promotion ----
world_stories = output.get('world', {}).get('stories', []) or []
usa_stories = output.get('usa', {}).get('stories', []) or []
world_urls = {s.get('url', '') for s in world_stories if s.get('url')}
promoted = []
for s in usa_stories:
    if len(world_stories) + len(promoted) >= 3:
        break
    if s.get('url', '') in world_urls:
        continue
    if curation.story_views(s) < WU_VIEW_FLOOR:
        continue
    if not _has_intl_signal(s):
        continue
    promoted.append(s)
    print(f"[world<-usa] promoted: {(s.get('headline','') or '?')[:60]}", file=sys.stderr)

if promoted:
    output['world']['stories'] = world_stories + promoted


# ---- CROSS-TAB DEDUP (World vs USA) ----
# User mandate 2026-05-22: "dont we have a QC check to stop duplicate stories"
# A story (by URL) shipping in BOTH World AND USA is a bug. Decide per story:
#   - International signal → keep in World, drop from USA
#   - No international signal → keep in USA, drop from World
_w = output.get('world', {}).get('stories', []) or []
_u = output.get('usa', {}).get('stories', []) or []

def _all_urls(s):
    urls = set()
    if s.get('url'): urls.add(s['url'])
    for p in s.get('perspectives', []) or []:
        if isinstance(p, dict) and p.get('url'):
            urls.add(p['url'])
    return urls

_w_url_to_story = {}
for s in _w:
    for u in _all_urls(s):
        _w_url_to_story[u] = s

_drop_from_world = set()
_drop_from_usa = set()
for s in _u:
    for u in _all_urls(s):
        if u in _w_url_to_story:
            world_s = _w_url_to_story[u]
            # Decide: keep international in World, US-only in USA
            if _has_intl_signal(s):
                _drop_from_usa.add(s.get('url',''))
                print(f"[xtab-dedup] keep in WORLD, drop from USA: '{(s.get('headline','') or '?')[:60]}'", file=sys.stderr)
            else:
                _drop_from_world.add(world_s.get('url',''))
                print(f"[xtab-dedup] keep in USA, drop from WORLD: '{(world_s.get('headline','') or '?')[:60]}'", file=sys.stderr)
            break

if _drop_from_world:
    output['world']['stories'] = [s for s in _w if s.get('url','') not in _drop_from_world]
if _drop_from_usa:
    output['usa']['stories'] = [s for s in _u if s.get('url','') not in _drop_from_usa]


# ---- HARD 24h AGE CAP — user mandate 2026-05-22: "nothing should be a day
# ago, 24 hours only." Drop any story (and any perspective) whose URL is
# older than 24h. Belt-and-suspenders: applies to every tab after all
# curation/promotion has run. ----
HARD_AGE_CAP_H = 24.0
for _tab, _container in list(output.items()):
    if not isinstance(_container, dict): continue
    _stories = _container.get('stories', [])
    if not isinstance(_stories, list): continue
    _kept = []
    for _s in _stories:
        # For perspective stories, use freshest perspective URL; else top-level url
        urls = [_s.get('url', '')]
        for _p in _s.get('perspectives', []) or []:
            if isinstance(_p, dict) and _p.get('url'):
                urls.append(_p['url'])
        ages = []
        for u in urls:
            m = re.search(r'/status/(\d+)', u or '')
            if not m: continue
            try:
                ts = (int(m.group(1)) >> 22) + 1288834974657
                ages.append((datetime.datetime.now() - datetime.datetime.fromtimestamp(ts/1000)).total_seconds() / 3600)
            except: pass
        if not ages:
            _kept.append(_s)  # no URL age we can read — keep
            continue
        if min(ages) > HARD_AGE_CAP_H:
            print(f"[24h-cap] drop {_tab}: '{(_s.get('headline','') or '?')[:50]}' (oldest URL {min(ages):.1f}h)", file=sys.stderr)
            continue
        _kept.append(_s)
    _container['stories'] = _kept

# ---- Preserve user-managed tabs (freespeech, submit) ----
for manual_tab in ('freespeech', 'submit'):
    if manual_tab in existing_full and isinstance(existing_full[manual_tab], dict):
        output[manual_tab] = existing_full[manual_tab]


# ---- Write stories.json in eXpressO's top-level-tab-key shape ----
final = dict(output)
final['lastUpdated'] = datetime.datetime.now().astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

with open('stories.json', 'w') as f:
    json.dump(final, f, indent=2)

print("[parse_grok] stories.json updated", file=sys.stderr)
