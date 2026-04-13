#!/usr/bin/env python3
"""
Parse Grok API response, validate every field, and output clean stories.json data.
If validation fails, exit non-zero so the pipeline keeps the old data.
"""
import sys, json, re, datetime

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
    tab_keys = {'world','business','sports','elon','allin','top','msm','pg6','pods','recipe','science','local'}
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
    'no recent post', 'no recent viral', 'no recent take', 'no recent hot take',
    'setting to null', 'no post found', 'not found',
    'no hot take found', 'no take found', 'no viral post', 'no notable post',
    'n/a', 'placeholder', 'no story found',
    'could not find', 'unable to find', 'no matching', 'none found'
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
    prompt = f'Use the x_search tool to search for: from:{h} {headline[:60]}. Return ONLY the tweet URL from the x_search results in format https://x.com/{h}/status/NUMERIC_ID. You MUST use x_search to find real posts. Do NOT invent or reason about status IDs. Only return URLs from actual tool results. If x_search returns no results, return "null".'
    payload = json.dumps({
        'model': 'grok-4-1-fast-non-reasoning',
        'input': [
            {'role': 'system', 'content': 'You MUST call x_search before answering. Return ONLY a tweet URL from the search results. Do NOT generate or guess status IDs. No explanation.'},
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

    # World perspectives (supports array or single object)
    world_raw = data.get('world', {})
    world_list = world_raw if isinstance(world_raw, list) else [world_raw]
    for wi, w in enumerate(world_list):
        if not isinstance(w, dict):
            continue
        for key in ['conservative', 'democrat', 'independent']:
            p = w.get(key, {})
            if isinstance(p, dict) and p.get('handle') and not p.get('url'):
                tasks.append((['world', wi, key], p['handle'], w.get('headline', '')))

    # Array tabs
    for tab in ['elon', 'sports', 'allin', 'pods', 'business', 'local']:
        items = data.get(tab, [])
        if not isinstance(items, list):
            items = [items]
        for i, item in enumerate(items):
            if isinstance(item, dict) and item.get('handle') and not item.get('url'):
                tasks.append(([tab, i], item['handle'], item.get('headline', '')))

    # Single tabs
    for tab in ['top', 'msm', 'pg6', 'recipe', 'science']:
        item = data.get(tab, {})
        if isinstance(item, dict) and item.get('handle') and not item.get('url'):
            tasks.append(([tab], item['handle'], item.get('headline', '')))

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
    """Verify URL exists, matches the handle, and isn't reused across tabs."""
    if url and isinstance(url, str) and '/status/' in url:
        # Check handle in URL matches claimed handle
        url_h = url_handle(url)
        claimed_h = handle.lower().lstrip('@')
        if url_h and url_h != claimed_h:
            print(f"  MISMATCHED URL: {url} (URL says @{url_h}, claim says {handle})", file=sys.stderr)
            # Still verify — maybe Grok mixed up handles but URL is real
        # Reject if same URL already used
        if url in _used_urls:
            print(f"  DEDUP: {url} already used", file=sys.stderr)
        elif verify_url(url):
            _used_urls.add(url)
            return url
        else:
            print(f"  FAKE URL (404): {url}", file=sys.stderr)
    if not handle:
        return '#'
    h = handle.lower().lstrip('@')
    return f"https://x.com/{h}"

# Map handles to real names so headlines are readable by normal people
HANDLE_NAMES = {
    '@pmarca': 'Marc Andreessen', '@chamath': 'Chamath Palihapitiya',
    '@DavidSacks': 'David Sacks', '@PalmerLuckey': 'Palmer Luckey',
    '@friedberg': 'David Friedberg', '@elonmusk': 'Elon Musk',
    '@JackPosobiec': 'Jack Posobiec', '@Cernovich': 'Mike Cernovich',
    '@RealCandaceO': 'Candace Owens', '@benshapiro': 'Ben Shapiro',
    '@TuckerCarlson': 'Tucker Carlson', '@DonaldJTrumpJr': 'Don Jr.',
    '@charliekirk11': 'Charlie Kirk', '@AOC': 'AOC',
    '@BernieSanders': 'Bernie Sanders', '@RBReich': 'Robert Reich',
    '@ggreenwald': 'Glenn Greenwald', '@Snowden': 'Edward Snowden',
    '@RayDalio': 'Ray Dalio', '@stephenasmith': 'Stephen A. Smith',
    '@colincowherd': 'Colin Cowherd', '@joerogan': 'Joe Rogan',
    '@lexfridman': 'Lex Fridman', '@MattWalshBlog': 'Matt Walsh',
    '@BillMelugin_': 'Bill Melugin', '@TimcastNews': 'Tim Pool',
    '@JamesOKeefeIII': "James O'Keefe", '@LibsOfTikTok': 'Libs of TikTok',
    '@SenWarren': 'Elizabeth Warren', '@SenTedCruz': 'Ted Cruz',
    '@PopCrave': 'Pop Crave', '@TMZ': 'TMZ',
    '@unusual_whales': 'Unusual Whales', '@WatcherGuru': 'Watcher Guru',
    '@ShamsCharania': 'Shams Charania (ESPN)', '@wojespn': 'Adrian Wojnarowski',
}

def humanize_headline(headline, handle):
    """Replace @handles in headlines with real names so normal readers understand."""
    h = headline
    # Replace the handle itself if it appears in the headline
    if handle in HANDLE_NAMES:
        short = handle.lstrip('@')
        # Replace variations: @handle, handle (without @), lowercase
        for variant in [handle, short, short.lower()]:
            if variant in h:
                h = h.replace(variant, HANDLE_NAMES[handle])
    # Replace any other known handles mentioned in the headline
    for hndl, name in HANDLE_NAMES.items():
        short = hndl.lstrip('@')
        if short in h and name not in h:
            h = h.replace('@' + short, name).replace(short, name)
    return h

def clean_story(s):
    """Validate and clean a single story dict. Returns None if garbage."""
    if not isinstance(s, dict):
        return None
    if is_garbage(s.get('headline', '')) and is_garbage(s.get('body', '')):
        return None
    handle = s.get('handle', '')
    if not handle:
        return None
    headline = str(s.get('headline', '') or s.get('body', '')[:80] or 'Untitled')
    headline = humanize_headline(headline, handle)
    return {
        'headline': headline,
        'handle': handle,
        'url': clean_url(handle, s.get('url')),
        'body': str(s.get('body', '')),
        'engagement': str(s.get('engagement', '')),
        'honesty': str(s.get('honesty', '8/10')),
        'notes': str(s.get('notes', ''))
    }

def clean_world(w):
    """Validate world story (3 perspectives)"""
    if not isinstance(w, dict):
        return None
    headline = w.get('headline', w.get('topic', ''))
    if is_garbage(headline):
        return None
    perspectives = []
    for key, label in [('conservative', 'Conservative'), ('democrat', 'Democrat'), ('independent', 'Independent')]:
        p = w.get(key, {})
        if not isinstance(p, dict) or not p.get('handle'):
            continue
        ptext = p.get('quote', p.get('angle', ''))
        if is_garbage(ptext):
            print(f"  SKIP garbage world/{key}", file=sys.stderr)
            continue
        perspectives.append({
            'label': label,
            'handle': p['handle'],
            'url': clean_url(p['handle'], p.get('url')),
            'text': str(ptext),
            'engagement': str(p.get('engagement', '')),
            'honesty': str(p.get('honesty', w.get('honesty', '8/10')))
        })
    if len(perspectives) < 2:
        print("  WARNING: World has fewer than 2 valid perspectives", file=sys.stderr)
        return None
    footnotes = w.get('footnotes', [])
    if not isinstance(footnotes, list):
        footnotes = []
    return {
        'headline': str(headline),
        'honesty': str(w.get('honesty', '8/10')),
        'perspectives': perspectives,
        'footnotes': [str(f) for f in footnotes],
        'notes': str(w.get('notes', '')),
        'body': 'Three-perspective roundup.'
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

output = {
    'lastUpdated': now.strftime("%-m/%-d/%Y, %-I:%M:%S %p")
}

# Process world (now supports array of stories)
world_raw = data.get('world', {})
if isinstance(world_raw, list):
    world_stories = [clean_world(w) for w in world_raw]
else:
    world_stories = [clean_world(world_raw)]
world_stories = [w for w in world_stories if w]
world_earlier = existing.get('world', {}).get('earlier', [])
if world_stories:
    # Rotate current stories to earlier
    old_stories = existing.get('world', {}).get('stories', [])
    for s in old_stories:
        s['time'] = s.get('time', update_time)
        world_earlier.insert(0, s)
    world_earlier = world_earlier[:10]
    output['world'] = {'stories': world_stories, 'earlier': world_earlier}
else:
    print("  WARNING: World stories failed validation, keeping old", file=sys.stderr)
    output['world'] = existing.get('world', {'stories': [], 'earlier': []})

# Process array tabs (elon, sports, allin, pods, business)
for tab in ['elon', 'sports', 'allin', 'pods', 'business', 'local']:
    tab_data = data.get(tab, [])
    posts = tab_data if isinstance(tab_data, list) else [tab_data]
    cleaned = []
    seen_urls = set()
    for p in posts:
        s = clean_story(p)
        if s and s['url'] not in seen_urls:
            if tab == 'elon':
                s['honesty'] = '10/10'
            seen_urls.add(s['url'])
            cleaned.append(s)

    tab_earlier = existing.get(tab, {}).get('earlier', [])
    if cleaned:
        old_stories = existing.get(tab, {}).get('stories', [])
        for s in old_stories:
            s['time'] = s.get('time', update_time)
            tab_earlier.insert(0, s)
        tab_earlier = tab_earlier[:10]
        output[tab] = {'stories': cleaned, 'earlier': tab_earlier}
    else:
        print(f"  WARNING: {tab} had no valid stories, keeping old", file=sys.stderr)
        output[tab] = existing.get(tab, {'stories': [], 'earlier': []})

# Process single-post tabs
for tab in ['top', 'msm', 'pg6', 'recipe', 'science']:
    s = clean_story(data.get(tab, {}))
    tab_earlier = existing.get(tab, {}).get('earlier', [])
    if s:
        old_stories = existing.get(tab, {}).get('stories', [])
        for old in old_stories:
            old['time'] = old.get('time', update_time)
            tab_earlier.insert(0, old)
        tab_earlier = tab_earlier[:10]
        output[tab] = {'stories': [s], 'earlier': tab_earlier}
    else:
        print(f"  WARNING: {tab} failed validation, keeping old", file=sys.stderr)
        output[tab] = existing.get(tab, {'stories': [], 'earlier': []})

# ---- Quality report ----
total_stories = 0
real_urls = 0
profile_urls = 0
for tab in ['world', 'business', 'sports', 'elon', 'allin', 'top', 'msm', 'pg6', 'pods', 'recipe', 'science', 'local']:
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

print(f"Quality: {total_stories} stories, {real_urls} real URLs, {profile_urls} profile-only", file=sys.stderr)

# ---- Fetch live stock quotes ----
TICKERS = ['^GSPC', '^IXIC', 'BTC-USD', 'TSLA', 'PLTR', 'META', 'COIN', 'SOFI', 'CLOV', 'AFRM', 'RUM', 'AMZN']

def fetch_quotes():
    """Fetch current prices from Yahoo Finance v8 chart API."""
    quotes = {}
    for ticker in TICKERS:
        try:
            url = f"https://query2.finance.yahoo.com/v8/finance/chart/{urllib.parse.quote(ticker)}?range=1d&interval=1d"
            r = subprocess.run(
                ['curl', '-s', '--max-time', '5', '-H', 'User-Agent: Mozilla/5.0', url],
                capture_output=True, text=True, timeout=8
            )
            d = json.loads(r.stdout)
            meta = d.get('chart', {}).get('result', [{}])[0].get('meta', {})
            if meta.get('regularMarketPrice'):
                prev = meta.get('previousClose', meta.get('chartPreviousClose', 0))
                price = meta['regularMarketPrice']
                chg = round(((price - prev) / prev) * 100, 2) if prev else 0
                state = meta.get('marketState', 'CLOSED')
                quotes[ticker] = {'price': round(price, 2), 'change': chg, 'state': state}
        except Exception:
            pass
    print(f"  Quotes fetched: {len(quotes)}/{len(TICKERS)} tickers", file=sys.stderr)
    return quotes

quotes = fetch_quotes()
if quotes:
    output['quotes'] = {
        'data': quotes,
        'fetchedAt': now.strftime("%-m/%-d/%Y, %-I:%M:%S %p")
    }
else:
    # Preserve old quotes if fetch failed
    old_quotes = existing.get('quotes')
    if old_quotes:
        output['quotes'] = old_quotes

# Write output
with open('stories.json', 'w') as f:
    json.dump(output, f, indent=2)

print("stories.json updated successfully")
