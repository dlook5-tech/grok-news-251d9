#!/bin/bash
# eXpressO News Auto-Update Script
# Uses Grok API + oEmbed verification pipeline:
#   Step 1: Ask Grok what's trending (constrained to KNOWN REAL handles)
#   Step 2: Verify EVERY URL via Twitter oEmbed API (hard gate)
#   Step 3: Only publish verified stories. Abort if quality too low.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

source .env

NOW=$(date "+%-m/%-d/%Y, %-I:%M:%S %p")
echo "=== eXpressO News Update — $NOW ==="

# ============================================================
# STEP 1: Ask Grok what's trending — CONSTRAINED to real handles
# ============================================================
echo "Step 1: Asking Grok what's trending..."

STEP1_RAW=$(curl -s --max-time 180 https://api.x.ai/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -d @- <<'ENDJSON'
{
  "model": "grok-4.20-0309-reasoning",
  "input": [
    {"role": "system", "content": "You are Grok, the AI of X. Answer in JSON only. No markdown, no code blocks.\n\nCRITICAL: You MUST use web_search to find every URL. Do NOT invent or guess URLs. If you cannot find a real post URL via web_search, set url to null.\n\nCRITICAL: Only use handles from the APPROVED LISTS below. Do NOT invent handles.\n\nENGAGEMENT QUALITY RULE: ONLY pick posts with HIGH ENGAGEMENT. Minimum 5,000 likes OR 500 replies OR 1,000 retweets. Prioritize VIRAL posts — the ones generating the most conversation, debate, and interaction. If a handle has no high-engagement recent posts, skip them and pick a different handle from the approved list who DOES have viral content. We want the hottest, most-discussed posts on X — NOT random low-interaction tweets. Include approximate engagement numbers (likes, replies, retweets) in the body text so we can verify quality."},
    {"role": "user", "content": "Find the MOST VIRAL, highest-engagement trending stories on X right now. Use web_search for EVERY URL.\n\nIMPORTANT: ONLY use handles from these approved lists. Do NOT make up handles.\n\nPRIORITY: Pick the posts with the MOST likes, replies, retweets, and interaction. We want posts that are BLOWING UP — going viral, generating massive threads, sparking debate. If you see a post with 50K likes, pick that over one with 2K likes. Engagement is KING.\n\nAPPROVED HANDLES BY CATEGORY:\n\nWORLD Conservative: @JackPosobiec, @baboramus, @baboramus, @Cernovich, @RealCandaceO, @benshapiro, @TuckerCarlson, @DonaldJTrumpJr, @charliekirk11, @RealDailyWire, @JDVance1, @SenTedCruz, @TomFitton, @JesseBWatters, @IngrahamAngle, @WarMonitors, @sentdefender, @CriticalThreats, @WhiteHouse\nWORLD Democrat: @AOC, @Ilhan, @RBReich, @BernieSanders, @RashidaTlaib, @kaboramus, @ChrisMurphyCT, @SenWarren, @JoyceWhiteVance, @ProPublica, @DropSiteNews, @maboramus\nWORLD Independent: @HamidRezaAz, @TheStudyofWar, @vtchakarova, @RayDalio, @dalperovitch, @InsightGL, @KimZetter, @Snowden, @ggreenwald\n\nBUSINESS: @DowdEdward, @RayDalio, @Stocktwits, @StockMKTNewz, @zaboramus, @WatcherGuru, @unusual_whales, @TruthGundlach, @LizAnnSonders, @elerianm\n\nSPORTS main: @ShamsCharania, @wojespn, @ClutchPoints, @BleacherReport, @CourtsideBuzzX, @lukaupdates, @PolymarketHoops, @TheAthletic, @ESPNStatsInfo\nSPORTS stephena: @stephenasmith (MUST use this exact handle)\nSPORTS cowherd: @TheHerd, @colincowherd (MUST use one of these)\n\nELON: @elonmusk (MUST use this exact handle, find 3 DIFFERENT recent posts — each must have a DIFFERENT tweet URL and DIFFERENT topic. Do NOT return the same tweet 3 times. Search for 3 separate posts. Pick the ones with the MOST engagement)\n\nPODS: @joerogan, @joeroganhq, @TuckerCarlson, @theallinpod, @lexfridman, @CallHerDaddy, @adamcarolla, @JREClips, @enews\n\nALLIN ($age): @chamath, @DavidSacks, @pmarca, @PalmerLuckey, @friedberg\n\nTOP: Any handle — it MUST be the single most VIRAL post on ALL of X right now. The one EVERYONE is talking about. Use web_search to find the post with the absolute highest engagement.\n\nMSM: @BillMelugin_, @libaboramus, @MattWalshBlog, @TimcastNews, @TheRabbitHole84, @SCOTUSblog, @InsightGL, @JamesOKeefeIII\n\nRECIPE: @tasteofhome, @FoodNetwork, @thekitchn, @HBHarvest, @foodandwine, @tasty, @KitchenSanc2ary, @budgetbytes\n\nLOCAL (MUST be Orange County / Newport Beach / SoCal — pick stories that would be FRONT PAGE of the Daily Pilot or OC Register. Real local NEWS: crime, politics, development, community issues, weather events, school board, city council, major local events. NOT random beach photos or fluff): @OC_Scanner, @ABC7, @ABORAMUS, @LAist, @ABORAMUS, @KTLA, @ABORAMUS, @OCRegister, @DailyPilot, @NBPDsocial, @CityofNewportBeach\n\nPG6: @PopCrave, @enaboramus, @enews, @JustJared, @etnow, @TMZ\n\nFor each category, search X for the post with the HIGHEST ENGAGEMENT from these handles. Use web_search to find each URL.\n\nJSON format:\n{\"world\":{\"stories\":[{\"topic\":\"...\",\"headline\":\"...\",\"conservative\":{\"handle\":\"@...\",\"url\":\"https://x.com/.../status/...\",\"angle\":\"...\"},\"democrat\":{\"handle\":\"@...\",\"url\":\"https://x.com/.../status/...\",\"angle\":\"...\"},\"independent\":{\"handle\":\"@...\",\"url\":\"https://x.com/.../status/...\",\"angle\":\"...\"},\"honesty\":\"X/10\",\"notes\":\"...\",\"footnotes\":[\"...\",\"...\"]}]},\"business\":{\"headline\":\"...\",\"handle\":\"@...\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"sports\":{\"main\":{\"headline\":\"...\",\"handle\":\"@...\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"stephena\":{\"headline\":\"...\",\"handle\":\"@stephenasmith\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"cowherd\":{\"headline\":\"...\",\"handle\":\"@TheHerd\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"}},\"elon\":{\"posts\":[{\"headline\":\"...\",\"handle\":\"@elonmusk\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"}]},\"pods\":{\"clips\":[{\"headline\":\"...\",\"handle\":\"@...\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"}]},\"allin\":{\"headline\":\"...\",\"handle\":\"@...\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"top\":{\"headline\":\"...\",\"handle\":\"@...\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"msm\":{\"headline\":\"...\",\"handle\":\"@...\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"recipe\":{\"posts\":[{\"headline\":\"...\",\"handle\":\"@...\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"}]},\"local\":{\"headline\":\"...\",\"handle\":\"@...\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"pg6\":{\"headline\":\"...\",\"handle\":\"@...\",\"url\":\"...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"}}"}
  ],
  "tools": [{"type": "web_search"}],
  "max_output_tokens": 8000,
  "temperature": 0.2
}
ENDJSON
)

