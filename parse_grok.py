#!/usr/bin/env python3
"""
Parse Grok API response, validate every field, and output clean stories.json data.
If validation fails, exit non-zero so the pipeline keeps the old data.
"""
import sys, json, re, datetime, urllib.parse, subprocess, os

# ---- Freshness check via Twitter snowflake ID ----
MAX_AGE_HOURS = 36  # 36h window — news cycle freshness for time-sensitive tabs
# Per-tab age overrides — evergreen content (personality posts, instructional, recipes,
# podcast clips) holds value beyond 36h. Without these overrides Elon often hits 1-2 stories
# because his hottest posts in any 4-hour window are often 36-48h old.
TAB_AGE_OVERRIDE = {
    'elon': 96,        # Elon's commentary holds value 4 days
    'allin': 72,       # billionaire takes hold ~3 days
    'pods': 96,        # podcast clips evergreen-ish for days
    'science': 168,    # research findings = ~1 week
    'recipe': 336,     # recipes evergreen ~2 weeks
    'golf': 168,       # instructional golf content evergreen
    'comedy': 96,      # standup clips hold for days
    'memes': 72,       # memes have a few days of cycle
    'pg6': 72,         # celebrity gossip holds 3 days
    'freespeech': 8760, # essentially never expires (1 year)
}

# ---- Cross-day dedup: never repeat a story within N hours, across any tab ----
SEEN_FILE = 'seen_history.json'
SEEN_WINDOW_HOURS = 72  # 3 day memory

def _normalize_headline(h):
    stopwords = {'the','a','an','is','are','was','were','to','of','in','on','at','for','and','or','but','with','as','by','from','his','her','its','this','that','will','has','have'}
    words = re.sub(r'[^\w\s]', ' ', h.lower()).split()
    return set(w for w in words if w not in stopwords and len(w) > 2)

def load_seen_history():
    try:
        with open(SEEN_FILE) as f:
            raw = json.load(f)
        cutoff = datetime.datetime.now() - datetime.timedelta(hours=SEEN_WINDOW_HOURS)
        fresh = []
        for entry in raw:
            try:
                ts = datetime.datetime.fromisoformat(entry.get('t', ''))
                if ts > cutoff:
                    fresh.append(entry)
            except Exception:
                pass
        return fresh
    except Exception:
        return []

def save_seen_history(entries):
    try:
        with open(SEEN_FILE, 'w') as f:
            json.dump(entries, f)
    except Exception as e:
        print(f'  save_seen err: {e}', file=sys.stderr)

def is_recently_seen(url, headline, seen):
    """Returns True if the URL exactly matches, or if headline is ≥70% word-overlap with a recent entry."""
    if url:
        for entry in seen:
            if entry.get('url') and entry['url'] == url:
                return ('url', entry.get('headline', '?'))
    norm = _normalize_headline(headline or '')
    # Only reject as "similar" if word overlap is very high (near-duplicate wording, not just same topic)
    if len(norm) >= 4:
        for entry in seen:
            seen_norm = _normalize_headline(entry.get('headline', ''))
            if len(seen_norm) >= 4:
                overlap = len(norm & seen_norm)
                smaller = min(len(norm), len(seen_norm))
                larger = max(len(norm), len(seen_norm))
                # Require >= 85% overlap on the smaller set AND >= 70% on the larger (catches true restatements,
                # not just same-topic stories with new angles)
                if smaller > 0 and overlap / smaller >= 0.85 and overlap / larger >= 0.7:
                    return ('similar', entry.get('headline', '?'))
    return None

SEEN_HISTORY = load_seen_history()
print(f'  Dedup history: {len(SEEN_HISTORY)} entries within {SEEN_WINDOW_HOURS}h', file=sys.stderr)

def url_age_hours(url):
    """Extract post age in hours from Twitter snowflake ID in URL. Returns None if not a status URL."""
    if not url:
        return None
    m = re.search(r'/status/(\d+)', url)
    if not m:
        return None
    try:
        sid = int(m.group(1))
        ts_ms = (sid >> 22) + 1288834974657
        post_time = datetime.datetime.fromtimestamp(ts_ms / 1000)
        age = datetime.datetime.now() - post_time
        return age.total_seconds() / 3600
    except Exception:
        return None

def url_posted_utc(url):
    """Extract post timestamp (UTC ISO string) from Twitter snowflake ID. Returns None if not available."""
    if not url: return None
    m = re.search(r'/status/(\d+)', url)
    if not m: return None
    try:
        sid = int(m.group(1))
        ts_ms = (sid >> 22) + 1288834974657
        post_time = datetime.datetime.utcfromtimestamp(ts_ms / 1000)
        return post_time.strftime('%Y-%m-%dT%H:%M:%SZ')
    except Exception:
        return None

def is_fresh(url, max_hours=MAX_AGE_HOURS):
    """Returns True if URL is fresh (within max_hours) or if age can't be determined."""
    age = url_age_hours(url)
    if age is None:
        return True  # Can't determine age, let it through
    return age <= max_hours

# ---- Parse API response ----
raw = sys.stdin.read()
try:
    r = json.loads(raw)
except json.JSONDecodeError:
    print("ERROR: Could not parse API response", file=sys.stderr)
    sys.exit(1)

if 'error' in r and r.get('error'):
    print('ERROR: ' + str(r['error']), file=sys.stderr)
    sys.exit(1)

# Extract text from response
text = ''
for item in r.get('output', []):
    if item.get('type') == 'message':
        for c in item.get('content', []):
            if c.get('type') == 'output_text':
                text = c['text']

text = text.strip()
if not text:
    print("ERROR: Empty response from Grok", file=sys.stderr)
    sys.exit(1)

# Strip markdown fences
if text.startswith('```'):
    text = re.sub(r'```json?\s*', '', text)
    text = re.sub(r'```\s*$', '', text)

# Strip grok render tags
text = re.sub(r'<grok:render[^>]*>.*?</grok:render>', '', text)

# Pre-fix the text BEFORE extracting JSON boundaries
# (Grok's missing braces cause depth counting to end early)
# Remove stray string labels between array objects
text = re.sub(r'\},\s*"[^"]{5,60}"\s*,\s*"(headline|handle)":', r'},{"\\1":', text)
text = re.sub(r'\},\s*"(headline|handle)":', r'},{"\\1":', text)
# Fix missing ] before next tab key — but only do it AFTER extraction in fix_json
# (can't do it here safely without knowing array context)

# Find JSON object
start = text.find('{')
if start == -1:
    print('ERROR: No JSON found in response', file=sys.stderr)
    print(f'Raw: {text[:200]}', file=sys.stderr)
    sys.exit(1)

# String-aware depth counter (ignores braces inside quoted strings)
depth = 0
end = 0
in_string = False
escape_next = False
for i in range(start, len(text)):
    ch = text[i]
    if escape_next:
        escape_next = False
        continue
    if ch == '\\' and in_string:
        escape_next = True
        continue
    if ch == '"':
        in_string = not in_string
        continue
    if in_string:
        continue
    if ch == '{': depth += 1
    elif ch == '}': depth -= 1
    if depth == 0:
        end = i + 1
        break

json_text = text[start:end]

# Fix common JSON issues
def fix_json(t):
    # Trailing commas
    t = re.sub(r',(\s*[}\]])', r'\1', t)
    # Remove stray string literals between array elements (Grok inserts labels like "hot take clip from pundit")
    t = re.sub(r'\},\s*"[^"]{5,60}"\s*,\s*"(headline|handle)":', r'},{"\\1":', t)
    # Missing opening braces in array elements: },\"key\" -> },{\"key\"
    # Grok sometimes outputs [{"a":"b"},"a":"c"}] instead of [{"a":"b"},{"a":"c"}]
    t = re.sub(r'\},\s*"(headline|handle)":', r'},{"\\1":', t)
    # Missing commas between }{ or }[ or ]{
    t = re.sub(r'\}(\s*)\{', r'},\1{', t)
    t = re.sub(r'\}(\s*)\[', r'},\1[', t)
    t = re.sub(r'\](\s*)\{', r'],\1{', t)
    # Fix unescaped chars inside strings
    result = []
    in_str = False
    esc = False
    valid_escapes = set('"\\bfnrtu/')
    for ch in t:
        if esc:
            if ch not in valid_escapes:
                # Invalid escape like \P — remove the backslash
                result.pop()  # remove the backslash we just added
                result.append(ch)
            else:
                result.append(ch)
            esc = False
            continue
        if ch == '\\' and in_str:
            result.append(ch)
            esc = True
            continue
        if ch == '"' and not esc:
            in_str = not in_str
        if in_str and ch == '\n':
            result.append('\\n')
            continue
        if in_str and ch == '\t':
            result.append('\\t')
            continue
        result.append(ch)
    return ''.join(result)

# Always run fix_json first — Grok's output is consistently malformed
fixed_text = fix_json(json_text)

def bracket_repair(t):
    """Walk through JSON tracking bracket stack; insert missing ] before tab keys."""
    tab_keys = {'world','usa','business','sports','elon','allin','top','msm','pg6','pods','recipe','science','local','memes','comedy','tiktok','golf'}
    result = list(t)
    stack = []  # track [ and {
    in_str = False
    esc = False
    i = 0
    insertions = []
    while i < len(t):
        ch = t[i]
        if esc:
            esc = False
            i += 1
            continue
        if ch == '\\' and in_str:
            esc = True
            i += 1
            continue
        if ch == '"' and not esc:
            in_str = not in_str
            i += 1
            continue
        if in_str:
            i += 1
            continue
        if ch == '{':
            stack.append('{')
        elif ch == '[':
            stack.append('[')
        elif ch == '}':
            if stack and stack[-1] == '{':
                stack.pop()
        elif ch == ']':
            if stack and stack[-1] == '[':
                stack.pop()
        elif ch == ',' and stack and stack[-1] == '[':
            # Inside an array — check if next non-ws is a tab key (means ] is missing)
            rest = t[i+1:i+30].lstrip()
            for tk in tab_keys:
                if rest.startswith(f'"{tk}"'):
                    insertions.append(i)
                    break
        i += 1
    # Apply insertions in reverse
    for pos in reversed(insertions):
        result.insert(pos, ']')
    return ''.join(result)

try:
    data = json.loads(fixed_text)
except json.JSONDecodeError as e:
    print(f'  First parse failed ({e.msg} at {e.pos}), attempting bracket repair...', file=sys.stderr)
    repaired = bracket_repair(fixed_text)
    with open('/tmp/grok_fixed.json', 'w') as f:
        f.write(repaired)
    try:
        data = json.loads(repaired)
        print('  Bracket repair succeeded', file=sys.stderr)
    except json.JSONDecodeError as e2:
        print(f'ERROR: JSON parse failed after repair: {e2}', file=sys.stderr)
        ctx = max(0, e2.pos - 60)
        print(f'Context: ...{repaired[ctx:ctx+120]}...', file=sys.stderr)
        sys.exit(1)

# ---- Validate and clean ----
GARBAGE = [
    'no recent viral post', 'setting to null', 'no post found',
    'no hot take', 'no recent elon', 'no recent post', 'not found',
    'no notable post', 'n/a'
]

def is_garbage(text):
    if not text:
        return True
    t = str(text).lower().strip()
    if len(t) < 3:
        return True
    return any(g in t for g in GARBAGE)

import subprocess, urllib.parse, os, concurrent.futures

_verified_cache = {}  # url -> (exists: bool, author: str)
_used_urls = set()    # global dedup across all tabs

# ---- Step 1.5: Find missing tweet URLs via focused Grok calls ----
XAI_API_KEY = os.environ.get('XAI_API_KEY', '')

