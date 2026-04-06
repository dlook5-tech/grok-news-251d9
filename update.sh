#!/bin/bash
# eXpressO News Auto-Update Script
# Uses Grok API in a 3-step pipeline:
#   Step 1: Ask Grok what's trending (stories + accounts)
#   Step 2: Ask Grok for specific post IDs (small batches)
#   Step 3: Validate and assemble, then update index.html + deploy

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

source .env

NOW=$(date "+%-m/%-d/%Y, %-I:%M:%S %p")
echo "=== eXpressO News Update — $NOW ==="

# ============================================================
# STEP 1: Ask Grok what's trending on X (stories, not URLs)
# ============================================================
echo "Step 1: Asking Grok what's trending..."

STEP1_RAW=$(curl -s --max-time 180 https://api.x.ai/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -d @- <<'ENDJSON'
{
  "model": "grok-4-1-fast-non-reasoning",
  "input": [
    {"role": "system", "content": "You are Grok, the AI of X. You know what is trending on X better than anyone. Answer in JSON only. No markdown, no code blocks."},
    {"role": "user", "content": "I need the BEST stories on X right now for a news curation site. NOT entertainment trends — real substance that showcases X's best citizen journalism.\n\nFor each category, tell me the story, the best account posting about it, and their angle.\n\n1. WORLD: The top 1-3 hard news stories (geopolitics, war, economy, policy). If ONE story dominates, just give that one. If 2-3 stories are equally important, give all of them. For EACH story, give the best conservative account, progressive/democrat account, and independent journalist.\n2. BUSINESS: Top market/finance analysis with real data.\n3. SPORTS: (a) Biggest sports NEWS story people actually care about (injuries, trades, results). (b) Most viral Stephen A. Smith clip right now. (c) Most viral Colin Cowherd clip right now.\n4. ELON: Elon's 3 most interesting recent posts, each on a DIFFERENT theme. Not repetitive Grok posts — diverse topics.\n5. PODS: Top 3 trending podcast clips on X right now from major podcasts (Joe Rogan, All-In, Call Her Daddy, The Daily, etc). Pick the ones with the most views/engagement.\n6. ALLIN: Best recent post from chamath, davidsacks, pmarca, or PalmerLuckey.\n7. TOP: Most viral post on all of X today.\n8. MSM: Story trending on X that CNN/NYT/WaPo are NOT covering.\n9. RECIPE: Top 2 most viral food/recipe posts on X right now.\n10. LOCAL: US local news from citizen journalists.\n\nJSON format:\n{\"world\":{\"stories\":[{\"topic\":\"...\",\"headline\":\"one-line headline\",\"conservative\":{\"handle\":\"@...\",\"angle\":\"2-3 sentences\"},\"democrat\":{\"handle\":\"@...\",\"angle\":\"2-3 sentences\"},\"independent\":{\"handle\":\"@...\",\"angle\":\"2-3 sentences\"},\"honesty\":\"X/10\",\"notes\":\"...\",\"footnotes\":[\"1. conservative honesty note\",\"2. democrat honesty note\",\"3. independent honesty note\"]}]},\"business\":{\"topic\":\"...\",\"headline\":\"...\",\"handle\":\"@...\",\"body\":\"2-3 sentences\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"sports\":{\"main\":{\"headline\":\"...\",\"handle\":\"@...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"stephena\":{\"headline\":\"...\",\"handle\":\"@stephenasmith\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"cowherd\":{\"headline\":\"...\",\"handle\":\"@TheHerd\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"}},\"elon\":{\"posts\":[{\"headline\":\"...\",\"handle\":\"@elonmusk\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},{\"headline\":\"...\",\"handle\":\"@elonmusk\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},{\"headline\":\"...\",\"handle\":\"@elonmusk\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"}]},\"pods\":{\"clips\":[{\"headline\":\"...\",\"handle\":\"@...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},{\"headline\":\"...\",\"handle\":\"@...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},{\"headline\":\"...\",\"handle\":\"@...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"}]},\"allin\":{\"topic\":\"...\",\"headline\":\"...\",\"handle\":\"@...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"top\":{\"topic\":\"...\",\"headline\":\"...\",\"handle\":\"@...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"msm\":{\"topic\":\"...\",\"headline\":\"...\",\"handle\":\"@...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},\"recipe\":{\"posts\":[{\"headline\":\"...\",\"handle\":\"@...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"},{\"headline\":\"...\",\"handle\":\"@...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"}]},\"local\":{\"topic\":\"...\",\"headline\":\"...\",\"handle\":\"@...\",\"body\":\"...\",\"honesty\":\"X/10\",\"notes\":\"...\"}}"}
  ],
  "tools": [{"type": "web_search"}],
  "max_output_tokens": 5000,
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

