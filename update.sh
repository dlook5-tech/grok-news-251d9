#!/bin/bash
# eXpressO News — Clean pipeline
# 1. Call Grok API (using Grok's own recommended prompt format)
# 2. Parse + validate + write stories.json
# 3. Deploy

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

source .env

echo "=== eXpressO News Update — $(date) ==="

# ============================================================
# STEP 1: Call Grok
# ============================================================
echo "Step 1: Asking Grok..."

# Grok's own recommended prompt structure
cat > /tmp/grok_prompt.txt <<'PROMPT'
You are Grok, built by xAI. You are the world's best real-time news curator for eXpressO News — a site that highlights the greatness of citizen journalism on X by surfacing the most viral, honest, interesting stories every hour.

Your job: analyze the most viral, talked-about, retweeted, and liked X posts RIGHT NOW across these categories. Your output MUST be valid JSON ONLY — no extra text, no markdown, no code fences, no explanations outside the JSON.

Categories and approved handles:

WORLD (ALWAYS 3 stories): The 3 MOST VIRAL GEOPOLITICS / HARD NEWS stories on X right now. WAR, POLITICS, INTERNATIONAL RELATIONS, GOVERNMENT, ECONOMY — NOT sports, NOT entertainment, NOT celebrity gossip. Each story gets tri-partisan views. Return array of 3. Keep quotes SHORT (1 sentence). For EVERY perspective quote, write WHAT THAT PERSON ACTUALLY SAID — never write "no recent post" or leave blank. If the handle hasn't posted about this exact story, write their likely angle. Each story has:
  Conservative (pick 1): @JackPosobiec @Cernovich @RealCandaceO @benshapiro @TuckerCarlson @DonaldJTrumpJr @charliekirk11 @RealDailyWire @JDVance1 @SenTedCruz @TomFitton @JesseBWatters @IngrahamAngle @WarMonitors @sentdefender @CriticalThreats @WhiteHouse
  Democrat (pick 1): @AOC @Ilhan @RBReich @BernieSanders @RashidaTlaib @ChrisMurphyCT @SenWarren @JoyceWhiteVance @ProPublica @DropSiteNews
  Independent (pick 1): @HamidRezaAz @TheStudyofWar @vtchakarova @RayDalio @dalperovitch @InsightGL @KimZetter @Snowden @ggreenwald

BUSINESS (ALWAYS 3 stories): Return 3 different trending business/markets posts as an array. Keep body SHORT (1 sentence). @DowdEdward @RayDalio @Stocktwits @StockMKTNewz @WatcherGuru @unusual_whales @TruthGundlach @LizAnnSonders @elerianm

SPORTS (3 posts, in this exact order): Post 1 = LEAD breaking sports news from @ClutchPoints @BleacherReport @TheAthletic @ESPNStatsInfo @ShamsCharania @wojespn @CourtsideBuzzX. Post 2 = Stephen A. Smith's BEST recent hot take from @stephenasmith — if nothing from today, use his most recent viral take. NEVER leave blank or say "no take found". Post 3 = Colin Cowherd's BEST recent hot take from @colincowherd or @TheHerd — same rule, use most recent viral take, NEVER blank. Stephen A and Cowherd ALWAYS have opinions — find them.

ELON (3 posts, different topics): @elonmusk only. Honesty always 10/10. EVERY post MUST have a descriptive headline — never leave headline blank.

ALLIN (3 posts, different people): @chamath @DavidSacks @pmarca @PalmerLuckey @friedberg

TOP: The single most viral post on ALL of X from the LAST 6 HOURS ONLY. Any account. Must be FRESH — not recycled from yesterday or days ago. If the same post has been trending for multiple days, find a NEWER one that's blowing up TODAY. Use x_search with a time filter to find posts from the last few hours.

MSM: Story blowing up on X that CNN/NYT/WaPo are ignoring. Rotate between these handles — do NOT always pick Matt Walsh. @BillMelugin_ @MattWalshBlog @TimcastNews @TheRabbitHole84 @SCOTUSblog @InsightGL @JamesOKeefeIII @LibsOfTikTok @TPostMillennial @RealSaavedra

PG6: Hottest celebrity/entertainment gossip. @PopCrave @enews @JustJared @etnow @TMZ

PODS (2-3 clips from DIFFERENT shows): Viral podcast clips. @joerogan @joeroganhq @TuckerCarlson @theallinpod @lexfridman @CallHerDaddy @adamcarolla @JREClips @enews @PBDPodcast @MegynKellyShow @fridmanclips