# Extract JSON from Step 1
echo "$STEP1_RAW" > /tmp/grok_step1_raw.json

cat > /tmp/grok_parse.py <<'PYPARSESCRIPT'
import json, re, sys

with open(sys.argv[1]) as f:
    r = json.load(f)

if 'error' in r and r.get('error'):
    print('ERROR: ' + str(r['error']), file=sys.stderr)
    sys.exit(1)

text = ''
for item in r.get('output', []):
    if item.get('type') == 'message':
        for c in item.get('content', []):
            if c.get('type') == 'output_text':
                text = c['text']

text = text.strip()
if text.startswith('```'):
    text = re.sub(r'```json?\s*', '', text)
    text = re.sub(r'```\s*$', '', text)
text = re.sub(r'<grok:render[^>]*>.*?</grok:render>', '', text)

decoder = json.JSONDecoder()
try:
    parsed, _ = decoder.raw_decode(text.strip())
except json.JSONDecodeError:
    quote_count = len(re.findall(r'(?<!\\)"', text))
    if quote_count % 2 != 0:
        text += '"'
    opens_b = text.count('{') - text.count('}')
    opens_a = text.count('[') - text.count(']')
    text = re.sub(r',\s*$', '', text)
    text += ']' * max(0, opens_a) + '}' * max(0, opens_b)
    try:
        parsed, _ = decoder.raw_decode(text.strip())
    except json.JSONDecodeError as e2:
        print(f'JSON parse failed after repair: {e2}', file=sys.stderr)
        print(f'Last 300 chars: {text[-300:]}', file=sys.stderr)
        sys.exit(1)
