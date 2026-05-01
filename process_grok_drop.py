#!/usr/bin/env python3
"""
Grok drop-folder processor.

User pastes Grok curation output into a .json file in ~/Desktop/grok_drops/.
This script:
  1. Validates every URL via Twitter oEmbed (must be a real, reachable tweet)
  2. Compares the Grok-provided text to the ACTUAL tweet text on X
     (catches paraphrasing / hallucination)
  3. Confirms post age < 36h via snowflake ID timestamp
  4. Merges validated entries into stories.json
  5. Archives the drop + writes a rejection log for user to show Grok

Accepted drop format (either structure works):

  # Multi-tab structure (matches Grok's sample):
  {
    "world": {
      "mainStory": "Headline",
      "views": [
        {"perspective": "Conservative", "honesty": "9/10", "text": "...",
         "link": "https://x.com/handle/status/NUMERIC_ID"}
      ]
    },
    "usa": { ... }
  }

  # Or flat per-tab array:
  {
    "world": [
      {"headline": "...", "perspectives": [
        {"label": "Conservative", "handle": "@...", "url": "...", "text": "...",
         "honesty": "9/10"}
      ]}
    ],
    "business": [
      {"headline": "...", "handle": "@...", "url": "...", "body": "...",
       "engagement": "...", "honesty": "..."}
    ]
  }

Run:
  python3 process_grok_drop.py                 # process all .json in drop folder
  python3 process_grok_drop.py --dry-run       # validate only, don't merge
  python3 process_grok_drop.py path/to/file    # process a specific file
"""

import os, sys, json, re, datetime, subprocess, urllib.parse, html, glob, shutil

PROJECT_DIR = '/Users/lookhome/grok-news-251d9/grok-news-251d9'
DROP_DIR = os.path.expanduser('~/Desktop/grok_drops')
ARCHIVE_DIR = os.path.join(DROP_DIR, 'archive')
STORIES_PATH = os.path.join(PROJECT_DIR, 'stories.json')
REJECT_LOG = os.path.join(DROP_DIR, 'rejections.log')
VALIDATE_LOG = os.path.join(DROP_DIR, 'last_run.log')
MAX_AGE_HOURS = 36

# ---- URL + age helpers (mirror parse_grok.py) ----
def extract_status_id(url):
    if not url: return None
    m = re.search(r'/status/(\d{15,20})', url)
    return m.group(1) if m else None

def snowflake_to_datetime(sid):
    try:
        ts_ms = (int(sid) >> 22) + 1288834974657
        return datetime.datetime.fromtimestamp(ts_ms / 1000, datetime.timezone.utc)
    except Exception:
        return None

def age_hours(url):
    sid = extract_status_id(url)
    if not sid: return None
    dt = snowflake_to_datetime(sid)
    if not dt: return None
    return (datetime.datetime.now(datetime.timezone.utc) - dt).total_seconds() / 3600

# ---- oEmbed fetch ----
def oembed(url):
    """Hit publish.twitter.com/oembed. Returns parsed dict or None on failure."""
    if not url: return None
    enc = urllib.parse.quote(url, safe=':/?=&')
    r = subprocess.run(
        ['curl', '-s', '--max-time', '15',
         f'https://publish.twitter.com/oembed?url={enc}&omit_script=1'],
        capture_output=True, text=True, timeout=20
    )
    if r.returncode != 0 or not r.stdout:
        return None
    try:
        return json.loads(r.stdout)
    except Exception:
        return None

def extract_tweet_text(oembed_html):
    """Strip the oEmbed blockquote to get the approximate tweet text."""
    if not oembed_html: return ''
    m = re.search(r'<p[^>]*>(.*?)</p>', oembed_html, re.DOTALL)
    if not m: return ''
    txt = m.group(1)
    # Strip any anchor tags but keep their visible text
    txt = re.sub(r'<a[^>]*>(.*?)</a>', r'\1', txt, flags=re.DOTALL)
    # Strip remaining HTML
    txt = re.sub(r'<[^>]+>', '', txt)
    # Decode HTML entities
    txt = html.unescape(txt)
    return txt.strip()

# ---- Text similarity ----
def normalize_text(s):
    s = (s or '').lower()
    # Strip URLs, @handles, hashtags, emoji-ish characters
    s = re.sub(r'https?://\S+', '', s)
    s = re.sub(r't\.co/\S+', '', s)
    s = re.sub(r'[@#][A-Za-z0-9_]+', '', s)
    return set(w for w in re.findall(r'[a-z]{3,}', s))

def text_similarity(grok_text, real_text):
    g = normalize_text(grok_text)
    r = normalize_text(real_text)
    if not g or not r: return 0.0
    return len(g & r) / max(1, min(len(g), len(r)))

