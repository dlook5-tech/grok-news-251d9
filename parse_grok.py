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
WU_VIEW_FLOOR = 50_000  # 2026-05-22: lowered 100K→50K per user (option 3 — loosen floors, keep features)


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
        # Find the first '{' and use json.JSONDecoder's raw_decode to consume
        # exactly one well-formed JSON object — handles nested braces/arrays
        # (e.g. {"perspectives":[{...},{...}]}). Old regex `\{[^{}]*\}` only
        # matched FLAT objects and was extracting the FIRST inner object on
        # nested responses, dropping the wrapper.
        start = text.find('{')
        if start < 0: return None
        try:
            obj, _ = json.JSONDecoder().raw_decode(text[start:])
            return obj
        except json.JSONDecodeError as e:
            print(f"[xai-call] JSON decode failed: {e} — text head: {text[start:start+200]!r}", file=sys.stderr)
            return None
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


_PERSPECTIVE_MIN_VIEWS = {
    'Conservative': 5_000,
    'Democrat': 1_000,      # Often muted on right-favoring stories — go lower so a substantive Dem reply isn't dropped
    'Independent': 1_000,
}
_PERSPECTIVE_MIN_FOLLOWERS = 1_000  # Quality floor: no "Yahoo accounts" per user

def find_perspectives(story_url, story_headline):
    """STAGE 2: For a chosen World/USA story, search the REPLIES and
    QUOTE-TWEETS of the original story tweet itself, find:
      - Conservative (right-leaning reply/QT)
      - Democrat    (left-leaning reply/QT — view floor lowered to 1K)
      - Independent (ONLY if a genuinely non-partisan take exists)

    User mandate (refined 2026-05-23 eve): "I want it to always be clean
    and objective by number of views. Maybe lower the perspective below
    5K if you don't have any Democrat contrasting view, as long as it's
    not some Yahoo." Don't look at the whole platform for "reactions";
    drill into the replies/QTs of the SOURCE tweet — that's where the
    political diversity actually lives. For any 50K+ view story there
    are usually dozens of substantive contrarian QTs.
    """
    if not story_url or '/status/' not in story_url:
        return []
    prompt = (
        f"For the X post at {story_url} (headline: {story_headline!r}), find the "
        f"highest-view politically-charged reactions to this specific news event.\n\n"
        f"WHERE TO LOOK (both are valid — pick the highest-view qualifying tweet per side):\n"
        f"  (a) Direct replies to the URL above\n"
        f"  (b) Quote-tweets that share the URL above with the user's own commentary\n"
        f"  (c) Original posts on X within the last 24h that are about THIS SAME news event\n"
        f"      (e.g. another commentator covering the same story with their own take)\n"
        f"  - NOT generic political posts unrelated to this specific event\n"
        f"  - NOT the original post itself or anything from the same author\n\n"
        f"SLOTS (return what you find — missing slots are fine):\n"
        f"  - Conservative: right-leaning / MAGA / Republican-aligned reply or QT.\n"
        f"  - Democrat: left-leaning / progressive / Democrat-aligned reply or QT.\n"
        f"  - Independent: ONLY include if there's a genuinely non-partisan or unusual "
        f"take that doesn't slot into Conservative or Democrat. Otherwise OMIT this slot — "
        f"do not manufacture one.\n\n"
        f"VIEW MINIMUMS (tiered for fairness — left-leaning replies on right-favoring "
        f"stories often get lower engagement but can still be substantive):\n"
        f"  - Conservative reaction: minimum 5,000 views.\n"
        f"  - Democrat reaction: minimum 1,000 views.\n"
        f"  - Independent reaction: minimum 1,000 views.\n\n"
        f"QUALITY (anti-spam / anti-Yahoo): each reply/QT account must have at least "
        f"1,000 followers, a real bio, and the reply itself must be SUBSTANTIVE — no "
        f"one-word reactions ('lol', 'true', emoji), no spam, no copy-paste talking "
        f"points. Real commentary only.\n\n"
        f"RULES:\n"
        f"  - All URLs must be real X status URLs you actually found via x_search. NEVER fabricate.\n"
        f"  - Each perspective's URL must be DIFFERENT from {story_url} (no self-quotes).\n"
        f"  - Posted in the last 24 hours.\n"
        f"  - If you can only find 0 or 1 perspective, return what you found. Don't force matches.\n\n"
        f"Return ONLY a JSON object:\n"
        f'{{"perspectives":[\n'
        f'  {{"label":"Conservative","handle":"@user","url":"https://x.com/.../status/<id>",'
        f'"body":"verbatim post text","views":<integer>,"honesty":<1-10>,"notes":"one-line plain-English honesty justification"}},\n'
        f'  {{"label":"Democrat","handle":"@user","url":"...","body":"...","views":...,"honesty":...,"notes":"..."}},\n'
        f'  {{"label":"Independent","handle":"@user","url":"...","body":"...","views":...,"honesty":...,"notes":"..."}}\n'
        f"]}}\n"
        f"Empty array {{\"perspectives\":[]}} is valid if nothing qualifies."
    )
    result = _xai_call(prompt, timeout=90, max_tokens=3000)
    if not result or 'perspectives' not in result:
        return []
    persps = result.get('perspectives') or []
    if not isinstance(persps, list):
        return []
    valid = []
    seen_urls = set()
    for p in persps:
        if not isinstance(p, dict): continue
        url = (p.get('url') or '').strip()
        if '/status/' not in url: continue
        if url == story_url: continue  # never let the source tweet ship as its own perspective
        if url in seen_urls: continue
        label = (p.get('label') or '').strip()
        if label not in ('Conservative', 'Democrat', 'Independent'): continue
        try:
            views = int(p.get('views') or 0)
        except (TypeError, ValueError):
            views = 0
        # Tiered floor — per-label minimums (M-019)
        if views < _PERSPECTIVE_MIN_VIEWS.get(label, 5_000):
            continue
        seen_urls.add(url)
        valid.append({
            'label': label,
            'handle': p.get('handle', '') or '',
            'url': url,
            'body': (p.get('body') or '')[:600],
            'views': views,
            'engagement': f"{views:,} views",
            'honesty': p.get('honesty'),
            'notes': (p.get('notes') or '')[:300],
        })
        if len(valid) >= 3:
            break
    return valid


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


