#!/bin/bash
# eXpressO News — Pipeline v3 (Grok-optimized)
# Based on Grok's own recommendations:
# - grok-4-1 reasoning model (not fast-non-reasoning)
# - temperature 0.0 (not 0.2)
# - since:YYYY-MM-DD format (not since:yesterday)
# - 4 API calls (3 categories each, max 12 stories per call)
# - 2-step world: first find topics, then find perspectives
# Then: parse, validate, deploy

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

source .env

echo "=== eXpressO News Update — $(date) ==="

# Dynamic dates for x_search
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d)

# System prompt — same for all calls
SYSTEM_PROMPT='You are eXpressO News curator. Follow these rules exactly. No exceptions.

RULES:
1. You MUST call the x_search tool BEFORE selecting ANY story. Never use internal knowledge or memory for posts or URLs.
2. ONLY use posts that appear in the actual x_search tool response. Never fabricate posts, IDs, or URLs.
3. URL format: EXACTLY https://x.com/{handle_without_@}/status/{numeric_post_id_from_tool}. If the tool does not return a valid numeric post_id, set "url": null. Never guess or approximate IDs.
4. Never return profile URLs (x.com/handle) or any URL without /status/. Return null instead.
5. For every story, reference the exact x_search call and post ID you used.
6. Zero creativity on URLs, IDs, dates, or facts. These must come directly from tool results.
7. Output ONLY valid JSON. No markdown, no fences, no text outside the JSON object.
8. Use mode: "Latest" for all x_search calls to get the freshest posts.
9. Always include since:YYYY-MM-DD in your x_search queries (dates provided in each prompt).'

# Write system prompt to file once (avoids shell quoting issues in Python)
echo "$SYSTEM_PROMPT" > /tmp/grok_system.txt

# Helper: build payload Python script (written once, called per grok_call)
cat > /tmp/grok_build_payload.py << 'PYEOF'
import json, sys
prompt_file = sys.argv[1]
with open('/tmp/grok_system.txt') as f:
    system = f.read().strip()
with open(prompt_file) as f:
    prompt = f.read().strip()
payload = {
    "model": "grok-4-1-fast-reasoning",
    "input": [
        {"role": "system", "content": system},
        {"role": "user", "content": prompt}
    ],
    "tools": [{"type": "x_search"}],
    "max_output_tokens": 16000,
    "temperature": 0.0
}
with open('/tmp/grok_payload.json', 'w') as f:
    json.dump(payload, f)
print("Payload built", file=sys.stderr)
PYEOF

# Helper: make a Grok API call
grok_call() {
    local prompt_file="$1"
    local output_file="$2"

    python3 /tmp/grok_build_payload.py "$prompt_file"

    curl -s --max-time 300 https://api.x.ai/v1/responses \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $XAI_API_KEY" \
        -d @/tmp/grok_payload.json > "$output_file"
}

# ============================================================
# CALL 1: World News (2-step approach)
# Step A: Find trending topics
# Step B: Find perspectives on those topics
# ============================================================
echo "Call 1: World News (2-step)..."

cat > /tmp/grok_prompt_world.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.

You are finding the 3 biggest DIFFERENT political/world news stories trending on X right now. Each story MUST be a DIFFERENT topic — never repeat the same event across multiple stories.

STEP A: Call x_search with these queries to find trending topics:
- query: "breaking news OR world news OR politics since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 20
- Identify the top 3 DISTINCT trending topics (3 different events/subjects, not 3 angles on 1 event)

STEP B: For EACH of the 3 topics, search for perspectives from all 3 sides. Each perspective MUST be about the SAME topic as its headline:
- Conservative: query: "(topic keywords) from:JackPosobiec OR from:TuckerCarlson OR from:benshapiro OR from:charliekirk11 OR from:TomFitton OR from:WhiteHouse OR from:SenTedCruz OR from:RealCandaceO OR from:BillMelugin_ since:$YESTERDAY", mode: "Latest", limit: 8
- Democrat: query: "(topic keywords) from:AOC OR from:BernieSanders OR from:SenWarren OR from:Ilhan OR from:ChrisMurphyCT OR from:JoyceWhiteVance OR from:atrupar OR from:RBReich since:$YESTERDAY", mode: "Latest", limit: 8
- Independent: query: "(topic keywords) from:ggreenwald OR from:mtaibbi OR from:BreakingPoints OR from:TheChiefNerd OR from:GeraldoRivera OR from:RayDalio OR from:Snowden since:$YESTERDAY", mode: "Latest", limit: 8

