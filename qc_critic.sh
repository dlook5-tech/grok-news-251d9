#!/bin/bash
# qc_critic.sh — second-pass QC by Grok.
# 1. Sends curated stories to Grok-as-critic.
# 2. Critic flags concerns AND returns full replacement posts where applicable.
# 3. Replacements are validated (engagement, context, freshness, URL) and swapped into stories.json.
# 4. Deploy continues.

set -e
MAIN="/Users/lookhome/grok-news-251d9/grok-news-251d9"
cd "$MAIN"
source .env

echo "=== QC Critic Pass — $(date) ===" > /tmp/expresso_qc_review.log

# 1. Compact summary of current picks
python3 <<'PYEOF' > /tmp/qc_summary.txt
import json
with open('/Users/lookhome/grok-news-251d9/grok-news-251d9/stories.json') as f:
    d = json.load(f)
lines = []
tabs = ['world','usa','business','local','sports','top','msm','elon','allin','pods','recipe','pg6','science','memes','comedy','tiktok','golf']
for tab in tabs:
    tv = d.get(tab, {})
    if not isinstance(tv, dict): continue
    stories = tv.get('stories', [])
    if not stories: continue
    lines.append(f"\n=== {tab.upper()} ===")
    for i, s in enumerate(stories, 1):
        if s.get('perspectives'):
            lines.append(f"  {i}. {s.get('headline','?')}")
            for p in s.get('perspectives', []):
                lines.append(f"     [{p.get('label')}] @{p.get('handle','')}: {(p.get('text','') or '')[:90]} (honesty {p.get('honesty','?')}, engagement {p.get('engagement','')})")
        else:
            lines.append(f"  {i}. @{s.get('handle','')}: {s.get('headline','')[:80]}")
            lines.append(f"     body: {(s.get('body','') or '')[:100]}")
            lines.append(f"     honesty {s.get('honesty','?')}, engagement {s.get('engagement','')}")
print('\n'.join(lines))
PYEOF

# 2. Critic prompt — asks for FULL replacement stories, not just suggestions
cat > /tmp/grok_p_critic.txt <<CRITIC_PROMPT
You are a SECOND-OPINION CRITIC for eXpressO News. The first Grok pass just curated these stories and is about to publish. Your job: identify ANY underperforming picks and replace them with demonstrably better posts.

Current picks:

$(cat /tmp/qc_summary.txt)

For EACH tab, use x_search RIGHT NOW to find the TOP posts on that subject. Compare against the current picks.

REPLACE a pick if ANY of these are true:
- A demonstrably MORE VIRAL / more compelling / fresher post exists on the same topic
- The current pick is a boring rerun or low-engagement filler
- The current pick is a context-less reply ("disputes a claim", "that is not true" without showing what)
- The current pick is older than 4 hours AND a fresher viral post on the same topic exists
- The current pick has lower engagement than an obvious alternative (e.g., 800 likes vs 15K likes available)

For each replacement, return the FULL replacement story object. The replacement MUST:
- Be a real X post (URL contains /status/ and a numeric ID)
- Be from within the last 24 hours
- Have higher engagement than the current pick
- Be self-contained (reader understands without clicking out)
- NOT be a reply starting with @someone
- NOT use vague references like "a claim", "the person", "someone"

Return JSON:
{"replacements":[
  {
    "tab": "world" | "usa" | "business" | "local" | "sports" | "top" | "msm" | "elon" | "allin" | "pods" | "recipe" | "pg6" | "science" | "memes" | "comedy" | "tiktok" | "golf",
    "slot_index": 0 (or 1, 2, 3, 4),
    "reason": "why the current pick is weak",
    "severity": "high" | "med" | "low",
    "perspective": null | "Conservative" | "Democrat" | "Independent",  // ONLY for world or usa tab, else null
    "new_story": {
      "headline": "...",
      "handle": "@...",
      "body": "1-sentence summary under 120 chars",
      "engagement": "e.g. 15.2K likes, 45.6M views",
      "url": "https://x.com/handle/status/NUMERIC_ID",
      "honesty": "9/10",
      "notes": "Fact / Opinion / Misleading explanation"
    }
  }
]}

Only return replacements where you have a CLEAR winner. Silence is fine if picks are genuinely strong. Max 10 replacements per run.
CRITIC_PROMPT

# 3. Call Grok critic
python3 /tmp/grok_build_payload.py /tmp/grok_p_critic.txt /tmp/grok_payload_critic.json

echo "[qc] calling critic..." >> /tmp/expresso_qc_review.log
curl -s --max-time 240 https://api.x.ai/v1/responses \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $XAI_API_KEY" \
    -d @/tmp/grok_payload_critic.json > /tmp/grok_raw_critic.json

# 4. Parse concerns, validate replacements, swap into stories.json
python3 <<'PYEOF' >> /tmp/expresso_qc_review.log
import json, re, datetime, sys
STORIES_PATH = '/Users/lookhome/grok-news-251d9/grok-news-251d9/stories.json'
sys.path.insert(0, '/Users/lookhome/grok-news-251d9/grok-news-251d9')

def url_age_hours(url):
    if not url: return None
    m = re.search(r'/status/(\d+)', url)
    if not m: return None
    try:
        sid = int(m.group(1))
        ts_ms = (sid >> 22) + 1288834974657
        post_time = datetime.datetime.fromtimestamp(ts_ms / 1000)
        return (datetime.datetime.now() - post_time).total_seconds() / 3600
    except Exception:
        return None