_GENERIC_HEADLINE_PATTERNS = [
    r'^shares?\s+(a\s+)?(video|link|image|photo|tweet)\b',
    r'^posts?\s+(a\s+)?(video|image|photo|link)\b',
    r'^short\s+(reply|affirmative\s+reply|comment)\b',
    r'^replies\s+(positively|affirmatively|with|[\'"])',
    r'^replies\s+about\s+a?\s+\w+\s+(post|reply)?\s*$',
    r'^comments?\s+on\s+a\s+(very\s+good\s+|good\s+|great\s+|nice\s+)?day',
    r'^comments?\s+(no\s+\w+|about\s+\w+)\s+on',
    r'^shares?\s+(an?\s+)?(image|gif)\b',
    r'^posts?\s+rocket\s+emoji',
    r'^elon(\s+musk)?\s+(shares?|posts?|comments?|replies)',
    # "X with a post" / "X at a post" / "X on a post" — generic, no context
    # Catches: Agrees with a post, Laughs at a post, Expresses surprise at a post,
    # Comments on a post with emoji, Marks agreement with target emoji
    r'\b(with|at|on|to)\s+a\s+post\b',
    r'\b(with|at|on|to)\s+a\s+post\s+(with|on|about)\s+\w+$',
    r'^marks\s+agreement\b',
    r'^expresses\s+\w+\s+(at|on|to)\s+a\s+post',
    r'^laughs?\s+(at|on)\s+a\s+post',
    r'^agrees?\s+(strongly|emphatically|exactly|with)?\s*(with\s+a\s+post|on\s+a\s+post|at\s+a\s+post)?\s*$',
    r'^notes?\s+(remaining\s+)?(issues|points|things)\s+in\s+a\s+(discussion|conversation|thread|post)',
    r'^[?\s\.]*$',
    r'^untitled$',
]
_GENERIC_HEADLINE_RE = re.compile('|'.join(_GENERIC_HEADLINE_PATTERNS), re.IGNORECASE)