print(json.dumps(parsed))
PYPARSESCRIPT

STEP1=$(python3 /tmp/grok_parse.py /tmp/grok_step1_raw.json)

if [ -z "$STEP1" ]; then
    echo "ERROR: Step 1 failed — keeping old content"
    exit 1
fi
echo "Step 1 done. Got story intelligence."

# ============================================================
# STEP 1.5: Fix null URLs — focused search per handle
# ============================================================
echo "Step 1.5: Fixing null URLs with focused searches..."

STEP1=$(python3 - "$STEP1" "$XAI_API_KEY" <<'FIXNULLS'
import json, sys, urllib.request, re, time

stories = json.loads(sys.argv[1])
api_key = sys.argv[2]

def search_handle_url(handle, topic):
    """Make a focused Grok API call to find a real URL for this handle."""
    handle_clean = handle.lstrip('@')
    payload = json.dumps({
        "model": "grok-4.20-0309-reasoning",
        "input": [
            {"role": "user", "content": f"Use web_search to find the most recent post by @{handle_clean} on X about: {topic}. Return ONLY the full URL (https://x.com/{handle_clean}/status/NUMBERS). Nothing else. No explanation."}
        ],
        "tools": [{"type": "web_search"}],
        "max_output_tokens": 200,
        "temperature": 0
    }).encode()

    try:
        req = urllib.request.Request(
            "https://api.x.ai/v1/responses",
            data=payload,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"}
        )
        resp = urllib.request.urlopen(req, timeout=60)
        data = json.loads(resp.read())
        for item in data.get('output', []):
            if item.get('type') == 'message':
                for c in item.get('content', []):
                    if c.get('type') == 'output_text':
                        urls = re.findall(r'https://x\.com/\w+/status/\d+', c['text'])
                        if urls:
                            return urls[0]
    except Exception as e:
        print(f"  API error for @{handle_clean}: {e}", file=sys.stderr)
    return None

fixed = 0

# Fix world perspectives
w = stories.get('world', {})
ws_list = w.get('stories', [])
if not ws_list and w.get('conservative'):
    ws_list = [w]
for ws in ws_list:
    topic = ws.get('topic', ws.get('headline', ''))
    for key in ['conservative', 'democrat', 'independent']:
        p = ws.get(key, {})
        if p.get('handle') and not p.get('url'):
            url = search_handle_url(p['handle'], topic)
            if url:
                p['url'] = url
                fixed += 1
                print(f"  Fixed: {p['handle']} → {url}", file=sys.stderr)
            time.sleep(0.5)

# Fix sports
sp = stories.get('sports', {})
for key in ['main', 'stephena', 'cowherd']:
    s = sp.get(key, {})
    if s.get('handle') and not s.get('url'):
        url = search_handle_url(s['handle'], s.get('headline', ''))
        if url:
            s['url'] = url
            fixed += 1
            print(f"  Fixed: {s['handle']} → {url}", file=sys.stderr)
        time.sleep(0.5)

# Fix elon
for ep in stories.get('elon', {}).get('posts', []):
    if ep.get('handle') and not ep.get('url'):
        url = search_handle_url(ep['handle'], ep.get('headline', ''))
        if url:
            ep['url'] = url
            fixed += 1
            print(f"  Fixed: {ep['handle']} → {url}", file=sys.stderr)
        time.sleep(0.5)

# Fix pods
for pc in stories.get('pods', {}).get('clips', []):
    if pc.get('handle') and not pc.get('url'):
        url = search_handle_url(pc['handle'], pc.get('headline', ''))
        if url:
            pc['url'] = url
            fixed += 1
            print(f"  Fixed: {pc['handle']} → {url}", file=sys.stderr)
        time.sleep(0.5)

# Fix recipe
for rp in stories.get('recipe', {}).get('posts', []):
    if rp.get('handle') and not rp.get('url'):
        url = search_handle_url(rp['handle'], rp.get('headline', ''))
        if url:
            rp['url'] = url
            fixed += 1
            print(f"  Fixed: {rp['handle']} → {url}", file=sys.stderr)
        time.sleep(0.5)

# Fix simple tabs
for tab in ['business', 'allin', 'top', 'msm', 'local', 'pg6']:
    d = stories.get(tab, {})
    if d.get('handle') and not d.get('url'):
        url = search_handle_url(d['handle'], d.get('headline', d.get('topic', '')))
        if url:
            d['url'] = url
            fixed += 1
            print(f"  Fixed: {d['handle']} → {url}", file=sys.stderr)
        time.sleep(0.5)

print(f"Step 1.5: Fixed {fixed} null URLs", file=sys.stderr)
print(json.dumps(stories))
FIXNULLS
)