# Use json.raw_decode to properly parse first JSON object (handles braces in strings)
decoder = json.JSONDecoder()
parsed, _ = decoder.raw_decode(text.strip())
print(json.dumps(parsed))
PYPARSESCRIPT

STEP1=$(python3 /tmp/grok_parse.py /tmp/grok_step1_raw.json)

if [ -z "$STEP1" ]; then
    echo "ERROR: Step 1 failed"
    exit 1
fi
echo "Step 1 done. Got story intelligence."

# ============================================================
# STEP 2: Build URL search request from Step 1 handles
# ============================================================
echo "Step 2: Finding real post URLs..."

# Generate the Step 2 prompt from Step 1 data
STEP2_PROMPT=$(echo "$STEP1" | python3 -c "
import sys, json

data = json.loads(sys.stdin.read())
lines = ['Find the real X post IDs (numeric status IDs) for these accounts. Use web_search. Return null if not found.', '']

i = 1
# World perspectives (1-3 stories)
w = data.get('world', {})
world_stories = w.get('stories', [])
# Backwards compat: if world has direct conservative/democrat/independent, wrap it
if not world_stories and w.get('conservative'):
    world_stories = [w]
for ws in world_stories:
    for key in ['conservative', 'democrat', 'independent']:
        p = ws.get(key, {})
        if p.get('handle'):
            topic = ws.get('topic', '')
            lines.append(f'{i}. {p[\"handle\"]} - posting about: {topic}')
            i += 1

# Sports: main + stephena + cowherd
sp = data.get('sports', {})
for key in ['main', 'stephena', 'cowherd']:
    s = sp.get(key, {})
    if s.get('handle'):
        lines.append(f'{i}. {s[\"handle\"]} - posting about: {s.get(\"headline\", \"\")}')
        i += 1

# Elon posts (up to 3)
elon = data.get('elon', {})
for ep in elon.get('posts', []):
    if ep.get('handle'):
        lines.append(f'{i}. {ep[\"handle\"]} - posting about: {ep.get(\"headline\", \"\")}')
        i += 1

# Pods clips (up to 3)
pods = data.get('pods', {})
for pc in pods.get('clips', []):
    if pc.get('handle'):
        lines.append(f'{i}. {pc[\"handle\"]} - posting about: {pc.get(\"headline\", \"\")}')
        i += 1

# Recipe posts (up to 2)
recipe = data.get('recipe', {})
for rp in recipe.get('posts', []):
    if rp.get('handle'):
        lines.append(f'{i}. {rp[\"handle\"]} - posting about: {rp.get(\"headline\", \"\")}')
        i += 1

# Simple tabs
for tab in ['business', 'allin', 'top', 'msm', 'local']:
    d = data.get(tab, {})
    h = d.get('handle', '')
    if h and h != 'N/A':
        lines.append(f'{i}. {h} - posting about: {d.get(\"topic\", d.get(\"headline\", \"\"))}')
        i += 1

lines.append('')
lines.append('JSON: {\"posts\":[{\"handle\":\"@...\",\"post_id\":NUMERIC_OR_NULL,\"preview\":\"first 50 chars of post\"}]}')
print('\\n'.join(lines))
")

# Write the Step 2 request to a temp file to avoid quoting issues
python3 -c "
import json, sys
prompt = sys.stdin.read().strip()
payload = {
    'model': 'grok-4-1-fast-non-reasoning',
    'input': [
        {'role': 'system', 'content': 'You are Grok on X. Find real post IDs from X. Use web_search to verify each one. Return null for post_id if you cannot find the real numeric ID. Do NOT fabricate IDs. Return JSON only.'},
        {'role': 'user', 'content': prompt}
    ],
    'tools': [{'type': 'web_search'}],
    'max_output_tokens': 3000,
    'temperature': 0.1
}
print(json.dumps(payload))
" <<< "$STEP2_PROMPT" > /tmp/grok_step2_payload.json

STEP2_RAW=$(curl -s --max-time 180 https://api.x.ai/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -d @/tmp/grok_step2_payload.json)

echo "$STEP2_RAW" > /tmp/grok_step2_raw.json
STEP2=$(python3 /tmp/grok_parse.py /tmp/grok_step2_raw.json)

echo "Step 2 done."

# ============================================================
# STEP 3: Assemble and update index.html
# ============================================================
echo "Step 3: Assembling and updating..."

python3 - "$NOW" "$STEP1" "$STEP2" <<'PYEOF'
import json, re, sys

now = sys.argv[1]
stories = json.loads(sys.argv[2])
url_data = json.loads(sys.argv[3])

# Build URL lookup from Step 2
url_map = {}
for post in url_data.get('posts', []):
    handle = post.get('handle', '').lower().lstrip('@')
    pid = post.get('post_id')
    if pid and str(pid).isdigit():
        url_map[handle] = f"https://x.com/{handle}/status/{pid}"

def get_url(handle):
    h = handle.lower().lstrip('@')
    if h in url_map:
        return url_map[h]
    return f"https://x.com/{h}"

with open('index.html', 'r') as f:
    html = f.read()

# ---- PRESERVE OLD STORIES INTO EARLIER ----
# Extract the current lastUpdated time to stamp old stories
old_time_match = re.search(r'lastUpdated: "([^"]*)"', html)
old_time = old_time_match.group(1) if old_time_match else now
from datetime import datetime
try:
    old_dt = datetime.strptime(old_time.strip(), "%m/%d/%Y, %I:%M:%S %p")
    old_time_short = old_dt.strftime("%-I:%M %p")
except:
    old_time_short = old_time

def preserve_earlier(tab_name, html_text):
    """Move current stories into the earlier array for a given tab."""
    # Extract current stories block
    pattern = r'(' + re.escape(tab_name) + r': \{[^}]*?stories: )(\[.*?\])(,\s*earlier: )(\[.*?\])'
    m = re.search(pattern, html_text, flags=re.DOTALL)
    if not m:
        return html_text
    old_stories_js = m.group(2).strip()
    old_earlier_js = m.group(4).strip()
    # Skip if old stories are empty
    if old_stories_js == '[]':
        return html_text
    # Filter out "Honesty footnotes" entries from old stories before archiving
    # Add time stamp to each old story
    old_stories_stamped = re.sub(
        r'(\{[\s\n]*headline:)',
        '{ time: "' + old_time_short + '", headline:',
        old_stories_js
    )
    # Remove honesty footnote objects from earlier (they clutter the archive)
    old_stories_stamped = re.sub(
        r',?\s*\{\s*time:[^}]*headline:\s*"Honesty footnotes"[^}]*\}',
        '',
        old_stories_stamped
    )
    # Merge: prepend old stories to existing earlier array
    if old_earlier_js == '[]':
        new_earlier = old_stories_stamped
    else:
        # Insert old stories at the beginning of earlier
        inner_old = old_stories_stamped.strip()[1:-1].strip()  # strip [ ]
        inner_existing = old_earlier_js.strip()[1:-1].strip()
        if inner_old and inner_existing:
            new_earlier = '[' + inner_old + ',\n' + inner_existing + ']'
        elif inner_old:
            new_earlier = '[' + inner_old + ']'
        else:
            new_earlier = old_earlier_js
    # Replace the earlier array in html
    html_text = re.sub(
        r'(' + re.escape(tab_name) + r': \{[^}]*?stories: \[.*?\],\s*earlier: )\[.*?\]',
        lambda mx: mx.group(1) + new_earlier,
        html_text, flags=re.DOTALL
    )
    return html_text

# Preserve stories for all tabs before overwriting
all_tabs = ['world', 'business', 'sports', 'elon', 'allin', 'top', 'msm', 'local', 'recipe', 'pods', 'pg6']
for tab in all_tabs:
    if tab in stories:
        html = preserve_earlier(tab, html)

html = re.sub(r'lastUpdated: "[^"]*"', 'lastUpdated: "' + now + '"', html)

def js_str(s):
    return json.dumps(s)

# ---- Update WORLD (1-3 stories) ----
if 'world' in stories:
    w = stories['world']
    # Support both array format and legacy single-story format
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
            url = get_url(p['handle'])
            text = p.get('angle', '')
            honesty = ws.get('honesty', '8/10')
            persp_lines.append(
                '            { label: "' + label + '", handle: "' + p['handle'] +
                '", url: "' + url + '", text: ' + js_str(text) +
                ', honesty: "' + honesty + '" }'
            )
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

    new_stories = '[\n        ' + ',\n        '.join(story_blocks) + '\n      ]'

    html = re.sub(
        r'(world: \{[^}]*?stories: )\[.*?\](,\s*earlier:)',
        lambda m: m.group(1) + new_stories + m.group(2),
        html, flags=re.DOTALL
    )

# ---- Update SPORTS (main + Stephen A + Cowherd) ----
if 'sports' in stories:
    sp = stories['sports']
    sport_stories = []

    for key in ['main', 'stephena', 'cowherd']:
        s = sp.get(key, {})
        if not s.get('handle'):
            continue
        url = get_url(s['handle'])
        prefix = '\U0001f3a4 ' if key in ('stephena', 'cowherd') else ''
        sport_stories.append(
            '{\n'
            '          headline: ' + js_str(prefix + s.get('headline', '')) + ',\n'
            '          handle: "' + s['handle'] + '",\n'
            '          url: "' + url + '",\n'
            '          honesty: "' + s.get('honesty', '8/10') + '",\n'
            '          notes: ' + js_str(s.get('notes', '')) + ',\n'
            '          body: ' + js_str(s.get('body', '')) + '\n'
            '        }'
        )
        # Add honesty footnote after main story
        if key == 'main':
            sport_stories.append(
                '{ headline: "Honesty footnotes", body: ' + js_str(s.get('notes', '')) + ' }'
            )

    new_stories = '[' + ',\n        '.join(sport_stories) + '\n      ]'
    pattern = r'(sports: \{[^}]*?stories: )\[.*?\](,\s*earlier:)'
    html = re.sub(pattern, lambda m: m.group(1) + new_stories + m.group(2), html, flags=re.DOTALL)

# ---- Update ELON (3 bangers) ----
if 'elon' in stories:
    elon = stories['elon']
    elon_stories = []
    for ep in elon.get('posts', []):
        if not ep.get('handle'):
            continue
        url = get_url(ep['handle'])
        elon_stories.append(
            '{\n'
            '          headline: ' + js_str(ep.get('headline', '')) + ',\n'
            '          handle: "' + ep['handle'] + '",\n'
            '          url: "' + url + '",\n'
            '          honesty: "' + ep.get('honesty', '10/10') + '",\n'
            '          notes: ' + js_str(ep.get('notes', '')) + ',\n'
            '          body: ' + js_str(ep.get('body', '')) + '\n'
            '        }'
        )
    new_stories = '[' + ',\n        '.join(elon_stories) + '\n      ]'
    pattern = r'(elon: \{[^}]*?stories: )\[.*?\](,\s*earlier:)'
    html = re.sub(pattern, lambda m: m.group(1) + new_stories + m.group(2), html, flags=re.DOTALL)

# ---- Update PODS (3 clips) ----
if 'pods' in stories:
    pods = stories['pods']
    pod_stories = []
    notes_all = []
    for pc in pods.get('clips', []):
        if not pc.get('handle'):
            continue
        url = get_url(pc['handle'])
        pod_stories.append(
            '{\n'
            '          headline: ' + js_str(pc.get('headline', '')) + ',\n'
            '          handle: "' + pc['handle'] + '",\n'
            '          url: "' + url + '",\n'
            '          honesty: "' + pc.get('honesty', '8/10') + '",\n'
            '          notes: ' + js_str(pc.get('notes', '')) + ',\n'
            '          body: ' + js_str(pc.get('body', '')) + '\n'
            '        }'
        )
        notes_all.append(pc.get('notes', ''))
    pod_stories.append(
        '{ headline: "Honesty footnotes", body: ' + js_str(' '.join(notes_all)) + ' }'
    )
    new_stories = '[' + ',\n        '.join(pod_stories) + '\n      ]'
    pattern = r'(pods: \{[^}]*?stories: )\[.*?\](,\s*earlier:)'
    html = re.sub(pattern, lambda m: m.group(1) + new_stories + m.group(2), html, flags=re.DOTALL)

# ---- Update RECIPE (2 posts) ----
if 'recipe' in stories:
    recipe = stories['recipe']
    recipe_stories = []
    notes_all = []
    for rp in recipe.get('posts', []):
        if not rp.get('handle'):
            continue
        url = get_url(rp['handle'])
        recipe_stories.append(
            '{\n'
            '          headline: ' + js_str(rp.get('headline', '')) + ',\n'
            '          handle: "' + rp['handle'] + '",\n'
            '          url: "' + url + '",\n'
            '          honesty: "' + rp.get('honesty', '10/10') + '",\n'
            '          notes: ' + js_str(rp.get('notes', '')) + ',\n'
            '          body: ' + js_str(rp.get('body', '')) + '\n'
            '        }'
        )
        notes_all.append(rp.get('notes', ''))
    recipe_stories.append(
        '{ headline: "Honesty footnotes", body: ' + js_str(' '.join(notes_all)) + ' }'
    )
    new_stories = '[' + ',\n        '.join(recipe_stories) + '\n      ]'
    pattern = r'(recipe: \{[^}]*?stories: )\[.*?\](,\s*earlier:)'
    html = re.sub(pattern, lambda m: m.group(1) + new_stories + m.group(2), html, flags=re.DOTALL)

# ---- Update simple tabs (business, allin, top, msm, local) ----
simple_tabs = ['business', 'allin', 'top', 'msm', 'local', 'pg6']
for tab in simple_tabs:
    if tab not in stories:
        continue
    d = stories[tab]
    handle = d.get('handle', '')
    if not handle or handle == 'N/A':
        continue

    url = get_url(handle)

    new_stories = (
        '[{\n'
        '          headline: ' + js_str(d.get('headline', d.get('topic', ''))) + ',\n'
        '          handle: "' + handle + '",\n'
        '          url: "' + url + '",\n'
        '          honesty: "' + d.get('honesty', '8/10') + '",\n'
        '          notes: ' + js_str(d.get('notes', '')) + ',\n'
        '          body: ' + js_str(d.get('body', '')) + '\n'
        '        },\n'
        '        { headline: "Honesty footnotes", body: ' + js_str(d.get('notes', '')) + ' }\n'
        '      ]'
    )

    pattern = r'(' + re.escape(tab) + r': \{[^}]*?stories: )\[.*?\](,\s*earlier:)'
    html = re.sub(pattern, lambda m, ns=new_stories: m.group(1) + ns + m.group(2), html, flags=re.DOTALL)

# Report URL quality
import re as re2
status_urls = re2.findall(r'url: "https://x\.com/[^"]+/status/\d+', html)
profile_urls = re2.findall(r'url: "https://x\.com/[a-zA-Z0-9_]+"[,\s]', html)
print(f"URLs with /status/: {len(status_urls)} | Profile-only: {len(profile_urls)}")

with open('index.html', 'w') as f:
    f.write(html)

print("index.html updated successfully")
PYEOF

# Step 4: Deploy to Netlify
echo "Deploying to Netlify..."
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"
npx netlify-cli deploy --prod --dir=. --auth="$NETLIFY_AUTH_TOKEN" --site="$NETLIFY_SITE_ID" 2>&1 | tail -5

echo "=== Update complete at $(date) ==="