# ---- Validation ----
def validate_entry(url, grok_text, handle_hint=''):
    """Return (ok, reason_or_realdata).
    ok=True → returns {'real_text':..., 'real_handle':..., 'age_h':..., 'similarity':...}
    ok=False → returns reason string.
    """
    if not url:
        return False, 'missing url'
    sid = extract_status_id(url)
    if not sid:
        return False, f'url has no valid /status/ID (got {url!r})'
    a = age_hours(url)
    if a is None:
        return False, 'cannot compute age from snowflake id'
    if a > MAX_AGE_HOURS:
        return False, f'post is {int(a)}h old (max {MAX_AGE_HOURS})'

    oe = oembed(url)
    if not oe:
        return False, 'oembed returned nothing — tweet may be deleted or private'
    real_text = extract_tweet_text(oe.get('html', ''))
    real_handle = (oe.get('author_name') or '').strip()

    sim = text_similarity(grok_text, real_text)
    if sim < 0.3:
        return False, (f'text mismatch ({int(sim*100)}% overlap) — looks paraphrased.\n'
                       f'   Grok  : {grok_text[:100]!r}\n'
                       f'   Actual: {real_text[:100]!r}')
    return True, {
        'real_text': real_text,
        'real_handle': real_handle,
        'age_h': a,
        'similarity': sim,
        'oembed_author_url': oe.get('author_url', ''),
    }

# ---- Drop-format normalization ----
def normalize_world_entry(drop, tab_name):
    """Convert either drop schema into our stories.json perspective format."""
    # Grok's sample schema: {mainStory, views:[{perspective, honesty, text, link}]}
    if isinstance(drop, dict) and 'mainStory' in drop and 'views' in drop:
        return {
            'headline': drop.get('mainStory', ''),
            'perspectives': [
                {
                    'label': v.get('perspective', ''),
                    'handle': extract_handle_from_url(v.get('link', '')),
                    'url': v.get('link', ''),
                    'text': v.get('text', ''),
                    'honesty': v.get('honesty', '8/10'),
                }
                for v in drop.get('views', [])
            ],
        }
    # Our native schema: {headline, perspectives:[{label, handle, url, text, honesty}]}
    if isinstance(drop, dict) and 'perspectives' in drop:
        return drop
    return None

def normalize_single_entry(drop):
    """For single-post tabs: accept either {handle, url, body/text, headline, ...} directly."""
    if not isinstance(drop, dict): return None
    url = drop.get('url') or drop.get('link', '')
    return {
        'headline': drop.get('headline') or drop.get('mainStory', ''),
        'handle': drop.get('handle') or extract_handle_from_url(url),
        'url': url,
        'body': drop.get('body') or drop.get('text', ''),
        'engagement': drop.get('engagement', ''),
        'honesty': drop.get('honesty', '8/10'),
        'notes': drop.get('notes', ''),
    }

def extract_handle_from_url(url):
    m = re.match(r'https?://(?:twitter\.com|x\.com)/([^/]+)/status/', url or '')
    return '@' + m.group(1) if m else ''

# ---- Core: validate a single drop file, return (additions_dict, log_lines) ----
def process_drop(drop_data):
    """drop_data is the parsed JSON. Returns (tab_additions, log_lines).
    tab_additions = {tab_name: [validated_story, ...]}
    """
    now_iso = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    additions = {}
    log_lines = []

    PERSPECTIVE_TABS = ('world', 'usa')
    SINGLE_TABS = ('business', 'sports', 'elon', 'allin', 'top', 'msm', 'pg6', 'pods',
                   'recipe', 'science', 'local', 'memes', 'comedy', 'tiktok', 'golf',
                   'freespeech')

    for tab_name, tab_payload in drop_data.items():
        if tab_name in PERSPECTIVE_TABS:
            # Expect either single story object or list of story objects
            candidates = tab_payload if isinstance(tab_payload, list) else [tab_payload]
            for cand in candidates:
                story = normalize_world_entry(cand, tab_name)
                if not story:
                    log_lines.append(f'REJECT {tab_name}: unrecognized entry format')
                    continue
                # Validate each perspective
                validated_perspectives = []
                any_rejection = False
                for p in story.get('perspectives', []):
                    ok, result = validate_entry(p.get('url', ''), p.get('text', ''), p.get('handle', ''))
                    if ok:
                        p_out = dict(p)
                        p_out['engagement'] = 'via Grok drop'
                        p_out['age_h'] = int(result['age_h'])
                        p_out['similarity'] = round(result['similarity'], 2)
                        validated_perspectives.append(p_out)
                        log_lines.append(f'OK     {tab_name} [{p.get("label")}] @{p.get("handle")}: {int(result["age_h"])}h, sim={int(result["similarity"]*100)}%')
                    else:
                        any_rejection = True
                        log_lines.append(f'REJECT {tab_name} [{p.get("label")}] @{p.get("handle")}: {result}')
                if len(validated_perspectives) >= 2:
                    story_out = {
                        'headline': story.get('headline', ''),
                        'perspectives': validated_perspectives,
                        'body': 'Three-perspective roundup.',
                        'posted': now_iso,
                        'source': 'grok_drop',
                    }
                    additions.setdefault(tab_name, []).append(story_out)
                else:
                    log_lines.append(f'REJECT {tab_name} story "{story.get("headline","")[:60]}": fewer than 2 valid perspectives after validation')

        elif tab_name in SINGLE_TABS:
            candidates = tab_payload if isinstance(tab_payload, list) else [tab_payload]
            for cand in candidates:
                story = normalize_single_entry(cand)
                if not story or not story.get('url'):
                    log_lines.append(f'REJECT {tab_name}: missing url in entry')
                    continue
                ok, result = validate_entry(story['url'], story.get('body', ''), story.get('handle', ''))
                if ok:
                    story['posted'] = now_iso
                    story['source'] = 'grok_drop'
                    story['similarity'] = round(result['similarity'], 2)
                    additions.setdefault(tab_name, []).append(story)
                    log_lines.append(f'OK     {tab_name} @{story.get("handle")}: {int(result["age_h"])}h, sim={int(result["similarity"]*100)}%')
                else:
                    log_lines.append(f'REJECT {tab_name} @{story.get("handle","?")}: {result}')
        else:
            log_lines.append(f'SKIP   unknown tab "{tab_name}" — supported: {list(PERSPECTIVE_TABS) + list(SINGLE_TABS)}')

    return additions, log_lines