def _is_generic_headline(h):
    if not h or not h.strip(): return True
    # search (not match) so patterns can detect generic phrases anywhere in headline
    return bool(_GENERIC_HEADLINE_RE.search(h.strip()))


def fetch_headline_for_post(url, body):
    """For a post URL whose headline is generic ('Shares video link', etc.), fire
    an xAI call to describe what's actually in the post (the video subject, the
    linked content, etc.). Returns a 1-line headline or None."""
    if not url or '/status/' not in url:
        return None
    prompt = (
        f"For the X post at {url}: write ONE newspaper-style headline (under 100 chars) "
        f"that describes WHAT IS IN THE POST — if it's a video, describe what the video shows; "
        f"if it's a link, describe what the linked content is about; if it's an image, describe the image; "
        f"if it's a reply or QT, describe what's being responded to and the response take. "
        f"The post text is: {body[:200]!r}\n"
        f"Return ONLY a JSON object: {{\"headline\":\"the descriptive headline\"}}. "
        f"NEVER write 'Shares video link', 'Posts photo', 'Short reply', or anything generic. "
        f"NEVER start the headline with the author's name (e.g. 'Elon Musk Shares Video of ...' — just write 'Photo of Cybertruck at Starbase'). "
        f"If you genuinely can't determine what the content is, return {{}}."
    )
    result = _xai_call(prompt, timeout=30, max_tokens=400)
    if not result or not result.get('headline'):
        return None
    h = (result['headline'] or '').strip()
    if _is_generic_headline(h): return None
    return h[:120]


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
        # PYTHON ENFORCEMENT: rewrite generic headlines ("Shares video link",
        # "Short affirmative reply", etc.) by fetching what's actually in the
        # post. User has flagged this bug 3+ times — prompt-only fix wasn't
        # holding; now enforced in Python.
        for s in elon_kept:
            h = (s.get('headline') or '').strip()
            if _is_generic_headline(h):
                better = fetch_headline_for_post(s.get('url',''), s.get('body',''))
                if better:
                    print(f"[elon-headline] rewrote '{h[:40]}' → '{better[:60]}'", file=sys.stderr)
                    s['headline'] = better
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

        # STAGE 1 (2026-05-22 user mandate): no perspective requirement.
        # Just 50K view floor + valid top-level URL. Goal is to see the
        # raw 8 candidates Grok returned and dial in algorithm before
        # adding perspectives back in stage 2.
        def _wu_qualified(s):
            if curation.story_views(s) < WU_VIEW_FLOOR: return False
            u = s.get('url', '') or ''
            return '/status/' in u

        cleaned_qual = [c for c in cleaned if _wu_qualified(c)]
        held = previous.get(tab, [])
        held_qual = [h for h in held if _wu_qualified(h)]
        chosen = curation.apply_hold(held_qual, cleaned_qual, top_n=999,
                                     sort_key=curation.story_velocity)
        chosen = [s for s in chosen if _wu_qualified(s)]

        # ===== STAGE 2: find Conservative / Democrat (+ optional Independent)
        # perspectives for each chosen story. M-018 mandate: re-fetch every
        # cron, no caching. Missing perspectives never block the story.
        # Parallelize with thread pool — typically 3-6 stories × ~10s each
        # collapses to ~10-15s wall time.
        import concurrent.futures as _cf
        def _enrich_one(_s):
            try:
                persps = find_perspectives(_s.get('url',''), _s.get('headline',''))
            except Exception as _e:
                print(f"[stage2-warn] {tab}: perspective fetch failed for "
                      f"@{_s.get('handle','?')}: {_e}", file=sys.stderr)
                persps = []
            if persps:
                _s['perspectives'] = persps
                labels = [p.get('label') for p in persps]
                print(f"[stage2] {tab} @{_s.get('handle','?')}: found {len(persps)} "
                      f"perspectives ({', '.join(labels)})", file=sys.stderr)
            else:
                # Strip any stale perspectives field so we don't show old data
                _s.pop('perspectives', None)
                print(f"[stage2] {tab} @{_s.get('handle','?')}: 0 perspectives "
                      f"(ships as inline-embed block)", file=sys.stderr)
            return _s
        if chosen:
            with _cf.ThreadPoolExecutor(max_workers=6) as _ex:
                chosen = list(_ex.map(_enrich_one, chosen))

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


