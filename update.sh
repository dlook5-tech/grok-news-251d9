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

WORLD (3 stories, each with tri-partisan views): The 3 MOST VIRAL hard news stories on X right now (most likes, reposts, replies, quote tweets). Pick stories with the HIGHEST real engagement numbers. Each story gets 3 perspectives:
  Conservative (pick 1 per story): @JackPosobiec @Cernovich @RealCandaceO @benshapiro @TuckerCarlson @DonaldJTrumpJr @charliekirk11 @RealDailyWire @JDVance1 @SenTedCruz @TomFitton @JesseBWatters @IngrahamAngle @WarMonitors @sentdefender @CriticalThreats @WhiteHouse
  Democrat (pick 1 per story): @AOC @Ilhan @RBReich @BernieSanders @RashidaTlaib @ChrisMurphyCT @SenWarren @JoyceWhiteVance @ProPublica @DropSiteNews
  Independent (pick 1 per story): @HamidRezaAz @TheStudyofWar @vtchakarova @RayDalio @dalperovitch @InsightGL @KimZetter @Snowden @ggreenwald

BUSINESS (3 posts): @DowdEdward @RayDalio @Stocktwits @StockMKTNewz @WatcherGuru @unusual_whales @TruthGundlach @LizAnnSonders @elerianm

SPORTS (3 posts): 1 breaking news from @ShamsCharania or @wojespn, PLUS 1 hot take clip from @colincowherd or @stephenasmith (ALWAYS include one of these two unless another pundit has a more viral clip). 3rd post from: @ClutchPoints @BleacherReport @CourtsideBuzzX @TheAthletic @ESPNStatsInfo @TheHerd

ELON (3 posts, different topics): @elonmusk only. Honesty always 10/10. EVERY post MUST have a descriptive headline — never leave headline blank.

ALLIN (3 posts, different people): @chamath @DavidSacks @pmarca @PalmerLuckey @friedberg

TOP (3 posts): The 3 most viral posts on ALL of X right now. Any account. Different handles for each.

MSM (3 posts): Stories blowing up on X that CNN/NYT/WaPo are ignoring. Rotate between these handles — do NOT always pick Matt Walsh. Use 3 DIFFERENT handles. @BillMelugin_ @MattWalshBlog @TimcastNews @TheRabbitHole84 @SCOTUSblog @InsightGL @JamesOKeefeIII @LibsOfTikTok @TPostMillennial @RealSaavedra

PG6 (3 posts): Hottest celebrity/entertainment gossip. @PopCrave @enews @JustJared @etnow @TMZ

PODS (3 clips from DIFFERENT shows): Viral podcast clips. @joerogan @joeroganhq @TuckerCarlson @theallinpod @lexfridman @CallHerDaddy @adamcarolla @JREClips @enews @PBDPodcast @MegynKellyShow @fridmanclips

RECIPE (3 posts): Actual FOOD RECIPES going viral — with ingredients and cooking steps. NOT politics, NOT news. Must be about cooking/baking/food. @tasteofhome @FoodNetwork @thekitchn @HBHarvest @foodandwine @tasty @KitchenSanc2ary @budgetbytes @halfbakedharvest @AmbitiousKitch

SCIENCE (3 posts): Most viral science/tech/space/health discovery posts. @elikiml @ProfFeynman @BadAstronomer @ScienceAlert @NASAWebb @SPabortsev @EricTopol @NatureNews @SciAm @DrEricDing

LOCAL (3 posts): Orange County / Newport Beach / SoCal ONLY. @OC_Scanner @ABC7 @LAist @KTLA @OCRegister @DailyPilot @NBPDsocial @CityofNewportBeach

Rules you MUST follow:
- Be ruthlessly objective and transparent. Never favor left or right.
- For EVERY post, include the real X post URL (https://x.com/handle/status/NUMERIC_ID). Use x_search (NOT web_search) to find the actual post with query like "from:handle topic_keywords". If you truly cannot find the specific post URL, set url to null — but TRY HARD to find it.
- Include real engagement numbers in a clean format like "12K likes, 3.4K reposts"
- Honesty scoring: 10 = verifiable fact or firsthand source (a whale washed up, a game score, a direct quote, an official statement — if it happened, it's 10). 9 = well-sourced reporting with minor editorial framing. 8 = analysis with opinion mixed in. 7 = opinion clearly labeled. 6 = spin/bias. DEFAULT TO 10 for factual events. Only lower if there are unverified claims or clear spin.
- Make it addictive for mainstream readers: short, scannable, juicy but factual
- ALWAYS return a story for every category. Never skip one. Never say "no post found."
- EVERY category MUST have EXACTLY 3 items in its array. This is critical — do not return just 1.
- EVERY story MUST have a non-empty headline field. Write a short descriptive headline even if the post is a reply or quote tweet.
- Keep body text SHORT (2-3 sentences max) to stay within output limits.

IMPORTANT: Every array below must have EXACTLY 3 objects. I am showing 3 to be clear. Do NOT return just 1.

Output ONLY this JSON structure. Nothing else:
{"world":[{"headline":"STORY1","honesty":"X/10","notes":"...","footnotes":["1.","2.","3."],"conservative":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"},"democrat":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"},"independent":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"}},{"headline":"STORY2","honesty":"X/10","notes":"...","footnotes":["1.","2.","3."],"conservative":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"},"democrat":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"},"independent":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"}},{"headline":"STORY3","honesty":"X/10","notes":"...","footnotes":["1.","2.","3."],"conservative":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"},"democrat":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"},"independent":{"handle":"@...","quote":"...","engagement":"...","url":"...","honesty":"X/10"}}],"business":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"sports":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"elon":[{"headline":"...","handle":"@elonmusk","body":"...","engagement":"...","url":"...","honesty":"10/10","notes":"..."},{"headline":"...","handle":"@elonmusk","body":"...","engagement":"...","url":"...","honesty":"10/10","notes":"..."},{"headline":"...","handle":"@elonmusk","body":"...","engagement":"...","url":"...","honesty":"10/10","notes":"..."}],"allin":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"top":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"msm":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"pg6":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"pods":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"recipe":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"science":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}],"local":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."}]}
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
    'max_output_tokens': 32000,
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