# ---- Merge validated entries into stories.json ----
def merge_into_stories(additions, dry_run=False):
    with open(STORIES_PATH) as f:
        data = json.load(f)
    for tab, new_stories in additions.items():
        if tab not in data:
            data[tab] = {'stories': [], 'earlier': []}
        existing = data[tab].get('stories', [])
        # Dedup by URL — if a new story matches an existing URL, skip
        existing_urls = set()
        for s in existing:
            if s.get('url'): existing_urls.add(s['url'])
            for p in s.get('perspectives', []):
                if p.get('url'): existing_urls.add(p['url'])
        truly_new = []
        for ns in new_stories:
            ns_urls = set()
            if ns.get('url'): ns_urls.add(ns['url'])
            for p in ns.get('perspectives', []):
                if p.get('url'): ns_urls.add(p['url'])
            if ns_urls & existing_urls:
                continue
            truly_new.append(ns)
        # Prepend new stories (they're the freshest curation)
        data[tab]['stories'] = truly_new + existing
    if not dry_run:
        with open(STORIES_PATH, 'w') as f:
            json.dump(data, f, indent=2)

def main():
    dry_run = '--dry-run' in sys.argv
    files = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not files:
        files = sorted(glob.glob(os.path.join(DROP_DIR, '*.json')))
    if not files:
        print(f'No .json files in {DROP_DIR} and none specified. Nothing to do.')
        return

    all_log = []
    all_additions = {}
    for path in files:
        print(f'\n=== {os.path.basename(path)} ===')
        try:
            with open(path) as f:
                drop_data = json.load(f)
        except Exception as e:
            print(f'  ERROR: could not parse — {e}')
            all_log.append(f'[{os.path.basename(path)}] ERROR parse: {e}')
            continue
        additions, log_lines = process_drop(drop_data)
        for line in log_lines:
            print('  ' + line)
        all_log.extend(f'[{os.path.basename(path)}] {ln}' for ln in log_lines)
        for tab, stories in additions.items():
            all_additions.setdefault(tab, []).extend(stories)

    # Write rejection log
    rejection_lines = [ln for ln in all_log if 'REJECT' in ln or 'ERROR' in ln]
    if rejection_lines:
        with open(REJECT_LOG, 'a') as f:
            f.write(f'\n\n### Run {datetime.datetime.now().isoformat()}\n')
            f.write('\n'.join(rejection_lines))
            f.write('\n')
    # Write latest-run log (always overwrite)
    with open(VALIDATE_LOG, 'w') as f:
        f.write('\n'.join(all_log))
        f.write('\n')

    # Merge
    total_validated = sum(len(v) for v in all_additions.values())
    total_rejected = len(rejection_lines)
    print(f'\n=== Summary ===')
    print(f'Validated: {total_validated} stories across {len(all_additions)} tabs')
    print(f'Rejected : {total_rejected} entries')
    for tab, stories in all_additions.items():
        print(f'  {tab}: +{len(stories)} stories')

    if total_validated and not dry_run:
        merge_into_stories(all_additions)
        print(f'\nMerged into {STORIES_PATH}')

    # Archive input files
    if not dry_run and files:
        ts = datetime.datetime.now().strftime('%Y-%m-%d_%H-%M-%S')
        for path in files:
            if not path.startswith(DROP_DIR): continue  # skip explicit paths outside drop dir
            dest = os.path.join(ARCHIVE_DIR, f'{ts}_{os.path.basename(path)}')
            shutil.move(path, dest)
            print(f'  archived: {dest}')

    if dry_run:
        print('\n(dry-run — stories.json NOT modified, drops NOT archived)')

    if rejection_lines:
        print(f'\n{len(rejection_lines)} rejections logged to: {REJECT_LOG}')
        print('Show these to Grok so they know what to fix.')

if __name__ == '__main__':
    main()