def parse_likes(eng_str):
    if not eng_str: return 0
    s = str(eng_str).lower()
    m = re.findall(r'([\d.]+)\s*([kmb]?)\s*likes?', s)
    best = 0
    for num_str, mult in m:
        try:
            num = float(num_str)
            if mult == 'k': num *= 1_000
            elif mult == 'm': num *= 1_000_000
            elif mult == 'b': num *= 1_000_000_000
            if num > best: best = num
        except Exception: pass
    return int(best)

def is_reply_body(body, headline=''):
    b = (body or '').strip()
    if not b: return False
    if b.startswith('@'): return True
    if len(b) < 25 and len(headline) < 40: return True
    low = b.lower().strip(' .!?"\'')
    BAD = {'this','exactly','no way','yes','correct','wrong','true','false','agreed','agree','lol','nope','yep','wow','sad','this is wrong','that is wrong','this isn\'t true'}
    if low in BAD: return True
    PATS = [r'\bdisputes?\s+(a|the|some)\s+claim\b', r'\bresponds?\s+to\s+(a|the|an|someone)\b', r'\bstating\s+the\s+person\b', r'\bthe\s+person\s+(is|has|says|said)\b', r'\bsomeone\s+(is|has|says|said)\b', r'\bhas\s+no\s+idea\b']
    for pat in PATS:
        if re.search(pat, low): return True
    return False

# Load critic response
try:
    with open('/tmp/grok_raw_critic.json') as f: raw = json.load(f)
    text = ''
    for item in raw.get('output', []):
        if item.get('type') == 'message':
            for c in item.get('content', []):
                if c.get('type') == 'output_text':
                    text = c['text']
    m = re.search(r'\{.*\}', text, re.DOTALL)
    if not m:
        print("No JSON in critic response. Raw: " + text[:300])
        sys.exit(0)
    parsed = json.loads(m.group(0))
except Exception as e:
    print(f"QC critic parse error: {e}")
    sys.exit(0)

replacements = parsed.get('replacements', [])
print(f"\n=== {len(replacements)} REPLACEMENTS SUGGESTED BY CRITIC ===\n")

# Load current stories
with open(STORIES_PATH) as f:
    stories_data = json.load(f)

applied = 0
skipped = 0
for r in replacements:
    tab = r.get('tab')
    slot = r.get('slot_index')
    new = r.get('new_story', {})
    sev = r.get('severity','?').upper()
    reason = r.get('reason','')
    perspective = r.get('perspective')

    new_url = new.get('url','')
    new_body = new.get('body','')
    new_handle = new.get('handle','')
    new_eng = new.get('engagement','')

    # Validate replacement
    if '/status/' not in new_url:
        print(f"[SKIP {sev}] {tab}[{slot}]: bad URL '{new_url}' — {reason}")
        skipped += 1; continue
    age = url_age_hours(new_url)
    if age is not None and age > 24:
        print(f"[SKIP {sev}] {tab}[{slot}]: replacement is {int(age)}h old")
        skipped += 1; continue
    if is_reply_body(new_body, new.get('headline','')):
        print(f"[SKIP {sev}] {tab}[{slot}]: replacement is a context-less reply")
        skipped += 1; continue
    new_likes = parse_likes(new_eng)

    # Find the slot to replace
    tv = stories_data.get(tab, {})
    if not isinstance(tv, dict) or not tv.get('stories'):
        print(f"[SKIP {sev}] {tab}: tab not found in stories.json")
        skipped += 1; continue
    try:
        slot = int(slot)
    except Exception:
        slot = 0
    if slot < 0 or slot >= len(tv['stories']):
        print(f"[SKIP {sev}] {tab}[{slot}]: slot out of range")
        skipped += 1; continue

    old = tv['stories'][slot]

    if perspective and old.get('perspectives'):
        # World tab — replace one perspective within the story
        swapped = False
        for p in old['perspectives']:
            if p.get('label') == perspective:
                old_likes = parse_likes(p.get('engagement', ''))
                if new_likes > 0 and old_likes > 0 and new_likes <= old_likes:
                    print(f"[SKIP {sev}] {tab} {perspective}: replacement engagement ({new_likes}) not higher than existing ({old_likes})")
                    skipped += 1; break
                p.update({
                    'handle': new_handle,
                    'text': new_body,
                    'url': new_url,
                    'honesty': new.get('honesty', p.get('honesty','8/10')),
                    'engagement': new_eng,
                })
                swapped = True
                print(f"[APPLY {sev}] {tab} {perspective}: {reason[:80]}")
                applied += 1
                break
        if not swapped:
            print(f"[SKIP {sev}] {tab}: perspective '{perspective}' not found in story")
            skipped += 1
    else:
        # Single-post tab
        old_likes = parse_likes(old.get('engagement', ''))
        if new_likes > 0 and old_likes > 0 and new_likes <= old_likes:
            print(f"[SKIP {sev}] {tab}[{slot}]: replacement engagement ({new_likes}) not higher than existing ({old_likes})")
            skipped += 1; continue
        tv['stories'][slot] = {
            'headline': new.get('headline') or new_body[:80],
            'handle': new_handle,
            'url': new_url,
            'body': new_body,
            'engagement': new_eng,
            'honesty': new.get('honesty', '8/10'),
            'notes': new.get('notes', ''),
            'posted': datetime.datetime.now().astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        }
        print(f"[APPLY {sev}] {tab}[{slot}]: {reason[:80]}")
        applied += 1

# Save updated stories.json
if applied > 0:
    with open(STORIES_PATH, 'w') as f:
        json.dump(stories_data, f, indent=2)
    print(f"\n✓ Applied {applied} replacements, skipped {skipped} (failed validation).")
else:
    print(f"\n✓ No replacements applied. {skipped} suggestions skipped at validation.")
PYEOF

cat /tmp/expresso_qc_review.log