# ---- GENERIC HEADLINE REWRITE (all tabs) ----
# User mandate (repeated 1000s of times): treat headlines like news stories —
# few words, clearly describe what the post is about. NEVER "Shares clip" /
# "Shares video" / "Short reply" / generic placeholders. Python-enforced now.
for _tab, _container in list(output.items()):
    if not isinstance(_container, dict): continue
    _stories = _container.get('stories', [])
    if not isinstance(_stories, list): continue
    for _s in _stories:
        if not isinstance(_s, dict): continue
        # If story has perspectives, rewrite each perspective's headline-like-field too
        for _p in _s.get('perspectives', []) or []:
            if not isinstance(_p, dict): continue
            _ph = (_p.get('text') or _p.get('body') or '').strip()
            # Perspectives have body/text not headline, leave alone
        # Rewrite top-level headline if generic
        _h = (_s.get('headline') or '').strip()
        if _is_generic_headline(_h) and _s.get('url'):
            _better = fetch_headline_for_post(_s.get('url',''), _s.get('body',''))
            if _better:
                print(f"[{_tab}-headline] rewrote '{_h[:40]}' → '{_better[:60]}'", file=sys.stderr)
                _s['headline'] = _better

# ---- HARD AGE CAPS per tab ----
# Default: 24h (user mandate "nothing should be a day ago, 24 hours only").
# Per-tab overrides for slower-cadence content where podcasters/etc don't
# post viral clips every day:
#   - pods: 48h (user 2026-05-22: "pods 2" = 2 days)
HARD_AGE_CAP_H = 24.0  # default for news tabs (daily content)
PER_TAB_AGE_CAP = {
    # News tabs (daily content cadence) — strict 24h
    # world, usa, top, business, msm, sports, pg6, comedy, elon = 24h default
    # Slower-cadence tabs — loosened so they're not always empty:
    'pods': 48.0,        # podcasters drop clips every 1-3 days
    'allin': 48.0,       # billionaire-podcaster posts often 1-2 day cadence
    'conspiracy': 48.0,  # investigative content takes time to surface
    'recipe': 72.0,      # recipe content has long shelf life, posts less daily
    'science': 72.0,     # research/breakthrough posts spaced out
    'local': 72.0,       # SoCal/OC content sparse on X
}
for _tab, _container in list(output.items()):
    if not isinstance(_container, dict): continue
    _stories = _container.get('stories', [])
    if not isinstance(_stories, list): continue
    _cap = PER_TAB_AGE_CAP.get(_tab, HARD_AGE_CAP_H)
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
        if min(ages) > _cap:
            print(f"[age-cap] drop {_tab}: '{(_s.get('headline','') or '?')[:50]}' (oldest URL {min(ages):.1f}h > {_cap:.0f}h cap)", file=sys.stderr)
            continue
        _kept.append(_s)
    _container['stories'] = _kept