echo "Step 1.5 done."

# ============================================================
# STEP 2: Verify EVERY URL via oEmbed + get tweet text (HARD GATE)
# ============================================================
echo "Step 2: Verifying all URLs via oEmbed (hard gate)..."

VERIFY_RESULT=$(python3 - "$STEP1" <<'VERIFYEOF'
import json, sys, urllib.request, urllib.parse, re, time

stories = json.loads(sys.argv[1])

def verify_url(url):
    """Check tweet via oEmbed. Returns (ok, author, tweet_text) or (False, '', '')."""
    if not url or '/status/' not in str(url):
        return False, '', ''
    try:
        oembed_url = f"https://publish.twitter.com/oembed?url={urllib.parse.quote(url, safe='')}"
        req = urllib.request.Request(oembed_url, headers={"User-Agent": "Mozilla/5.0"})
        resp = urllib.request.urlopen(req, timeout=10)
        if resp.getcode() == 200:
            data = json.loads(resp.read())
            author = data.get('author_name', '')
            text_match = re.search(r'<p[^>]*>(.*?)</p>', data.get('html',''), re.DOTALL)
            tweet_text = re.sub(r'<[^>]+>', '', text_match.group(1))[:200] if text_match else ''
            return True, author, tweet_text
        return False, '', ''
    except:
        return False, '', ''

# Collect and verify ALL URLs
verified = {}  # handle -> {url, author, text}
failed = []
total = 0

def check(label, handle, url):
    global total
    total += 1
    h = handle.lower().lstrip('@')
    ok, author, text = verify_url(url)
    if ok:
        verified[h] = {"url": url, "author": author, "text": text}
        print(f"  ✅ [{total}] {label}: @{h} → {author}", file=sys.stderr)
    else:
        failed.append((label, h, url))
        print(f"  ❌ [{total}] {label}: @{h} → FAKE ({url})", file=sys.stderr)
    time.sleep(0.12)

# World perspectives
w = stories.get('world', {})
ws_list = w.get('stories', [])
if not ws_list and w.get('conservative'):
    ws_list = [w]
for ws in ws_list:
    for key in ['conservative', 'democrat', 'independent']:
        p = ws.get(key, {})
        if p.get('handle'):
            check(f'world.{key}', p['handle'], p.get('url',''))

# Sports
sp = stories.get('sports', {})
for key in ['main', 'stephena', 'cowherd']:
    s = sp.get(key, {})
    if s.get('handle'):
        check(f'sports.{key}', s['handle'], s.get('url',''))

# Elon
for i, ep in enumerate(stories.get('elon', {}).get('posts', [])):
    if ep.get('handle'):
        check(f'elon.{i}', ep['handle'], ep.get('url',''))

# Pods
for i, pc in enumerate(stories.get('pods', {}).get('clips', [])):
    if pc.get('handle'):
        check(f'pods.{i}', pc['handle'], pc.get('url',''))

# Recipe
for i, rp in enumerate(stories.get('recipe', {}).get('posts', [])):
    if rp.get('handle'):
        check(f'recipe.{i}', rp['handle'], rp.get('url',''))

# Simple tabs
for tab in ['business', 'allin', 'top', 'msm', 'local', 'pg6']:
    d = stories.get(tab, {})
    if d.get('handle') and d.get('handle') != 'N/A':
        check(tab, d['handle'], d.get('url',''))

pass_rate = len(verified) / total if total > 0 else 0
print(f"\nVerification: {len(verified)}/{total} passed ({pass_rate:.0%}), {len(failed)} FAKE", file=sys.stderr)

# HARD GATE: If less than 40% pass, ABORT
if pass_rate < 0.4:
    print(f"ABORT: Only {pass_rate:.0%} passed verification. Keeping old content.", file=sys.stderr)
    print("ABORT")
    sys.exit(0)

# Output the verified map as JSON
print(json.dumps(verified))
VERIFYEOF
)

