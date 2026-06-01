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


# ---- M-025: Non-English detection ----
# User mandate 2026-05-23 evening: "dont post anything not translated"
# Heuristic: if >5% of alphabetic chars in body are non-ASCII letters, the
# post is in a non-Latin/non-English script (Turkish ş/ğ/ü, Russian Cyrillic,
# Chinese, Arabic, etc.). Drop it from shipping. Headlines are always English
# (Grok writes summaries) so we only check the body.
def _is_non_english(text):
    if not text or len(text) < 20:
        return False
    letters = [c for c in text if c.isalpha()]
    if len(letters) < 10:
        return False
    non_ascii = [c for c in letters if ord(c) > 127]
    return (len(non_ascii) / len(letters)) > 0.05


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
    Returns {parent_url, parent_handle, parent_text} or None if original/not-found.

    M-049: hard-validate against Grok template-echo. The earlier prompt
    included a literal placeholder URL as the shape example; Grok would echo
    it back (substituting 'unknown' for the bracketed tokens) when it could
    not actually verify the parent. That shipped junk like
    'https://x.com/unknown/status/unknown' into stories.json. The new prompt
    no longer shows a placeholder URL shape, and we reject any result whose
    URL contains 'unknown' / angle brackets / example.com, plus require real
    handle and text payloads."""
    if not url or '/status/' not in url:
        return None
    prompt = (
        f"For the X post at {url}, find the tweet it is replying to OR quote-tweeting. "
        f"You MUST verify the parent post actually exists by reading it on X — do NOT guess. "
        f"If you find the parent, return ONLY this JSON: "
        f'{{"parent_url": "<the real X URL>", "parent_handle": "@<the real handle>", "parent_text": "<verbatim text, ≤280 chars>"}}. '
        f"If you cannot verify the parent (post is original, deleted, or you do not have access), "
        f"return an empty JSON object: {{}}. "
        f"DO NOT invent or guess values. DO NOT return placeholder strings like 'unknown'. "
        f"DO NOT return the literal template strings — return real values or {{}}."
    )
    result = _xai_call(prompt, timeout=30, max_tokens=400)
    if not result or not result.get('parent_url'):
        return None
    p_url = (result.get('parent_url') or '').strip()
    p_handle = (result.get('parent_handle') or '').strip()
    p_text = (result.get('parent_text') or '').strip()
    # M-049 reject conditions — any one of these means Grok hallucinated:
    if '/status/' not in p_url:
        return None
    low = p_url.lower()
    if 'unknown' in low or '<' in p_url or '>' in p_url or 'example.com' in low or 'placeholder' in low:
        print(f"[parent-reject] template-echo URL: {p_url!r}", file=sys.stderr)
        return None
    if not p_handle or p_handle.lower() in ('@unknown', '@<handle>', '@handle', '<handle>', 'unknown'):
        print(f"[parent-reject] bad handle: {p_handle!r}", file=sys.stderr)
        return None
    if '<' in p_handle or '>' in p_handle:
        print(f"[parent-reject] template-echo handle: {p_handle!r}", file=sys.stderr)
        return None
    # M-061 (2026-06-01): EMPTY parent_text is OK — parent posts can legitimately
    # be image-only / video-only with no caption. Only reject template-echo text
    # ("<text>"). The X embed renders the image either way, and a missing parent
    # was the silent root cause of "where is what he's commenting on?" complaints
    # (IMG_1689–1690, IMG_1693–1696) AND the current @1327GT350 / @sethdillon
    # cases — we were throwing away a real parent_url because the post happened
    # to be image-only.
    if p_text and '<' in p_text and '>' in p_text:
        print(f"[parent-reject] template parent_text for {p_url}", file=sys.stderr)
        return None
    return {
        'parent_url': p_url,
        'parent_handle': p_handle,
        'parent_text': (p_text or '')[:280],  # may be empty for image-only parents
    }


_PERSPECTIVE_MIN_VIEWS = {
    'Conservative': 1_000,  # Lowered 5K→1K 2026-05-23 eve: too many real replies sit in 2-4K range and were getting dropped
    'Democrat': 1_000,
    'Independent': 1_000,
}
_PERSPECTIVE_MIN_FOLLOWERS = 1_000  # Quality floor: no "Yahoo accounts" per user

def find_opposing_perspective(story_url, story_headline, existing_persps, target_label, min_views=1_000):
    """M-043 + M-058: When find_perspectives returns <2 perspectives for a
    story that clearly has political controversy, fire a TARGETED follow-up
    xAI call asking specifically for the opposing-side reaction. Grok often
    returns 1 when 3 exist; this nudge usually finds the others.

    M-058 (2026-05-31): the post-oEmbed backfill pass now calls with
    min_views=100 (instead of 1K) so sparse low-view World/USA stories
    still get a counter-perspective. User: "Just find counter with most
    views". The 1K default is kept for the in-Stage-2 fallback path so it
    doesn't get noisier than necessary on the common case.

    target_label: 'Democrat', 'Conservative', or 'Independent'.
    existing_persps: list of perspectives already found (so we can describe
    them to Grok and ask for the OPPOSING take).
    min_views: floor for the returned perspective's view count.
    Returns a single perspective dict or None.
    """
    if not story_url or '/status/' not in story_url:
        return None
    existing_desc = '. '.join(
        f"{p.get('label','?')} @{p.get('handle','?')}: {(p.get('body','') or '')[:120]}"
        for p in existing_persps[:2]
    ) or 'no perspectives found yet'
    prompt = (
        f"For the X post at {story_url} (headline: {story_headline!r}), I already "
        f"have: {existing_desc}.\n\n"
        f"NOW FIND a {target_label} reaction that CRITIQUES or DISAGREES with the "
        f"story (or with the existing perspective if shown above).\n\n"
        f"Look in:\n"
        f"  - Direct replies to {story_url}\n"
        f"  - Quote-tweets sharing the URL with critical commentary\n"
        f"  - Original posts within 24h on the SAME news event from {target_label}-aligned commentators\n\n"
        f"Quality floors:\n"
        f"  - Minimum {min_views:,} views\n"
        f"  - Account ≥1K followers + real bio\n"
        f"  - No vulgar slurs, no pure-emoji posts, no spam\n\n"
        f"Pick the HIGHEST-VIEWED qualifying critique/disagreement. Return ONLY one "
        f"perspective. If you genuinely cannot find any {target_label} critique with "
        f">={min_views:,} views, return {{\"perspective\": null}}.\n\n"
        f"Return ONLY a JSON object:\n"
        f'{{"perspective":{{"label":"{target_label}","handle":"@user","url":"https://x.com/.../status/<id>",'
        f'"body":"verbatim post text","views":<integer>}}}}'
    )
    try:
        result = _xai_call(prompt, timeout=60, max_tokens=1000)
    except Exception:
        return None
    if not result:
        return None
    p = result.get('perspective')
    if not isinstance(p, dict):
        return None
    url = (p.get('url') or '').strip()
    if '/status/' not in url or url == story_url:
        return None
    try:
        views = int(p.get('views') or 0)
    except (TypeError, ValueError):
        views = 0
    if views < min_views:
        return None
    return {
        'label': target_label,
        'handle': p.get('handle','') or '',
        'url': url,
        'body': (p.get('body') or '')[:600],
        'views': views,
        'engagement': f"{views:,} views",
    }


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
        f"HIGHEST-VIEWED political reaction on X for each of these slots:\n"
        f"  - Conservative: right-leaning / MAGA / Republican-aligned reaction\n"
        f"  - Democrat: left-leaning / progressive / Democrat-aligned reaction\n"
        f"  - Independent: ONLY if a non-partisan or unusual take exists. Otherwise OMIT.\n\n"
        f"Pick by view count. The highest-viewed qualifying reaction per side wins — "
        f"don't curate by 'analysis quality,' the user wants raw winners.\n\n"
        f"WHERE TO LOOK:\n"
        f"  (a) Direct replies to {story_url}\n"
        f"  (b) Quote-tweets sharing the URL with the user's own commentary\n"
        f"  (c) Original posts within 24h on the SAME news event from other commentators\n"
        f"  NOT: generic political posts unrelated to this story. NOT the source post or anything from the same author.\n\n"
        f"AUTO-REJECT (don't return these — promotes freaks online, not citizen journalism):\n"
        f"  - Vulgar slurs / personal attacks with no substance ('X is a hooker / pedophile / nazi')\n"
        f"  - Pure emoji reactions ('🎯' alone) or one-character posts\n"
        f"  - Spam / copy-paste talking points repeated across many accounts\n\n"
        f"QUALITY FLOORS (all required):\n"
        f"  - Minimum 1,000 views per perspective.\n"
        f"  - Account ≥1K followers and a real bio (not bot/spam account).\n\n"
        f"That's it — no character-length minimum, no 'must be analytical.' A blunt "
        f"3-word reaction from a real account with 50K views beats a thoughtful "
        f"essay from someone with 200 followers.\n\n"
        f"RULES:\n"
        f"  - All URLs must be real X status URLs you found via x_search. NEVER fabricate.\n"
        f"  - Each perspective's URL must be DIFFERENT from {story_url}.\n"
        f"  - Posted in the last 24 hours.\n"
        f"  - DO NOT score honesty — separate downstream pass handles that.\n"
        f"  - If you genuinely cannot find a qualifying reaction for a side, OMIT that slot. "
        f"Don't manufacture takes. Empty slot > fake content.\n\n"
        f"Return ONLY a JSON object:\n"
        f'{{"perspectives":[\n'
        f'  {{"label":"Conservative","handle":"@user","url":"https://x.com/.../status/<id>",'
        f'"body":"verbatim post text","views":<integer>}},\n'
        f'  {{"label":"Democrat","handle":"@user","url":"...","body":"...","views":...}},\n'
        f'  {{"label":"Independent","handle":"@user","url":"...","body":"...","views":...}}\n'
        f"]}}"
    )
    result = _xai_call(prompt, timeout=120, max_tokens=5000)
    if result is None:
        # M-048: distinguish API failure from empty-but-valid response. None
        # means _xai_call hit an exception (HTTP error, timeout, credits
        # exhausted). Raise so the caller preserves prior perspectives.
        raise RuntimeError('xAI call failed (None response) — likely API/credits issue')
    if 'perspectives' not in result:
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
        # M-035: NO character-length minimum. User never asked for it. Highest-viewed
        # qualifying reaction wins per side. Anti-vulgar handled in prime-directive
        # prompt's auto-reject list, not by length.
        seen_urls.add(url)
        valid.append({
            'label': label,
            'handle': p.get('handle', '') or '',
            'url': url,
            'body': (p.get('body') or '')[:600],
            'views': views,
            'engagement': f"{views:,} views",
            # honesty + notes set by score_honesty() pass (M-021)
        })

    # M-036: ONE perspective per label, the HIGHEST-VIEWED Grok returned for
    # that side. User mandate 2026-05-23 night: "honesty 5 is ok if its the
    # highest viewed [democrat] perspective. if its not, 5 is way too low."
    # So we never fall back to a lower-viewed alternative — top-per-label only.
    # Honesty floor (M-034) then applies to that one pick.
    by_label = {}
    for v in valid:
        lab = v['label']
        if lab not in by_label or v['views'] > by_label[lab]['views']:
            by_label[lab] = v
    return [by_label[lab] for lab in ('Conservative', 'Democrat', 'Independent') if lab in by_label]


# ============================================================
# M-021: HONESTY SCORING IS A SEPARATE LABELING PASS.
# Honesty must NEVER affect story selection or perspective fetch.
# Runs AFTER Stage 1 (selection) and Stage 2 (perspectives) complete.
# Each shipped story + each shipped perspective gets one scoring call,
# parallelized. xAI just labels — never filters, never reorders.
# ============================================================
def score_honesty(url, body, headline=''):
    """Returns {honesty: int 1-10, notes: str} for the given post.
    NEVER drops or filters — always returns a dict, defaults to 7/null if scoring fails."""
    if not url or '/status/' not in url:
        return {'honesty': None, 'notes': ''}
    text = ((headline or '') + ' — ' + (body or '')).strip()[:500]
    prompt = (
        f"Score this X post for honesty 1-10 using this rubric:\n"
        f"  10 = VERIFIED FACT only (court records, scoreboards, official stats, raw video of exactly what's claimed)\n"
        f"   9 = factual core with minor editorializing (news report + light framing)\n"
        f"   8 = analysis / commentary / institutional perspective (think tanks CSIS/Brookings/Heritage/RAND/AEI NEVER score 10 — max 8)\n"
        f"   7 = opinion / prediction / hot take ('I think X will happen')\n"
        f"   6 = contains a specific misleading claim\n"
        f"   5 = demonstrably false statement\n"
        f"  ≤4 = serial misrepresentation, conspiracy without specifics, pure personal attacks with no factual content\n\n"
        f"ATTRIBUTION: video/audio of person speaking = attribution VERIFIED (score the content, not 'fabricated').\n"
        f"Transcript-only quotes have attribution uncertainty.\n\n"
        f"COMMON MISSCORES TO AVOID:\n"
        f"  - Vulgar personal attacks with no checkable claim ('X is a hooker / pedophile / nazi') = 3, NOT 5+\n"
        f"  - Pure praise/congratulation with no factual content ('Way to go!' / 'You're a hero!') = 6 max, NOT 8+\n"
        f"  - Calling someone a slur or generic insult without supporting evidence = 2-3\n"
        f"  - One-line reactions like 'lol' or 'true' or pure emoji = 4 max\n"
        f"  - Sarcastic dunks WITHOUT facts ('Sure, Jan') = 4-5\n"
        f"  - Sarcastic dunks WITH a checkable claim attached = 6-7\n\n"
        f"Post URL: {url}\n"
        f"Post text: {text!r}\n\n"
        f"Return ONLY a JSON object: "
        f'{{"honesty": <1-10 integer>, "notes": "<one-line plain-English why, max 120 chars>"}}'
    )
    try:
        result = _xai_call(prompt, timeout=30, max_tokens=400)
    except Exception as e:
        print(f"[honesty-score] xAI failed for {url}: {e}", file=sys.stderr)
        return {'honesty': None, 'notes': ''}
    if not result:
        return {'honesty': None, 'notes': ''}
    try:
        h = int(result.get('honesty') or 0)
    except (TypeError, ValueError):
        h = 0
    if not (1 <= h <= 10):
        h = None
    notes = (result.get('notes') or '')[:120]
    return {'honesty': h, 'notes': notes}


def fetch_top_qt(url):
    """Find the highest-view QT/RT of a given post URL.
    Returns {qt_url, qt_handle, qt_views} or None if no notable QT exists.

    M-049: same template-echo defense as fetch_parent. Reject Grok responses
    that contain 'unknown', angle brackets, or empty handle."""
    if not url or '/status/' not in url:
        return None
    prompt = (
        f"Find the highest-view quote-tweet or retweet (with commentary) of the X post {url}. "
        f"Use x_search to find QTs/RTs that reference this URL. "
        f"You MUST verify the QT/RT exists — do NOT guess. "
        f"Return ONLY this JSON: "
        f'{{"qt_url": "<the real X URL>", "qt_handle": "@<the real handle>", "qt_views": <integer>}}. '
        f"If no notable QT exists with at least 5,000 verified views, return {{}}. "
        f"DO NOT invent values. DO NOT return placeholder strings like 'unknown'."
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
    qt_url = (result.get('qt_url') or '').strip()
    qt_handle = (result.get('qt_handle') or '').strip()
    if '/status/' not in qt_url:
        return None
    low = qt_url.lower()
    if 'unknown' in low or '<' in qt_url or '>' in qt_url or 'example.com' in low or 'placeholder' in low:
        print(f"[qt-reject] template-echo URL: {qt_url!r}", file=sys.stderr)
        return None
    if not qt_handle or qt_handle.lower() in ('@unknown', '@<handle>', '@handle', '<handle>', 'unknown'):
        print(f"[qt-reject] bad handle: {qt_handle!r}", file=sys.stderr)
        return None
    if '<' in qt_handle or '>' in qt_handle:
        print(f"[qt-reject] template-echo handle: {qt_handle!r}", file=sys.stderr)
        return None
    return {
        'qt_url': qt_url,
        'qt_handle': qt_handle,
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
    # 2026-05-23 night: SAS reply 'Affirming a statement with Instagram reel link'
    # — user: 'this is a newspaper with attention getting headlines, does that
    # seem like it?'
    r'^affirm(ing|s)\b',
    r'^confirms?\s+a\s+statement\b',
    r'^(affirms?|denies?|confirms?|endorses?|disagrees?)\s+(a|with\s+a|the)?\s*(statement|post|claim|tweet|video|reel|clip|link|article)',
    r'\b(with|via)\s+(an?\s+)?(instagram|tiktok|youtube)\s+(reel|video|link|clip|post)\b',
    # 2026-05-23 late: user caught more generics that slipped through cron #26.
    # Pattern: verb + (a|the) + generic-noun-of-reaction. Catches:
    #   'Agrees on a point in conversation'
    #   'Confirms a point with Yes'
    #   'Notes importance of a statement'
    #   'Emphasizes agreement in thread'
    #   'Reacts with target emoji to post'
    r'^(strongly|fully|emphatically|exactly|absolutely|completely|totally|simply|just|even|deeply)?\s*(agrees?|confirms?|denies?|emphasizes?|notes?|reacts?|expresses?|stresses?|salutes?|supports?|opposes?|questions?|challenges?|defends?)\s+(on\s+|in\s+|of\s+|with\s+)?(a|the|some|any)\s+(point|statement|claim|view|opinion|thread|conversation|discussion|post|tweet|article|comment|reply|message|agreement|importance|achievement|topic|issue|matter|subject|take)\b',
    r'^reacts?\s+with\s+\w+\s+emoji\b',
    r'\bin\s+(a\s+)?(conversation|thread|discussion)\s*$',
    r'\bwith\s+[\'"]?(yes|no|true|same|this|that|exactly)[\'"]?\s*$',
    # Catch 'importance/significance/relevance of a [generic noun]' anywhere
    r'\b(importance|significance|relevance|need|truth|value)\s+of\s+a\s+(point|statement|claim|view|opinion|comment|reply|message|tweet|post|thread)\b',
    # M-047 2026-05-24 night: meta-commentary about someone's social media isn't news.
    # User: 'BBC analysis of Donald Trump's 2026 social media posts' — 'not a news story'
    r'\b(analysis|review|breakdown|recap|roundup|summary|look)\s+of\s+\w+(\'s|s\')?\s+(social media|tweets?|posts?|threads?|x\s+posts?|twitter\s+posts?)\b',
    r'\b(social media|tweet|post|thread)\s+(analysis|review|breakdown|recap|roundup)\b',
    r'^(bbc|cnn|reuters|nyt|nytimes|wapo|fox news|abc|nbc|cbs|msnbc|guardian)\s+(analysis|review|breakdown|recap|reports? on|looks? at)\s+',
    r'\b(reviews?|analyzes?|breaks?\s+down|recaps?)\s+(donald\s+trump|trump|biden|elon\s+musk)(\'s|s\')?\s+(social media|tweets?|posts?|threads?|year|day|week|month)\b',
    # 2026-05-23 even later: cron #27 still missed adverb-prefixed forms and
    # parallel constructions like 'achievement or statement', 'take on topic',
    # 'point on key issue', 'restriction or prohibition'.
    r'\b(take|point|view|opinion|comment|reply|message)\s+on\s+(a\s+|the\s+|some\s+|any\s+|key\s+|important\s+|critical\s+|main\s+|the\s+main\s+)?(topic|issue|matter|subject|point|statement)\b',
    r'\b(achievement|statement|claim|view|opinion|restriction|prohibition|announcement|comment)\s+or\s+(achievement|statement|claim|view|opinion|restriction|prohibition|announcement|comment)\b',
]
_GENERIC_HEADLINE_RE = re.compile('|'.join(_GENERIC_HEADLINE_PATTERNS), re.IGNORECASE)


def _is_generic_headline(h):
    if not h or not h.strip(): return True
    # search (not match) so patterns can detect generic phrases anywhere in headline
    return bool(_GENERIC_HEADLINE_RE.search(h.strip()))


def verify_url_handle(url):
    """M-040: hallucination guard. Call X's oEmbed API to confirm the URL
    actually resolves AND that the handle in the URL matches the actual tweet
    author. Catches Grok pairing a real handle with someone else's status ID.
    Returns True if URL is valid + handle matches; False if either fails OR
    if oEmbed API errors (fail-safe: drop unverifiable URLs).
    """
    if not url or '/status/' not in url:
        return False
    m = re.search(r'(?:x|twitter)\.com/([^/]+)/status/', url)
    if not m:
        return False
    url_handle = m.group(1).lower()
    api = 'https://publish.twitter.com/oembed?dnt=true&url=' + url
    try:
        req = _urlreq.Request(api, headers={'User-Agent': 'eXpressO/1.0'})
        with _urlreq.urlopen(req, timeout=10) as r:
            data = json.load(r)
    except Exception:
        # oEmbed unreachable or 404 — URL doesn't resolve. Drop it.
        return False
    author_url = (data.get('author_url') or '').rstrip('/')
    if not author_url:
        return False
    actual_handle = author_url.rsplit('/', 1)[-1].lower()
    return url_handle == actual_handle


def pull_netlify_submissions():
    """M-038: Pull Post/Replace form submissions from Netlify Forms API.
    Returns submissions from the last 24h as story-shaped dicts. Older
    submissions are dropped from the public view (they stay in the
    submitter's localStorage forever — that's the M-038 24h-public,
    private-forever architecture).
    """
    site_id = _os.environ.get('NETLIFY_SITE_ID', '')
    auth = _os.environ.get('NETLIFY_AUTH_TOKEN', '')
    if not site_id or not auth:
        print('[netlify-pull] missing NETLIFY_SITE_ID or NETLIFY_AUTH_TOKEN — skipping', file=sys.stderr)
        return []
    api_url = f'https://api.netlify.com/api/v1/sites/{site_id}/submissions?per_page=100'
    try:
        req = _urlreq.Request(api_url, headers={'Authorization': f'Bearer {auth}'})
        with _urlreq.urlopen(req, timeout=30) as r:
            data = json.load(r)
    except Exception as e:
        print(f'[netlify-pull] failed: {e} — submit tab will be empty this cron', file=sys.stderr)
        return []
    if not isinstance(data, list):
        return []
    now = datetime.datetime.now(datetime.timezone.utc)
    out = []
    seen_urls = set()
    for s in data:
        if not isinstance(s, dict): continue
        if s.get('form_name') != 'post-replace': continue
        d = s.get('data', {}) or {}
        url = (d.get('url') or '').strip()
        if not url or '/status/' not in url: continue
        if url in seen_urls: continue  # dedup multiple submissions of same URL
        note = (d.get('note') or '').strip()
        created = s.get('created_at', '')
        created_dt = None
        for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
            try:
                created_dt = datetime.datetime.strptime(created, fmt).replace(tzinfo=datetime.timezone.utc)
                break
            except ValueError:
                continue
        if not created_dt: continue
        age_h = (now - created_dt).total_seconds() / 3600
        if age_h > 24: continue  # 24h public window
        # Extract handle from URL for display
        m = re.search(r'(?:x|twitter)\.com/([^/]+)/status/', url)
        handle = ('@' + m.group(1)) if m else ''
        seen_urls.add(url)
        out.append({
            'url': url,
            'handle': handle,
            'headline': (note[:100] if note else 'Reader submission'),
            'body': note or 'Submitted via Post/Replace form.',
            'views': 0,  # submissions don't have engagement metric
            'engagement': '',
            'submitted_at': created,
            'age_hours': round(age_h, 1),
        })
    # Most recent first
    out.sort(key=lambda x: x.get('submitted_at', ''), reverse=True)
    print(f'[netlify-pull] {len(out)} submissions in last 24h (public window)', file=sys.stderr)
    return out


def pull_follow_suggestions():
    """M-051: pull visitor-submitted handle suggestions for the Follow tab.
    Same Netlify Forms API as M-038 post-replace, but filters for the
    'follow-suggest' form. Returns the last 24h of suggestions, deduped on
    normalized handle. Owner reviews them and manually appends approved handles
    to follow_handles.json (suggestions never auto-add — keeps editorial control).
    """
    site_id = _os.environ.get('NETLIFY_SITE_ID', '')
    auth = _os.environ.get('NETLIFY_AUTH_TOKEN', '')
    if not site_id or not auth:
        return []
    api_url = f'https://api.netlify.com/api/v1/sites/{site_id}/submissions?per_page=100'
    try:
        req = _urlreq.Request(api_url, headers={'Authorization': f'Bearer {auth}'})
        with _urlreq.urlopen(req, timeout=30) as r:
            data = json.load(r)
    except Exception as e:
        print(f'[follow-suggest-pull] failed: {e}', file=sys.stderr)
        return []
    if not isinstance(data, list):
        return []
    # Load current handle list so we can mark suggestions already-followed.
    try:
        with open('follow_handles.json') as f:
            current = {h.lower().lstrip('@') for h in json.load(f).get('handles', [])}
    except Exception:
        current = set()
    now = datetime.datetime.now(datetime.timezone.utc)
    out = []
    seen_handles = set()
    for s in data:
        if not isinstance(s, dict): continue
        if s.get('form_name') != 'follow-suggest': continue
        d = s.get('data', {}) or {}
        raw = (d.get('handle') or '').strip()
        if not raw: continue
        # Normalize: strip leading @, https://x.com/, etc. Take first alnum/_ run.
        m = re.search(r'(?:x|twitter)\.com/([A-Za-z0-9_]+)', raw)
        handle = m.group(1) if m else raw.lstrip('@').strip()
        handle = re.sub(r'[^A-Za-z0-9_].*$', '', handle)  # cut at first non-handle char
        if not handle or len(handle) > 30: continue
        key = handle.lower()
        if key in seen_handles: continue
        reason = (d.get('reason') or '').strip()[:200]
        created = s.get('created_at', '')
        created_dt = None
        for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
            try:
                created_dt = datetime.datetime.strptime(created, fmt).replace(tzinfo=datetime.timezone.utc)
                break
            except ValueError:
                continue
        if not created_dt: continue
        age_h = (now - created_dt).total_seconds() / 3600
        if age_h > 24: continue
        seen_handles.add(key)
        out.append({
            'handle': handle,
            'reason': reason,
            'already_followed': key in current,
            'submitted_at': created,
            'age_hours': round(age_h, 1),
        })
    out.sort(key=lambda x: x.get('submitted_at', ''), reverse=True)
    print(f'[follow-suggest-pull] {len(out)} handle suggestions in last 24h', file=sys.stderr)
    return out


def fetch_headline_for_post(url, body, parent_text=None, parent_handle=None):
    """For a post URL whose headline is generic ('Shares video link', etc.), fire
    an xAI call to write an ATTENTION-GRABBING NEWSPAPER HEADLINE.
    If parent_text/parent_handle are provided (the post is a reply or QT), the
    headline uses the PARENT'S content as the news hook — that's what readers care
    about. Returns a 1-line headline or None.
    """
    if not url or '/status/' not in url:
        return None
    parent_block = ''
    if parent_text:
        ph = parent_handle or '?'
        parent_block = (
            f"\n⚠️ CRITICAL: This post is a REPLY/QT to @{ph} who posted: {parent_text[:280]!r}\n"
            f"The HEADLINE MUST DESCRIBE THE PARENT'S NEWS EVENT — not the reaction.\n"
            f"NEVER write headlines like:\n"
            f"  ❌ 'Agrees with post on X'\n"
            f"  ❌ 'Reacts to X'\n"
            f"  ❌ 'Endorses statement about Y'\n"
            f"  ❌ 'Confirms Z is true'\n"
            f"  ❌ '@author + verb + topic'\n"
            f"ALWAYS write the actual news from the parent:\n"
            f"  ✅ 'NYPD chief resigns amid corruption probe' (when parent says that)\n"
            f"  ✅ 'Britain cleared slavery compensation debt before 2015' (extract the fact)\n"
            f"  ✅ 'Police refuse to release Henry Nowak bodycam footage' (extract the news)\n"
            f"Pretend the reply doesn't exist. Write the headline for the PARENT post alone.\n"
        )
    prompt = (
        f"Write ONE attention-grabbing NEWSPAPER HEADLINE (under 100 chars) for the X post at {url}.\n\n"
        f"Style: like a newspaper front page — specific, factual, hook the reader. "
        f"Use proper nouns, concrete actions, real verbs. Active voice. No vague "
        f"verbs like 'affirms', 'reacts', 'comments', 'discusses'.\n\n"
        f"The post text is: {body[:300]!r}\n"
        f"{parent_block}"
        f"\nBAD examples (NEVER write these):\n"
        f"  - 'Shares video link', 'Posts photo', 'Affirming a statement', 'Reacts with emoji'\n"
        f"  - 'Author comments on news', 'Replies to discussion', 'Author with a post'\n"
        f"  - Starting with the author's name ('Elon Musk Shares...' — readers know whose tab they're in)\n\n"
        f"GOOD examples:\n"
        f"  - 'Cybertruck photographed at Starbase launch pad'\n"
        f"  - 'NYPD chief resigns amid federal corruption probe'\n"
        f"  - 'Stephen A endorses News Nation report on WH cure-funds trust'\n\n"
        f"Return ONLY a JSON object: {{\"headline\":\"the headline\"}}. "
        f"If you genuinely can't determine what the news is, return {{}}."
    )
    result = _xai_call(prompt, timeout=30, max_tokens=400)
    if not result or not result.get('headline'):
        return None
    h = (result['headline'] or '').strip()
    # If rewrite STILL came back generic, fall back to the parent's first sentence
    # (truncated to 100 chars). Better to ship the news verbatim than ship 'Agrees with X'.
    if _is_generic_headline(h):
        if parent_text:
            first_sentence = re.split(r'[.!?\n]', parent_text.strip(), 1)[0].strip()
            if first_sentence and len(first_sentence) >= 20 and not _is_generic_headline(first_sentence):
                return first_sentence[:120]
        return None
    return h[:120]


# ============================================================
# M-050 — FINAL HEADLINE TIGHTENING PASS
# User mandate 2026-05-27 5:17 PM PT: "Clarifies / directs / point to are
# waste words. The best thing AI was good at originally was writing tight
# language. Write code to make sure every block for every tab has the best
# tightest newspaper title for each item after all stories are picked. The
# last editing step. This is one thing AI should be A+ at every time."
#
# This pass runs LAST — after QC dedup, oEmbed verification, M-046 backfill,
# M-049 scrubber — on every shipped story across every tab. It asks xAI to
# rewrite the headline to AP-front-page tightness: strongest verb, fewest
# words, one line, no filler prefixes. Validation rejects rewrites that are
# longer, still filler, or empty.
# ============================================================

# Verb prefixes that signal a weak/filler headline. M-050 rewrites anything
# starting with these — they describe the act of posting rather than the news.
# M-056: expanded to catch leading filler verbs the user explicitly flagged:
# "Affirms calls stresses demands" was a real shipped headline that slipped
# the original regex (affirms/calls/demands weren't in the list). Plus other
# generic news-verbs that show up as Elon-reaction filler (urges/vows/
# proposes/etc). Each pattern keeps its inflections.
_TIGHTEN_FILLER_PREFIXES = re.compile(
    r'^\s*('
    r'clarif(?:ies|y|ied)|defend(?:s|ed|ing)?|note(?:s|d)?(?:\s+that)?|'
    r'point(?:s|ed)?\s+(?:to|out)|correct(?:s|ed|ing)?|comment(?:s|ed|ing)?(?:\s+on)?|'
    r'discuss(?:es|ed|ing)?|react(?:s|ed|ing)?(?:\s+to)?|mention(?:s|ed|ing)?|'
    r'address(?:es|ed|ing)?|acknowledge(?:s|d|ing)?|talk(?:s|ed|ing)?\s+about|'
    r'agree(?:s|d|ing)?(?:\s+(?:with|on|that))?|repl(?:ies|ying|ied)\s+to|'
    r'respond(?:s|ed|ing)?\s+to|express(?:es|ed|ing)?|share(?:s|d|ing)?|'
    r'cite(?:s|d|ing)?|reposts?|retweets?|note(?:s)?\s+how|'
    r'highlight(?:s|ed|ing)?|emphasiz(?:es|ed|ing)|stress(?:es|ed|ing)?|'
    r'praises?|criticiz(?:es|ed|ing)|mock(?:s|ed|ing)?|celebrate(?:s|d|ing)?|'
    r'endorse(?:s|d|ing)?|backs?|supports?|confirms?|state(?:s|d)?|says?|'
    r'announce(?:s|d|ing)?|hints?\s+at|teases?|jokes?\s+about|laughs?\s+at|'
    r'weighs?\s+in|chimes?\s+in|reveals?|admits?|insists?|argues?|claims?|'
    r'compares?|equates?|contrasts?|explains?|describes?|'
    # M-056 additions:
    r'affirms?|affirmed|affirming|calls?(?:\s+(?:for|on|out|to))?|'
    r'demand(?:s|ed|ing)?|urge(?:s|d|ing)?|propose(?:s|d|ing)?|'
    r'suggest(?:s|ed|ing)?|push(?:es|ed|ing)?(?:\s+(?:for|back))?|'
    r'voice(?:s|d|ing)?|vow(?:s|ed|ing)?|pledge(?:s|d|ing)?|'
    r'thank(?:s|ed|ing)?|congratulate(?:s|d|ing)?|decries?|denounce(?:s|d|ing)?|'
    r'condemn(?:s|ed|ing)?|threaten(?:s|ed|ing)?|warn(?:s|ed|ing)?(?:\s+against)?|'
    r'hails?|salutes?|honors?|remembers?|recalls?|recounts?|raises?(?:\s+concerns?)?|'
    r'offer(?:s|ed|ing)?|deny(?:ing)?|denies|denied'
    r')\b',
    re.IGNORECASE
)


def tighten_headline(current_headline, body='', parent_text=None, parent_handle=None):
    """M-050: rewrite a headline to tightest AP-newspaper style.

    Returns the rewritten string, or the original if the rewrite failed or
    didn't improve. Skips xAI call entirely if the headline is already short
    and lacks a filler prefix (fast path)."""
    if not current_headline:
        return current_headline
    cur = current_headline.strip()
    if not cur:
        return current_headline
    # Fast path: already-tight headlines (short + strong verb) don't need a call.
    already_tight = len(cur) <= 55 and not _TIGHTEN_FILLER_PREFIXES.match(cur)
    if already_tight:
        return cur
    parent_block = ''
    if parent_text and parent_text.strip():
        ph = parent_handle or '?'
        parent_block = (
            f"\nThis post is a reply/QT to {ph} who said: {parent_text[:280]!r}\n"
            f"Use the PARENT's content as the news hook.\n"
        )
    body_snip = (body or '').strip()[:300]
    prompt = (
        f"Rewrite this headline to the tightest possible newspaper headline.\n\n"
        f"Current headline: {cur!r}\n"
        f"Post body: {body_snip!r}{parent_block}\n"
        f"Rules — be ruthless:\n"
        f"- Strong active verb early. NEVER start with filler verbs like:\n"
        f"  Clarifies / Defends / Notes / Points to / Corrects / Comments on /\n"
        f"  Discusses / Reacts / Addresses / Mentions / Expresses / Shares /\n"
        f"  Highlights / Stresses / Praises / Endorses / Confirms / Says /\n"
        f"  Reveals / Admits / Explains / Describes / Agrees with.\n"
        f"- Fewest words possible to convey the ACTUAL news (target: 6-10 words).\n"
        f"- Under 70 characters. One line. AP / NYT front-page style.\n"
        f"- Concrete nouns and specific numbers; no hedging.\n"
        f"- DO NOT start with the poster's name.\n"
        f"- If the original is already as tight as it can be, return it unchanged.\n\n"
        f"Examples of BAD → GOOD rewrites:\n"
        f"  ❌ 'Clarifies separation between Starlink civilian system and Starshield for US military'\n"
        f"  ✅ 'Starlink civilian and Starshield military are separate systems'\n"
        f"  ❌ 'Defends understanding of OpenAI founding challenges'\n"
        f"  ✅ 'Defends OpenAI founding story against critics'\n"
        f"  ❌ 'Points to drone maker not Pentagon for system misuse'\n"
        f"  ✅ 'Drone maker, not Pentagon, misused Starlink in Russia strike'\n"
        f"  ❌ 'Corrects claim about Starshield use by drone company'\n"
        f"  ✅ 'No, Starshield wasn\\'t used in Russia drone strike'\n\n"
        f"Return ONLY a JSON object: {{\"headline\": \"<new tight headline>\"}}.\n"
        f"If the original is genuinely already as tight as possible, return {{}}."
    )
    try:
        result = _xai_call(prompt, timeout=20, max_tokens=200)
    except Exception:
        return cur
    if not result or not result.get('headline'):
        return cur
    new = (result['headline'] or '').strip().strip('"').strip("'").strip()
    # Take only the first line — defends against multi-line responses.
    new = new.splitlines()[0].strip() if new else ''
    if not new:
        return cur
    # Validation: reject rewrites that are equal, longer than original,
    # still start with filler, too short, or too long absolute.
    if new.lower() == cur.lower():
        return cur
    if len(new) > len(cur) + 5:
        # Allow tiny growth (rounding) but not real growth.
        return cur
    if _TIGHTEN_FILLER_PREFIXES.match(new):
        return cur
    if len(new) < 15 or len(new.split()) < 3:
        return cur
    if len(new) > 100:
        return cur
    return new


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
        'pg6', 'recipe', 'science', 'local', 'conspiracy', 'comedy', 'allin', 'follow']


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
    # User mandate 2026-05-23 evening: "for Elon Tab, don't cut off anything
    # where he talks about one of his companies. If he has over a million
    # views on the story, post it. Make the Python code that simple."
    # → No promo filter. Ship every Elon post Grok returned.
    # → QC dedup skips Elon (see _DEDUP_ORDER) so his multi-take threads
    #   on the same topic all show.
    if tab == 'elon':
        elon_kept = list(cleaned)
        # ORDER MATTERS (M-037): fetch parent FIRST so the headline rewriter
        # can use parent context. Otherwise emoji-only replies get headlines
        # like "Reacts with target emoji" instead of describing the actual news.
        import concurrent.futures as _cf_p
        def _enrich_parent(_s):
            # M-042 strengthened: try parent fetch for EVERY Elon post, not just
            # short ones. If the post is original, fetch_parent returns None and
            # we move on. Cost: 9-16 extra xAI calls per cron, ~5s wall time.
            if _s.get('parent_url'):
                return _s
            try:
                parent = fetch_parent(_s.get('url',''))
            except Exception as _e:
                print(f"[elon-parent-warn] @{_s.get('handle','?')}: {_e}", file=sys.stderr)
                return _s
            if parent:
                _s['parent_url'] = parent['parent_url']
                _s['parent_handle'] = parent['parent_handle']
                _s['parent_text'] = parent['parent_text']
                print(f"[elon-parent] @{_s.get('handle','?')} → parent @{parent['parent_handle']}", file=sys.stderr)
            return _s
        if elon_kept:
            with _cf_p.ThreadPoolExecutor(max_workers=6) as _ex:
                elon_kept = list(_ex.map(_enrich_parent, elon_kept))
        # Now rewrite generic headlines using parent context if available.
        # M-039: also trigger rewrite when body is short (<60 chars) — emoji
        # replies and one-liners can't produce a meaningful headline on their
        # own; the rewriter uses parent context. Don't wait for the regex to
        # catch the headline — bias toward trying.
        for s in elon_kept:
            h = (s.get('headline') or '').strip()
            body = (s.get('body') or '').strip()
            needs_rewrite = _is_generic_headline(h) or len(body) < 60
            if needs_rewrite:
                better = fetch_headline_for_post(
                    s.get('url',''), s.get('body',''),
                    parent_text=s.get('parent_text'), parent_handle=s.get('parent_handle'))
                if better:
                    print(f"[elon-headline] rewrote '{h[:40]}' → '{better[:60]}'", file=sys.stderr)
                    s['headline'] = better
        output[tab] = {'stories': [_body_to_text(s) for s in elon_kept],
                       '_candidates': tab_candidates}
        print(f"[elon] {len(elon_kept)} posts (no promo filter, no top_n cap)", file=sys.stderr)
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
        # M-026 fix: pass max_age_hours=999 so apply_hold does NOT pre-filter on
        # 24h. The per-tab age cap loop downstream applies 24h + the 500K-view
        # bypass for late-bloomer viral stories.
        # M-044 fix: sort by RAW VIEWS (not velocity) for World/USA. Velocity
        # returns -1 for stories >24h without views_at_save, dropping big
        # late-bloomer stories to the bottom of the QC dedup queue where they
        # get killed as dupes of lower-view fresher takes. With story_views,
        # the 6.8M @WhiteHouse Trump-Iran story (31h old) wins QC over the
        # 324K @spectatorindex story shipped first because of velocity sort.
        chosen = curation.apply_hold(held_qual, cleaned_qual, top_n=999,
                                     sort_key=curation.story_views,
                                     max_age_hours=999)
        chosen = [s for s in chosen if _wu_qualified(s)]

        # ===== STAGE 2: find Conservative / Democrat (+ optional Independent)
        # perspectives for each chosen story. M-018 mandate: re-fetch every
        # cron, no caching. Missing perspectives never block the story.
        # Parallelize with thread pool — typically 3-6 stories × ~10s each
        # collapses to ~10-15s wall time.
        import concurrent.futures as _cf
        def _enrich_one(_s):
            # M-048: track whether the call ACTUALLY ran vs threw. If xAI is down
            # or out of credits, find_perspectives raises and we should preserve
            # the previous cron's perspectives (carried via apply_hold) rather
            # than wiping them. Only wipe when Stage 2 actually ran and got 0.
            _stage2_ran = True
            try:
                persps = find_perspectives(_s.get('url',''), _s.get('headline',''))
            except Exception as _e:
                print(f"[stage2-warn] {tab}: perspective fetch failed for "
                      f"@{_s.get('handle','?')}: {_e} — keeping previous perspectives if any", file=sys.stderr)
                persps = []
                _stage2_ran = False
            # If the call didn't fire successfully (xAI down) and we already
            # have perspectives from the previous cron, keep them.
            if not _stage2_ran and _s.get('perspectives'):
                print(f"[stage2-preserve] {tab} @{_s.get('handle','?')}: "
                      f"keeping {len(_s.get('perspectives',[]))} previous perspectives",
                      file=sys.stderr)
                return _s

            # M-043: if we got fewer than 2 perspectives, the first pass found a
            # one-sided take and stopped. Fire a targeted follow-up for each
            # MISSING side asking specifically for an opposing critique. Cheap
            # nudge (~1-2 extra xAI calls per story).
            if 0 < len(persps) < 2 and _s.get('views', 0) >= 100_000:
                existing_labels = {p.get('label') for p in persps}
                # Always at minimum try to get an opposing partisan take
                for target in ('Democrat', 'Conservative', 'Independent'):
                    if target in existing_labels: continue
                    if len(persps) >= 2: break
                    try:
                        extra = find_opposing_perspective(
                            _s.get('url',''), _s.get('headline',''), persps, target)
                    except Exception as _e:
                        print(f"[stage2-fallback-warn] {tab}: {_e}", file=sys.stderr)
                        extra = None
                    if extra:
                        persps.append(extra)
                        print(f"[stage2-fallback] {tab} @{_s.get('handle','?')}: "
                              f"added {target} via opposing-view search "
                              f"(@{extra.get('handle','?')} {extra.get('views',0):,}v)",
                              file=sys.stderr)

            if persps:
                _s['perspectives'] = persps
                labels = [p.get('label') for p in persps]
                print(f"[stage2] {tab} @{_s.get('handle','?')}: found {len(persps)} "
                      f"perspectives ({', '.join(labels)})", file=sys.stderr)
            else:
                _s.pop('perspectives', None)
                print(f"[stage2] {tab} @{_s.get('handle','?')}: 0 perspectives "
                      f"(ships as inline-embed block)", file=sys.stderr)
            return _s
        if chosen:
            with _cf.ThreadPoolExecutor(max_workers=6) as _ex:
                chosen = list(_ex.map(_enrich_one, chosen))

        # M-041: NESTED COMMENTS — for each perspective that's a reply, fetch
        # the parent post so the frontend can embed it ABOVE the reply.
        # User mandate 2026-05-24: "nesting comments so we know what context
        # comments like these are speaking to. Otherwise, it's useless."
        # Example: @AdamKinzinger reply "If Foxnews admits it's bad, it's bad"
        # is meaningless without the FoxNews/TreyYingst post embedded above it.
        # Frontend's renderWorldStory already passes parent_url through —
        # this just populates it via fetch_parent.
        def _enrich_persp_parent(_p):
            if not isinstance(_p, dict) or _p.get('parent_url'):
                return _p
            try:
                _parent = fetch_parent(_p.get('url',''))
            except Exception:
                return _p
            if _parent:
                _p['parent_url'] = _parent['parent_url']
                _p['parent_handle'] = _parent['parent_handle']
                _p['parent_text'] = _parent['parent_text']
                print(f"[persp-parent] {tab} {_p.get('label','?')} @{_p.get('handle','?')} "
                      f"→ parent @{_parent['parent_handle']}", file=sys.stderr)
            return _p
        _all_persps = []
        for _cs in chosen:
            for _p in (_cs.get('perspectives', []) or []):
                _all_persps.append(_p)
        if _all_persps:
            with _cf.ThreadPoolExecutor(max_workers=10) as _ex:
                list(_ex.map(_enrich_persp_parent, _all_persps))

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

    # --- M-051 FOLLOW tab: editable handles file, one top post per author, ---
    # ranked by views descending. No QT boost, no perspectives, no per-tab cap,
    # no cross-tab dedup (intentional overlap with elon/allin/world/etc — the
    # whole point is showing the user's people in one place even if they also
    # rank in topical tabs). Just rank Grok's per-handle top-views response.
    if tab == 'follow':
        # M-060 (2026-06-01): user — "On follow page or any page no
        # promotions" (IMG_1668–1669). Filter out marketing/ad posts before
        # ranking. Detection is conservative: only drop posts that contain
        # 2+ strong promo signals OR a single VERY explicit promo phrase.
        # Both the body text and headline are checked.
        _PROMO_STRONG = re.compile(
            r'\b(?:preorder|pre-order|pre[- ]?save|available now|out now|'
            r'shop now|buy now|order now|on sale now|limited time|'
            r'limited edition|use code|promo code|discount code|coupon code|'
            r'link in bio|tap link in bio|swipe up|click the link)\b',
            re.IGNORECASE)
        _PROMO_WEAK = re.compile(
            r'\b(?:available at|drops? today|launches? today|new merch|'
            r'official drop|free shipping|sale ends|exclusive offer|'
            r'subscriber(?:s)? only|early access|membership|subscribe)\b',
            re.IGNORECASE)
        def _is_promo(s):
            if not isinstance(s, dict):
                return False
            blob = ((s.get('body','') or '') + ' ' + (s.get('headline','') or '')).strip()
            if not blob:
                return False
            if _PROMO_STRONG.search(blob):
                return True
            return len(_PROMO_WEAK.findall(blob)) >= 2

        _promo_dropped = 0
        _filtered = []
        for c in cleaned:
            if _is_promo(c):
                _promo_dropped += 1
                continue
            _filtered.append(c)
        cleaned = _filtered

        # Keep at most ONE post per handle (highest-view if Grok returned more).
        _by_handle = {}
        for c in cleaned:
            h = (c.get('handle') or '').lstrip('@').lower()
            if not h: continue
            v = curation.story_views(c)
            if h not in _by_handle or v > curation.story_views(_by_handle[h]):
                _by_handle[h] = c
        follow_chosen = sorted(_by_handle.values(),
                               key=curation.story_views, reverse=True)
        if _promo_dropped:
            print(f"[follow] M-060: dropped {_promo_dropped} promo/ad posts",
                  file=sys.stderr)
        print(f"[follow] {len(follow_chosen)} handles posted in last 24h "
              f"(top: @{(follow_chosen[0].get('handle','?') if follow_chosen else '?')} "
              f"{(curation.story_views(follow_chosen[0]) if follow_chosen else 0):,}v)",
              file=sys.stderr)
        output[tab] = {'stories': [_body_to_text(s) for s in follow_chosen],
                       '_candidates': tab_candidates}
        continue

    # --- All other tabs: Ristretto verbatim with per-tab cap ---
    # MSM bumped to 5 (M-024 — user: "so many choices, low views makes sense").
    _tab_top_n = {'msm': 5}.get(tab, 3)
    chosen = curation.curate(tab, previous.get(tab, []), cleaned, top_n=_tab_top_n)
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
        # Rewrite top-level headline if generic — pass parent context if available
        # so reply/QT posts (Stephen A "Affirming a statement", etc.) get newspaper
        # headlines about the parent's news, not the reaction.
        _h = (_s.get('headline') or '').strip()
        if _is_generic_headline(_h) and _s.get('url'):
            _better = fetch_headline_for_post(
                _s.get('url',''), _s.get('body',''),
                parent_text=_s.get('parent_text'), parent_handle=_s.get('parent_handle'))
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
    # world, usa, top, business, msm, sports, pg6, comedy = 24h default
    # Slower-cadence tabs — loosened so they're not always empty:
    'pods': 48.0,        # podcasters drop clips every 1-3 days
    'allin': 48.0,       # billionaire-podcaster posts often 1-2 day cadence
    'conspiracy': 48.0,  # investigative content takes time to surface
    'recipe': 72.0,      # recipe content has long shelf life, posts less daily
    'science': 72.0,     # research/breakthrough posts spaced out
    'local': 72.0,       # SoCal/OC content sparse on X
    'elon': 48.0,        # M-042: user mandate — show ALL Elon posts/replies/RTs
}
# M-026: BIG-VIEWS AGE EXCEPTION for World + USA.
# User mandate 2026-05-23 evening: late-blooming viral stories (e.g. Barilla
# pasta plant at 1.4M views, 49h old) shouldn't be killed by 24h cap. If a
# story crossed the threshold (500K views) it's clearly viral regardless of
# when it was posted — ship it.
_BIG_VIEW_BYPASS_TABS = {'world', 'usa'}
_BIG_VIEW_BYPASS_FLOOR = 500_000

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
            # M-026: big-views bypass for World/USA only
            _v = int(_s.get('views', 0) or 0)
            if _tab in _BIG_VIEW_BYPASS_TABS and _v >= _BIG_VIEW_BYPASS_FLOOR:
                print(f"[age-cap-bypass] keep {_tab}: '{(_s.get('headline','') or '?')[:50]}' "
                      f"({_v:,} views >= {_BIG_VIEW_BYPASS_FLOOR:,} bypass, age {min(ages):.1f}h)",
                      file=sys.stderr)
                _kept.append(_s)
                continue
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
# Priority (earlier wins): world > usa > business > sports > pg6 ...
# Tabs EXCLUDED from dedup (because their content NATURALLY overlaps):
#   - elon (M-023): his own multi-take threads should all ship
#   - msm  (M-024): mainstream media's whole purpose is covering the same news
#                   that's in World/USA — dedup was emptying the tab
#   - top  (M-052): top tab IS "absolute most-viewed across the platform",
#                   which by definition overlaps with World/USA/Elon. User:
#                   "#1 should be #1 posts, regardless of whether its in
#                   another tab" — same exemption logic as MSM.
#   - follow (M-051): editable handles' top post shown even if it's also
#                   the news of the day in another tab
_DEDUP_ORDER = ['world','usa','business','sports','pg6','science',
                'pods','allin','conspiracy','local','recipe','comedy']
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
    # M-055 (2026-05-27): political names + win/loss verbs appear in nearly
    # every political headline — they shouldn't count as distinctive dedup
    # tokens. Live false-positive: USA #5 'Team Trump thanks Texas after
    # Paxton wins Senate primary' deduped against USA #1 'Trump's 2026
    # endorsement scorecard shows strong wins' on ['trump', 'wins'].
    'trump','biden','harris','obama','clinton','desantis','newsom','paxton',
    'kennedy','sanders','warren','schumer','pelosi','mccarthy','johnson',
    'wins','loses','beats','defeats','endorses','endorsed','wins','victory',
    'primary','primaries','election','elections','elected','president',
    'senate','house','governor','congress','republican','democrat','democratic',
    'republicans','democrats','gop','dem','dems',
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
            # M-014 + M-055: both cross-tab and within-tab now require 3+
            # shared tokens. Within-tab was previously 2, which false-matched
            # unrelated political stories sharing common names/verbs (e.g.
            # 'trump' + 'wins'). Names + win/loss verbs now in the stoplist
            # (M-055), and the threshold-3 keeps the safety even when those
            # words aren't stoplisted. LLM dedup (M-014) is the real same-
            # event backstop.
            min_shared = 3
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

    # Helper: get the actual story dict from output for an item index
    def _story_at(item):
        tab, idx, handle, head = item
        c = output_dict.get(tab, {})
        sts = c.get('stories', []) or []
        if 0 <= idx < len(sts):
            return sts[idx]
        return None
    def _views(item):
        s = _story_at(item)
        try: return int((s.get('views') if s else 0) or 0)
        except: return 0

    to_drop = {}  # (tab, idx_in_tab) -> (kept_label, drop_head, reason)
    promotions = []  # M-045: (kept_tab, kept_idx, replacement_story_dict, dropped_label) — replace small kept story with big dropped story
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
            kept_item, drop_item = items[i], items[j]
        elif b_rank < a_rank:
            kept_item, drop_item = items[j], items[i]
        else:
            kept_item, drop_item = items[i], items[j]

        kept_tab, kept_idx, kept_handle, kept_head = kept_item
        drop_tab, drop_idx, drop_handle, drop_head = drop_item
        kept_views = _views(kept_item)
        drop_views = _views(drop_item)

        # M-045: if the dropped-tab story has SIGNIFICANTLY more views than the
        # kept-tab story, REPLACE the kept-tab story IN-PLACE with the bigger
        # story, and drop the source. Threshold: 2x views AND >=500K.
        if drop_views >= 2 * kept_views and drop_views >= 500_000:
            drop_story = _story_at(drop_item)
            if drop_story:
                promotions.append((kept_tab, kept_idx, drop_story, drop_tab + '/' + drop_handle, reason, drop_views, kept_views))
                # Only drop the SOURCE (drop_tab) — the kept_tab slot gets overwritten in-place
                to_drop[(drop_tab, drop_idx)] = (f"promoted into {kept_tab}",
                                                  drop_head, "M-045 source")
                continue

        drop_key = (drop_tab, drop_idx)
        kept_label = f"{kept_tab}/{kept_handle}"
        if drop_key in to_drop: continue
        to_drop[drop_key] = (kept_label, drop_head, reason)

    # Apply M-045 promotions FIRST (overwrite small kept-tab story with big
    # dropped-tab story). drops happen AFTER, removing only the source.
    for kept_tab, kept_idx, new_story, source_label, reason, drop_v, kept_v in promotions:
        c = output_dict.get(kept_tab, {})
        sts = c.get('stories', []) or []
        if 0 <= kept_idx < len(sts):
            print(f"[qc-llm-promote] {kept_tab}[{kept_idx}]: replaced ({kept_v:,}v) "
                  f"with {source_label} ({drop_v:,}v) — {reason}", file=sys.stderr)
            sts[kept_idx] = new_story
        c['stories'] = sts

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

# ============================================================
# M-021: HONESTY SCORING PASS — runs LAST, never affects selection.
# Score every shipped story + every shipped perspective in news tabs.
# Parallelized via thread pool. Entertainment tabs (NO_HONESTY) skipped
# on the frontend anyway so no point scoring them.
# ============================================================
_HONESTY_NEWS_TABS = ['world','usa','top','msm','business','sports','pods','pg6',
                      'science','local','conspiracy','allin','follow']
import concurrent.futures as _cf_honesty

_score_jobs = []  # list of (target_dict,) for each thing to score
for _h_tab in _HONESTY_NEWS_TABS:
    _h_container = output.get(_h_tab, {})
    if not isinstance(_h_container, dict): continue
    for _h_story in _h_container.get('stories', []) or []:
        if not _h_story.get('url'): continue
        _score_jobs.append(_h_story)
        for _h_p in _h_story.get('perspectives', []) or []:
            if isinstance(_h_p, dict) and _h_p.get('url'):
                _score_jobs.append(_h_p)

def _score_one(item):
    s = score_honesty(item.get('url',''), item.get('body',''), item.get('headline',''))
    item['honesty'] = s.get('honesty')
    item['notes'] = s.get('notes', '')
    return item

if _score_jobs:
    print(f"[honesty-score] scoring {len(_score_jobs)} items in parallel...", file=sys.stderr)
    with _cf_honesty.ThreadPoolExecutor(max_workers=10) as _ex:
        list(_ex.map(_score_one, _score_jobs))
    _scored = sum(1 for j in _score_jobs if j.get('honesty'))
    print(f"[honesty-score] {_scored}/{len(_score_jobs)} items got valid 1-10 scores", file=sys.stderr)

# M-028: Drop PERSPECTIVES with honesty < 5 (serial misrep / conspiracy).
# Stories themselves are picked by views and never dropped on honesty.
# User mandate 2026-05-23 evening: "honesty 3 is that even news?" — a Tara
# Dublin reply got scored 3 (personal attack on Modi/Rubio with no facts);
# user correctly flagged it as not-news. Threshold of 5 keeps anything
# "demonstrably false" and up, drops conspiracy/serial-misrep only.
_PERSP_HONESTY_FLOOR = 5  # 7→5 on 2026-05-23 night: 7 was killing legit Democrat takes on USA stories (no Dem perspective on Khalil deportation). 5 drops conspiracy/serial-misrep (≤4) but keeps partisan reactions even if they make "specific misleading claims" or "demonstrably false statements" — those still represent a real political angle. The 80-char body min + vulgar-attack auto-reject in the Stage 2 prompt are the actual quality controls.
for _h_tab in _HONESTY_NEWS_TABS:
    _h_container = output.get(_h_tab, {})
    if not isinstance(_h_container, dict): continue
    for _h_story in _h_container.get('stories', []) or []:
        _persps = _h_story.get('perspectives', []) or []
        if not _persps: continue
        _persps_kept = []
        for _p in _persps:
            if not isinstance(_p, dict):
                continue
            _ph = _p.get('honesty')
            if _ph is not None and isinstance(_ph, (int, float)) and _ph < _PERSP_HONESTY_FLOOR:
                print(f"[honesty-floor] drop perspective in {_h_tab}: @{_p.get('handle','?')} "
                      f"({_p.get('label','?')}, honesty={_ph}) — '{(_p.get('body','') or '')[:60]}'",
                      file=sys.stderr)
                continue
            _persps_kept.append(_p)
        _h_story['perspectives'] = _persps_kept


# ---- M-025 + M-059: Translate non-English bodies instead of dropping ----
# M-025 (2026-05-23): "dont post anything not translated" — original
# implementation dropped non-English stories outright.
# M-059 (2026-06-01): "No foreign language allowed please translate"
# (IMG_1674) — user wants translation, not deletion. The frontend already
# renders a `translation` field above the embed (see renderAutoEmbedBlock
# and renderWorldStory). So now we translate via xAI and keep the story.
# Falls back to drop ONLY if the translation call fails or returns garbage.
def _translate_to_english(text):
    if not text or len(text.strip()) < 4:
        return None
    snippet = text.strip()[:600]
    prompt = (
        f"Translate this X post to English. Return ONLY a JSON object with one key:\n"
        f'{{"translation": "<the English translation, ≤500 chars, preserve meaning>"}}\n\n'
        f"If the text is ALREADY in English, return {{}}. If it's untranslatable "
        f"(pure emoji, single symbol, etc.), return {{}}.\n\n"
        f"Post text:\n{snippet!r}"
    )
    try:
        result = _xai_call(prompt, timeout=20, max_tokens=400)
    except Exception:
        return None
    if not isinstance(result, dict):
        return None
    t = (result.get('translation') or '').strip()
    if not t or len(t) < 4:
        return None
    return t[:500]

import concurrent.futures as _cf_translate

# Gather every non-English block (story body OR perspective body) into a job
# list, translate in parallel, then write back. Dropping only happens if the
# translation comes back empty AND the body has < 8 substantive chars of
# Latin-script content (so a single emoji '😂' still drops).
_translate_jobs = []  # list of (target_dict, source_text_key)

for _l_tab, _l_container in list(output.items()):
    if not isinstance(_l_container, dict): continue
    for _l_s in _l_container.get('stories', []) or []:
        if not isinstance(_l_s, dict): continue
        _body = _l_s.get('body') or ''
        if _is_non_english(_body) and not _l_s.get('translation'):
            _translate_jobs.append((_l_s, _body, _l_tab, 'story',
                                    _l_s.get('handle','?'),
                                    _l_s.get('headline','')[:50]))
        for _l_p in _l_s.get('perspectives', []) or []:
            if not isinstance(_l_p, dict): continue
            _pb = _l_p.get('body') or _l_p.get('text') or ''
            if _is_non_english(_pb) and not _l_p.get('translation'):
                _translate_jobs.append((_l_p, _pb, _l_tab, 'perspective',
                                        _l_p.get('handle','?'),
                                        _l_p.get('label','?')))

def _translate_one(job):
    target, src, tab, kind, handle, label = job
    t = _translate_to_english(src)
    return target, t, tab, kind, handle, label

_translated_n = 0
_dropped_n = 0
if _translate_jobs:
    print(f"[m059] M-059: translating {len(_translate_jobs)} non-English bodies...",
          file=sys.stderr)
    with _cf_translate.ThreadPoolExecutor(max_workers=6) as _ex:
        _results = list(_ex.map(_translate_one, _translate_jobs))
    for target, t, tab, kind, handle, label in _results:
        if t:
            target['translation'] = t
            _translated_n += 1
            print(f"[m059] translated {kind} {tab}/@{handle} ({label[:40]!r})",
                  file=sys.stderr)
        else:
            # Could not translate — fall back to drop. Mark target for removal
            # by setting an attribute we sweep below.
            target['__m059_drop__'] = True
            _dropped_n += 1
            print(f"[m059-drop] {kind} {tab}/@{handle}: untranslatable",
                  file=sys.stderr)

# Sweep: remove anything tagged for drop
if _dropped_n:
    for _l_tab, _l_container in list(output.items()):
        if not isinstance(_l_container, dict): continue
        _kept_s = []
        for _l_s in _l_container.get('stories', []) or []:
            if not isinstance(_l_s, dict): continue
            if _l_s.get('__m059_drop__'):
                continue
            _kept_p = [
                _p for _p in (_l_s.get('perspectives') or [])
                if isinstance(_p, dict) and not _p.get('__m059_drop__')
            ]
            if _kept_p:
                _l_s['perspectives'] = _kept_p
            elif _l_s.get('perspectives'):
                _l_s.pop('perspectives', None)
            _kept_s.append(_l_s)
        _l_container['stories'] = _kept_s

if _translated_n or _dropped_n:
    print(f"[m059] M-059: translated {_translated_n}, dropped untranslatable {_dropped_n}",
          file=sys.stderr)


# M-033: Restore EARLIER tab population (regression from Ristretto migration).
# User mandate 2026-05-23 night: "Why doesn't the earlier tab work anymore?
# You might have to go back to the expresso before you put Restratto in.
# You probably wiped it out during that refresh."
# For each tab: stories that were in the PREVIOUS stories.json's `stories`
# array but got displaced this cron go into `earlier`. Cap at 10. Drops items
# older than 24h to keep "earlier today" actually about today.
import re as _re_earlier
def _url_age_h_earlier(url):
    m = _re_earlier.search(r'/status/(\d+)', url or '')
    if not m: return None
    try:
        ts = (int(m.group(1)) >> 22) + 1288834974657
        return (datetime.datetime.now() - datetime.datetime.fromtimestamp(ts/1000)).total_seconds()/3600
    except: return None

for _e_tab, _e_container in list(output.items()):
    if not isinstance(_e_container, dict): continue
    if _e_tab in ('freespeech', 'submit', 'follow_suggest'): continue  # user-managed
    _e_current_urls = {s.get('url') for s in (_e_container.get('stories', []) or []) if s.get('url')}
    _e_prev = previous.get(_e_tab, []) or []
    _e_displaced = []
    for _e_p in _e_prev:
        if not isinstance(_e_p, dict): continue
        _e_url = _e_p.get('url', '')
        if not _e_url or _e_url in _e_current_urls: continue
        # Same-day freshness: skip if older than 24h
        _e_age = _url_age_h_earlier(_e_url)
        if _e_age is not None and _e_age > 24: continue
        _e_displaced.append(_e_p)
        if len(_e_displaced) >= 10: break
    _e_container['earlier'] = _e_displaced


# M-040: HALLUCINATION GUARD — verify every shipped URL via X's oEmbed API.
# Drops stories where the handle in the URL doesn't match the actual tweet
# author (Grok pairs real text with wrong status ID sometimes — user caught
# Jan 6 story embedding @edward_bernayz's Azealia Banks tweet).
# Parallelized; ~10 API calls per cron is cheap, ~1-2s wall time.
import concurrent.futures as _cf_oembed
def _verify_one(item):
    item['_url_verified'] = verify_url_handle(item.get('url',''))
    return item

_verify_jobs = []
_verify_news_tabs = ['world','usa','top','msm','business','sports','elon','pods','pg6',
                     'recipe','science','local','conspiracy','comedy','allin','follow']
for _v_tab in _verify_news_tabs:
    _v_container = output.get(_v_tab, {})
    if not isinstance(_v_container, dict): continue
    for _v_story in _v_container.get('stories', []) or []:
        if _v_story.get('url'): _verify_jobs.append(_v_story)
        for _v_p in _v_story.get('perspectives', []) or []:
            if isinstance(_v_p, dict) and _v_p.get('url'):
                _verify_jobs.append(_v_p)

if _verify_jobs:
    print(f'[oembed-verify] checking {len(_verify_jobs)} URLs against X oEmbed API...', file=sys.stderr)
    with _cf_oembed.ThreadPoolExecutor(max_workers=10) as _ex:
        list(_ex.map(_verify_one, _verify_jobs))

# Drop stories that failed verification (and their perspectives along with them).
# Also drop individual perspectives that failed even if the story is valid.
for _v_tab in _verify_news_tabs:
    _v_container = output.get(_v_tab, {})
    if not isinstance(_v_container, dict): continue
    _sts = _v_container.get('stories', []) or []
    _kept = []
    for _v_story in _sts:
        if not _v_story.pop('_url_verified', False):
            print(f"[oembed-drop] {_v_tab}: '{(_v_story.get('headline','') or '?')[:55]}' — URL handle mismatch or unresolvable", file=sys.stderr)
            continue
        # Drop bad perspectives
        _filtered_persps = []
        for _v_p in _v_story.get('perspectives', []) or []:
            if isinstance(_v_p, dict) and _v_p.pop('_url_verified', False):
                _filtered_persps.append(_v_p)
            elif isinstance(_v_p, dict):
                print(f"[oembed-drop] {_v_tab} persp: @{_v_p.get('handle','?')} — URL handle mismatch", file=sys.stderr)
        if 'perspectives' in _v_story:
            _v_story['perspectives'] = _filtered_persps
        _kept.append(_v_story)
    _v_container['stories'] = _kept

# M-046: POST-OEMBED PERSPECTIVE BACKFILL.
# When oEmbed dropped a perspective and the story is now <2 perspectives AND
# views >= 100K, re-fire the M-043 opposing-view fallback for the missing label.
# Without this, hallucinated Democrat perspectives leave World/USA stories
# showing only the Conservative side (or vice versa). Story-level oEmbed kills
# of the parent story aren't recovered — those are correct drops.
import concurrent.futures as _cf_refill
def _refill_one(_args):
    _r_tab, _r_story = _args
    # M-058 (2026-05-31): user — "Can't send this partisan without counter
    # comment even if few views. Just find counter with most views." The old
    # 100K view threshold meant low-view World/USA stories shipped one-sided.
    # Now we attempt a backfill on every World/USA story with <2 perspectives,
    # regardless of view count. find_opposing_perspective drops its own floor
    # to 100 views (was 1K) when called from this pass to make the search
    # actually return something for sparse stories.
    persps = _r_story.get('perspectives', []) or []
    if len(persps) >= 2:
        return _r_tab, _r_story
    existing_labels = {p.get('label') for p in persps if isinstance(p, dict)}
    for target in ('Democrat', 'Conservative', 'Independent'):
        if target in existing_labels: continue
        if len(persps) >= 2: break
        try:
            # M-058: drop the floor to 100 views so sparse low-view World/USA
            # stories still get a counter-perspective.
            extra = find_opposing_perspective(
                _r_story.get('url',''), _r_story.get('headline',''),
                persps, target, min_views=100)
        except Exception as _e:
            print(f"[oembed-refill-warn] {_r_tab}: {_e}", file=sys.stderr)
            extra = None
        if extra:
            # Verify the refill URL too — don't re-introduce the hallucination problem
            try:
                if verify_url_handle(extra.get('url','')):
                    persps.append(extra)
                    print(f"[oembed-refill] {_r_tab} @{_r_story.get('handle','?')}: "
                          f"backfilled {target} after oEmbed drop "
                          f"(@{extra.get('handle','?')} {extra.get('views',0):,}v)",
                          file=sys.stderr)
                else:
                    print(f"[oembed-refill-warn] {_r_tab}: refill candidate @{extra.get('handle','?')} "
                          f"also hallucinated, skipping", file=sys.stderr)
            except Exception:
                pass
    _r_story['perspectives'] = persps
    return _r_tab, _r_story

_refill_jobs = []
for _v_tab in ('world','usa'):  # only World/USA care about perspective balance
    _v_container = output.get(_v_tab, {})
    if not isinstance(_v_container, dict): continue
    for _v_story in _v_container.get('stories', []) or []:
        # M-058: removed the views >= 100K filter (was preventing low-view
        # partisan stories like @MarioNawfal 66K from ever getting a
        # counter-perspective). The user explicitly mandated: "Can't send
        # this partisan without counter comment even if few views."
        if len(_v_story.get('perspectives',[]) or []) < 2:
            _refill_jobs.append((_v_tab, _v_story))

if _refill_jobs:
    print(f'[oembed-refill] {len(_refill_jobs)} stories qualify for post-oEmbed perspective backfill', file=sys.stderr)
    with _cf_refill.ThreadPoolExecutor(max_workers=4) as _ex:
        list(_ex.map(_refill_one, _refill_jobs))


# ---- M-063 PARTISAN-WITHOUT-COUNTER DROP ----
# User mandate 2026-06-01: "Story worth number two story on the site is
# pure biased and doesn't even have a counteracting story on the other
# side. My kindergarten wouldn't do this, let alone AI." (re: @MarioNawfal
# Trump-Ukraine 66K views, World #2, 0 perspectives — M-058 backfill
# couldn't find a counter).
# Policy: if a World/USA story has <2 perspectives AFTER all backfill
# attempts AND its headline contains political-trigger words, drop the
# story. Better to ship 4 balanced stories than 5 with a one-sided take.
_M063_POLITICAL_TRIGGERS = re.compile(
    r'\b(?:'
    # Politicians and family
    r'trump|biden|harris|obama|clinton|desantis|newsom|paxton|vance|'
    r'sanders|warren|schumer|pelosi|mccarthy|johnson|kennedy|warnock|'
    r'pence|rfk|ramaswamy|haley|christie|aoc|cruz|hawley|cotton|'
    # Conflicts / hot-button countries
    r'ukraine|russia|putin|zelensky|zelenskyy|iran|israel|hamas|gaza|'
    r'palestine|palestinian|china|taiwan|nato|brics|'
    # Domestic political topics
    r'antifa|maga|woke|wokeness|gop|dems?|democrat(?:ic)?|republican(?:s)?|'
    r'liberal(?:s)?|conservative(?:s)?|leftist(?:s)?|right-?wing|'
    r'election(?:s)?|primary|primaries|impeach(?:ment)?|'
    r'abortion|second amendment|2a|deep state|globalist(?:s)?|'
    # Government bodies (only when paired with another trigger via OR)
    r'white house|senate|congress|supreme court|scotus|ice\b|doge|fbi'
    r')\b',
    re.IGNORECASE)
def _is_political(s):
    if not isinstance(s, dict):
        return False
    blob = ((s.get('headline','') or '') + ' ' + (s.get('body','') or '')).lower()
    return bool(_M063_POLITICAL_TRIGGERS.search(blob))

_m063_dropped = 0
for _wu_tab in ('world', 'usa'):
    _wu_container = output.get(_wu_tab, {})
    if not isinstance(_wu_container, dict):
        continue
    _wu_kept = []
    for _wu_s in _wu_container.get('stories', []) or []:
        _n_persps = len(_wu_s.get('perspectives', []) or [])
        if _n_persps < 2 and _is_political(_wu_s):
            _m063_dropped += 1
            print(f"[m063-drop] {_wu_tab} @{_wu_s.get('handle','?')} "
                  f"{(_wu_s.get('headline','') or '')[:50]!r}: "
                  f"partisan story with {_n_persps} perspectives "
                  f"(needs 2+ for balance)", file=sys.stderr)
            continue
        _wu_kept.append(_wu_s)
    _wu_container['stories'] = _wu_kept
if _m063_dropped:
    print(f"[m063] M-063: dropped {_m063_dropped} partisan one-sided World/USA stories", file=sys.stderr)


# ---- Preserve user-managed tabs (freespeech only — submit now cron-managed) ----
# 'submit' was previously preserved from existing_full, but M-038 moves it to
# cron-pull from Netlify Forms (24h public window). Removed from this loop so
# the cron-pulled submissions don't get clobbered by the previous deploy's data.
for manual_tab in ('freespeech',):
    if manual_tab in existing_full and isinstance(existing_full[manual_tab], dict):
        output[manual_tab] = existing_full[manual_tab]

# M-038: Reader Post/Replace submissions — 24h public window. After 24h the
# submission falls off the public list but stays in the submitter's localStorage
# forever (frontend already handles that side independently).
_subs = pull_netlify_submissions()
output['submit'] = {'stories': _subs, 'earlier': []}

# M-051: pull visitor follow-handle suggestions from same Netlify Forms API.
# These do NOT auto-add to follow_handles.json — owner reviews + appends manually.
_follow_subs = pull_follow_suggestions()
output['follow_suggest'] = {'suggestions': _follow_subs}


# ---- M-049 scrubber: strip broken parent_url placeholders BEFORE writing ----
# Carry-overs from prior crons (via apply_hold) may still contain the old
# 'https://x.com/unknown/status/unknown' / '@unknown' template-echo garbage.
# Even though fetch_parent now rejects those, any record that already shipped
# with them needs to be cleaned. Otherwise the next deploy reships the
# placeholder embeds. The new fetch_parent will repopulate real values on the
# next cron; until then, the frontend just doesn't render a parent block,
# which is the correct degraded state.
def _scrub_broken_parent(obj):
    pu = (obj.get('parent_url') or '').lower()
    ph = (obj.get('parent_handle') or '').lower()
    if not pu and not ph: return False
    if ('unknown' in pu or '<' in pu or '>' in pu or 'example.com' in pu
            or 'placeholder' in pu or ph in ('@unknown', '@<handle>', '<handle>', 'unknown')):
        obj.pop('parent_url', None)
        obj.pop('parent_handle', None)
        obj.pop('parent_text', None)
        return True
    return False

_scrub_n = 0
for _tab_key, _tab_val in output.items():
    if not isinstance(_tab_val, dict): continue
    for _s in (_tab_val.get('stories') or []):
        if not isinstance(_s, dict): continue
        if _scrub_broken_parent(_s):
            _scrub_n += 1
            print(f"[parent-scrub] {_tab_key} @{_s.get('handle','?')}: removed placeholder parent_url", file=sys.stderr)
        for _p in (_s.get('perspectives') or []):
            if isinstance(_p, dict) and _scrub_broken_parent(_p):
                _scrub_n += 1
                print(f"[parent-scrub] {_tab_key} persp @{_p.get('handle','?')}: removed placeholder parent_url", file=sys.stderr)
if _scrub_n:
    print(f"[parent-scrub] M-049: cleaned {_scrub_n} broken parent_url placeholders", file=sys.stderr)


# ---- M-053 NORMALIZER: ensure every perspective has text=body ----
# Perspectives added AFTER the per-tab loop's _body_to_text pass (M-046
# oembed-refill, M-043 opposing-view fallback) ship with body but no text
# field. Frontend renderWorldStory falls back to "View post" when text is
# empty. Copy body→text wherever text is missing, idempotently.
for _norm_tab, _norm_val in output.items():
    if not isinstance(_norm_val, dict): continue
    for _norm_s in (_norm_val.get('stories') or []):
        if not isinstance(_norm_s, dict): continue
        for _norm_p in (_norm_s.get('perspectives') or []):
            if not isinstance(_norm_p, dict): continue
            if not (_norm_p.get('text') or '').strip() and (_norm_p.get('body') or '').strip():
                _norm_p['text'] = _norm_p['body']


# ---- M-053 EMPTY-BLOCK GATE + M-057 IMAGE-ONLY STORY GATE ----
# M-053 (2026-05-27): never ship blocks that would render as bare "View post"
# (renderWorldStory and renderAutoEmbedBlock fall back to that string when
# headline/body are both empty).
#
# M-057 (2026-05-31): user — "no tweets like this please on the follow page
# ... eliminate anything like this that has no content. That's just a
# picture." Original 8-char threshold passed image-only posts because their
# engagement field had text ("100K views") even when there was no real text
# to read. Tighter rules now:
#   * Engagement no longer counts as content (just a metric).
#   * URLs are stripped before measuring length (so "https://x.com/long…"
#     captions don't masquerade as substance).
#   * STORIES need ≥ 12 substantive chars in headline OR body. Below that
#     the block has no informational value — it's just a photo.
#   * PERSPECTIVES keep the looser 3-char floor — emoji-only reactions like
#     "💯" or "True" are still meaningful as a signal of agreement.
_URL_RE_M057 = re.compile(r'https?://\S+', re.IGNORECASE)
def _substantive_text(s):
    if not isinstance(s, str): return ''
    return re.sub(r'\s+', ' ', _URL_RE_M057.sub('', s)).strip()

def _story_has_content(obj):
    if not isinstance(obj, dict):
        return False
    headline = _substantive_text(obj.get('headline') or '')
    body = _substantive_text(obj.get('body') or obj.get('text') or '')
    return len(headline) >= 12 or len(body) >= 12

# M-062 (2026-06-01): perspectives whose body is just a query to the @grok
# X account (e.g. "@grok what is Senator Warnock's net worth?") are not
# opinions or critiques — they're prompts to an AI. Drop them from
# perspective slots. User: "Where is Gaurav's reply?" / "Referring to
# what?" (cron #44 screenshots) — these @grok queries fooled the pipeline
# into shipping them as Conservative/Democrat takes.
_GROK_QUERY_RE = re.compile(r'^\s*@grok\b.*\?', re.IGNORECASE | re.DOTALL)

def _perspective_has_content(obj):
    if not isinstance(obj, dict):
        return False
    headline = _substantive_text(obj.get('headline') or '')
    body = _substantive_text(obj.get('body') or obj.get('text') or '')
    raw_body = (obj.get('body') or obj.get('text') or '').strip()
    # M-062: kill @grok-query perspectives — they're not stances.
    if _GROK_QUERY_RE.match(raw_body):
        return False
    return len(headline) >= 3 or len(body) >= 3

# Back-compat alias still used by older call sites (e.g. mandate audit string)
def _block_has_content(obj):
    return _story_has_content(obj)

_drop_stories = 0
_drop_persps = 0
for _tab_key, _tab_val in output.items():
    if not isinstance(_tab_val, dict): continue
    stories = _tab_val.get('stories')
    if not isinstance(stories, list): continue
    _kept_stories = []
    for _s in stories:
        if not isinstance(_s, dict): continue
        if not _story_has_content(_s):
            _drop_stories += 1
            print(f"[m053-drop-story] {_tab_key} @{_s.get('handle','?')}: "
                  f"no substantive text (image-only?)", file=sys.stderr)
            continue
        persps = _s.get('perspectives') or []
        if persps:
            _kept_p = []
            for _p in persps:
                if _perspective_has_content(_p):
                    _kept_p.append(_p)
                else:
                    _drop_persps += 1
                    print(f"[m053-drop-persp] {_tab_key} @{_s.get('handle','?')} "
                          f"{_p.get('label','?')} @{_p.get('handle','?')}: "
                          f"empty body/headline", file=sys.stderr)
            if _kept_p:
                _s['perspectives'] = _kept_p
            else:
                _s.pop('perspectives', None)
        _kept_stories.append(_s)
    _tab_val['stories'] = _kept_stories
if _drop_stories or _drop_persps:
    print(f"[m053] M-053+M-057: dropped {_drop_stories} content-less stories, "
          f"{_drop_persps} empty perspectives", file=sys.stderr)


# ---- M-054 TOP TAB GLOBAL LEADERBOARD ----
# User mandate 2026-05-27: "these cant be top storries < 1M views, no way"
# (cron #41 Top showed only A24 at 916K while Elon-tab had 38M-view posts).
# Grok's call_grok_top_multi is biased toward entertainment/K-pop accounts and
# misses political/news/Elon mega-virals. Per M-052 Top is exempt from cross-
# tab dedup, so the same story can appear in BOTH Top AND its categorical tab.
# Make Top = global leaderboard of top-N viewed stories across all news tabs,
# merged with Grok's own Top candidates so we don't lose unique entertainment
# content the news tabs miss.
def _top_views_of(s):
    try:
        return int(s.get('views', 0) or 0)
    except (TypeError, ValueError):
        return 0

_M054_SOURCE_TABS = ('world', 'usa', 'business', 'msm', 'sports', 'elon',
                     'follow', 'pods', 'science', 'allin', 'comedy', 'pg6')
_M054_TARGET_COUNT = 5
_M054_VIEW_FLOORS = (1_000_000, 500_000, 250_000)  # try tightest first, fall back

_existing_top = (output.get('top', {}) or {}).get('stories', []) or []
_global_pool = list(_existing_top)
for _src_tab in _M054_SOURCE_TABS:
    _src_stories = (output.get(_src_tab, {}) or {}).get('stories', []) or []
    for _src_s in _src_stories:
        if not isinstance(_src_s, dict):
            continue
        _global_pool.append(dict(_src_s))  # shallow copy — Top owns its slot
# Dedupe by URL, keeping the first occurrence (which is Top's own pick if present)
_seen_urls = set()
_deduped_pool = []
for _gp in _global_pool:
    _u = _gp.get('url') or ''
    if _u and _u in _seen_urls:
        continue
    _seen_urls.add(_u)
    _deduped_pool.append(_gp)
_deduped_pool.sort(key=_top_views_of, reverse=True)
# M-064 (2026-06-01): NEVER fall through to "top-N regardless of views"
# — that's how 2K-view trash got into Top (user: "2,000 views is the top
# video on X? Come on."). Walk the floors top-down; the first floor that
# yields ANY stories wins, even if fewer than TARGET_COUNT. Showing 3
# legit mega-viral posts beats padding to 5 with K-pop low-view fillers.
_picked_top = []
_chosen_floor = None
for _floor in _M054_VIEW_FLOORS:
    _candidates_at_floor = [s for s in _deduped_pool if _top_views_of(s) >= _floor]
    if _candidates_at_floor:
        _picked_top = _candidates_at_floor[:_M054_TARGET_COUNT]
        _chosen_floor = _floor
        if len(_picked_top) >= _M054_TARGET_COUNT:
            break
        # Otherwise fall through to next-lower floor to see if we can fill more,
        # BUT only if the next floor strictly improves — never accept stories
        # below the lowest configured floor.

# If even at the lowest configured floor we have nothing, Top tab ships empty
# rather than garbage. This is the "shitshow stops" guard.
if _picked_top:
    print(f"[m054] Top tab populated with {len(_picked_top)} global-leaderboard "
          f"stories at floor {_chosen_floor:,} views (pool size {len(_deduped_pool)})",
          file=sys.stderr)
else:
    print(f"[m054] Top tab EMPTY this cron — no story across any tab cleared the "
          f"lowest configured floor ({_M054_VIEW_FLOORS[-1]:,} views). "
          f"Pool size {len(_deduped_pool)}. Shipping empty rather than garbage.",
          file=sys.stderr)
if _picked_top:
    output.setdefault('top', {})['stories'] = _picked_top
    for _pt in _picked_top:
        print(f"  [m054-top] {_top_views_of(_pt):>12,}v @{_pt.get('handle','?')} "
              f"{(_pt.get('headline','') or _pt.get('body','') or '?')[:60]}",
              file=sys.stderr)


# ---- M-050 FINAL HEADLINE TIGHTENING PASS ----
# Last editing step before write. Every story on every tab gets its headline
# rewritten to AP-newspaper tightness. Parent context is passed through so the
# tightener can rewrite emoji-reply headlines using the parent's news instead
# of the reaction. Skips perspectives — those render verbatim, not as headlines.
# Parallelized with ThreadPoolExecutor; ~30-60s wall-time for a full cron.
import concurrent.futures as _cf_tighten

_tighten_jobs = []  # list of (story_dict, current_headline, body, parent_text, parent_handle)
for _tab_key, _tab_val in output.items():
    if _tab_key in ('earlier', 'submit', 'lastUpdated', 'follow_suggest'):
        continue
    if not isinstance(_tab_val, dict):
        continue
    for _s in (_tab_val.get('stories') or []):
        if not isinstance(_s, dict):
            continue
        _hl = _s.get('headline') or ''
        if not _hl:
            continue
        _tighten_jobs.append((_tab_key, _s, _hl,
                              _s.get('body') or _s.get('text') or '',
                              _s.get('parent_text'),
                              _s.get('parent_handle')))

def _tighten_one(job):
    _tab, _s, _hl, _body, _pt, _ph = job
    try:
        new_hl = tighten_headline(_hl, _body, _pt, _ph)
    except Exception as _e:
        return (_tab, _hl, _hl, str(_e))
    return (_tab, _hl, new_hl, None)

if _tighten_jobs:
    print(f"[tighten] M-050: rewriting {len(_tighten_jobs)} headlines for AP-newspaper tightness...", file=sys.stderr)
    _tighten_changed = 0
    _tighten_skipped = 0
    with _cf_tighten.ThreadPoolExecutor(max_workers=10) as _ex:
        _results = list(_ex.map(_tighten_one, _tighten_jobs))
    # Apply rewrites in second pass so the map doesn't mutate while iterating.
    for (_, _s, _, _, _, _), (_tab, _orig, _new, _err) in zip(_tighten_jobs, _results):
        if _err:
            print(f"[tighten-warn] {_tab}: {_err}", file=sys.stderr)
            continue
        if _new and _new != _orig:
            _s['headline'] = _new
            _tighten_changed += 1
            print(f"[tighten] {_tab}: {_orig!r} -> {_new!r}", file=sys.stderr)
        else:
            _tighten_skipped += 1
    print(f"[tighten] M-050: rewrote {_tighten_changed}, kept {_tighten_skipped} unchanged", file=sys.stderr)


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
    # M-055 fix: previously labeled this catch-all as "same event in
    # another tab" — but qc-dupe also fires within-tab. We can't reliably
    # distinguish here without re-running the dedup logic, so be honest
    # about the ambiguity.
    return '(qc-dropped — within-tab or cross-tab dupe per dedup heuristic)'

_report_lines = []
# M-027: cron_report timestamp in Pacific Time (user mandate 2026-05-23).
# UTC kept inline for traceability with Z suffix, but PT is what humans read.
try:
    from zoneinfo import ZoneInfo as _ZI
    _utc_dt = datetime.datetime.strptime(final['lastUpdated'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    _pt_str = _utc_dt.astimezone(_ZI("America/Los_Angeles")).strftime('%Y-%m-%d %-I:%M %p PT')
    _report_lines.append(f"=== CRON @ {_pt_str}  ({final['lastUpdated']}) ===")
except Exception:
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

# M-031 CORRECTED 2026-05-23: user wants the table. Restored the exact format.
# DO NOT REMOVE — user explicit: "Leave it in the exact form in this table;
# that's what I like; that's what we've been talking about. Leave it."
_report_lines.append("| TAB        | N | Top Views | Age range  | Top Headline                                       |")
_report_lines.append("|------------|---|-----------|------------|----------------------------------------------------|")
for tab in ('world','usa','top','business','msm','sports','elon','follow','pods','pg6',
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