# ---- FINAL QC: cross-tab event dedup ----
# User mandate 2026-05-23: "cant u just do a QC at the end looking for dups"
# The URL-only cross-tab dedup catches the SAME tweet appearing in two tabs.
# This catches SAME EVENT, DIFFERENT TWEETS — e.g., Minnesota Medicaid fraud
# shipping simultaneously in USA (@bigNews) and MSM (@washghost1) and Top
# (@DOJ) via three different reporters.
#
# Heuristic: two stories are dupes if they share BOTH:
#   (a) ≥2 distinctive 4+char non-stop tokens, OR
#   (b) any shared $-figure (e.g. "$90m") — money tokens are highly distinctive
# Expanded stoplist drops common news verbs (signs/holds/calls/announces/etc) and
# generic adjectives (massive/major/huge/big) so they don't count toward the 2.
#
# Priority (earlier wins): world > usa > top > msm > business > sports > pg6 ...
_DEDUP_ORDER = ['world','usa','top','msm','business','sports','pg6','science',
                'pods','allin','conspiracy','local','recipe','comedy','elon']
_QC_STOP = {
    # articles / pronouns / conjunctions
    'the','from','with','that','this','about','have','will','their','they','them',
    'these','those','than','then','your','what','when','where','some','been','were',
    'has','was','will','would','could','should','into','over','more','very','just',
    'such','here','there','only','also','same','both','each','itself','must',
    # common news verbs
    'says','said','tells','told','holds','signs','calls','plans','wants','seeks',
    'takes','gives','makes','goes','comes','sees','shows','asks','adds','warns',
    'announces','reveals','reports','reacts','shares','posts','breaks','meets',
    'discusses','responds','launches','sends','pushes','urges','condemns','denies',
    'admits','agrees','offers','accuses','claims','suggests','vows','threatens',
    # generic intensifiers / adjectives often used in headlines
    'massive','major','huge','large','small','big','little','recent','latest','new',
    'old','first','last','top','best','worst','full','great','only','many','most',
    'real','fake','true','false','good','bad','right','wrong','high','low',
    # bland nouns common across all news
    'news','story','update','report','statement','today','yesterday','week','day',
    'time','year','part','thing','case','plan','idea','show','clip','video','photo',
    'post','tweet','reply','people','person','public','media','press','event',
    # 2026-05-23: false-positive triggers seen on live data
    # ('real' + 'trump' was making any "real X" headline dupe with any Trump story)
}

_MONEY_RE = re.compile(r'\$\d+(?:\.\d+)?[mkbt]?', re.IGNORECASE)

def _qc_extract(s):
    """Return (distinctive_tokens, money_tokens) for dupe comparison."""
    h = (s.get('headline','') or s.get('body','') or '')
    h_low = h.lower()
    tokens = {w for w in re.findall(r'[a-z]{4,}', h_low) if w not in _QC_STOP}
    money = {m.lower() for m in _MONEY_RE.findall(h_low)}
    return tokens, money

def _qc_is_dupe(t1, m1, t2, m2, min_shared=2):
    """≥min_shared distinctive tokens shared, OR any shared money figure.
    min_shared=2 for within-tab (default), =3 for cross-tab (M-014).
    Cross-tab needs the stricter threshold because {trump, deal} or {iran, trump}
    shared between unrelated political stories is just background noise — almost
    every US political headline contains both. False positive on 2026-05-23:
    Anthropic-AI USA story dropped vs Iran-deal World story on shared {trump, deal}."""
    if m1 and m2 and (m1 & m2):
        return ('money', m1 & m2)
    shared = t1 & t2
    if len(shared) >= min_shared:
        return ('tokens', shared)
    return None

_qc_seen = []  # list of (tab, tokens, money, headline)
for _qc_tab in _DEDUP_ORDER:
    _qc_container = output.get(_qc_tab, {})
    if not isinstance(_qc_container, dict): continue
    _qc_stories = _qc_container.get('stories', []) or []
    _qc_kept = []
    for _qc_s in _qc_stories:
        _qc_t, _qc_m = _qc_extract(_qc_s)
        if len(_qc_t) < 2 and not _qc_m:
            _qc_kept.append(_qc_s); continue
        _qc_match = None
        for _prev_tab, _prev_t, _prev_m, _prev_h in _qc_seen:
            # M-014: cross-tab needs 3+ shared tokens; within-tab keeps 2+.
            min_shared = 2 if _prev_tab == _qc_tab else 3
            d = _qc_is_dupe(_qc_t, _qc_m, _prev_t, _prev_m, min_shared=min_shared)
            if d:
                _qc_match = (_prev_tab, d, _prev_h); break
        if _qc_match:
            _prev_tab, (_kind, _overlap), _prev_h = _qc_match
            scope = 'within-tab' if _prev_tab == _qc_tab else 'cross-tab'
            print(f"[qc-dupe] drop {_qc_tab}: '{(_qc_s.get('headline','') or '?')[:55]}' "
                  f"({scope} shared {_kind} {sorted(_overlap)} w/ {_prev_tab}: '{_prev_h[:55]}')",
                  file=sys.stderr)
            continue
        _qc_kept.append(_qc_s)
        _qc_seen.append((_qc_tab, _qc_t, _qc_m, _qc_s.get('headline','') or ''))
    _qc_container['stories'] = _qc_kept