CRITICAL: ALL 3 perspectives MUST discuss the EXACT same topic as the headline. If a handle's recent post is about a different subject, DO NOT use it — try another handle from the list. If no handle from a side posted about this topic, pick a different topic that all 3 sides ARE discussing. NEVER grab a random recent post that doesn't match the headline.

Body/quote: 1 sentence max, under 120 characters. Just the hook.
Footnotes: Format "Conservative X/10: [why this score]", "Democrat X/10: [why]", "Independent X/10: [why]". Explain what cost points vs 10/10.
Honesty: 10 = verifiable fact. 9 = sourced reporting with framing. 8 = analysis + opinion. 7 = opinion. 6 = spin.

Return this JSON:
{"world":[{"headline":"...","honesty":"X/10","notes":"...","footnotes":["Conservative X/10: ...","Democrat X/10: ...","Independent X/10: ..."],"conservative":{"handle":"@...","quote":"...","engagement":"...","url":"https://x.com/.../status/...","honesty":"X/10"},"democrat":{"handle":"@...","quote":"...","engagement":"...","url":"https://x.com/.../status/...","honesty":"X/10"},"independent":{"handle":"@...","quote":"...","engagement":"...","url":"https://x.com/.../status/...","honesty":"X/10"}},{"headline":"...","honesty":"X/10","notes":"...","footnotes":["Conservative X/10: ...","Democrat X/10: ...","Independent X/10: ..."],"conservative":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"},"democrat":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"},"independent":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"}},{"headline":"...","honesty":"X/10","notes":"...","footnotes":["Conservative X/10: ...","Democrat X/10: ...","Independent X/10: ..."],"conservative":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"},"democrat":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"},"independent":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"}}]}
PROMPT

grok_call /tmp/grok_prompt_world.txt /tmp/grok_raw1.json
echo "Call 1 done."

# ============================================================
# CALL 2: Elon + AllIn + Top + MSM (4 categories)
# ============================================================
echo "Call 2: Elon, AllIn, Top, MSM..."

cat > /tmp/grok_prompt2.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.

For EACH category, use x_search with since:$YESTERDAY and mode:"Latest" to find posts. Return EXACTLY 3 stories per category.

ELON (3 posts, 3 DIFFERENT topics): Search: "from:elonmusk since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 15. Pick the 3 most viral on different topics. Honesty always 10/10.

ALLIN (3 posts, 3 DIFFERENT people): Search for each: "from:chamath since:$YESTERDAY", "from:DavidSacks since:$YESTERDAY", "from:pmarca since:$YESTERDAY", "from:PalmerLuckey since:$YESTERDAY", "from:friedberg since:$YESTERDAY". Pick 3 different people.

TOP (3 posts): Search: "since:$YESTERDAY filter:has_engagement min_faves:50000", mode: "Latest", limit: 20. The 3 single most viral posts on ALL of X right now. Any account. Different handles.

MSM (3 posts, 3 DIFFERENT handles — NEVER use the same handle twice): Stories blowing up on X that mainstream media is ignoring. Search EACH handle separately to ensure diversity:
  "from:BillMelugin_ since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 5
  "from:MattWalshBlog since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 5
  "from:TimcastNews since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 5
  "from:LibsOfTikTok since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 5
  "from:RealSaavedra since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 5
  "from:JamesOKeefeIII since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 5
  Pick 1 post from 3 DIFFERENT handles. If 2 posts are from the same handle, drop one and pick from another handle.

Body text: 1 sentence max, under 120 chars. Just the hook.
Honesty: 10 = verifiable fact. 9 = sourced with framing. 8 = analysis + opinion. 7 = opinion. 6 = spin. DEFAULT 10 for facts.
Notes field: Explain why you scored honesty what you did. If below 10, say what cost points.

Return this JSON (every array has 3 items):
{"elon":[{"headline":"...","handle":"@elonmusk","body":"...","engagement":"...","url":"...","honesty":"10/10","notes":"..."},{"headline":"...","handle":"@elonmusk","body":"...","engagement":"...","url":"...","honesty":"10/10","notes":"..."},{"headline":"...","handle":"@elonmusk","body":"...","engagement":"...","url":"...","honesty":"10/10","notes":"..."}],"allin":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"top":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"msm":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}]}
PROMPT

