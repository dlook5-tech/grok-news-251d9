#!/usr/bin/env python3
"""
Fetch top 3 viral TikToks from tikwm.com (free, unofficial TikTok API).
Writes results to /tmp/grok_raw_tiktok.json so it flows through the same parse pipeline as Grok responses.
"""
import json, re, subprocess, sys, time

MIN_VIEWS = 500_000       # only truly viral content
MIN_LIKES = 50_000
REGION = "us"
FETCH_COUNT = 25          # pull a pool, then pick top 3

def fetch_feed():
    url = f"https://www.tikwm.com/api/feed/list?region={REGION}&count={FETCH_COUNT}"
    r = subprocess.run(['curl', '-s', '--max-time', '15', '-H', 'User-Agent: Mozilla/5.0', url],
                       capture_output=True, text=True, timeout=20)
    try:
        d = json.loads(r.stdout)
    except Exception as e:
        print(f"[tiktok] parse err: {e}", file=sys.stderr)
        return []
    if d.get('code') != 0:
        print(f"[tiktok] api error: {d.get('msg')}", file=sys.stderr)
        return []
    return d.get('data', []) or []

def fmt_count(n):
    if n >= 1_000_000_000: return f"{n/1_000_000_000:.1f}B"
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000: return f"{n/1_000:.0f}K"
    return str(n)

def is_english(text):
    """Rough filter: at least 60% of non-space chars should be ASCII Latin letters."""
    if not text: return False
    chars = [c for c in text if not c.isspace() and not c.isdigit()]
    if not chars: return False
    ascii_letters = sum(1 for c in chars if c.isascii() and c.isalpha())
    return ascii_letters / len(chars) >= 0.5

# Content-farm / spam account patterns (these handles post shock-ragebait to farm views)
FARM_HANDLE_PATTERNS = [
    r'quiz', r'_pro\d*$', r'_official\d*$', r'\.?official\d*$',
    r'^[a-z]+\d{3,}$',   # word + 3+ digits (e.g., user12345)
    r'ai[._-]?(art|clip|video|story|creation)',  # AI content farms
    r'(edit|edits|vibes?)\.?\d*$',  # generic edit accounts
    r'(reels?|shorts?|viral|trending|hot|clips?)\.?\d*$',  # clickbait farms
    r'^\.',              # handles starting with dot (junk)
    r'boost|slowed|speedup',  # audio-remix spam
]
FARM_REGEX = [re.compile(p, re.I) for p in FARM_HANDLE_PATTERNS]

# Keywords in title that suggest content-farm ragebait or ads
BAD_TITLE_KEYWORDS = [
    'english quiz', 'iq test', 'guess the', 'name the', 'can you',
    'use your headphones', 'use headphones', 'subscribe', 'follow for more',
    'link in bio', 'dm me', 'check my profile',
    'sponsored', '#ad', 'promo code', 'discount code',
    'slowed', 'reverb', 'nightcore',  # audio manipulations aren't real content
]

def is_farm_account(handle):
    """True if handle matches bot/content-farm patterns."""
    if not handle: return True
    h = handle.lower().lstrip('@')
    for rx in FARM_REGEX:
        if rx.search(h): return True
    return False

def is_bad_title(title):
    """True if title contains content-farm/ad keywords."""
    if not title: return False
    t = title.lower()
    return any(kw in t for kw in BAD_TITLE_KEYWORDS)

def to_story(v):
    author = v.get('author') or {}
    uid = author.get('unique_id') if isinstance(author, dict) else None
    if not uid or not isinstance(uid, str):
        return None
    video_id = v.get('video_id') or v.get('aweme_id')
    if not video_id:
        return None
    title = (v.get('title') or '').strip()
    # English-language filter — reject non-Latin content
    if not is_english(title):
        print(f"[tiktok] reject @{uid}: non-English", file=sys.stderr)
        return None
    # Content-farm filter — reject bot/spam accounts
    if is_farm_account(uid):
        print(f"[tiktok] reject @{uid}: farm/bot handle pattern", file=sys.stderr)
        return None
    # Bad title filter — reject obvious ads / ragebait / engagement-farm quizzes
    if is_bad_title(title):
        print(f"[tiktok] reject @{uid}: farm title '{title[:40]}'", file=sys.stderr)
        return None
    # Canonical TikTok URL
    url = f"https://www.tiktok.com/@{uid}/video/{video_id}"
    # Headline: first ~60 chars of title before hashtags
    headline = title.split('#')[0].strip()
    if len(headline) > 80: headline = headline[:77] + '...'
    if not headline:
        headline = (author.get('nickname') or 'TikTok') + " viral clip"
    plays = v.get('play_count') or 0
    likes = v.get('digg_count') or 0
    shares = v.get('share_count') or 0
    engagement = f"{fmt_count(plays)} views, {fmt_count(likes)} likes"
    return {
        "headline": headline,
        "handle": f"@{uid}",
        "body": title[:120] if title else "Viral TikTok",
        "engagement": engagement,
        "url": url,
        "honesty": "8/10",
        "notes": f"Viral TikTok — {plays:,} views, {likes:,} likes, {shares:,} shares.",
        "_plays": plays,
        "_likes": likes,
    }

def pick_top(stories, n=3):
    # sort by plays first, then likes
    stories.sort(key=lambda s: (s.get('_plays', 0), s.get('_likes', 0)), reverse=True)
    # filter by minimums
    out = []
    seen_handles = set()
    for s in stories:
        if s.get('_plays', 0) < MIN_VIEWS and s.get('_likes', 0) < MIN_LIKES:
            continue
        h = s['handle'].lower()
        if h in seen_handles:
            continue  # dedup creators within batch
        seen_handles.add(h)
        # Strip internal fields
        s.pop('_plays', None); s.pop('_likes', None)
        out.append(s)
        if len(out) >= n:
            break
    return out

def main():
    print("[tiktok] fetching from tikwm.com...", file=sys.stderr)
    raw = fetch_feed()
    print(f"[tiktok] got {len(raw)} candidates", file=sys.stderr)
    stories = [s for s in (to_story(v) for v in raw) if s]
    picked = pick_top(stories, 3)
    print(f"[tiktok] picked {len(picked)} after viral filter", file=sys.stderr)
    # Write in the shape update.sh / parse_grok.py expect for raw responses
    # Grok raw format wraps content in choices[0].message.content as a JSON string
    wrapped = {
        "choices": [{
            "message": {
                "content": json.dumps({"tiktok": picked})
            }
        }]
    }
    with open('/tmp/grok_raw_tiktok.json', 'w') as f:
        json.dump(wrapped, f)
    print(f"[tiktok] wrote /tmp/grok_raw_tiktok.json", file=sys.stderr)

if __name__ == '__main__':
    main()