if [ "$VERIFY_RESULT" = "ABORT" ] || [ -z "$VERIFY_RESULT" ]; then
    echo "QUALITY GATE FAILED — not enough verified URLs. Keeping old content."
    exit 0
fi

echo "$VERIFY_RESULT" > /tmp/grok_verified_urls.json
echo "Step 2 done."

# ============================================================
# STEP 3: Assemble ONLY verified stories into index.html
# ============================================================
echo "Step 3: Assembling verified stories only..."

python3 - "$NOW" "$STEP1" <<'PYEOF'
import json, re, sys

now = sys.argv[1]
stories = json.loads(sys.argv[2])

# Load verified URLs + tweet text
try:
    with open('/tmp/grok_verified_urls.json') as f:
        verified = json.loads(f.read())
except:
    verified = {}

def get_verified_url(handle):
    """ONLY return verified URLs. Returns None if not verified."""
    h = handle.lower().lstrip('@')
    v = verified.get(h)
    if v:
        return v['url']
    return None

def get_verified_headline(handle, grok_headline, grok_body):
    """Use tweet text to fix headline if it doesn't match."""
    h = handle.lower().lstrip('@')
    v = verified.get(h)

    # QUALITY: If headline is a URL/link or garbage, always replace it
    is_garbage_headline = (
        grok_headline.startswith('http') or
        grok_headline.startswith('https://t.co') or
        len(grok_headline.strip()) < 5
    )

    if not v or not v.get('text'):
        if is_garbage_headline and grok_body and not grok_body.startswith('http'):
            clean = grok_body[:80].strip()
            if len(grok_body) > 80:
                clean = clean.rsplit(' ', 1)[0] + '...'
            return clean, grok_body
        return grok_headline, grok_body

    tweet_text = v['text']
    author = v.get('author', '')

    # If headline is garbage, always use tweet text
    if is_garbage_headline:
        clean = tweet_text[:80].strip()
        if len(tweet_text) > 80:
            clean = clean.rsplit(' ', 1)[0] + '...'
        return clean, f"{author}: {tweet_text[:250]}"

    # Check overlap
    h_words = set(w.lower() for w in grok_headline.split() if len(w) > 2)
    t_words = set(w.lower() for w in tweet_text.split() if len(w) > 2)
    overlap = h_words & t_words
    if len(overlap) >= 2:
        return grok_headline, grok_body  # Close enough
    # Use tweet text as headline
    clean = tweet_text[:80].strip()
    if len(tweet_text) > 80:
        clean = clean.rsplit(' ', 1)[0] + '...'
    return clean, f"{author}: {tweet_text[:250]}"

with open('index.html', 'r') as f:
    html = f.read()