def find_tweet_url(handle, headline):
    """Make a focused Grok API call to find a specific tweet URL."""
    if not XAI_API_KEY:
        return None
    h = handle.lstrip('@')
    prompt = f'Find the most recent tweet by @{h} about: "{headline}". Return ONLY the tweet URL in format https://x.com/{h}/status/NUMERIC_ID. Nothing else — just the URL or "null" if not found.'
    payload = json.dumps({
        'model': 'grok-4-1-fast-non-reasoning',
        'input': [
            {'role': 'system', 'content': 'Return ONLY a tweet URL. No explanation.'},
            {'role': 'user', 'content': prompt}
        ],
        'tools': [{'type': 'x_search'}],
        'max_output_tokens': 200,
        'temperature': 0
    })
    try:
        result = subprocess.run(
            ['curl', '-s', '--max-time', '30',
             'https://api.x.ai/v1/responses',
             '-H', 'Content-Type: application/json',
             '-H', f'Authorization: Bearer {XAI_API_KEY}',
             '-d', payload],
            capture_output=True, text=True, timeout=35
        )
        resp = json.loads(result.stdout)
        for item in resp.get('output', []):
            if item.get('type') == 'message':
                for c in item.get('content', []):
                    if c.get('type') == 'output_text':
                        txt = c['text'].strip()
                        match = re.search(r'https://x\.com/\S+/status/(\d+)', txt)
                        if match:
                            return match.group(0)
    except Exception as e:
        print(f"  URL lookup failed for {handle}: {e}", file=sys.stderr)
    return None

def enrich_urls(data):
    """Find real tweet URLs for stories that have null/missing URLs."""
    tasks = []  # (path, handle, headline)

    # World perspectives (now an array of world stories)
    world_data = data.get('world', [])
    world_items = world_data if isinstance(world_data, list) else [world_data]
    for wi, w in enumerate(world_items):
        if not isinstance(w, dict):
            continue
        for key in ['conservative', 'democrat', 'independent']:
            p = w.get(key, {})
            if isinstance(p, dict) and p.get('handle') and not p.get('url'):
                tasks.append((['world', wi, key], p['handle'], w.get('headline', '')))

    # USA perspectives (same structure as world)
    usa_data = data.get('usa', [])
    usa_items = usa_data if isinstance(usa_data, list) else [usa_data]
    for wi, w in enumerate(usa_items):
        if not isinstance(w, dict):
            continue
        for key in ['conservative', 'democrat', 'independent']:
            p = w.get(key, {})
            if isinstance(p, dict) and p.get('handle') and not p.get('url'):
                tasks.append((['usa', wi, key], p['handle'], w.get('headline', '')))

    # All array tabs
    for tab in ['elon', 'sports', 'allin', 'pods', 'business', 'top', 'msm', 'pg6', 'recipe', 'science', 'local', 'memes', 'comedy', 'tiktok', 'golf']:
        items = data.get(tab, [])
        if not isinstance(items, list):
            items = [items]
        for i, item in enumerate(items):
            if isinstance(item, dict) and item.get('handle') and not item.get('url'):
                tasks.append(([tab, i], item['handle'], item.get('headline', '')))

    if not tasks:
        return data

    print(f"  Finding URLs for {len(tasks)} stories...", file=sys.stderr)

    # Run up to 5 concurrent lookups
    found = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
        futures = {executor.submit(find_tweet_url, handle, headline): (path, handle)
                   for path, handle, headline in tasks}
        for future in concurrent.futures.as_completed(futures):
            path, handle = futures[future]
            url = future.result()
            if url:
                found += 1
                # Set the URL in data
                obj = data
                for k in path[:-1]:
                    obj = obj[k]
                if isinstance(path[-1], int):
                    obj[path[-1]]['url'] = url
                else:
                    obj[path[-1]]['url'] = url
                print(f"  FOUND: {handle} -> {url}", file=sys.stderr)

    print(f"  URL enrichment: {found}/{len(tasks)} found", file=sys.stderr)
    return data

# ---- Run URL enrichment ----
data = enrich_urls(data)