# ============================================================
# M-014: LLM SEMANTIC DEDUP — backstop pass after rule-based QC.
# User mandate 2026-05-23: "if we could also add to the backend of that an AI
# intelligence QC check where it reads all the stories to make sure none are
# the same."
#
# After the rule-based QC, fire ONE xAI call that reads ALL shipped news-tab
# headlines and returns pairs that are semantically the same event despite not
# triggering token overlap (e.g. completely different wording on the same news).
# Drop the LOWER-priority tab's story (using _DEDUP_ORDER as tiebreaker).
# Graceful degradation: if xAI errors or response is malformed, log and
# continue — never block the cron.
# ============================================================
def _qc_llm_semantic_dedup(output_dict):
    items = []  # (tab, idx_in_tab, handle, headline)
    for tab in _DEDUP_ORDER:
        c = output_dict.get(tab, {})
        if not isinstance(c, dict): continue
        sts = c.get('stories', []) or []
        for idx, s in enumerate(sts):
            h = (s.get('headline','') or s.get('body','') or '').strip()
            if not h: continue
            items.append((tab, idx, s.get('handle','?'), h[:120]))
    if len(items) < 2:
        print(f"[qc-llm] only {len(items)} stories; skipping LLM dedup", file=sys.stderr)
        return
    if len(items) > 50:
        items = items[:50]
    listing = '\n'.join(f"[{i}] {tab}/{handle}: {h}"
                       for i, (tab, _, handle, h) in enumerate(items))
    prompt = (
        "You are reviewing news-site headlines for duplicate EVENTS. Two headlines "
        "are duplicates if they describe THE SAME news event from different angles, "
        "reporters, or wording — not just sharing a person/place/topic.\n\n"
        "EXAMPLES of duplicates (same event):\n"
        "  '$90M Minnesota Medicaid fraud bust' and 'DOJ charges $90M MN fraud suspect'\n"
        "  'Hamas releases hostage video' and 'Israeli hostage video released by Hamas'\n\n"
        "EXAMPLES of NOT duplicates (different events, same names):\n"
        "  'Trump signs Iran deal' and 'Trump signs trade bill' (different deals)\n"
        "  'Anthropic AI contract' and 'Iran nuclear deal' (just shared 'deal')\n"
        "  'Stephen A Smith on Lakers' and 'Stephen A Smith on Heat' (different shows)\n\n"
        "Headlines:\n\n"
        + listing +
        "\n\nReturn ONLY a JSON object: {\"dupes\":[[i,j,\"one-sentence reason\"], ...]} "
        "where i and j are indices and j is the SAME event as i. If no duplicates, "
        "return {\"dupes\":[]}. Be conservative — only flag if you are confident."
    )
    try:
        result = _xai_call(prompt, timeout=45, max_tokens=2000)
    except Exception as e:
        print(f"[qc-llm] xAI call failed: {e} — skipping", file=sys.stderr)
        return
    if not result or 'dupes' not in result:
        print(f"[qc-llm] no usable response — skipping", file=sys.stderr)
        return
    dupes = result.get('dupes') or []
    if not isinstance(dupes, list):
        print(f"[qc-llm] malformed dupes field — skipping", file=sys.stderr)
        return

    to_drop = {}  # (tab, idx_in_tab) -> (kept_label, drop_head, reason)
    for entry in dupes:
        try:
            i, j = int(entry[0]), int(entry[1])
            reason = (entry[2] if len(entry) > 2 else 'LLM flagged as same event')[:120]
        except (TypeError, ValueError, IndexError):
            continue
        if not (0 <= i < len(items) and 0 <= j < len(items)) or i == j:
            continue
        a_tab, a_idx, a_handle, a_head = items[i]
        b_tab, b_idx, b_handle, b_head = items[j]
        a_rank = _DEDUP_ORDER.index(a_tab) if a_tab in _DEDUP_ORDER else 999
        b_rank = _DEDUP_ORDER.index(b_tab) if b_tab in _DEDUP_ORDER else 999
        if a_rank < b_rank:
            drop_key = (b_tab, b_idx); kept_label = f"{a_tab}/{a_handle}"; drop_head = b_head
        elif b_rank < a_rank:
            drop_key = (a_tab, a_idx); kept_label = f"{b_tab}/{b_handle}"; drop_head = a_head
        else:
            drop_key = (b_tab, b_idx); kept_label = f"{a_tab}/{a_handle}"; drop_head = b_head
        if drop_key in to_drop: continue
        to_drop[drop_key] = (kept_label, drop_head, reason)

    if not to_drop:
        print(f"[qc-llm] reviewed {len(items)} stories; 0 semantic dupes flagged", file=sys.stderr)
        return

    drops_by_tab = {}
    for (tab, idx), info in to_drop.items():
        drops_by_tab.setdefault(tab, []).append((idx, info))
    for tab, drop_list in drops_by_tab.items():
        idxes = {i for i, _ in drop_list}
        c = output_dict.get(tab, {})
        sts = c.get('stories', []) or []
        for i, info in drop_list:
            kept, head, reason = info
            print(f"[qc-llm] drop {tab}: '{head[:55]}' "
                  f"(LLM: same as {kept} — {reason})", file=sys.stderr)
        c['stories'] = [s for i, s in enumerate(sts) if i not in idxes]