# ---- PRESERVE OLD STORIES INTO EARLIER ----
old_time_match = re.search(r'lastUpdated: "([^"]*)"', html)
old_time = old_time_match.group(1) if old_time_match else now
from datetime import datetime
try:
    old_dt = datetime.strptime(old_time.strip(), "%m/%d/%Y, %I:%M:%S %p")
    old_time_short = old_dt.strftime("%-I:%M %p")
except:
    old_time_short = old_time

def preserve_earlier(tab_name, html_text):
    pattern = r'(' + re.escape(tab_name) + r': \{[^}]*?stories: )(\[.*?\])(,\s*earlier: )(\[.*?\])'
    m = re.search(pattern, html_text, flags=re.DOTALL)
    if not m:
        return html_text
    old_stories_js = m.group(2).strip()
    old_earlier_js = m.group(4).strip()
    if old_stories_js == '[]':
        return html_text
    old_stories_stamped = re.sub(
        r'(\{[\s\n]*headline:)',
        '{ time: "' + old_time_short + '", headline:',
        old_stories_js
    )
    old_stories_stamped = re.sub(
        r',?\s*\{\s*time:[^}]*headline:\s*"Honesty footnotes"[^}]*\}',
        '',
        old_stories_stamped
    )
    if old_earlier_js == '[]':
        new_earlier = old_stories_stamped
    else:
        inner_old = old_stories_stamped.strip()[1:-1].strip()
        inner_existing = old_earlier_js.strip()[1:-1].strip()
        if inner_old and inner_existing:
            new_earlier = '[' + inner_old + ',\n' + inner_existing + ']'
        elif inner_old:
            new_earlier = '[' + inner_old + ']'
        else:
            new_earlier = old_earlier_js
    html_text = re.sub(
        r'(' + re.escape(tab_name) + r': \{[^}]*?stories: \[.*?\],\s*earlier: )\[.*?\]',
        lambda mx: mx.group(1) + new_earlier,
        html_text, flags=re.DOTALL
    )
    return html_text

# Preserve stories for all tabs
all_tabs = ['world', 'business', 'sports', 'elon', 'allin', 'top', 'msm', 'local', 'recipe', 'pods', 'pg6']
for tab in all_tabs:
    if tab in stories:
        html = preserve_earlier(tab, html)

html = re.sub(r'lastUpdated: "[^"]*"', 'lastUpdated: "' + now + '"', html)

def js_str(s):
    return json.dumps(s)

updated_tabs = 0

# ---- Update WORLD (only verified perspectives) ----
if 'world' in stories:
    w = stories['world']
    world_stories = w.get('stories', [])
    if not world_stories and w.get('conservative'):
        world_stories = [w]

    story_blocks = []
    for ws in world_stories:
        persp_lines = []
        for key, label in [('conservative', 'Conservative'), ('democrat', 'Democrat'), ('independent', 'Independent')]:
            p = ws.get(key, {})
            if not p.get('handle'):
                continue
            url = get_verified_url(p['handle'])
            if not url:
                continue  # SKIP unverified perspectives
            text = p.get('angle', '')
            honesty = ws.get('honesty', '8/10')
            persp_lines.append(
                '            { label: "' + label + '", handle: "' + p['handle'] +
                '", url: "' + url + '", text: ' + js_str(text) +
                ', honesty: "' + honesty + '" }'
            )
        if not persp_lines:
            continue  # Skip story if no verified perspectives
        persp_js = ",\n".join(persp_lines)
        footnotes = ws.get('footnotes', [])
        fn_js = json.dumps(footnotes) if footnotes else '[]'
        story_blocks.append(
            '{\n'
            '          headline: ' + js_str(ws.get('headline', ws.get('topic', ''))) + ',\n'
            '          honesty: "' + ws.get('honesty', '8/10') + '",\n'
            '          perspectives: [\n' + persp_js + '\n          ],\n'
            '          notes: ' + js_str(ws.get('notes', '')) + ',\n'
            '          body: "Three-perspective roundup.",\n'
            '          footnotes: ' + fn_js + '\n'
            '        }'
        )

    if story_blocks:
        new_stories = '[\n        ' + ',\n        '.join(story_blocks) + '\n      ]'
        html = re.sub(
            r'(world: \{[^}]*?stories: )\[.*?\](,\s*earlier:)',
            lambda m: m.group(1) + new_stories + m.group(2),
            html, flags=re.DOTALL
        )
        updated_tabs += 1