def verify_url(url):
    """Check if a tweet URL exists via oEmbed. Returns True/False."""
    if not url or '/status/' not in url:
        return False
    if url in _verified_cache:
        return _verified_cache[url]
    try:
        oembed = f"https://publish.twitter.com/oembed?url={urllib.parse.quote(url, safe='')}"
        result = subprocess.run(
            ['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '5', oembed],
            capture_output=True, text=True, timeout=8
        )
        exists = result.stdout.strip() == '200'
        _verified_cache[url] = exists
        return exists
    except Exception:
        _verified_cache[url] = False
        return False

def url_handle(url):
    """Extract handle from URL path"""
    try:
        path = urllib.parse.urlparse(url).path
        return path.split('/')[1].lower()
    except Exception:
        return ''

def clean_url(handle, url):
    """Verify URL exists, matches the handle, and isn't reused across tabs.
    Returns None for invalid URLs — caller should reject the story.
    Exception: tiktok.com/youtube.com/etc URLs are passed through (validated elsewhere)."""
    if url and isinstance(url, str):
        u = url.lower()
        # Non-X video platforms — pass through (validated separately)
        if any(dom in u for dom in ('tiktok.com', 'youtube.com', 'youtu.be', 'instagram.com')):
            return url
        # X post URL — must have /status/
        if '/status/' in url:
            url_h = url_handle(url)
            claimed_h = handle.lower().lstrip('@')
            if url_h and url_h != claimed_h:
                print(f"  MISMATCHED URL: {url} (URL says @{url_h}, claim says {handle})", file=sys.stderr)
            if url in _used_urls:
                print(f"  DEDUP: {url} already used", file=sys.stderr)
                return None
            if verify_url(url):
                _used_urls.add(url)
                return url
            print(f"  FAKE URL (404): {url}", file=sys.stderr)
            return None
    # Anything else (profile URL, missing URL, etc) — reject, do not silently fall back
    print(f"  INVALID URL (no /status/): '{url}' — rejecting story", file=sys.stderr)
    return None

def trim_text(text, max_sentences=2, max_chars=150):
    """Trim text to max_sentences and max_chars. Keep it punchy."""
    if not text:
        return ''
    text = str(text).strip()
    # Split into sentences
    sentences = re.split(r'(?<=[.!?])\s+', text)
    trimmed = '. '.join(sentences[:max_sentences])
    if not trimmed.endswith(('.', '!', '?')):
        trimmed += '.'
    # Hard cap on length
    if len(trimmed) > max_chars:
        trimmed = trimmed[:max_chars].rsplit(' ', 1)[0] + '...'
    return trimmed

# Minimum engagement thresholds per tab — reject low-engagement stories at QC time.
# Grok sometimes returns small posts from our listed handles even when more viral ones exist.
MIN_LIKES_BY_TAB = {
    'world': 1000, 'usa': 1000, 'top': 2000, 'msm': 500, 'business': 500,
    'sports': 300, 'elon': 1000, 'allin': 500, 'pg6': 1000, 'pods': 500,
    'science': 100, 'recipe': 100, 'local': 50,
    'memes': 500, 'comedy': 300, 'tiktok': 100_000, 'golf': 100,
}

def parse_likes(eng_str):
    """Parse engagement string like '5.2K likes', '1.1M views, 30K likes' to a likes number."""
    if not eng_str: return 0
    s = str(eng_str).lower()
    # Find largest "X[K|M] likes" token
    m = re.findall(r'([\d.]+)\s*([kmb]?)\s*likes?', s)
    if not m:
        # Fall back to any number followed by k/m
        m = re.findall(r'([\d.]+)\s*([kmb])', s)
    best = 0
    for num_str, mult in m:
        try:
            num = float(num_str)
            if mult == 'k': num *= 1_000
            elif mult == 'm': num *= 1_000_000
            elif mult == 'b': num *= 1_000_000_000
            if num > best: best = num
        except Exception:
            pass
    return int(best)

def is_reply_body(body, headline=''):
    """Reject replies that lack self-contained context.
    A reply starts with @mention or is too terse to stand alone."""
    b = (body or '').strip()
    if not b: return False  # empty body — let other checks handle
    if b.startswith('@'): return True  # direct reply to someone
    if len(b) < 25 and len(headline) < 40: return True  # too short to convey context
    # Terse reactions with no content
    low = b.lower().strip(' .!?"\'')
    BAD = {'this', 'exactly', 'no way', 'yes', 'correct', 'wrong', 'true', 'false',
           'agreed', 'agree', 'lol', 'nope', 'yep', 'wow', 'sad', 'this is wrong',
           'that is wrong', 'this isn\'t true', 'you have no idea what you\'re talking about'}
    if low in BAD: return True
    return False


def headline_similarity(h1, h2):
    """Jaccard overlap of significant words between two headlines. 0.0-1.0."""
    sw = {'the','and','for','are','but','not','all','can','had','her','was','one','our',
          'out','has','his','how','its','may','new','now','old','see','way','who','did',
          'get','let','say','she','too','use','with','from','have','this','that','will',
          'each','make','like','just','over','such','take','than','them','very','when',
          'come','could','would','about','after','being','their','there','these','those',
          'which','other','into','more','some','what','been','were','then','also','most',
          'must','upon','trump','biden','harris'}  # exclude politician names from dedup keys
    def toks(s):
        return {w for w in re.split(r'[^a-zA-Z]+', (s or '').lower())
                if len(w) >= 3 and w not in sw}
    t1, t2 = toks(h1), toks(h2)
    if not t1 or not t2: return 0.0
    return len(t1 & t2) / max(1, min(len(t1), len(t2)))


def enforce_uniqueness(stories, label, min_headline_overlap=0.4):
    """Post-assembly dedup — run ONCE over the final story list to enforce:
      1. Handle diversity: no handle appears as same side twice.
      2. Headline similarity: no two stories share >= min_headline_overlap of
         significant words (kills near-duplicate stories like SPLC x2).
    Scoring for dedup: prefer stories with more /status/ URLs, higher engagement
    signal, more insight markers. Returns filtered list.
    """
    def score(s):
        # Use the unified interestingness score on each perspective + sum them.
        # Plus base credit for having /status/ URL on each.
        sc = 0
        for p in s.get('perspectives', []):
            if '/status/' in (p.get('url') or ''): sc += 5
            sc += interestingness_score(p, tab=label)
        return sc

    kept = []
    seen_side_handles = {}   # label -> set of handles
    for s in sorted(stories, key=score, reverse=True):
        # 1. Check handle diversity
        ok = True
        pending = {}
        for p in s.get('perspectives', []):
            side = p.get('label', '')
            h = (p.get('handle','') or '').lower().lstrip('@')
            if h and h in seen_side_handles.get(side, set()):
                print(f"  DEDUP {label}: @{h} repeats as {side} \u2014 dropping '{s.get('headline','')[:55]}'", file=sys.stderr)
                ok = False; break
            pending[side] = h
        if not ok: continue

        # 2. Check headline similarity to already-kept stories
        dupe = None
        for k in kept:
            sim = headline_similarity(s.get('headline',''), k.get('headline',''))
            if sim >= min_headline_overlap:
                dupe = (k.get('headline',''), sim); break
        if dupe:
            print(f"  DEDUP {label}: headline too similar ({int(dupe[1]*100)}%) to kept story \u2014 dropping '{s.get('headline','')[:55]}' (dup of '{dupe[0][:55]}')", file=sys.stderr)
            continue

        # Accept
        for side, h in pending.items():
            if h: seen_side_handles.setdefault(side, set()).add(h)
        kept.append(s)

    return kept


def enforce_single_post_uniqueness(stories, tab_label, min_headline_overlap=0.4):
    """Post-assembly dedup for single-post tabs (business, msm, pods, pg6, memes, comedy, tiktok, elon).
    Enforces:
      1. Handle diversity: max 1 post per handle (catches @WatcherGuru twice from backfill).
      2. Headline similarity: drops near-duplicate topics even from different handles.
    Preserves order within the tab; drops the later/lower-scored duplicate.
    """
    if not stories:
        return stories

    def score(s):
        # Use unified interestingness score + URL bonus
        sc = interestingness_score(s, tab=tab_label)
        url = s.get('url', '') or ''
        if '/status/' in url or 'tiktok.com' in url or 'youtube.com' in url:
            sc += 3
        return sc

    kept = []
    seen_handles = set()
    for s in sorted(stories, key=score, reverse=True):
        h = (s.get('handle', '') or '').lower().lstrip('@')
        # 1. Handle dedup
        if h and h in seen_handles:
            print(f"  DEDUP {tab_label}: duplicate handle @{h} — dropping '{s.get('headline','')[:55]}'", file=sys.stderr)
            continue
        # 2. Headline similarity dedup
        dupe = None
        for k in kept:
            sim = headline_similarity(s.get('headline', ''), k.get('headline', ''))
            if sim >= min_headline_overlap:
                dupe = (k.get('headline', ''), sim); break
        if dupe:
            print(f"  DEDUP {tab_label}: headline {int(dupe[1]*100)}% similar to kept story — dropping '{s.get('headline','')[:55]}' (dup of '{dupe[0][:55]}')", file=sys.stderr)
            continue
        if h: seen_handles.add(h)
        kept.append(s)
    return kept


def grok_same_topic_check(stories, tab_label='world', timeout=90):
    """Semantic same-topic verifier.

    For each world/USA story, ask Grok: "Do all 3 perspectives discuss the SAME
    specific event described in the headline, or does any drift to an unrelated
    topic?" Returns a filtered list with drifting perspectives swapped out for
    the best remaining same-topic ones, or the story dropped entirely if fewer
    than 2 perspectives stay on topic.

    One API call per story. Requires XAI_API_KEY env var.
    Falls back to original stories on any failure (never breaks the pipeline).
    """
    if not stories:
        return stories
    api_key = os.environ.get('XAI_API_KEY')
    if not api_key:
        print(f"  [semantic] XAI_API_KEY not set — skipping semantic check for {tab_label}", file=sys.stderr)
        return stories

    # Build compact payload describing all stories
    summary_lines = []
    for i, s in enumerate(stories):
        summary_lines.append(f"STORY {i}: headline=\"{s.get('headline','')[:120]}\"")
        for j, p in enumerate(s.get('perspectives', [])):
            label = p.get('label','')
            txt = (p.get('text','') or '')[:200].replace('"', "'").replace('\n', ' ')
            summary_lines.append(f"  P{j} [{label}] @{p.get('handle','')}: \"{txt}\"")
    summary = '\n'.join(summary_lines)

    prompt = f"""You are a topic-drift detector for eXpressO News. For each STORY below, determine whether each perspective (P0, P1, P2) is ON-TOPIC with the headline.

BE GENEROUS. A perspective is ON-TOPIC if it discusses ANY meaningful aspect of the broader event in the headline:
- Direct commentary on the specific event/people/action
- Second-order consequences of that event (e.g., headline "US strikes on Iran" + perspective about economic fallout of those strikes = ON-TOPIC)
- Historical parallels or comparisons tied to the event
- Criticism of any party involved in the event
- Different framing or angle on the same underlying event
- Reaction, prediction, or analysis tied to the event

A perspective is OFF-TOPIC only if it clearly discusses a DIFFERENT news story entirely — not a different angle on the same story. Example: headline "SPLC indicted on fraud charges" and perspective is about a Congressional immigration bill = OFF-TOPIC. But headline "SPLC indicted" and perspective is "DOJ under Trump is weaponizing prosecutions" = ON-TOPIC (different framing of same event).

When in doubt, mark as ON-TOPIC. We prefer false positives (keep marginal perspectives) over false negatives (drop legitimate ones).

Return JSON: {{"stories": [{{"story_index": 0, "on_topic": [0, 1, 2]}}, ...]}}
Where "on_topic" is the list of perspective indices (P0=0, P1=1, P2=2) that ARE on-topic.

Stories:
{summary}

Return ONLY the JSON object, no prose."""

    try:
        payload = {
            "model": "grok-4-fast",
            "input": prompt,
            "max_output_tokens": 2000
        }
        with open('/tmp/_semantic_payload.json', 'w') as f:
            json.dump(payload, f)
        r = subprocess.run([
            'curl', '-s', f'--max-time', str(timeout),
            'https://api.x.ai/v1/responses',
            '-H', 'Content-Type: application/json',
            '-H', f'Authorization: Bearer {api_key}',
            '-d', '@/tmp/_semantic_payload.json'
        ], capture_output=True, text=True, timeout=timeout + 10)
        if r.returncode != 0:
            print(f"  [semantic] curl failed for {tab_label}: {r.stderr[:200]}", file=sys.stderr)
            return stories
        raw = json.loads(r.stdout)
        if 'error' in raw and raw['error']:
            print(f"  [semantic] API error for {tab_label}: {str(raw['error'])[:200]}", file=sys.stderr)
            return stories
        text = ''
        for item in raw.get('output', []):
            if item.get('type') == 'message':
                for c in item.get('content', []):
                    if c.get('type') == 'output_text':
                        text = c['text']
        m = re.search(r'\{.*\}', text, re.DOTALL)
        if not m:
            print(f"  [semantic] no JSON in response for {tab_label}", file=sys.stderr)
            return stories
        parsed = json.loads(m.group(0))
    except Exception as e:
        print(f"  [semantic] exception for {tab_label}: {e}", file=sys.stderr)
        return stories

    # Apply results. User rule:
    #   - Prefer stories where all 3 perspectives are on-topic (the story is important
    #     enough to attract all 3 sides).
    #   - If a perspective drifts, drop that perspective silently (don't print the drift
    #     block — ship 2 sides, not a broken 3rd).
    #   - If NO 3-perspective story exists in this batch, fall back to 2-perspective
    #     stories. Drop anything with fewer than 2 on-topic perspectives.
    results = parsed.get('stories', [])
    result_map = {r.get('story_index'): r.get('on_topic', [0, 1, 2]) for r in results}
    three_perspective = []
    two_perspective = []
    for i, s in enumerate(stories):
        on_topic_idx = result_map.get(i, [0, 1, 2])
        perspectives = s.get('perspectives', [])
        if not perspectives:
            continue
        kept_perspectives = [p for j, p in enumerate(perspectives) if j in on_topic_idx]
        dropped = [p for j, p in enumerate(perspectives) if j not in on_topic_idx]
        for p in dropped:
            print(f"  [semantic] DRIFT {tab_label} story {i} '{s.get('headline','')[:55]}' — dropping {p.get('label')} @{p.get('handle')}: off-topic", file=sys.stderr)
        if len(kept_perspectives) < 2:
            print(f"  [semantic] REJECT {tab_label} story {i} — fewer than 2 perspectives on-topic", file=sys.stderr)
            continue
        s_out = dict(s)
        s_out['perspectives'] = kept_perspectives
        if len(kept_perspectives) >= 3:
            three_perspective.append(s_out)
        else:
            two_perspective.append(s_out)

    # Tiered return: if any story has all 3, ONLY ship 3-perspective stories
    # (the 2-perspective ones aren't important enough). Only fall back to
    # 2-perspective stories if the batch has zero 3-perspective candidates.
    if three_perspective:
        print(f"  [semantic] {tab_label}: shipping {len(three_perspective)} 3-perspective stories, dropping {len(two_perspective)} 2-perspective (a 3-story exists so bar is raised)", file=sys.stderr)
        kept_stories = three_perspective
    elif two_perspective:
        print(f"  [semantic] {tab_label}: no 3-perspective stories — falling back to {len(two_perspective)} 2-perspective stories", file=sys.stderr)
        kept_stories = two_perspective
    else:
        # Safety net: semantic verifier killed everything. Don't ship zero — return
        # the pre-semantic input (entity gate already caught the worst drift).
        # Better to show slightly-drifting perspectives than an empty tab.
        print(f"  [semantic] {tab_label}: WOULD GO TO ZERO — skipping semantic, shipping {len(stories)} pre-semantic stories as safety net", file=sys.stderr)
        kept_stories = list(stories)

    print(f"  [semantic] {tab_label}: {len(stories)} stories -> {len(kept_stories)} after semantic verification", file=sys.stderr)
    return kept_stories


def honesty_consistency_review(items, label='world', timeout=90):
    """Second-pass audit: examine each post's honesty score AND its reasoning side-by-side.
    If they don't logically match (score 9 but reasoning calls it projection; score 3 but
    reasoning is innocuous fact), Grok rescores OR rewrites the reasoning so they're
    internally consistent.

    `items` = list of dicts with at minimum {handle, text, honesty, notes}.
    Returns a dict mapping item_index -> {honesty, notes} for items needing correction.
    """
    api_key = os.environ.get('XAI_API_KEY')
    if not api_key or not items:
        return {}

    # Build summary
    lines = []
    for i, p in enumerate(items):
        text = (p.get('text') or p.get('body') or '').replace('"', "'").replace('\n', ' ')[:200]
        notes = (p.get('notes') or p.get('evidence') or '').replace('"', "'").replace('\n', ' ')[:200]
        lines.append(f'ITEM {i}: @{p.get("handle","?")} | score={p.get("honesty","?")} | notes="{notes}" | text="{text}"')
    summary = '\n'.join(lines)

    prompt = f"""You are a CONSISTENCY AUDITOR for honesty scores on eXpressO News. The first Grok pass scored these posts. Some scores may not match their reasoning — score=9 with notes that describe projection from a known liar, or score=3 with notes that describe verified fact.

For EACH item below, examine score vs notes. If they don't logically match:
- Correct the score so it agrees with the reasoning, OR
- Rewrite the notes so the reasoning supports the score

Anchor scoring (same as first pass):
  10 = pure verifiable fact from credible source
  8-9 = factual core with light editorializing
  5-7 = opinion/take with factual basis, normal partisan bias
  3-4 = significantly biased, cherry-picked, moderate distortion
  1-2 = severe distortion, projection, known fabricator
  0 = demonstrably false

Apply same standard to every party. If reasoning identifies projection or known-liar pattern, score MUST be 0-2. If reasoning identifies verified fact from credible source, score MUST be 9-10.

ITEMS:
{summary}

Return JSON ONLY (only include items that need correction):
{{"corrections": [
  {{"index": <int>, "honesty": "<X/10>", "notes": "<one plain-English sentence>"}}
]}}
"""

    try:
        payload = {
            "model": "grok-4-fast",
            "input": prompt,
            "max_output_tokens": 2500,
            "temperature": 0.0,
        }
        with open('/tmp/_honesty_review.json', 'w') as f:
            json.dump(payload, f)
        r = subprocess.run([
            'curl', '-s', '--max-time', str(timeout),
            'https://api.x.ai/v1/responses',
            '-H', 'Content-Type: application/json',
            '-H', f'Authorization: Bearer {api_key}',
            '-d', '@/tmp/_honesty_review.json'
        ], capture_output=True, text=True, timeout=timeout + 10)
        if r.returncode != 0 or not r.stdout:
            return {}
        raw = json.loads(r.stdout)
        if 'error' in raw and raw.get('error'):
            print(f"  [honesty-review] {label} API error: {str(raw['error'])[:120]}", file=sys.stderr)
            return {}
        text = ''
        for item in raw.get('output', []):
            if item.get('type') == 'message':
                for c in item.get('content', []):
                    if c.get('type') == 'output_text':
                        text = c['text']
        m = re.search(r'\{.*\}', text, re.DOTALL)
        if not m:
            return {}
        parsed = json.loads(m.group(0))
        corrections = {}
        for c in parsed.get('corrections', []):
            idx = c.get('index')
            if isinstance(idx, int):
                corrections[idx] = {
                    'honesty': str(c.get('honesty', '')),
                    'notes': str(c.get('notes', '')),
                }
        if corrections:
            print(f"  [honesty-review] {label}: corrected {len(corrections)} of {len(items)} scores for consistency", file=sys.stderr)
        return corrections
    except Exception as e:
        print(f"  [honesty-review] {label} exception: {e}", file=sys.stderr)
        return {}


def evidence_check_score(handle, claim_text, story_headline, timeout=90):
    """Per-claim evidence check. For a politician's post, ask Grok to look up their
    DOCUMENTED TRACK RECORD on the specific subject of the claim. Score reflects whether
    the record supports or contradicts the claim. Same algorithm for every politician
    of every party — only documented evidence counts.

    Returns dict {score, evidence, verdict, sources} or None on failure.
    """
    api_key = os.environ.get('XAI_API_KEY')
    if not api_key:
        return None
    if not claim_text or len(claim_text.strip()) < 5:
        return None

    prompt = f"""You are an impartial fact-evidence scorer. Apply this same process to EVERY politician of EVERY party — no bias for or against, only documented evidence.

POLITICIAN: {handle}
STORY CONTEXT: {story_headline[:120]}
CLAIM IN POST: "{claim_text[:300]}"

Use x_search and web_search to look up THIS POLITICIAN's documented TRACK RECORD on the SPECIFIC SUBJECT of the claim above. Look for:
- Have they done what they're claiming, in fact?
- Have they failed to do what they're claiming?
- Is the claim consistent with their actual record on this subject?
- Is the claim a reasonable extension of past action?

Score 1-10:
- 10/10: Strong documented track record consistent with the claim. Reality supports them.
- 8/10:  Mostly consistent, minor gaps.
- 5/10:  Mixed track record or insufficient evidence either way.
- 3/10:  Record contradicts the claim. Claim isn't supported by their actions.
- 1/10:  Claim is the OPPOSITE of their actual record. Pure projection.

Return JSON ONLY (no prose):
{{"score": <int>, "evidence": "<one sentence factual summary citing what you found>", "verdict": "consistent" | "mixed" | "contradicted" | "projection", "sources": ["<domain1>", "<domain2>"]}}"""

    try:
        payload = {
            "model": "grok-4-fast",
            "input": prompt,
            "tools": [{"type": "x_search"}, {"type": "web_search"}],
            "max_output_tokens": 1500,
            "temperature": 0.0,
        }
        with open('/tmp/_evidence_payload.json', 'w') as f:
            json.dump(payload, f)
        r = subprocess.run([
            'curl', '-s', '--max-time', str(timeout),
            'https://api.x.ai/v1/responses',
            '-H', 'Content-Type: application/json',
            '-H', f'Authorization: Bearer {api_key}',
            '-d', '@/tmp/_evidence_payload.json'
        ], capture_output=True, text=True, timeout=timeout + 10)
        if r.returncode != 0 or not r.stdout:
            return None
        raw = json.loads(r.stdout)
        if 'error' in raw and raw.get('error'):
            return None
        text = ''
        for item in raw.get('output', []):
            if item.get('type') == 'message':
                for c in item.get('content', []):
                    if c.get('type') == 'output_text':
                        text = c['text']
        m = re.search(r'\{.*\}', text, re.DOTALL)
        if not m:
            return None
        result = json.loads(m.group(0))
        # Validate
        score = result.get('score')
        if not isinstance(score, int) or score < 1 or score > 10:
            return None
        return {
            'score': score,
            'evidence': str(result.get('evidence', ''))[:300],
            'verdict': str(result.get('verdict', '')).lower(),
            'sources': result.get('sources', [])[:5],
        }
    except Exception as e:
        print(f"  [evidence] {handle} error: {e}", file=sys.stderr)
        return None


def is_cheerleading(text):
    """Reject posts that are mostly positive adjectives with no specific claim.
    'Trump's strategy is brilliant.' / 'Great day for America!' / 'Amazing work Mr. President!'
    These have no insight — just emotional approval signaling. Useless on a news site."""
    t = (text or '').strip()
    if not t: return False
    low = t.lower()
    # Common cheerleading words that signal applause without analysis
    CHEER_WORDS = ['brilliant', 'amazing', 'incredible', 'fantastic', 'perfect',
                   'genius', 'tremendous', 'awesome', 'wonderful', 'phenomenal',
                   'unbelievable', 'stunning', 'masterful', 'flawless',
                   'great job', 'well done', 'so good', 'so based',
                   'love this', 'love it', 'beautiful',
                   'historic win', 'best ever', 'goat status', 'this is the way',
                   "let's go", 'lets go', 'what a moment']
    # If more than half the post's "content words" are cheerleading words, reject
    import re as _re
    cheer_count = sum(1 for cw in CHEER_WORDS if cw in low)
    # Strong cheerleading signal: multiple cheer words OR a single cheer word
    # in a very short post that lacks specifics
    if cheer_count >= 2:
        return True
    # Short post (<80 chars) with at least 1 cheer word and no specifics
    if cheer_count >= 1 and len(t) < 80:
        # Look for specifics: numbers, "because", named entities (capitalized words past first)
        has_numbers = bool(_re.search(r'\d', t))
        has_because = ' because ' in low or ' the reason ' in low
        if not (has_numbers or has_because):
            return True
    return False


def is_stenography(text, label=''):
    """Reject perspectives that are JUST quoting someone else without adding a take.
    e.g. Democrat post = "Hegseth: 'You go from defense to war...'" with no Democrat
    framing or response. The poster needs to be ADDING to the conversation, not just
    transcribing the other side."""
    t = (text or '').strip()
    if not t: return False
    # Detect "X: ..." pattern at start, where X is a name or title
    import re as _re
    # Pattern: starts with "Word: " or "Word Word: " (someone speaking)
    quote_pattern_match = _re.match(r'^[A-Z][a-zA-Z\.]+(\s+[A-Z][a-zA-Z\.]+)?\s*:\s*"', t)
    if quote_pattern_match:
        # The post starts with "Hegseth: '..." or "Schumer: '..."
        # Check if there's a take AFTER the quote — look for 50+ char trailing content
        # past the closing quote that contains insight markers
        # Simple heuristic: if 80%+ of the post is inside quotes, it's stenography
        in_quote_chars = 0
        in_quote = False
        for ch in t:
            if ch == '"':
                in_quote = not in_quote
                continue
            if in_quote:
                in_quote_chars += 1
        if in_quote_chars / max(1, len(t)) > 0.5:
            return True
    return False


def is_announcement(text):
    """Reject wire-service announcements — pure factual statements with no take.
    These are 'X did Y' with no opinion, analysis, contrarian angle, or insight.
    Used for world/USA perspectives where we want THOUGHTFUL commentary, not news tickers."""
    t = (text or '').strip()
    if not t: return False
    low = t.lower()

    # Hard block: wire-service prefixes — pure announcement format
    ANNOUNCEMENT_PREFIXES = [
        'breaking:', 'breaking ', 'just in:', 'just in ', 'update:', 'update ',
        'new:', 'developing:', 'developing ', 'report:', 'reports:',
        'alert:', 'confirmed:', 'exclusive:', 'watch:', 'watch ',
    ]
    for pref in ANNOUNCEMENT_PREFIXES:
        if low.startswith(pref):
            return True

    # Generic positive announcements with exclamation but no substance
    # ("The meeting went very well!", "Big news today!", "What a day!")
    GENERIC_POSITIVE_PHRASES = [
        'went very well', 'went well', 'big day', 'big news', 'what a day',
        'huge announcement', 'big announcement', 'so excited', 'very excited',
    ]
    if any(phrase in low for phrase in GENERIC_POSITIVE_PHRASES) and len(t) < 120:
        return True

    # All-caps ticker-style (≥5 consecutive caps words, no lowercase analysis after)
    import re as _re
    if _re.match(r'^[A-Z0-9 ,.\-:\']{30,}$', t[:60]):
        return True

    # Short factual statement with no opinion markers
    # These are insight signals — words used when someone actually has a take
    INSIGHT_MARKERS = [
        # Opinion/analysis framing
        ' because ', ' however', ' but ', ' actually ', ' really ', ' truly ',
        ' seems ', ' think', ' believe', ' argue', ' suggest', ' imagine',
        ' perhaps', ' probably', ' clearly ', ' obviously', ' frankly',
        # Contrast/nuance
        ' although', ' despite', ' while ', ' yet ', ' even if', ' whereas',
        # Causation/framework
        ' this means', ' means that', ' reveals', ' shows that', ' suggests that',
        ' this is why', ' the reason', ' the real ', ' the actual',
        # Second-person engagement
        ' you ', 'if you', 'when you',
        # First-person take
        ' i ', "i'm ", 'i think', 'i believe', 'my take', 'my view',
        # Historical/structural framing
        ' history', ' historically', ' pattern', ' regime', ' system', ' decade',
        ' never ', ' always ', ' every time', ' the way',
        # Question/invitation to think
        '?', '!',
    ]
    has_insight = any(m in low for m in INSIGHT_MARKERS)

    # Short factual statements (<70 chars) WITHOUT any insight marker are announcements.
    # (Grok often returns ~100-char summaries that truncate real takes — 70 is the safer
    # threshold to only catch pure wire-service "X happened" posts, not truncated opinions.)
    if len(t) < 70 and not has_insight:
        return True

    return False


# POLITICIAN HANDLES — a sitting/former politician posting about politics is PR/advocacy,
# not journalism. Their honesty cap is 7/10 regardless of party. Non-partisan rule.
POLITICIAN_HANDLES = {
    # POTUS / VP / White House
    'potus', 'realdonaldtrump', 'whitehouse', 'flotus', 'presssec', 'kamalaharris', 'joebiden', 'vp',
    # Republican pols
    'sentedcruz', 'speakerjohnson', 'donaldjtrumpjr', 'vivekgramaswamy', 'hawleymo', 'randpaul',
    'dancrenshawtx', 'mtgreenee', 'jdvance', 'nikkihaley', 'desantis', 'rongovsantis', 'gop',
    # Democratic pols
    'aoc', 'berniesanders', 'senwarren', 'ilhan', 'chrismurphyct', 'rbreich', 'joycewhitevance',
    'senschumer', 'repjayapal', 'speakerpelosi', 'corybooker', 'housedemocrats', 'ewarren',
    'petebuttigieg', 'jentaub', 'maxinewaters', 'govtimwalz', 'gavinnewsom', 'senmarkkelly',
    'repelicrane', 'barackobama', 'maryltrump',
    # Government bureaucracy that posts politically
    'thejusticedept', 'deptofwar',
}
POLITICIAN_PREFIXES = ('sen', 'rep', 'gov')  # SenSomething, RepSomething, GovSomething handles

# VIP roster — handles the user has flagged as consistently interesting.
# Matches are normalized (lowercase, no @). Used by interestingness_score().
VIP_HANDLES = {
    # Conservative
    'billoreilly', 'jessebwatters', 'gutfeldfox', 'dineshdsouza', 'potus',
    'realdonaldtrump', 'nickshirleyy', 'pbdspodcast', 'tuckercarlson',
    'mattwalshblog', 'jackposobiec', 'catturd2',
    # Independent / heterodox
    'billmaher', 'naval', 'mtslive', 'iancarrollshow', 'ggreenwald', 'mtaibbi',
    'breakingpoints', 'krystalball', 'saagarenjeti',
    # Business / Tech / $age
    'billackman', 'sawyermerritt', 'tesla', 'pmarca', 'chamath', 'davidsacks',
    'friedberg', 'palmerluckey', 'elonmusk', 'theallinpod',
    # Pop / culture
    'nickiminaj',
}


def interestingness_score(s, tab=''):
    """Score a story 0-10 on Expresso fit.
    Combines existing signals: engagement + insight markers + VIP bonus minus
    announcement/cheerleading/stenography penalties + length bonus.

    Used to RANK accepted posts (not gate them — gates are upstream). Higher
    score = better candidate. Useful for picking the best K from N.
    """
    score = 5.0  # neutral baseline

    # --- Text content (handles both single-post and perspective-block schemas) ---
    text = (s.get('text') or s.get('body') or s.get('quote') or '').strip()
    headline = (s.get('headline') or '').strip()
    handle = ((s.get('handle') or '') + '').lower().lstrip('@')
    full_text = (text + ' ' + headline).strip()

    # --- Engagement bonus (up to +3) ---
    eng = (s.get('engagement') or '').lower()
    likes = 0
    for num_str, mult in re.findall(r'([\d.]+)\s*([kmb]?)\s*likes?', eng):
        try:
            num = float(num_str)
            if mult == 'k': num *= 1_000
            elif mult == 'm': num *= 1_000_000
            elif mult == 'b': num *= 1_000_000_000
            likes = max(likes, int(num))
        except: pass
    if likes >= 100_000: score += 3.0
    elif likes >= 25_000: score += 2.5
    elif likes >= 10_000: score += 2.0
    elif likes >= 3_000:  score += 1.5
    elif likes >= 1_000:  score += 1.0
    elif likes >= 200:    score += 0.5

    # --- VIP bonus (+2) ---
    if handle in VIP_HANDLES:
        score += 2.0

    # --- Insight marker count (+0.3 each, capped at +2) ---
    INSIGHT_MARKERS_FOR_SCORE = [
        ' because ', ' however', ' actually ', ' this means', ' the real reason',
        ' i think', ' i believe', ' my take', ' historically', ' pattern',
        ' regime', ' decade', ' never ', ' always ',
        ' although', ' despite', ' yet ', ' second-order', ' counterintuitive',
        ' the way', ' contrary to', ' contrast', ' nuance', ' framework',
        ' explains why', ' the reason', ' shows that', ' suggests that',
    ]
    low = full_text.lower()
    insight_hits = sum(1 for m in INSIGHT_MARKERS_FOR_SCORE if m in low)
    score += min(2.0, insight_hits * 0.4)

    # --- Length bonus (substantive posts get +1) ---
    if len(text) >= 150:   score += 1.0
    elif len(text) >= 100: score += 0.5

    # --- Penalties ---
    if is_announcement(text): score -= 4.0
    if is_cheerleading(text): score -= 3.0
    if is_stenography(text):  score -= 3.0
    # Reply with no context (already filtered upstream, but defensive)
    if text.lstrip().startswith('@'): score -= 2.0

    # Clamp 0-10
    return max(0.0, min(10.0, score))


def clean_story(s, tab=''):
    """Validate and clean a single story dict. Returns None if garbage."""
    if not isinstance(s, dict):
        return None
    if is_garbage(s.get('headline', '')) and is_garbage(s.get('body', '')):
        return None
    handle = s.get('handle', '')
    if not handle:
        return None
    headline = str(s.get('headline', '') or s.get('body', '')[:80] or 'Untitled')

    # CONTEXT GATE: reject reply-only / too-terse / reaction-only posts
    body = s.get('body', '') or ''
    if is_reply_body(body, headline):
        print(f"  REJECT {tab}: context-less reply/reaction - {handle}: '{body[:40]}'", file=sys.stderr)
        return None

    # ENGAGEMENT GATE: reject low-engagement posts for tabs that should be viral-only
    min_likes = MIN_LIKES_BY_TAB.get(tab, 0)
    if min_likes > 0:
        likes = parse_likes(s.get('engagement', ''))
        if likes > 0 and likes < min_likes:
            print(f"  REJECT {tab}: low engagement {likes} < {min_likes} ({handle})", file=sys.stderr)
            return None

    # FRESHNESS GATE: check the RAW url from Grok BEFORE clean_url sanitizes it
    max_age = TAB_AGE_OVERRIDE.get(tab, MAX_AGE_HOURS)
    raw_url = s.get('url', '')
    age = url_age_hours(raw_url)
    if age is not None and age > max_age:
        print(f"  STALE ({int(age)}h old): {handle} - {headline[:50]}", file=sys.stderr)
        return None

    url = clean_url(handle, raw_url)
    if url is None:
        return None  # reject stories with invalid/broken URLs — don't fall back to profile page

    # Double-check cleaned URL too
    age2 = url_age_hours(url)
    if age2 is not None and age2 > max_age:
        print(f"  STALE ({int(age2)}h old): {handle} - {headline[:50]}", file=sys.stderr)
        return None

    out = {
        'headline': headline,
        'handle': handle,
        'url': url,
        'body': trim_text(s.get('body', ''), max_sentences=2, max_chars=150),
        'engagement': str(s.get('engagement', '')),
        'honesty': str(s.get('honesty', '8/10')),
        'notes': str(s.get('notes', '')),
        'posted': datetime.datetime.now().astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'post_ts': url_posted_utc(url) or datetime.datetime.now().astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    }
    # Pass through Grok's translation field if present (for foreign-language posts/quote-tweets)
    if s.get('translation'):
        out['translation'] = str(s['translation'])
    return out

def clean_world(w):
    """Validate world story — REQUIRES all 3 perspectives (conservative, democrat, independent)."""
    if not isinstance(w, dict):
        return None
    headline = w.get('headline', w.get('topic', ''))
    if is_garbage(headline):
        return None
    perspectives = []
    # SOFTER GATE: per-perspective rejection now skips the perspective rather than the
    # whole story. A 2-of-3 story still ships (better than carrying-over from history).
    for key, label in [('conservative', 'Conservative'), ('democrat', 'Democrat'), ('independent', 'Independent')]:
        p = w.get(key, {})
        if not isinstance(p, dict):
            print(f"  SKIP world/USA {key} perspective: missing entirely", file=sys.stderr)
            continue
        # Grok sometimes omits the 'handle' field but includes URL — derive handle from URL.
        if not p.get('handle'):
            url = p.get('url', '') or ''
            m = re.match(r'https?://(?:twitter\.com|x\.com)/([^/]+)/status/', url)
            if m:
                p = dict(p)  # copy so we don't mutate input
                p['handle'] = '@' + m.group(1)
        if not p.get('handle'):
            print(f"  SKIP world/USA {key} perspective: no handle and no URL to derive from", file=sys.stderr)
            continue
        # Grok sometimes returns 'quote', sometimes 'body', sometimes 'text', sometimes 'angle'.
        # Accept any of them — schema flexibility prevents silent drops.
        ptext = (p.get('quote') or p.get('body') or p.get('text') or p.get('angle') or '').strip()
        if is_garbage(ptext):
            print(f"  SKIP world/USA {key} perspective: garbage text", file=sys.stderr)
            continue
        if is_announcement(ptext):
            print(f"  SKIP world/USA {key} @{p['handle']}: bare announcement", file=sys.stderr)
            continue
        if is_cheerleading(ptext):
            print(f"  SKIP world/USA {key} @{p['handle']}: cheerleading", file=sys.stderr)
            continue
        if is_stenography(ptext, label):
            print(f"  SKIP world/USA {key} @{p['handle']}: just quoting", file=sys.stderr)
            continue
        p_url = clean_url(p['handle'], p.get('url'))
        if not p_url or '/status/' not in p_url:
            print(f"  SKIP world/USA {key} @{p['handle']}: no /status/ URL", file=sys.stderr)
            continue
        p_age = url_age_hours(p_url)
        if p_age is not None and p_age > MAX_AGE_HOURS:
            print(f"  SKIP world/USA {key}: URL is {int(p_age)}h old", file=sys.stderr)
            continue
        # Honesty score comes from Grok's holistic judgment (see grok_system.txt).
        # No mechanical caps or overrides — Grok considers source reputation,
        # track record, bias, and content together when scoring.
        _persp = {
            'label': label,
            'handle': p['handle'],
            'url': p_url,
            'text': trim_text(ptext, max_sentences=2, max_chars=150),
            'engagement': str(p.get('engagement', '')),
            'honesty': str(p.get('honesty', w.get('honesty', '8/10')))
        }
        # Pass through Grok's translation field if present
        if p.get('translation'): _persp['translation'] = str(p['translation'])
        if p.get('notes'): _persp['notes'] = str(p['notes'])
        perspectives.append(_persp)
    # Accept 1+ perspective. Single-take fresh story beats carried-over filler.
    # The frontend renders whatever perspectives we give it (1, 2, or 3 blocks).
    if len(perspectives) < 1:
        print(f"  REJECT world story: 0 perspectives", file=sys.stderr)
        return None

    # RELEVANCE CHECK: entity-based same-topic gate.
    # Extract NAMED ENTITIES from the headline (multi-word Capitalized phrases +
    # Uppercase acronyms + hashtags). Every perspective must reference at least
    # one of these exact entities — word-bag overlap was too loose.
    stop_words = {'the','and','for','are','but','not','you','all','can','had','her','was','one','our','out','has','his','how','its','may','new','now','old','see','way','who','did','get','let','say','she','too','use','with','from','have','this','that','will','each','make','like','just','over','such','take','than','them','very','when','come','could','would','about','after','being','their','there','these','those','which','other','into','more','some','what','been','were','then','also','most','must','upon'}

    _hl_str = str(headline)
    entities = set()

    # 1. Multi-word Capitalized phrases (e.g., "Southern Poverty Law Center", "Strait of Hormuz", "Spirit Airlines")
    #    + include the full phrase, each individual capitalized word, and the acronym
    for _m in re.finditer(r'(?:[A-Z][a-zA-Z\']{1,}(?:\s+(?:of\s+|and\s+|the\s+)?)?){2,}[A-Z][a-zA-Z\']{1,}', _hl_str):
        phrase = _m.group(0).strip()
        phrase_parts = phrase.split()
        if len(phrase_parts) >= 2:
            entities.add(phrase.lower())
            # Each significant word inside the phrase
            for _piece in phrase_parts:
                _pl = _piece.lower().strip(".,;:'\"")
                if len(_pl) >= 4 and _pl not in stop_words and _pl not in {'and','the','of'}:
                    entities.add(_pl)
            # Acronym
            _caps = [_piece[0] for _piece in phrase_parts if _piece and _piece[0].isupper()]
            if 2 <= len(_caps) <= 6:
                entities.add(''.join(_caps).lower())

    # 2. Standalone capitalized nouns (people/places) — single capitalized word
    #    that isn't a sentence-starter. 4+ chars so we don't match tiny tokens.
    for _m in re.finditer(r'(?<![\.\!\?:]\s)(?<![\.\!\?:])\b([A-Z][a-zA-Z\']{3,})\b', ' ' + _hl_str):
        _nw = _m.group(1).lower()
        if _nw not in stop_words and _nw not in {'trump','biden','harris','kamala'}:
            entities.add(_nw)

    # 3. All-caps acronyms (SPLC, IRGC, NATO, SCOTUS, DOJ, ICE, CIA, FBI)
    for _m in re.finditer(r'\b([A-Z]{2,6})\b', _hl_str):
        entities.add(_m.group(1).lower())

    # 4. Hashtags
    for _m in re.finditer(r'#([A-Za-z0-9_]{3,})', _hl_str):
        entities.add('#' + _m.group(1).lower())

    # 5. @mentions
    for _m in re.finditer(r'@([A-Za-z0-9_]{3,})', _hl_str):
        entities.add('@' + _m.group(1).lower())

    # 6. Fall back to plain significant words if no entities found (short or trivial headlines)
    if len(entities) < 2:
        for _tk in re.split(r'[^a-zA-Z]+', _hl_str.lower()):
            if len(_tk) >= 4 and _tk not in stop_words:
                entities.add(_tk)

    # SAME-TOPIC GATE: each perspective must match at least one entity from the headline.
    # This is stricter than word-bag overlap — we're matching specific people/orgs/events.
    # Accept 1 off-topic out of 3; reject if 2+ are off-topic.
    off_topic = []
    for p in perspectives:
        ptext_lower = (p.get('text','') or '').lower()
        # Check exact entity match anywhere in perspective text
        matched = [e for e in entities if e in ptext_lower]
        if not matched:
            # Secondary: any significant single word from perspective text that appears
            # among headline entities (fallback for when perspective uses shorter names)
            ptext_words = {w for w in re.split(r'[^a-zA-Z]+', ptext_lower)
                           if len(w) >= 4 and w not in stop_words}
            matched = [w for w in ptext_words if w in entities]
        if not matched:
            off_topic.append(p['label'])
            print(f"  OFF-TOPIC: {p['label']} @{p.get('handle','')}: no entity match with headline '{str(headline)[:55]}'", file=sys.stderr)
            print(f"              headline entities={sorted(entities)[:8]}... | perspective='{(p.get('text','') or '')[:80]}'", file=sys.stderr)

    # 1 off-topic out of 3 is tolerated (other 2 carry the story); 2+ off-topic = reject.
    if len(off_topic) >= 2:
        print(f"  REJECT world/USA story: {len(off_topic)}/3 off-topic perspectives: {off_topic}", file=sys.stderr)
        return None
    if off_topic:
        print(f"  WARN world/USA story: 1 off-topic perspective ({off_topic[0]}) — keeping story, other 2 carry topic (semantic verifier will handle)", file=sys.stderr)

    footnotes = w.get('footnotes', [])
    if not isinstance(footnotes, list):
        footnotes = []
    return {
        'headline': str(headline),
        'honesty': str(w.get('honesty', '8/10')),
        'perspectives': perspectives,
        'footnotes': [str(f) for f in footnotes],
        'notes': str(w.get('notes', '')),
        'body': 'Three-perspective roundup.',
        'posted': datetime.datetime.now().strftime("%-m/%-d/%Y %-I:%M %p")
    }

# ---- Build output ----
now = datetime.datetime.now()
update_time = now.strftime("%-I:%M %p")

# Load existing stories.json to preserve earlier
try:
    with open('stories.json', 'r') as f:
        existing = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    existing = {}

def expire_old_stories(stories, max_age_hours=MAX_AGE_HOURS):
    """Remove stories with ANY URL older than max_age_hours. Zero tolerance for stale content."""
    kept = []
    for s in stories:
        if 'perspectives' in s:
            urls = [p.get('url', '') for p in s.get('perspectives', [])]
        else:
            urls = [s.get('url', '')]

        # If ANY URL is old, drop the entire story
        has_old = False
        for u in urls:
            age = url_age_hours(u)
            if age is not None and age > max_age_hours:
                has_old = True
                break

        if has_old:
            hl = s.get('headline', '?')[:40]
            print(f"  EXPIRED earlier: {hl}", file=sys.stderr)
        else:
            kept.append(s)
    return kept

output = {
    'lastUpdated': now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
}

# Process world (now an array of stories)
world_data = data.get('world', {})
world_items = world_data if isinstance(world_data, list) else [world_data]
world_cleaned = []
for w in world_items:
    ws = clean_world(w)
    if ws:
        world_cleaned.append(ws)

world_earlier = existing.get('world', {}).get('earlier', [])
if world_cleaned:
    old_stories = existing.get('world', {}).get('stories', [])
    for s in old_stories:
        s['time'] = s.get('time', update_time)
        if 'posted' not in s:
            s['posted'] = now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        world_earlier.insert(0, s)
    world_earlier = expire_old_stories(world_earlier)
    # Deduplicate world earlier by headline similarity
    seen_world_headlines = set()
    deduped_world = []
    for s in world_earlier:
        # Use first perspective URL as dedup key
        urls = [p.get('url', '') for p in s.get('perspectives', [])]
        primary_url = urls[0] if urls else ''
        if primary_url and primary_url in seen_world_headlines:
            continue
        if primary_url:
            seen_world_headlines.add(primary_url)
        deduped_world.append(s)
    world_earlier = deduped_world[:10]

    # HANDLE DIVERSITY: no handle should appear as the SAME SIDE twice across the 3 world stories.
    # If @ggreenwald is Independent in Story 1, he can't be Independent in Story 2 or 3.
    seen_side_handles = {'Conservative': set(), 'Democrat': set(), 'Independent': set(), 'Third-party': set()}
    diverse_world = []
    for s in world_cleaned:
        ok = True
        pending = {}
        for p in s.get('perspectives', []):
            label = p.get('label', '')
            h = (p.get('handle','') or '').lower().lstrip('@')
            if h and h in seen_side_handles.get(label, set()):
                print(f"  REJECT world story: @{h} repeats as {label} — forcing handle variety", file=sys.stderr)
                ok = False; break
            pending[label] = h
        if ok:
            for lab, h in pending.items():
                if h: seen_side_handles.setdefault(lab, set()).add(h)
            diverse_world.append(s)
    world_cleaned = diverse_world

    # Backfill world to target=3 from previous stories + earlier if short
    # CRITICAL: re-check age AND URL validity on every backfill candidate —
    # never let stale content OR profile-only URLs through.
    WORLD_TARGET = 3
    def _world_fresh(os):
        """Every perspective URL must be <24h old AND be a /status/ URL (no profiles)."""
        for p in (os.get('perspectives') or []):
            url = p.get('url') or ''
            if '/status/' not in url:
                return False  # profile-only URL — reject backfill candidate
            a = url_age_hours(url)
            if a is not None and a > MAX_AGE_HOURS:
                return False
        return True
    if len(world_cleaned) < WORLD_TARGET:
        used_urls = set()
        for s in world_cleaned:
            for p in (s.get('perspectives') or []):
                if p.get('url'): used_urls.add(p['url'])
        for old_s in existing.get('world', {}).get('stories', []):
            if len(world_cleaned) >= WORLD_TARGET: break
            perspective_urls = {p.get('url') for p in (old_s.get('perspectives') or []) if p.get('url')}
            if perspective_urls & used_urls: continue
            if not _world_fresh(old_s):
                print(f"  BACKFILL SKIP world: stale story '{old_s.get('headline','')[:50]}'", file=sys.stderr)
                continue
            world_cleaned.append(old_s)
            used_urls.update(perspective_urls)
        for old_s in existing.get('world', {}).get('earlier', []):
            if len(world_cleaned) >= WORLD_TARGET: break
            perspective_urls = {p.get('url') for p in (old_s.get('perspectives') or []) if p.get('url')}
            if perspective_urls & used_urls: continue
            if not _world_fresh(old_s):
                continue
            world_cleaned.append(old_s)
            used_urls.update(perspective_urls)
        if len(world_cleaned) < WORLD_TARGET:
            print(f"  WARN world: only {len(world_cleaned)}/{WORLD_TARGET} after backfill (all alternatives were stale)", file=sys.stderr)
    # Final post-assembly dedup: handle diversity + headline similarity across ALL sources
    # (fresh Grok picks AND backfilled stories). This is the gate that kills SPLC-twice
    # and CoryBooker-twice issues — where one slipped through fresh and one via backfill.
    world_cleaned = enforce_uniqueness(world_cleaned, label='world')
    # Semantic same-topic verification — ask Grok if all 3 perspectives actually
    # discuss the headline event, or if any has drifted to unrelated territory.
    world_cleaned = grok_same_topic_check(world_cleaned, tab_label='world')
    output['world'] = {'stories': world_cleaned[:WORLD_TARGET], 'earlier': world_earlier}
else:
    print("  WARNING: World stories failed validation, rebuilding from existing (age+URL-checked)", file=sys.stderr)
    WORLD_TARGET = 3
    def _world_fresh2(os):
        for p in (os.get('perspectives') or []):
            url = p.get('url') or ''
            if '/status/' not in url: return False  # reject profile-only
            a = url_age_hours(url)
            if a is not None and a > MAX_AGE_HOURS: return False
        return True
    rebuilt = []
    used = set()
    for s in existing.get('world', {}).get('stories', []):
        if len(rebuilt) >= WORLD_TARGET: break
        purls = {p.get('url') for p in (s.get('perspectives') or []) if p.get('url')}
        if purls & used: continue
        if not _world_fresh2(s): continue
        rebuilt.append(s); used.update(purls)
    for s in existing.get('world', {}).get('earlier', []):
        if len(rebuilt) >= WORLD_TARGET: break
        purls = {p.get('url') for p in (s.get('perspectives') or []) if p.get('url')}
        if purls & used: continue
        if not _world_fresh2(s): continue
        rebuilt.append(s); used.update(purls)
    output['world'] = {'stories': rebuilt, 'earlier': existing.get('world', {}).get('earlier', [])}

# Process USA (same logic as World — 3 perspectives per story, national US news)
usa_data = data.get('usa', {})
usa_items = usa_data if isinstance(usa_data, list) else [usa_data]
usa_cleaned = []
for u in usa_items:
    us = clean_world(u)  # reuse world validator — identical structure
    if us:
        usa_cleaned.append(us)

usa_earlier = existing.get('usa', {}).get('earlier', [])
if usa_cleaned:
    old_usa = existing.get('usa', {}).get('stories', [])
    for s in old_usa:
        s['time'] = s.get('time', update_time)
        if 'posted' not in s:
            s['posted'] = now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        usa_earlier.insert(0, s)
    usa_earlier = expire_old_stories(usa_earlier)
    seen_usa_urls = set()
    dedup_usa = []
    for s in usa_earlier:
        urls = [p.get('url', '') for p in s.get('perspectives', [])]
        primary_url = urls[0] if urls else ''
        if primary_url and primary_url in seen_usa_urls: continue
        if primary_url: seen_usa_urls.add(primary_url)
        dedup_usa.append(s)
    usa_earlier = dedup_usa[:10]

    # Handle diversity across USA stories
    seen_usa_side = {'Conservative': set(), 'Democrat': set(), 'Independent': set(), 'Third-party': set()}
    diverse_usa = []
    for s in usa_cleaned:
        ok = True
        pending = {}
        for p in s.get('perspectives', []):
            label = p.get('label', '')
            h = (p.get('handle','') or '').lower().lstrip('@')
            if h and h in seen_usa_side.get(label, set()):
                print(f"  REJECT USA story: @{h} repeats as {label}", file=sys.stderr)
                ok = False; break
            pending[label] = h
        if ok:
            for lab, h in pending.items():
                if h: seen_usa_side.setdefault(lab, set()).add(h)
            diverse_usa.append(s)
    usa_cleaned = diverse_usa

    # Backfill USA with age + /status/ URL re-check
    USA_TARGET = 3
    def _usa_fresh(os):
        for p in (os.get('perspectives') or []):
            url = p.get('url') or ''
            if '/status/' not in url: return False  # reject profile-only
            a = url_age_hours(url)
            if a is not None and a > MAX_AGE_HOURS: return False
        return True
    if len(usa_cleaned) < USA_TARGET:
        used_urls = set()
        for s in usa_cleaned:
            for p in (s.get('perspectives') or []):
                if p.get('url'): used_urls.add(p['url'])
        for old_s in existing.get('usa', {}).get('stories', []):
            if len(usa_cleaned) >= USA_TARGET: break
            purls = {p.get('url') for p in (old_s.get('perspectives') or []) if p.get('url')}
            if purls & used_urls: continue
            if not _usa_fresh(old_s): continue
            usa_cleaned.append(old_s)
            used_urls.update(purls)
        for old_s in existing.get('usa', {}).get('earlier', []):
            if len(usa_cleaned) >= USA_TARGET: break
            purls = {p.get('url') for p in (old_s.get('perspectives') or []) if p.get('url')}
            if purls & used_urls: continue
            if not _usa_fresh(old_s): continue
            usa_cleaned.append(old_s)
            used_urls.update(purls)
    usa_cleaned = enforce_uniqueness(usa_cleaned, label='usa')
    usa_cleaned = grok_same_topic_check(usa_cleaned, tab_label='usa')
    output['usa'] = {'stories': usa_cleaned[:USA_TARGET], 'earlier': usa_earlier}
else:
    # No new USA stories — rebuild from existing with age + /status/ URL re-check
    USA_TARGET = 3
    rebuilt = []
    used = set()
    for s in existing.get('usa', {}).get('stories', []):
        if len(rebuilt) >= USA_TARGET: break
        purls = {p.get('url') for p in (s.get('perspectives') or []) if p.get('url')}
        if purls & used: continue
        bad = False
        for p in (s.get('perspectives') or []):
            url = p.get('url') or ''
            if '/status/' not in url:
                bad = True; break  # profile-only — reject
            a = url_age_hours(url)
            if a is not None and a > MAX_AGE_HOURS: bad = True; break
        if bad: continue
        rebuilt.append(s); used.update(purls)
    rebuilt = enforce_uniqueness(rebuilt, label='usa-rebuild')
    rebuilt = grok_same_topic_check(rebuilt, tab_label='usa-rebuild')
    output['usa'] = {'stories': rebuilt, 'earlier': existing.get('usa', {}).get('earlier', [])}

# Process all array tabs (everything is now 3 stories)
NON_SOCAL_KEYWORDS = {'new york', 'nyc', 'manhattan', 'brooklyn', 'michigan', 'detroit', 'chicago', 'boston', 'seattle', 'portland', 'denver', 'atlanta', 'miami', 'dallas', 'houston', 'phoenix', 'philadelphia', 'san francisco', 'minnesota', 'ohio', 'florida', 'texas', 'virginia', 'washington dc', 'maine', 'vermont'}

for tab in ['elon', 'sports', 'allin', 'pods', 'business', 'top', 'msm', 'pg6', 'recipe', 'science', 'local', 'memes', 'comedy', 'tiktok', 'golf']:
    tab_data = data.get(tab, [])
    posts = tab_data if isinstance(tab_data, list) else [tab_data]
    cleaned = []
    seen_urls = set()
    seen_handles = set()
    for p in posts:
        s = clean_story(p, tab=tab)
        if s and s['url'] not in seen_urls:
            # Honesty scoring is now fully Grok's holistic judgment — no Python overrides.
            # See grok_system.txt for the criteria Grok applies (source reputation,
            # track record, bias, content quality, all weighted together).
            # LOCAL tab: reject non-SoCal stories
            if tab == 'local':
                combined = (s.get('headline', '') + ' ' + s.get('body', '')).lower()
                if any(kw in combined for kw in NON_SOCAL_KEYWORDS):
                    print(f"  REJECT local: non-SoCal story '{s['headline'][:50]}'", file=sys.stderr)
                    continue
                # Also reject stories sourced from non-local outlets — even if the content
                # mentions SoCal, a @nypost or @nytimes byline makes the block look like
                # NY news to users. Keep Local to local-first outlets and SoCal citizen accounts.
                local_handle = (s.get('handle','') or '').lower().lstrip('@')
                NON_LOCAL_OUTLETS = {
                    'nypost', 'nytimes', 'nymag', 'newyorkpost', 'newyorker', 'gothamist',
                    'bostonglobe', 'washingtonpost', 'chicagotribune', 'detroitnews',
                    'miamiherald', 'houstonchronicle', 'dallasnews', 'apnews',
                    'reuters', 'cnn', 'foxnews', 'nbcnews', 'cbsnews', 'abcnews',
                    'bbcworld', 'usatoday', 'axios', 'politico', 'thehill', 'bloomberg'
                }
                if local_handle in NON_LOCAL_OUTLETS:
                    print(f"  REJECT local: non-local source @{local_handle} '{s['headline'][:50]}'", file=sys.stderr)
                    continue
            # TIKTOK tab: URL MUST be tiktok.com — reject X profile URLs, etc
            if tab == 'tiktok':
                url = s.get('url', '').lower()
                if 'tiktok.com' not in url:
                    print(f"  REJECT tiktok: non-tiktok URL '{s.get('url','')[:60]}'", file=sys.stderr)
                    continue
            # GOLF tab: URL should be tiktok.com or youtube.com (video-first)
            if tab == 'golf':
                url = s.get('url', '').lower()
                if 'tiktok.com' not in url and 'youtube.com' not in url and 'youtu.be' not in url and '/status/' not in url:
                    print(f"  REJECT golf: not a video URL '{s.get('url','')[:60]}'", file=sys.stderr)
                    continue
            # Handle diversity: max 1 per handle for tabs where variety matters
            # (Sports is handled specially below — Stephen A & Cowherd are allowed as pinned bonus slots)
            if tab in ('msm', 'pods', 'business', 'comedy', 'memes', 'tiktok', 'pg6'):
                h = s.get('handle', '').lower()
                if h in seen_handles:
                    print(f"  REJECT {tab}: duplicate handle {h}", file=sys.stderr)
                    continue
                seen_handles.add(h)
                # Pods: also dedupe by SHOW — a Tucker clip from @TuckerCarlson AND
                # a Tucker clip from a fan-repost account (@RyanRozbiani) = same show, reject one.
                # Uses word-boundary regex so "tucker" hits whether it's a handle, headline, or body.
                if tab == 'pods':
                    _text_blob = (s.get('handle','') + ' ' + s.get('headline','') + ' ' + s.get('body','')).lower()
                    # show_key: list of word-boundary patterns to match.
                    SHOW_PATTERNS = [
                        ('tucker',      r'\btucker\b|tuckercarlson'),
                        ('rogan',       r'\brogan\b|\bjre\b|joerogan'),
                        ('lex',         r'lex\s*fridman|fridmanclips|lexclips'),
                        ('allin',       r'all[-\s]?in\s*pod|theallinpod|allinpod'),
                        ('pbd',         r'patrick\s*bet[-\s]?david|pbdpodcast'),
                        ('shawnryan',   r'shawn\s*ryan|shawnryan'),
                        ('megyn',       r'megyn\s*kelly|megynkelly'),
                        ('crowder',     r'crowder|louderwithcrowder|stevencrowder'),
                        ('flagrant',    r'flagrant|andrew\s*schulz|andrewschulz'),
                        ('fullsend',    r'full\s*send|fullsend'),
                        ('callher',     r'call\s*her\s*daddy|callherdaddy|alex\s*cooper'),
                        ('acarolla',    r'adam\s*carolla|adamcarolla'),
                        ('russell',     r'russell\s*brand|russellbrand'),
                        ('piers',       r'piers\s*morgan|piersmorgan'),
                        ('theo',        r'theo\s*von|theovon|thiseasthemom'),
                    ]
                    show_key = None
                    for sk, pat in SHOW_PATTERNS:
                        if re.search(pat, _text_blob):
                            show_key = sk; break
                    if show_key:
                        bk = 'show:' + show_key
                        if bk in seen_handles:
                            print(f"  REJECT pods: duplicate show '{show_key}' — already have one from @{s.get('handle','')}", file=sys.stderr)
                            continue
                        seen_handles.add(bk)
            # Sports: bonus slots are Stephen A (exactly 1) + Cowherd (exactly 1) — never 2 of the same bonus.
            if tab == 'sports':
                h = s.get('handle', '').lower().lstrip('@')
                is_sas = h in ('stephenasmith', 'firsttake')
                is_cowherd = h in ('colincowherd', 'theherd')
                # Track bonus slot uniqueness
                if is_sas and 'bonus:sas' in seen_handles:
                    print(f"  REJECT sports: second Stephen A clip (only 1 allowed) — {h}", file=sys.stderr)
                    continue
                if is_cowherd and 'bonus:cowherd' in seen_handles:
                    print(f"  REJECT sports: second Cowherd clip (only 1 allowed) — {h}", file=sys.stderr)
                    continue
                if not (is_sas or is_cowherd) and h in seen_handles:
                    print(f"  REJECT sports: duplicate news handle {h}", file=sys.stderr)
                    continue
                if is_sas: seen_handles.add('bonus:sas')
                elif is_cowherd: seen_handles.add('bonus:cowherd')
                else: seen_handles.add(h)
            # Cross-day dedup: never repeat a story shown in the last 72 hours.
            # EXCEPTIONS:
            #   - 'elon' tab: only dedup by exact URL within last 24h (he posts often
            #     and the headline-similarity check rejects too many fresh takes).
            dup = is_recently_seen(s.get('url', ''), s.get('headline', ''), SEEN_HISTORY)
            if dup:
                reason, prev_headline = dup
                if tab == 'elon':
                    # Only block exact same URL within 24h. Otherwise, allow.
                    if reason == 'url':
                        # Check how recently
                        same_recent = False
                        for h in SEEN_HISTORY[-30:]:
                            if h.get('url') == s.get('url',''):
                                try:
                                    seen_dt = datetime.datetime.fromisoformat(h.get('t',''))
                                    if (datetime.datetime.now() - seen_dt).total_seconds() < 24*3600:
                                        same_recent = True; break
                                except Exception: pass
                        if same_recent:
                            print(f"  REJECT elon: same URL shown <24h ago", file=sys.stderr)
                            continue
                        # else allow
                    # else (headline match): allow for elon
                else:
                    print(f"  REJECT {tab}: {reason} dedup '{s['headline'][:50]}' ~= '{prev_headline[:50]}'", file=sys.stderr)
                    continue
            # Topic diversity within THIS batch: if >= 40% keyword overlap with a story we already kept, skip (pick a different topic instead)
            new_norm = _normalize_headline((s.get('headline') or '') + ' ' + (s.get('body') or ''))
            topic_collision = False
            for kept in cleaned:
                kept_norm = _normalize_headline((kept.get('headline') or '') + ' ' + (kept.get('body') or ''))
                if len(new_norm) < 3 or len(kept_norm) < 3:
                    continue
                overlap = len(new_norm & kept_norm)
                smaller = min(len(new_norm), len(kept_norm))
                if smaller > 0 and overlap / smaller >= 0.4:
                    print(f"  REJECT {tab}: same-topic as '{kept.get('headline','')[:50]}' — '{s['headline'][:50]}'", file=sys.stderr)
                    topic_collision = True
                    break
            if topic_collision:
                continue
            seen_urls.add(s['url'])
            cleaned.append(s)

    tab_earlier = existing.get(tab, {}).get('earlier', [])
    if cleaned:
        old_stories = existing.get(tab, {}).get('stories', [])
        for s in old_stories:
            s['time'] = s.get('time', update_time)
            if 'posted' not in s:
                s['posted'] = now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            tab_earlier.insert(0, s)
        tab_earlier = expire_old_stories(tab_earlier)
        # Deduplicate earlier by URL — keep only first occurrence of each URL
        seen_earlier_urls = set()
        deduped_earlier = []
        for s in tab_earlier:
            urls = []
            if 'perspectives' in s:
                urls = [p.get('url', '') for p in s.get('perspectives', [])]
            else:
                urls = [s.get('url', '')]
            primary_url = urls[0] if urls else ''
            if primary_url and primary_url in seen_earlier_urls:
                continue  # Skip duplicate
            if primary_url:
                seen_earlier_urls.add(primary_url)
            deduped_earlier.append(s)
        tab_earlier = deduped_earlier[:10]
        # Target count: 5 for sports (3 news + 2 bonus), 3 for everything else
        target = 4 if tab == 'sports' else 3
        # If fresh fetch is short, pad aggressively — but RE-CHECK AGE on every backfill candidate
        # (a post that was fresh yesterday might now be >24h old; never let stale content through)
        if len(cleaned) < target:
            used_urls = set(s.get('url') for s in cleaned)
            _max_age = TAB_AGE_OVERRIDE.get(tab, MAX_AGE_HOURS)
            def _fresh_enough(os):
                u = os.get('url') or ''
                a = url_age_hours(u)
                if a is not None and a > _max_age:
                    print(f"  BACKFILL SKIP {tab}: {int(a)}h old (limit {_max_age}h) — {os.get('headline','')[:50]}", file=sys.stderr)
                    return False
                return True
            # Priority 1: previous run's top stories (re-age-checked)
            for old_s in existing.get(tab, {}).get('stories', []):
                if len(cleaned) >= target: break
                old_url = old_s.get('url')
                if old_url and old_url in used_urls: continue
                if not _fresh_enough(old_s): continue
                cleaned.append(old_s); used_urls.add(old_url)
            # Priority 2: previous earlier (also re-age-checked)
            for old_s in existing.get(tab, {}).get('earlier', []):
                if len(cleaned) >= target: break
                old_url = old_s.get('url')
                if old_url and old_url in used_urls: continue
                if not _fresh_enough(old_s): continue
                cleaned.append(old_s); used_urls.add(old_url)
            if len(cleaned) < target:
                print(f"  WARN {tab}: only {len(cleaned)}/{target} stories even after backfill", file=sys.stderr)
        # Post-assembly uniqueness for single-post tabs — catches duplicate handles
        # + near-identical headlines that slipped through from backfill (the 2-WatcherGuru
        # bug pattern).
        if tab in ('business', 'msm', 'pods', 'pg6', 'memes', 'comedy', 'top', 'recipe', 'science'):
            cleaned = enforce_single_post_uniqueness(cleaned, tab_label=tab)

        # SPORTS-SPECIFIC: ensure both Stephen A and Cowherd slots are filled.
        # If Grok didn't return them, pull the most recent SAS/Cowherd post from
        # existing.sports (history). User insists both are required every run.
        if tab == 'sports':
            def _is_sas(s):
                h = (s.get('handle','') or '').lower().lstrip('@')
                return h in ('stephenasmith', 'firsttake')
            def _is_cowherd(s):
                h = (s.get('handle','') or '').lower().lstrip('@')
                return h in ('colincowherd', 'theherd')
            has_sas = any(_is_sas(s) for s in cleaned)
            has_cowherd = any(_is_cowherd(s) for s in cleaned)
            if not has_sas or not has_cowherd:
                # Look in existing sports history for last SAS/Cowherd post
                old_sports = existing.get('sports', {}).get('stories', []) + existing.get('sports', {}).get('earlier', [])
                if not has_sas:
                    for old_s in old_sports:
                        if _is_sas(old_s):
                            print(f"  SPORTS: backfilling SAS slot from history — @{old_s.get('handle')}", file=sys.stderr)
                            cleaned.append(old_s); break
                if not has_cowherd:
                    for old_s in old_sports:
                        if _is_cowherd(old_s):
                            print(f"  SPORTS: backfilling Cowherd slot from history — @{old_s.get('handle')}", file=sys.stderr)
                            cleaned.append(old_s); break
            # Trim non-SAS/Cowherd news posts to make room for the bonus slots.
            # Final order: 2 news + 1 SAS + 1 Cowherd = 4 total.
            news_posts = [s for s in cleaned if not _is_sas(s) and not _is_cowherd(s)]
            sas_posts = [s for s in cleaned if _is_sas(s)]
            cow_posts = [s for s in cleaned if _is_cowherd(s)]
            cleaned = news_posts[:2] + sas_posts[:1] + cow_posts[:1]

        output[tab] = {'stories': cleaned[:target], 'earlier': tab_earlier}
    else:
        # No fresh stories passed filters. Construct target from existing.stories + existing.earlier.
        print(f"  WARNING: {tab} had no valid fresh stories, rebuilding from existing", file=sys.stderr)
        target = 4 if tab == 'sports' else 3
        rebuilt = []
        used_urls = set()
        for s in existing.get(tab, {}).get('stories', []):
            if len(rebuilt) >= target: break
            url = s.get('url')
            if url and url in used_urls: continue
            rebuilt.append(s)
            used_urls.add(url)
        for s in existing.get(tab, {}).get('earlier', []):
            if len(rebuilt) >= target: break
            url = s.get('url')
            if url and url in used_urls: continue
            rebuilt.append(s)
            used_urls.add(url)
        old_earlier = existing.get(tab, {}).get('earlier', [])
        if len(rebuilt) < target:
            print(f"  WARN {tab}: rebuilt only {len(rebuilt)}/{target} from existing", file=sys.stderr)
        # Same dedup pass on rebuilt stories
        if tab in ('business', 'msm', 'pods', 'pg6', 'memes', 'comedy', 'top', 'recipe', 'science'):
            rebuilt = enforce_single_post_uniqueness(rebuilt, tab_label=tab + '-rebuild')
        output[tab] = {'stories': rebuilt, 'earlier': old_earlier}

# ---- Quality report ----
total_stories = 0
real_urls = 0
profile_urls = 0
for tab in ['world', 'business', 'sports', 'elon', 'allin', 'top', 'msm', 'pg6', 'pods', 'recipe', 'local', 'memes', 'comedy', 'tiktok', 'golf']:
    for s in output.get(tab, {}).get('stories', []):
        total_stories += 1
        if 'perspectives' in s:
            for p in s['perspectives']:
                if '/status/' in p.get('url', ''):
                    real_urls += 1
                else:
                    profile_urls += 1
        else:
            if '/status/' in s.get('url', ''):
                real_urls += 1
            else:
                profile_urls += 1

# Per-tab breakdown
print(f"\n--- QC REPORT ---", file=sys.stderr)
for tab in ['world', 'usa', 'business', 'sports', 'elon', 'allin', 'top', 'msm', 'pg6', 'pods', 'recipe', 'science', 'local', 'memes', 'comedy', 'tiktok', 'golf']:
    stories = output.get(tab, {}).get('stories', [])
    earlier = output.get(tab, {}).get('earlier', [])
    status = "✓" if len(stories) >= 3 else f"⚠ ONLY {len(stories)}"
    print(f"  {tab:10s}: {len(stories)} stories {status}, {len(earlier)} earlier", file=sys.stderr)
print(f"Quality: {total_stories} stories, {real_urls} real URLs, {profile_urls} profile-only", file=sys.stderr)
print(f"--- END QC ---\n", file=sys.stderr)

# ---- Stock quotes fetching REMOVED (billionaire holdings/market tracker deleted per user) ----
# No quotes fetching. Don't carry forward old quotes either.

# Write output
# Update cross-day seen history with the stories we published this run
now_iso = datetime.datetime.now().isoformat()
for tab_key, tab_val in output.items():
    if isinstance(tab_val, dict) and 'stories' in tab_val:
        for s in tab_val['stories']:
            SEEN_HISTORY.append({
                't': now_iso,
                'url': s.get('url', ''),
                'headline': s.get('headline', ''),
                'tab': tab_key
            })
save_seen_history(SEEN_HISTORY)
print(f"  Seen history saved: {len(SEEN_HISTORY)} total entries", file=sys.stderr)

# Preserve static tabs (freespeech) from existing stories.json — these are hand-curated
# and not populated by Grok, so we carry them through unchanged every run.
STATIC_TABS = ['freespeech']
for static_key in STATIC_TABS:
    if static_key in existing:
        output[static_key] = existing[static_key]
    elif static_key not in output:
        output[static_key] = {'stories': [], 'earlier': []}

# ============================================================
# NEVER-EMPTY GUARANTEE
# Per user requirement: every tab must always have at least 1 story.
# If a tab is empty after all filters/dedup/semantic, fall back to:
#   1. Most recent story from existing.stories (last cron's output)
#   2. Most recent story from existing.earlier (older history)
#   3. (No further fallback — tab will be empty if literally nothing exists)
# Stories carried over get a 'carried_over' flag so the UI could optionally
# de-emphasize them, but ship something rather than nothing.
# ============================================================
TAB_TARGETS = {
    'world': 3, 'usa': 3, 'business': 3, 'allin': 3, 'msm': 3, 'pg6': 3,
    'pods': 3, 'recipe': 3, 'science': 3, 'local': 3, 'top': 3, 'memes': 3,
    'comedy': 3, 'tiktok': 3, 'elon': 3, 'golf': 3, 'sports': 4,
}

def _scan_snapshots_for_tab(tab_key, max_snapshots=20):
    """Pull stories for a tab from the last N desktop snapshots (deeper history).
    Used when in-file 'earlier' is too thin to top up. Returns list of stories
    deduped by URL, freshest snapshot first.
    """
    import glob as _glob, os as _os
    pool = []
    seen = set()
    snaps = sorted(
        _glob.glob(_os.path.expanduser('~/Desktop/expresso_snapshots/*/code/stories.example.json')),
        reverse=True
    )[:max_snapshots]
    for f in snaps:
        try:
            d = json.load(open(f))
            for s in d.get(tab_key, {}).get('stories', []) + d.get(tab_key, {}).get('earlier', []):
                urls = set([s.get('url','')] + [p.get('url','') for p in s.get('perspectives',[])])
                urls.discard('')
                if urls & seen: continue
                pool.append(s)
                seen.update(urls)
        except Exception: pass
    return pool

for tab_key in list(output.keys()):
    if tab_key in ('lastUpdated', 'freespeech', 'quotes'): continue
    tab_data = output.get(tab_key)
    if not isinstance(tab_data, dict): continue
    n_target = TAB_TARGETS.get(tab_key, 1)
    current = tab_data.get('stories') or []
    if len(current) >= n_target: continue  # already at target

    # Need to top up. Pull from existing.stories + existing.earlier first (in-file history).
    fallback_pool = (existing.get(tab_key, {}).get('stories', []) +
                     existing.get(tab_key, {}).get('earlier', []))
    # If in-file history isn't enough to reach target, scan desktop snapshots (~20 prior crons).
    if len(fallback_pool) < (n_target - len(current) + len(current)):  # need more
        snapshot_pool = _scan_snapshots_for_tab(tab_key)
        # Combine, in-file first (more recent), then snapshot history
        existing_urls = set()
        for s in fallback_pool:
            if s.get('url'): existing_urls.add(s['url'])
            for p in s.get('perspectives',[]):
                if p.get('url'): existing_urls.add(p['url'])
        for s in snapshot_pool:
            urls = set([s.get('url','')] + [p.get('url','') for p in s.get('perspectives',[])])
            urls.discard('')
            if urls & existing_urls: continue
            fallback_pool.append(s)
            existing_urls.update(urls)
        if fallback_pool:
            print(f"  [never-empty] {tab_key}: pulled {len(snapshot_pool)} stories from snapshot history for top-up", file=sys.stderr)
    if not fallback_pool:
        print(f"  [never-empty] {tab_key}: {len(current)}/{n_target} and no historical content to top up", file=sys.stderr)
        continue

    # Track URLs already in current to avoid duplicates
    seen_urls = set()
    for s in current:
        if s.get('url'): seen_urls.add(s['url'])
        for p in s.get('perspectives', []):
            if p.get('url'): seen_urls.add(p['url'])

    # Add highest-quality not-already-seen stories from history
    needed = n_target - len(current)
    added = []
    for s in fallback_pool:
        if len(added) >= needed: break
        s_urls = set()
        if s.get('url'): s_urls.add(s['url'])
        for p in s.get('perspectives', []):
            if p.get('url'): s_urls.add(p['url'])
        if s_urls & seen_urls: continue
        s_copy = dict(s)
        s_copy['carried_over'] = True
        added.append(s_copy)
        seen_urls.update(s_urls)

    if added:
        print(f"  [never-empty] {tab_key}: had {len(current)}/{n_target}, carrying over {len(added)} from history", file=sys.stderr)
        output[tab_key]['stories'] = current + added

# Honesty scoring is now done HOLISTICALLY by Grok during initial curation —
# no post-hoc Python overrides. Grok considers source reputation, track record,
# bias level, and content quality together to produce a single 0-10 score with
# a one-line plain-English reason in `notes`. See grok_system.txt for criteria.

with open('stories.json', 'w') as f:
    json.dump(output, f, indent=2)

print("stories.json updated successfully")