grok_call /tmp/grok_prompt2.txt /tmp/grok_raw2.json
echo "Call 2 done."

# ============================================================
# CALL 3: Business + Sports + Pods + Pg6 (4 categories)
# ============================================================
echo "Call 3: Business, Sports, Pods, Pg6..."

cat > /tmp/grok_prompt3.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.

For EACH category, use x_search with since:$YESTERDAY and mode:"Latest" to find posts. Return EXACTLY 3 stories per category.

BUSINESS (3 posts): Must be about stocks, markets, finance, crypto, or business deals. NOT geopolitics/military. Search: "from:unusual_whales OR from:WatcherGuru OR from:StockMKTNewz OR from:RayDalio OR from:LizAnnSonders OR from:elerianm since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 15. Pick posts about market moves, earnings, deals, or economic data — skip anything that's pure politics/military.

SPORTS (3 posts, MUST be this exact structure):
  Post 1: Breaking sports news. Search: "from:ShamsCharania OR from:wojespn OR from:BleacherReport OR from:ESPNStatsInfo since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 10
  Post 2: Stephen A Smith hot take. Search: "from:stephenasmith since:$YESTERDAY", mode: "Latest", limit: 5
  Post 3: Colin Cowherd hot take. Search: "from:colincowherd OR from:TheHerd since:$YESTERDAY", mode: "Latest", limit: 5

PODS (3 clips, 3 DIFFERENT shows — never repeat same host):
  Search each separately: "from:TuckerCarlson since:$YESTERDAY", "from:lexfridman OR from:fridmanclips since:$YESTERDAY", "from:theallinpod since:$YESTERDAY", "from:joerogan OR from:JREClips since:$YESTERDAY", "from:MegynKellyShow since:$YESTERDAY", "from:PBDPodcast since:$YESTERDAY"
  Pick 3 from DIFFERENT shows.

PG6 (3 posts): Celebrity/entertainment gossip with HIGH engagement. Search: "from:PopCrave OR from:TMZ OR from:enews OR from:JustJared OR from:etnow since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 20. Pick the 3 posts with the HIGHEST likes+reposts. Minimum 500 likes required — skip low-engagement posts. Prioritize PopCrave and TMZ (they get the most engagement).

Body text: 1 sentence max, under 120 chars.
Honesty: 10 = verifiable fact. 9 = sourced with framing. 8 = analysis + opinion. 7 = opinion. DEFAULT 10 for facts.
Notes: Explain why you scored honesty what you did.