RECIPE: An actual FOOD RECIPE going viral — with ingredients and cooking steps. NOT politics, NOT news. Must be about cooking/baking/food. @tasteofhome @FoodNetwork @thekitchn @HBHarvest @foodandwine @tasty @KitchenSanc2ary @budgetbytes @halfbakedharvest @AmbitiousKitch

SCIENCE: Most viral science/tech/space/health discovery post. @elikiml @ProfFeynman @BadAstronomer @ScienceAlert @NASAWebb @SPabortsev @EricTopol @NatureNews @SciAm @DrEricDing

LOCAL (ALWAYS 3 stories): Return 3 different Orange County / Newport Beach / SoCal stories as an array. Front-page-worthy real news only. Keep body SHORT (1 sentence). @OC_Scanner @ABC7 @LAist @KTLA @OCRegister @DailyPilot @NBPDsocial @CityofNewportBeach

Rules you MUST follow:
- RECENCY IS KING: Every post must be from the LAST 12 HOURS. Do NOT recycle posts from yesterday or earlier. If you've seen the same story trending for days, find a FRESHER angle or a different story. Stale content = failure.
- Be ruthlessly objective and transparent. Never favor left or right.
- For EVERY post, include the real X post URL (https://x.com/handle/status/NUMERIC_ID). Use x_search (NOT web_search) to find the actual post with query like "from:handle topic_keywords". If you truly cannot find the specific post URL, set url to null — but TRY HARD to find it.
- Include real engagement numbers in a clean format like "12K likes, 3.4K reposts"
- Honesty scoring: 10 = firsthand/direct source, 9 = well-sourced reporting, 8 = sourced analysis, 7 = opinion clearly labeled, 6 = spin/bias present
- Make it addictive for mainstream readers: short, scannable, juicy but factual
- ALWAYS return a story for every category. Never skip one. Never say "no post found." Never write "placeholder" or "no recent take" — those are FAILURES. If nothing is from today, use the most recent viral post. There is ALWAYS something.
- KEEP IT SHORT: Body/quote text must be 1-2 sentences MAX. No long paragraphs. Stories must fit on a laptop screen without scrolling. Scannable = good.
- HEADLINE RULE: Every headline MUST say WHAT THE STORY IS ABOUT in specific, pithy language. BAD: "Stephen A with fiery clip" or "Elon posts about tech". GOOD: "Stephen A rips Lakers for blowing 20-point lead to Celtics" or "Elon: Tesla AI5 chip will be made at TSMC and Samsung". The headline is the ONLY thing people see before clicking — make it tell the story.
- USE REAL NAMES in headlines, not handles. Write "Marc Andreessen" not "pmarca". Write "Chamath Palihapitiya" not "chamath". Write "Palmer Luckey" not "PalmerLuckey". This site is for mainstream readers who don't know X handles.

Output ONLY this JSON structure. Nothing else:
{"world":[{"headline":"...","honesty":"X/10","notes":"why this score","footnotes":["1. conservative bias note","2. democrat bias note","3. independent bias note"],"conservative":{"handle":"@...","quote":"2-3 sentences","engagement":"12K likes, 3K reposts","url":"https://x.com/.../status/... or null","honesty":"X/10"},"democrat":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"},"independent":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"}}],"business":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"sports":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"elon":[{"headline":"...","handle":"@elonmusk","body":"...","engagement":"...","url":"...","honesty":"10/10","notes":"..."}],"allin":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"top":{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},"msm":{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},"pg6":{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},"pods":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"recipe":{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},"science":{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},"local":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}]}
PROMPT

# Build API payload
python3 -c "
import json
with open('/tmp/grok_prompt.txt') as f:
    prompt = f.read().strip()
payload = {
    'model': 'grok-4-1-fast-non-reasoning',
    'input': [
        {'role': 'system', 'content': 'You are Grok, built by xAI. You are the worlds best real-time news curator. You have native access to X via x_search. For EVERY post, use x_search to find the actual tweet URL with /status/ID. Return ONLY valid JSON. Nothing else.'},
        {'role': 'user', 'content': prompt}
    ],
    'tools': [{'type': 'x_search'}, {'type': 'web_search'}],
    'max_output_tokens': 6000,
    'temperature': 0.2
}
with open('/tmp/grok_payload.json', 'w') as f:
    json.dump(payload, f)
"

GROK_RAW=$(curl -s --max-time 180 https://api.x.ai/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -d @/tmp/grok_payload.json)

echo "Step 1 done."

# ============================================================
# STEP 2: Parse, validate, write stories.json
# ============================================================
echo "Step 2: Parsing and validating..."

# Save raw for debugging
echo "$GROK_RAW" > /tmp/grok_raw.json

echo "$GROK_RAW" | python3 parse_grok.py

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
