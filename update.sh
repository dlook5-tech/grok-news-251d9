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
3. URL format: EXACTLY https://x.com/{handle_without_@}/status/{numeric_post_id_from_tool}. If the tool does not return a valid numeric post_id, set "url": null.
4. Never return profile URLs (x.com/handle) or any URL without /status/. Return null instead.
5. Zero creativity on URLs, IDs, dates, or facts. These must come directly from tool results.
6. Output ONLY valid JSON. No markdown, no fences, no text outside the JSON object.
7. Use EXPLICIT x_search operators in query strings: min_faves:N, min_retweets:N, since:YYYY-MM-DD, from:handle, -exclude_word. Do NOT rely on natural language instructions for filtering.
8. Use mode: "Top" to get highest-engagement posts (not "Latest" which is purely chronological).'

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

You are finding the 3 biggest DIFFERENT political/world news stories trending on X right now.

STEP A — Find 3 DISTINCT topics using NEGATIVE KEYWORD EXCLUSION:
- Search 1: "breaking news OR world news OR politics since:$YESTERDAY min_faves:1000", mode: "Top", limit: 15
  → Identify TOPIC 1 and its keywords
- Search 2: "(breaking news OR politics) since:$YESTERDAY min_faves:1000 -(topic1 keywords)" mode: "Top", limit: 15
  → Identify TOPIC 2 (MUST be different from topic 1 — use -keyword to exclude topic 1 terms)
- Search 3: "(breaking news OR politics) since:$YESTERDAY min_faves:500 -(topic1 keywords) -(topic2 keywords)" mode: "Top", limit: 15
  → Identify TOPIC 3 (exclude BOTH topic 1 and 2 keywords)

STEP B — For EACH topic, find 3 perspectives. Each perspective MUST be about the SAME topic:
- Conservative: query: "(topic keywords) from:JackPosobiec OR from:TuckerCarlson OR from:benshapiro OR from:charliekirk11 OR from:TomFitton OR from:WhiteHouse OR from:SenTedCruz OR from:RealCandaceO OR from:BillMelugin_ since:$YESTERDAY", mode: "Top", limit: 10
- Democrat: query: "(topic keywords) from:AOC OR from:BernieSanders OR from:SenWarren OR from:Ilhan OR from:ChrisMurphyCT OR from:JoyceWhiteVance OR from:atrupar OR from:RBReich since:$YESTERDAY", mode: "Top", limit: 10
- Independent: query: "(topic keywords) from:ggreenwald OR from:mtaibbi OR from:BreakingPoints OR from:TheChiefNerd OR from:GeraldoRivera OR from:RayDalio OR from:Snowden since:$YESTERDAY", mode: "Top", limit: 10

CRITICAL: ALL 3 perspectives MUST discuss the EXACT same topic as the headline. If a handle's recent post is about a different subject, DO NOT use it — try another handle. NEVER grab a random recent post that doesn't match.

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

For EACH category, use x_search with the EXACT operators shown. Return EXACTLY 3 stories per category.

ELON (3 posts, 3 DIFFERENT topics): Search: "from:elonmusk since:$YESTERDAY min_faves:5000", mode: "Top", limit: 15. Pick the 3 most viral on different topics. Honesty always 10/10.

ALLIN (3 posts, 3 DIFFERENT people): Search for each: "from:chamath since:$YESTERDAY min_faves:100", "from:DavidSacks since:$YESTERDAY min_faves:100", "from:pmarca since:$YESTERDAY min_faves:100", "from:PalmerLuckey since:$YESTERDAY min_faves:100", "from:friedberg since:$YESTERDAY min_faves:100". mode: "Top". Pick 3 different people, highest engagement post from each.

TOP (3 posts): Search: "since:$YESTERDAY min_faves:50000", mode: "Top", limit: 20. The 3 single most viral posts on ALL of X right now. Any account. Different handles.

MSM (3 posts, 3 DIFFERENT handles — NEVER use the same handle twice): Stories blowing up on X that mainstream media is ignoring. Search EACH handle separately:
  "from:BillMelugin_ since:$YESTERDAY min_faves:500", mode: "Top", limit: 5
  "from:MattWalshBlog since:$YESTERDAY min_faves:500", mode: "Top", limit: 5
  "from:TimcastNews since:$YESTERDAY min_faves:500", mode: "Top", limit: 5
  "from:LibsOfTikTok since:$YESTERDAY min_faves:500", mode: "Top", limit: 5
  "from:RealSaavedra since:$YESTERDAY min_faves:500", mode: "Top", limit: 5
  "from:JamesOKeefeIII since:$YESTERDAY min_faves:200", mode: "Top", limit: 5
  Pick 1 post from 3 DIFFERENT handles — the highest engagement from each.

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