Return this JSON (every array has 3 items, each = {"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}):
{"business":[{...},{...},{...}],"sports":[{...},{...},{...}],"pods":[{...},{...},{...}],"pg6":[{...},{...},{...}]}
PROMPT

grok_call /tmp/grok_prompt3.txt /tmp/grok_raw3.json
echo "Call 3 done."

# ============================================================
# CALL 4: Recipe + Science + Local (3 categories)
# ============================================================
echo "Call 4: Recipe, Science, Local..."

cat > /tmp/grok_prompt4.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.

For EACH category, use x_search with since:$YESTERDAY and mode:"Latest" to find posts. Return EXACTLY 3 stories per category.

RECIPE (3 posts): Actual FOOD RECIPES with cooking instructions — must be a recipe you can make (ingredients + method). NOT product roundups, NOT kitchen gadget ads, NOT listicles. Search: "from:FoodNetwork OR from:tasty OR from:halfbakedharvest OR from:budgetbytes OR from:foodandwine OR from:tasteofhome OR from:KitchenSanc2ary since:$YESTERDAY recipe OR cook OR bake OR ingredients", mode: "Latest", limit: 15. The body must name the dish being made.

SCIENCE (3 posts): Actual science DISCOVERIES, BREAKTHROUGHS, or research findings. NOT award votes, NOT self-promotion, NOT rankings. Must be about a scientific finding or space/health/tech discovery. Search: "from:NASAWebb OR from:EricTopol OR from:ScienceAlert OR from:ProfFeynman OR from:NatureNews OR from:SciAm OR from:DrEricDing since:$YESTERDAY filter:has_engagement", mode: "Latest", limit: 15. Body must describe what was discovered or found.

LOCAL (3 posts): ONLY stories about Orange County, Newport Beach, Huntington Beach, Irvine, Costa Mesa, Laguna Beach, or greater Southern California (LA, San Diego). NEVER include stories about other states (NYC, Michigan, etc.) even if posted by a SoCal outlet. Read each post and verify the LOCATION of the story is in SoCal before including it. Search: "from:OC_Scanner OR from:ABC7 OR from:KTLA OR from:LAist OR from:OCRegister OR from:DailyPilot since:$YESTERDAY", mode: "Latest", limit: 20. If a post is about a non-SoCal location, SKIP it and pick the next one.

Body text: 1 sentence max, under 120 chars.
Honesty: 10 = verifiable fact. 9 = sourced with framing. 8 = analysis + opinion. DEFAULT 10 for facts.
Notes: Explain why you scored honesty what you did.

Return this JSON (every array has 3 items, each = {"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}):
{"recipe":[{...},{...},{...}],"science":[{...},{...},{...}],"local":[{...},{...},{...}]}
PROMPT

grok_call /tmp/grok_prompt4.txt /tmp/grok_raw4.json
echo "Call 4 done."

# ============================================================
# STEP 2: Merge all 4 responses, parse, validate
# ============================================================
echo "Step 2: Parsing and validating..."

python3 -c "
import json, sys, re

def extract_json_text(raw_file):
    try:
        with open(raw_file) as f:
            r = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f'ERROR reading {raw_file}: {e}', file=sys.stderr)
        return None
    if 'error' in r and r.get('error'):
        print('ERROR from ' + raw_file + ': ' + str(r['error']), file=sys.stderr)
        return None
    # Collect ALL output_text blocks and return the LAST one that contains JSON
    # (Grok puts tool call fragments in earlier output_text blocks)
    candidates = []
    for item in r.get('output', []):
        if item.get('type') == 'message':
            for c in item.get('content', []):
                if c.get('type') == 'output_text':
                    candidates.append(c['text'])
    # Return last candidate that has a { (most likely to be the JSON)
    for t in reversed(candidates):
        if '{' in t:
            return t
    return candidates[-1] if candidates else None

def parse_json(text):
    if not text:
        return {}
    text = text.strip()
    if text.startswith('\`\`\`'):
        text = re.sub(r'\`\`\`json?\s*', '', text)
        text = re.sub(r'\`\`\`\s*$', '', text)
    start = text.find('{')
    if start == -1:
        return {}
    depth = 0; end = 0; in_string = False; escape_next = False
    for i in range(start, len(text)):
        ch = text[i]
        if escape_next: escape_next = False; continue
        if ch == '\\\\' and in_string: escape_next = True; continue
        if ch == '\"': in_string = not in_string; continue
        if in_string: continue
        if ch == '{': depth += 1
        elif ch == '}': depth -= 1
        if depth == 0: end = i + 1; break
    try:
        return json.loads(text[start:end])
    except:
        fixed = re.sub(r',(\s*[}\]])', r'\1', text[start:end])
        try:
            return json.loads(fixed)
        except:
            return {}

merged = {}
for i in range(1, 5):
    t = extract_json_text(f'/tmp/grok_raw{i}.json')
    d = parse_json(t)
    if d:
        print(f'  Call {i}: got keys {list(d.keys())}', file=sys.stderr)
        merged.update(d)
    else:
        print(f'  Call {i}: FAILED or empty', file=sys.stderr)

if not merged:
    print('ERROR: All API calls failed', file=sys.stderr)
    sys.exit(1)

fake_response = {
    'output': [{
        'type': 'message',
        'content': [{'type': 'output_text', 'text': json.dumps(merged)}]
    }]
}
print(json.dumps(fake_response))
" > /tmp/grok_raw.json

cat /tmp/grok_raw.json | python3 parse_grok.py

if [ $? -ne 0 ]; then
    echo "ABORT: Validation failed. Old stories.json preserved."
    exit 1
fi

echo "Step 2 done."

# ============================================================
# STEP 3: Deploy
# ============================================================
echo "Step 3: Deploying..."
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"
npx netlify-cli deploy --prod --dir=. --auth="$NETLIFY_AUTH_TOKEN" --site="$NETLIFY_SITE_ID" 2>&1 | tail -5

echo "=== Done at $(date) ==="