_qc_llm_semantic_dedup(output)

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


# ===================================================================
# CRON REPORT — auto-generated EVERY cron run.
# Mandate 2026-05-23: "Include it in the code if you miss it once."
# This used to depend on a wakeup-driven render in chat. Now it's
# generated structurally by the cron, committed alongside stories.json,
# and viewable any time by reading cron_report.md.
# Format spec: REPORT_FORMAT.md (committed). DO NOT remove this block.
# ===================================================================
def _fmt_views(v):
    try: v = int(v)
    except: return '?'
    if v >= 1_000_000: return f'{v/1_000_000:.1f}M'.replace('.0M','M')
    if v >= 1_000:     return f'{v/1_000:.1f}K'.replace('.0K','K')
    return str(v)

def _url_age_h(url):
    m = re.search(r'/status/(\d+)', url or '')
    if not m: return None
    try:
        ts = (int(m.group(1)) >> 22) + 1288834974657
        return (datetime.datetime.now() - datetime.datetime.fromtimestamp(ts/1000)).total_seconds()/3600
    except: return None

def _report_drop_reason(cand, shipped_urls, world_shipped_urls, usa_shipped_urls,
                       top_shipped_urls, msm_shipped_urls, tab_max_age_h):
    """Best-effort: explain why a candidate didn't ship."""
    url = cand.get('url', '')
    v = int(cand.get('combined_views') or cand.get('views') or 0)
    a = _url_age_h(url)
    if not url or '/status/' not in url:
        return '(no /status/ url)'
    if v < 50_000:
        # World/USA have 50K floor; other tabs vary, but <50K is suspicious for News tabs
        return f'(<50K floor)'
    if a is not None and a > tab_max_age_h:
        return f'(>{int(tab_max_age_h)}h age cap, {a:.1f}h old)'
    # Cross-tab dedup check
    for other_tab, other_urls in [('world', world_shipped_urls), ('usa', usa_shipped_urls),
                                   ('top', top_shipped_urls), ('msm', msm_shipped_urls)]:
        if url in other_urls:
            return f'(dup of {other_tab} tab)'
    return '(qc-dropped — same event in another tab)'