# ---- Update SPORTS (only verified) ----
if 'sports' in stories:
    sp = stories['sports']
    sport_stories = []
    for key in ['main', 'stephena', 'cowherd']:
        s = sp.get(key, {})
        if not s.get('handle'):
            continue
        url = get_verified_url(s['handle'])
        if not url:
            continue  # SKIP unverified
        prefix = '\U0001f3a4 ' if key in ('stephena', 'cowherd') else ''
        s_headline, s_body = get_verified_headline(s['handle'], s.get('headline',''), s.get('body',''))
        sport_stories.append(
            '{\n'
            '          headline: ' + js_str(prefix + s_headline) + ',\n'
            '          handle: "' + s['handle'] + '",\n'
            '          url: "' + url + '",\n'
            '          honesty: "' + s.get('honesty', '8/10') + '",\n'
            '          notes: ' + js_str(s.get('notes', '')) + ',\n'
            '          body: ' + js_str(s_body) + '\n'
            '        }'
        )
        if key == 'main':
            sport_stories.append(
                '{ headline: "Honesty footnotes", body: ' + js_str(s.get('notes', '')) + ' }'
            )
    if sport_stories:
        new_stories = '[' + ',\n        '.join(sport_stories) + '\n      ]'
        pattern = r'(sports: \{[^}]*?stories: )\[.*?\](,\s*earlier:)'
        html = re.sub(pattern, lambda m: m.group(1) + new_stories + m.group(2), html, flags=re.DOTALL)
        updated_tabs += 1

# ---- Update ELON (only verified, DEDUPLICATED) ----
if 'elon' in stories:
    elon_stories = []
    seen_elon_urls = set()
    for ep in stories['elon'].get('posts', []):
        if not ep.get('handle'):
            continue
        url = get_verified_url(ep['handle'])
        if not url:
            continue
        # DEDUP: skip if we already have this URL
        if url in seen_elon_urls:
            continue
        seen_elon_urls.add(url)
        ep_headline, ep_body = get_verified_headline(ep['handle'], ep.get('headline',''), ep.get('body',''))
        elon_stories.append(
            '{\n'
            '          headline: ' + js_str(ep_headline) + ',\n'
            '          handle: "' + ep['handle'] + '",\n'
            '          url: "' + url + '",\n'
            '          honesty: "' + ep.get('honesty', '10/10') + '",\n'
            '          notes: ' + js_str(ep.get('notes', '')) + ',\n'
            '          body: ' + js_str(ep_body) + '\n'
            '        }'
        )
    if elon_stories:
        new_stories = '[' + ',\n        '.join(elon_stories) + '\n      ]'
        pattern = r'(elon: \{[^}]*?stories: )\[.*?\](,\s*earlier:)'
        html = re.sub(pattern, lambda m: m.group(1) + new_stories + m.group(2), html, flags=re.DOTALL)
        updated_tabs += 1

# ---- Update PODS (only verified) ----
if 'pods' in stories:
    pod_stories = []
    notes_all = []
    for pc in stories['pods'].get('clips', []):
        if not pc.get('handle'):
            continue
        url = get_verified_url(pc['handle'])
        if not url:
            continue
        pc_headline, pc_body = get_verified_headline(pc['handle'], pc.get('headline',''), pc.get('body',''))
        pod_stories.append(
            '{\n'
            '          headline: ' + js_str(pc_headline) + ',\n'
            '          handle: "' + pc['handle'] + '",\n'
            '          url: "' + url + '",\n'
            '          honesty: "' + pc.get('honesty', '8/10') + '",\n'
            '          notes: ' + js_str(pc.get('notes', '')) + ',\n'
            '          body: ' + js_str(pc_body) + '\n'
            '        }'
        )
        notes_all.append(pc.get('notes', ''))
    if pod_stories:
        pod_stories.append(
            '{ headline: "Honesty footnotes", body: ' + js_str(' '.join(notes_all)) + ' }'
        )
        new_stories = '[' + ',\n        '.join(pod_stories) + '\n      ]'
        pattern = r'(pods: \{[^}]*?stories: )\[.*?\](,\s*earlier:)'
        html = re.sub(pattern, lambda m: m.group(1) + new_stories + m.group(2), html, flags=re.DOTALL)
        updated_tabs += 1