For EACH category, use x_search with the EXACT operators shown. Return EXACTLY 3 stories per category.

BUSINESS (3 posts): Must be about stocks, markets, finance, crypto, or business deals. NOT geopolitics/military. Search: "from:unusual_whales OR from:WatcherGuru OR from:StockMKTNewz OR from:RayDalio OR from:LizAnnSonders OR from:elerianm since:$YESTERDAY min_faves:200", mode: "Top", limit: 15. Pick posts about market moves, earnings, deals, or economic data.

SPORTS (3 posts, MUST be this exact structure):
  Post 1: Breaking sports news. Search: "from:ShamsCharania OR from:wojespn OR from:BleacherReport OR from:ESPNStatsInfo since:$YESTERDAY min_faves:100", mode: "Top", limit: 10
  Post 2: Stephen A Smith hot take. Search: "from:stephenasmith since:$YESTERDAY min_faves:20", mode: "Top", limit: 5
  Post 3: Colin Cowherd hot take. Search: "from:colincowherd OR from:TheHerd since:$YESTERDAY min_faves:20", mode: "Top", limit: 5

PODS (3 clips, 3 DIFFERENT shows — never repeat same host):
  Search each separately with mode: "Top":
  "from:TuckerCarlson since:$YESTERDAY min_faves:500"
  "from:lexfridman OR from:fridmanclips since:$YESTERDAY min_faves:100"
  "from:theallinpod since:$YESTERDAY min_faves:100"
  "from:joerogan OR from:JREClips since:$YESTERDAY min_faves:500"
  "from:MegynKellyShow since:$YESTERDAY min_faves:100"
  "from:PBDPodcast since:$YESTERDAY min_faves:100"
  Pick 3 from DIFFERENT shows — highest engagement from each.

PG6 (3 posts): Celebrity/entertainment gossip. Search: "from:PopCrave OR from:TMZ since:$YESTERDAY min_faves:1000", mode: "Top", limit: 15. If fewer than 3 results, do second search: "from:enews OR from:JustJared OR from:etnow since:$YESTERDAY min_faves:200", mode: "Top", limit: 10. Pick the 3 highest-engagement posts.

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

For EACH category, use x_search with the EXACT operators shown. Return EXACTLY 3 stories per category.

RECIPE (3 posts): Actual FOOD RECIPES you can cook. NOT product lists, NOT gadget ads, NOT listicles. Search: "from:FoodNetwork OR from:tasty OR from:halfbakedharvest OR from:budgetbytes OR from:foodandwine OR from:tasteofhome OR from:KitchenSanc2ary since:$YESTERDAY min_faves:10", mode: "Top", limit: 15. Body must name the dish. Skip any post that is not a recipe.

SCIENCE (3 posts): Actual science DISCOVERIES or research findings. NOT award votes, NOT rankings, NOT self-promotion. Search: "from:NASAWebb OR from:EricTopol OR from:ScienceAlert OR from:ProfFeynman OR from:NatureNews OR from:SciAm OR from:DrEricDing since:$YESTERDAY min_faves:50", mode: "Top", limit: 15. Body must describe what was discovered.

LOCAL (3 posts): ONLY stories physically located in Orange County, Newport Beach, Huntington Beach, Irvine, LA, or SoCal. Use location keywords AND negative exclusion to filter out wire stories:
  Search: "(\"Orange County\" OR \"Newport Beach\" OR \"Huntington Beach\" OR \"Los Angeles\" OR SoCal OR \"Southern California\") from:OC_Scanner OR from:ABC7 OR from:KTLA OR from:LAist OR from:OCRegister OR from:DailyPilot since:$YESTERDAY -Michigan -NYC -\"New York\" -Chicago -Florida -Texas", mode: "Top", limit: 20
  If fewer than 3 results, broaden: "from:OC_Scanner OR from:KTLA OR from:ABC7 since:$YESTERDAY min_faves:10 -Michigan -NYC -\"New York\" -Florida", mode: "Top", limit: 20
  Every story MUST be about a SoCal location.

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