_report_lines = []
_report_lines.append(f"=== CRON @ {final['lastUpdated']} ===")
_report_lines.append("")
_report_lines.append("Auto-generated by parse_grok.py at cron time. Format locked per REPORT_FORMAT.md.")
_report_lines.append("")

# Per-tab cap mapping for drop-reason inference
TAB_CAPS_FOR_REPORT = {**PER_TAB_AGE_CAP}  # uses module-level dict
for t in ('world','usa','top','business','msm','sports','pg6','comedy','elon'):
    TAB_CAPS_FOR_REPORT.setdefault(t, HARD_AGE_CAP_H)

# Build shipped-url sets
def _urls_of(tab_key):
    out = set()
    for s in (final.get(tab_key,{}) or {}).get('stories',[]) or []:
        if s.get('url'): out.add(s['url'])
    return out
world_urls = _urls_of('world')
usa_urls = _urls_of('usa')
top_urls = _urls_of('top')
msm_urls = _urls_of('msm')

# WORLD + USA — full 8-candidate breakdown
for tab in ('world','usa'):
    cands = (final.get(tab,{}) or {}).get('_candidates',[]) or []
    sts = (final.get(tab,{}) or {}).get('stories',[]) or []
    shipped_urls = {s.get('url') for s in sts if s.get('url')}
    _report_lines.append(f"{tab.upper()} — {len(cands)} candidates Grok returned")
    for i, c in enumerate(cands, 1):
        v = c.get('combined_views') or c.get('views') or 0
        url = c.get('url','') or ''
        h = (c.get('headline','') or '')[:60]
        handle = c.get('handle','?').lstrip('@')
        if url in shipped_urls:
            mark = '✅'; reason = ''
        else:
            mark = '❌'
            reason = ' ' + _report_drop_reason(c, shipped_urls, world_urls, usa_urls,
                                                top_urls, msm_urls,
                                                TAB_CAPS_FOR_REPORT.get(tab, HARD_AGE_CAP_H))
        _report_lines.append(f"  {i}. {_fmt_views(v):>6s} {mark} @{handle} — {h}{reason}")
    _report_lines.append("")

# Per-tab summary table
_report_lines.append("| TAB        | N | Top Views | Age range  | Top Headline                                       |")
_report_lines.append("|------------|---|-----------|------------|----------------------------------------------------|")
for tab in ('world','usa','top','business','msm','sports','elon','pods','pg6',
            'recipe','science','local','conspiracy','comedy','allin'):
    sts = (final.get(tab,{}) or {}).get('stories',[]) or []
    if not sts:
        _report_lines.append(f"| {tab:<10s} | 0 |    —      | —          | (empty)                                            |")
        continue
    top_view = 0
    top_head = ''
    ages = []
    for s in sts:
        v = int(s.get('views', 0) or 0)
        if v == 0:
            try:
                v = int(re.findall(r'(\d[\d.]*)\s*([kmb]?)\s*views', (s.get('engagement','') or '').lower())[0][0].replace(',','').replace('.','')) if 'views' in (s.get('engagement','') or '').lower() else 0
            except: pass
        if v > top_view:
            top_view = v; top_head = (s.get('headline','') or s.get('body','') or '?')[:50]
        a = _url_age_h(s.get('url',''))
        if a is not None: ages.append(a)
    age_range = f'{min(ages):.1f}-{max(ages):.1f}h' if ages else '—'
    _report_lines.append(f"| {tab:<10s} | {len(sts)} | {_fmt_views(top_view):>9s} | {age_range:<10s} | {top_head:<50s} |")

with open('cron_report.md', 'w') as f:
    f.write('\n'.join(_report_lines) + '\n')
print(f"[parse_grok] cron_report.md written ({len(_report_lines)} lines)", file=sys.stderr)