# ---- Update RECIPE (only verified) ----
if 'recipe' in stories:
    recipe_stories = []
    notes_all = []
    for rp in stories['recipe'].get('posts', []):
        if not rp.get('handle'):
            continue
        url = get_verified_url(rp['handle'])
        if not url:
            continue
        rp_headline, rp_body = get_verified_headline(rp['handle'], rp.get('headline',''), rp.get('body',''))
        recipe_stories.append(
            '{\n'
            '          headline: ' + js_str(rp_headline) + ',\n'
            '          handle: "' + rp['handle'] + '",\n'
            '          url: "' + url + '",\n'
            '          honesty: "' + rp.get('honesty', '10/10') + '",\n'
            '          notes: ' + js_str(rp.get('notes', '')) + ',\n'
            '          body: ' + js_str(rp_body) + '\n'
            '        }'
        )
        notes_all.append(rp.get('notes', ''))
    if recipe_stories:
        recipe_stories.append(
            '{ headline: "Honesty footnotes", body: ' + js_str(' '.join(notes_all)) + ' }'
        )
        new_stories = '[' + ',\n        '.join(recipe_stories) + '\n      ]'
        pattern = r'(recipe: \{[^}]*?stories: )\[.*?\](,\s*earlier:)'
        html = re.sub(pattern, lambda m: m.group(1) + new_stories + m.group(2), html, flags=re.DOTALL)
        updated_tabs += 1

# ---- Update simple tabs (ONLY if verified) ----
simple_tabs = ['business', 'allin', 'top', 'msm', 'local', 'pg6']
for tab in simple_tabs:
    if tab not in stories:
        continue
    d = stories[tab]
    handle = d.get('handle', '')
    if not handle or handle == 'N/A':
        continue
    url = get_verified_url(handle)
    if not url:
        continue  # SKIP unverified — keep old content for this tab

    headline_raw, body_raw = get_verified_headline(handle, d.get('headline', d.get('topic','')), d.get('body',''))

    new_stories = (
        '[{\n'
        '          headline: ' + js_str(headline_raw) + ',\n'
        '          handle: "' + handle + '",\n'
        '          url: "' + url + '",\n'
        '          honesty: "' + d.get('honesty', '8/10') + '",\n'
        '          notes: ' + js_str(d.get('notes', '')) + ',\n'
        '          body: ' + js_str(body_raw) + '\n'
        '        },\n'
        '        { headline: "Honesty footnotes", body: ' + js_str(d.get('notes', '')) + ' }\n'
        '      ]'
    )

    pattern = r'(' + re.escape(tab) + r': \{[^}]*?stories: )\[.*?\](,\s*earlier:)'
    html = re.sub(pattern, lambda m, ns=new_stories: m.group(1) + ns + m.group(2), html, flags=re.DOTALL)
    updated_tabs += 1

# Final quality report
import re as re2
status_urls = re2.findall(r'url: "https://x\.com/[^"]+/status/\d+', html)
profile_urls = re2.findall(r'url: "https://x\.com/[a-zA-Z0-9_]+"[,\s]', html)
print(f"Updated {updated_tabs} tabs | URLs with /status/: {len(status_urls)} | Profile-only: {len(profile_urls)}")

with open('index.html', 'w') as f:
    f.write(html)

print("index.html updated successfully")
PYEOF

# Step 4: Deploy to Netlify
echo "Deploying to Netlify..."
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"
npx netlify-cli deploy --prod --dir=. --functions=netlify/functions --auth="$NETLIFY_AUTH_TOKEN" --site="$NETLIFY_SITE_ID" 2>&1 | tail -5

echo "=== Update complete at $(date) ==="
