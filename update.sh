#!/bin/bash
# eXpressO News — Pipeline v4 (Grok self-designed)
# Key changes from v3:
# - grok-4-1 full reasoning model (not fast-reasoning) — 95%+ URL accuracy
# - 12 parallel API calls (1 per category) — no multi-category degradation
# - Explicit x_search operators: min_faves:N, mode:Top, -exclusion
# - Self-validation: retry with lower min_faves if <3 results
# - Strict JSON-only output, no prose

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Source .env if it exists (Mac local dev). On GitHub Actions, secrets come via env vars.
if [ -f .env ]; then
    source .env
fi
# Fail loudly if required secrets are missing.
: "${XAI_API_KEY:?XAI_API_KEY is required (set via .env on Mac, GitHub Secrets in CI)}"
: "${NETLIFY_AUTH_TOKEN:?NETLIFY_AUTH_TOKEN is required (set via .env on Mac, GitHub Secrets in CI)}"

echo "=== eXpressO News v4 Update — $(date) ==="

# Dynamic dates
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d)

# System prompt — strict JSON-only, operator-first
cat > /tmp/grok_system.txt << 'SYSEOF'
You are eXpressO News curator. Output ONLY valid JSON. No markdown, no fences, no prose.

CORE RULES:
1. MUST call x_search tool BEFORE selecting ANY story. Never use memory.
2. ONLY use posts from x_search results. Never fabricate URLs or IDs or handles.
3. URL: EXACTLY https://x.com/{handle}/status/{numeric_id}. If no valid ID, set "url": null.
4. Never return profile URLs. Return null instead.
5. Use EXPLICIT operators in queries: min_faves:N, since:YYYY-MM-DD, from:handle, -exclude.
6. Use mode: "Top" for engagement ranking.
7. SELF-VALIDATE: Before including a post, confirm url contains /status/ and a numeric ID.
8. FALLBACK: If <3 valid results, re-run search with lower min_faves (halve it). Try up to 2 fallbacks.

APPROVED HANDLES:
Each tab's prompt below contains an "APPROVED HANDLES" list. You may ONLY pick posts authored by handles from that list. If you can't find a strong post from the approved list, return fewer items rather than reaching outside the list. NEVER fabricate a handle that isn't on the approved list.

ENGAGEMENT REQUIREMENTS:
For every post returned, include an "engagement" field with the actual numeric metrics from x_search results. Format: "123K likes, 45K retweets, 12K replies" (use real numbers from the search). Pick the post with the HIGHEST combined engagement (likes + retweets + replies) from the approved handles. Do NOT settle for low-engagement posts when a high-engagement one exists.

HANDLE DIVERSITY:
Across all 3 stories on a single tab, use 3 DIFFERENT handles. Never return the same handle twice on the same tab. Exception: Elon tab requires 3 different posts from @elonmusk (deduplicated by URL, not handle).

HONESTY SCORING (0-10) — grade the WORST claim in the post, not the average. Lies poison the post.

CORE PRINCIPLE: If a post contains ANY demonstrably false factual claim, the score reflects that lie — regardless of whatever true opinions or fair takes are also present in the same post. You cannot launder a lie by surrounding it with legitimate opinions.

Examples of how this plays out:
  - Post says "Charles is demanding US support Ukraine. We are in a war with Iran. We've wasted $300B on Ukraine. Not one penny more!" → The "Not one penny more" is a fair opinion, BUT (a) "demanding" overstates royal posture, (b) "war with Iran" is factually false (no AUMF, no declaration), (c) "$300B" is inflated (~$175B actual). Three false framings present → score 2-3, NOT 6. The legitimate opinion does not redeem the lies.
  - Post says "Trump's tariffs will hurt the middle class — here's why X, Y, Z" → It's an opinion/prediction, not a factual claim. If the supporting points are reasonable, score 7. If the "X, Y, Z" are demonstrably false data points, score drops to 3.
  - Post says "Earnings for Q3 were $X" with no editorializing → If $X is verifiable, score 10. If $X is wrong, score 0-1.

Anchor scores:
  10 = pure verifiable fact from a credible source restating reality (e.g. AP wire, NASA, court ruling, direct quote with context). NO false claims, NO editorializing.
  8-9 = post REPORTS a real, verifiable factual event (verified video clip, direct quote on record, recent news ruling) PLUS opinion/commentary. The factual core is accurate and the commentary doesn't introduce false claims. Even sharp partisan satire on accurate news lands here. EXAMPLE: "Sage Steele quote-tweets a real Sunny Hostin clip and adds satirical commentary — Hostin actually said it, SCOTUS actually ruled, Steele's take is opinion." → 8.
  5-7 = pure opinion/prediction/take with NO factual reporting and NO lies. Partisan but defensible. EXAMPLE: "I think AI replaces 50% of jobs by 2030" — pure prediction → 7.
  3-4 = contains 1 demonstrably false claim or significantly inflated number (the lie defines the score regardless of whatever else is in the post)
  1-2 = contains MULTIPLE demonstrably false claims, OR severe projection by someone with documented track record on this topic
  0 = pathological liar recounting falsified history, or a single egregious lie that's the entire point of the post

KEY INSIGHT — don't undervalue accurate-news + commentary: A post that quotes a real, verifiable news event and adds opinion commentary should score 8-9, NOT 7. The 5-7 band is reserved for posts that are PURELY opinion (no factual reporting at all). When the factual core is real and verifiable, the commentary doesn't drag it below 8 unless the commentary itself introduces lies.

KEY RULE — track record matters: If a politician posts about a problem they themselves caused, ignored, or failed to address, that's projection. Score very low (1-3) regardless of how the post is worded. Walz posting "we'll catch fraud in MN" while presiding over the $250M Feeding Our Future fraud is projection → 1.

Source reputation matters: If someone with a documented history of fabricating about a topic posts something on that topic, score with skepticism even if the literal claim is technically defensible.

Apply the SAME standard to every party. A Democrat with a track record of distortion gets the same low score as a Republican with the same track record. No partisan bias.

In the "notes" field for every post, write ONE PLAIN-ENGLISH SENTENCE that names what the score is grading. Be specific about the lies if any are present. Examples:
  - "AP wire reporting a court verdict — verifiable fact." → 10
  - "Walz claiming fraud will be caught in MN, despite presiding over the $250M Feeding Our Future fraud his administration ignored — projection." → 1
  - "Fox News headline accurately summarizing the indictment, with light conservative framing." → 8
  - "Fair 'no more money for Ukraine' opinion, but post also claims false 'war with Iran' framing and inflates Ukraine aid by ~70% — multiple lies poison the take." → 2
  - "Schumer attacking GOP for partisan obstruction during a shutdown his party also helped engineer — standard partisan spin, no demonstrable lies." → 4

FOREIGN-LANGUAGE TRANSLATION:
If the post is in a non-English language, OR if it quote-tweets/replies to a non-English parent tweet, include a "translation" field in your JSON with a faithful English rendering of the foreign-language content. Format:
  - For a non-English post itself: "translation": "<English translation of the post>"
  - For a quote-tweet of a non-English parent: "translation": "Quoted (translated from <Lang>): <English translation of the parent>. Elon's caption: <his English caption if any>"
Always include the source language. Never leave foreign-language text untranslated for readers — they can't read it.
SYSEOF

# Payload builder — model can be overridden per call via 3rd arg.
# Default = grok-4-fast (cheap, fast). World/USA use grok-4 (full reasoning) because
# their prompts are heavier (3-perspective + topic-lock) and grok-4-fast was hallucinating
# fake snowflake URLs under load.
cat > /tmp/grok_build_payload.py << 'PYEOF'
import json, sys
prompt_file = sys.argv[1]
output_payload = sys.argv[2] if len(sys.argv) > 2 else '/tmp/grok_payload.json'
model = sys.argv[3] if len(sys.argv) > 3 else 'grok-4-fast'
with open('/tmp/grok_system.txt') as f:
    system = f.read().strip()
with open(prompt_file) as f:
    prompt = f.read().strip()
payload = {
    "model": model,
    "input": [
        {"role": "system", "content": system},
        {"role": "user", "content": prompt}
    ],
    "tools": [{"type": "x_search"}],
    "max_output_tokens": 8000,
    "temperature": 0.0
}
with open(output_payload, 'w') as f:
    json.dump(payload, f)
PYEOF

# Helper: make a single Grok API call with retry on transient errors.
# xAI API occasionally returns "Service temporarily unavailable" or similar — retry up to 3 times
# with exponential backoff (5s, 15s, 30s) so a transient blip doesn't drop the whole tab.
grok_call() {
    local prompt_file="$1"
    local output_file="$2"
    local model="${3:-grok-4-fast}"  # default fast; override for heavy tabs
    local payload_file="/tmp/grok_payload_$(basename "$prompt_file" .txt).json"

    python3 /tmp/grok_build_payload.py "$prompt_file" "$payload_file" "$model"

    local attempt
    for attempt in 1 2 3; do
        curl -s --max-time 300 https://api.x.ai/v1/responses \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $XAI_API_KEY" \
            -d @"$payload_file" > "$output_file"

        # Check if response is a transient error worth retrying
        local is_transient
        is_transient=$(python3 -c "
import json, sys
try:
    d = json.load(open('$output_file'))
    err = (d.get('error') or '') if isinstance(d.get('error'), str) else str(d.get('error', ''))
    transient = any(kw in err.lower() for kw in ['service temporarily', 'try again', 'timeout', 'rate limit', 'overloaded', '503', '504', '502'])
    # ALSO retry if we got a response but it's empty (no message output)
    if not err and not d.get('output') and not d.get('choices'): transient = True
    print('1' if transient else '0')
except Exception: print('0')
" 2>/dev/null)

        if [ "$is_transient" != "1" ]; then
            return 0
        fi
        if [ "$attempt" -lt 3 ]; then
            local delay=$(( attempt * 10 ))
            echo "  [retry] $(basename $prompt_file) hit transient error, retrying in ${delay}s (attempt $attempt/3)" >&2
            sleep $delay
        fi
    done
    return 0  # leave whatever last response we got, parse_grok will handle gracefully
}

# ============================================================
# WRITE ALL 12 PROMPTS
# ============================================================

# --- WORLD (3 stories × 3 perspectives) ---
cat > /tmp/grok_p_world.txt <<'PROMPT'
Find 3 INTERNATIONAL news stories from the last 24 hours.

APPROVED HANDLES (use ONLY these — pick ONE handle per perspective slot per story):
  Conservative: @JackPosobiec, @Cernovich, @RealCandaceO, @benshapiro, @TuckerCarlson, @DonaldJTrumpJr, @charliekirk11, @RealDailyWire, @JDVance1, @SenTedCruz, @TomFitton, @JesseBWatters, @IngrahamAngle, @WarMonitors, @sentdefender, @CriticalThreats, @WhiteHouse
  Democrat: @AOC, @Ilhan, @RBReich, @BernieSanders, @RashidaTlaib, @ChrisMurphyCT, @SenWarren, @JoyceWhiteVance, @ProPublica, @DropSiteNews
  Independent/Analyst: @HamidRezaAz, @TheStudyofWar, @vtchakarova, @RayDalio, @dalperovitch, @InsightGL, @KimZetter, @Snowden, @ggreenwald

Use x_search to discover what's hot internationally:
"(Iran OR Israel OR China OR Russia OR Ukraine OR Europe OR Middle East OR war OR geopolitics) lang:en min_faves:5000 since:$YESTERDAY", mode:Top, limit:30

From the results, pick 3 DISTINCT topics (each topic = a different country/conflict/event).
For EACH topic, run a focused x_search restricted to approved handles:
"(topic_keywords) (from:JackPosobiec OR from:RBReich OR from:TheStudyofWar OR ...) since:$YESTERDAY min_faves:500", mode:Top, limit:15

For each topic, pick UP TO 3 different POVs (Conservative / Democrat / Independent), one HIGHEST-ENGAGEMENT post per perspective. Each post must be from a DIFFERENT approved handle. Across all 3 stories' perspectives, prefer 9 different handles total.

If a topic has only 1 or 2 distinguishable POVs from the approved list, set missing sides to null. Don't pad with off-list handles.

CRITICAL — NO HALLUCINATION:
- ONLY use URLs and text returned by x_search results.
- URL must be exactly as returned: https://x.com/HANDLE/status/NUMERIC_ID
- Verbatim quote = exact tweet text from search results.
- Reject pure announcements (BREAKING:, all-caps tickers, single-emoji posts).
- DO NOT invent URLs, IDs, or handles.
- Engagement field MUST contain real numbers from x_search (e.g. "47K likes, 12K retweets, 3.2K replies").

Return JSON only:
{"world":[
  {"headline":"short topic","conservative":{"handle":"@x","quote":"verbatim","url":"...","engagement":"47K likes, 12K retweets, 3.2K replies","honesty":"X/10","notes":"why this score"} or null,"democrat":{...} or null,"independent":{...} or null,"footnotes":["why each","..."],"notes":"summary"},
  ...3 stories
]}
PROMPT

# --- USA (national US news — 3-perspective like World) ---
cat > /tmp/grok_p_usa.txt <<'PROMPT'
Find 3 US NATIONAL news stories from the last 24 hours (domestic politics, SCOTUS, Congress, federal policy — NOT foreign affairs).

APPROVED HANDLES (use ONLY these — pick ONE handle per perspective slot per story):
  Conservative: @JackPosobiec, @Cernovich, @RealCandaceO, @benshapiro, @TuckerCarlson, @DonaldJTrumpJr, @charliekirk11, @RealDailyWire, @JDVance1, @SenTedCruz, @TomFitton, @JesseBWatters, @IngrahamAngle, @WhiteHouse
  Democrat: @AOC, @Ilhan, @RBReich, @BernieSanders, @RashidaTlaib, @ChrisMurphyCT, @SenWarren, @JoyceWhiteVance, @ProPublica, @DropSiteNews
  Independent/Analyst: @TheStudyofWar, @ProPublica, @SCOTUSblog, @KimZetter, @Snowden, @ggreenwald, @InsightGL

Use x_search to discover hot domestic topics:
"(politics OR Congress OR SCOTUS OR Trump OR Senate OR DOJ OR FBI OR ICE OR \"White House\") lang:en min_faves:5000 since:$YESTERDAY", mode:Top, limit:30

For EACH of 3 distinct topics, focused x_search on approved handles:
"(topic_keywords) (from:JackPosobiec OR from:AOC OR from:SCOTUSblog OR ...) since:$YESTERDAY min_faves:500", mode:Top, limit:15

From each topic's results, pick up to 3 different POVs by IDEOLOGICAL LEAN of the actual handle (Conservative / Democrat / Independent). Pick the HIGHEST-ENGAGEMENT post per perspective from the approved list. Use DIFFERENT handles per side AND across stories — aim for 9 different handles across 3 stories. Missing side → null.

CRITICAL — NO HALLUCINATION:
- URLs and quotes ONLY from x_search results.
- Format: https://x.com/HANDLE/status/NUMERIC_ID exactly as returned.
- Verbatim tweet text only.
- Reject pure announcements (BREAKING:, all-caps).
- NEVER invent URLs, IDs, or handles.
- Engagement field MUST contain real numbers (e.g. "47K likes, 12K retweets, 3.2K replies").

Return JSON only:
{"usa":[
  {"headline":"short","conservative":{"handle":"@x","quote":"verbatim","url":"...","engagement":"47K likes, 12K retweets, 3.2K replies","honesty":"X/10","notes":"why this score"} or null,"democrat":{...} or null,"independent":{...} or null,"footnotes":[...],"notes":"..."},
  ...3 stories
]}
PROMPT

# --- ELON ---
cat > /tmp/grok_p_elon.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: Elon's 3 MOST THOUGHT-PROVOKING posts AND replies — not just original tweets. His REPLIES to other people's posts are often the most interesting because they give context to a story he's amplifying. Mix originals + replies for variety.

APPROVED HANDLE: @elonmusk only. Pick 3 DIFFERENT POSTS (different URLs) — never duplicate the same /status/ID.

Search mode: "Top": "from:elonmusk since:$YESTERDAY min_faves:5000", limit: 25 (this returns BOTH originals and replies).
ALSO search mode: "Latest": "from:elonmusk since:$YESTERDAY min_faves:2000", limit: 25.
FALLBACK: If <3 substantive, retry with min_faves:1000.

ACCEPTED POST TYPES (strict — applies to Elon tab, no exceptions):
- Original posts → always self-contained, ACCEPT.
- Quote-tweets → parent is EMBEDDED and visible inline, ACCEPT.
- Pure text replies WITHOUT visible parent (just "Replying to @someone" header + Elon's reply text) → STRICT REJECT. The reader sees only Elon's response, not what he's responding to. They cannot understand the post without doing research. NEVER pick these.
- One-word replies, emoji-only, or context-less ("yes", "exactly", "🔥") → SKIP.

If a quote-tweet's parent is in a non-English language (French/Portuguese/Spanish/etc), you MUST set "translation" field with full English translation of the parent tweet. If you can't translate, SKIP and pick another post.

QUALITY BAR: substantive content — prediction, announcement, sharp critique, joke with a point, policy take, contrarian observation. Pick the 3 HIGHEST-ENGAGEMENT substantive posts of the day from @elonmusk.

DIVERSITY: 3 DIFFERENT topics, 3 DIFFERENT URLs. Verify URLs are unique before returning. Mix originals and replies — at least one of each if available.

HONESTY SCORING (apply rigorously, NOT auto-10):
- 10 = verified fact (e.g. "Tesla earnings beat by X" — checkable)
- 9 = factual core with minor editorializing
- 8 = analysis or commentary with no false claims
- 7 = opinion, prediction, or hot take presented as such
- 6 = contains a specific misleading claim ("X is a fraud" without proof, "Y laundered money" without conviction)
- 5 = demonstrably false statement
Most Elon posts are 7-9 (opinions, predictions, jokes). Reserve 10 for VERIFIABLE facts.
Body: 1 sentence describing the take and (if reply) what he's responding to, under 120 chars.
Engagement field MUST contain real numbers (e.g. "147K likes, 22K retweets, 8K replies").
Return JSON: {"elon":[{"headline":"...","handle":"@elonmusk","body":"...","engagement":"147K likes, 22K retweets, 8K replies","url":"...","honesty":"X/10","notes":"why this score"},...]}
PROMPT

# --- ALLIN ---
cat > /tmp/grok_p_allin.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: Find the 3 MOST THOUGHT-PROVOKING posts from billionaire operators — ORIGINAL INSIGHT, contrarian takes, deep framing. NOT generic "interesting" or "agree" reactions.

APPROVED HANDLES (use ONLY these — pick 3 DIFFERENT handles):
@chamath, @DavidSacks, @pmarca, @PalmerLuckey, @friedberg

Search EACH person separately, prefer mode: "Latest" for freshness + insight keywords:
"from:chamath (insight OR analysis OR \"hot take\" OR contrarian OR perspective OR \"why this matters\" OR underrated) since:$YESTERDAY min_faves:100", mode: "Latest"
"from:DavidSacks (insight OR analysis OR \"hot take\" OR contrarian OR perspective OR \"why this matters\" OR underrated) since:$YESTERDAY min_faves:100", mode: "Latest"
"from:pmarca (insight OR analysis OR contrarian OR perspective OR underrated) since:$YESTERDAY min_faves:100", mode: "Latest"
"from:PalmerLuckey (insight OR analysis OR contrarian OR perspective) since:$YESTERDAY min_faves:100", mode: "Latest"
"from:friedberg (insight OR analysis OR contrarian OR perspective) since:$YESTERDAY min_faves:100", mode: "Latest"
FALLBACK 1: If any person has no insight-keyword results, broaden to: "from:handle since:$YESTERDAY min_faves:100", mode: "Top".
FALLBACK 2: If still no results, retry with min_faves:20.

QUALITY BAR — pick ONLY posts with novel angle, sharp contrarian view, or deep insight. REJECT generic "interesting" / "agree" / "exactly" posts.

CONTEXT RULE: ORIGINAL posts or quote-tweets only. NO context-less replies (starting with "@someone" or "that isn't true").

Pick 3 posts from 3 DIFFERENT approved handles — strongest ORIGINAL INSIGHT (highest combined likes+retweets+replies among substantive posts) from each.
Body: 1 sentence, under 120 chars.
Engagement field MUST contain real numbers (e.g. "5.2K likes, 800 retweets, 200 replies").
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Notes: say "Fact" or "Opinion" and call out any specific lies.
Return JSON: {"allin":[{"headline":"...","handle":"@...","body":"...","engagement":"5.2K likes, 800 retweets, 200 replies","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- TOP VIRAL ---
cat > /tmp/grok_p_top.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
Find the 3 most viral posts on ALL of X right now.
Primary search: "lang:en since:$TODAY", mode: "Top", limit: 10. Let X's ranking algorithm find the most viral content.
Fallback: "lang:en since:$YESTERDAY min_faves:5000", mode: "Top", limit: 10.
Pick the 3 highest-engagement posts. 3 DIFFERENT handles.
Body: 1 sentence, under 120 chars.
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Notes: say "Fact" or "Opinion" and call out any specific lies.
Return JSON: {"top":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- MSM ---
cat > /tmp/grok_p_msm.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: Stories blowing up on X that MSM is IGNORING or UNDERREPORTING — the juicier, more suppressed the better. Prefer NOVEL ANGLES, exposé-style reporting, undercover footage, data that contradicts official narratives.

APPROVED HANDLES (use ONLY these):
@BillMelugin_, @MattWalshBlog, @TimcastNews, @TheRabbitHole84, @SCOTUSblog, @InsightGL, @JamesOKeefeIII, @LibsOfTikTok, @RealSaavedra, @collinrugg, @EndWokeness, @WallStreetApes

CRITICAL DIVERSITY RULE: 3 DIFFERENT handles. NO repeats. If you've used @MattWalshBlog for one story, use a different handle for the others. The user has flagged that we keep returning the same handle (Matt Walsh) for every story — STOP DOING THAT.

Search EACH handle separately, mode: "Latest" for freshness:
"from:BillMelugin_ since:$YESTERDAY min_faves:500", mode: "Latest"
"from:MattWalshBlog since:$YESTERDAY min_faves:500", mode: "Latest"
"from:TimcastNews since:$YESTERDAY min_faves:500", mode: "Latest"
"from:TheRabbitHole84 since:$YESTERDAY min_faves:500", mode: "Latest"
"from:JamesOKeefeIII since:$YESTERDAY min_faves:200", mode: "Latest"
"from:LibsOfTikTok since:$YESTERDAY min_faves:500", mode: "Latest"
"from:collinrugg OR from:EndWokeness OR from:WallStreetApes OR from:RealSaavedra OR from:SCOTUSblog OR from:InsightGL since:$YESTERDAY min_faves:500", mode: "Latest"
FALLBACK: If a handle has no Latest results, try mode: "Top" with same min_faves. Then retry with min_faves:100.

QUALITY BAR: pick posts with a SPECIFIC STORY that MSM isn't covering — not hot takes ABOUT the media. Actual events, data, undercover footage, specific officials doing specific things.

PICK 3 posts from 3 DIFFERENT approved handles — HIGHEST ENGAGEMENT post from each. Verify the 3 handles are not identical before returning.

Body: 1 sentence, under 120 chars.
Engagement field MUST contain real numbers (e.g. "47K likes, 12K retweets, 3.2K replies").
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Notes: say "Fact" or "Opinion" and call out any specific lies.
Return JSON: {"msm":[{"headline":"...","handle":"@...","body":"...","engagement":"47K likes, 12K retweets, 3.2K replies","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- BUSINESS ---
cat > /tmp/grok_p_business.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: 3 MOST THOUGHT-PROVOKING business/markets posts. Original analysis, contrarian calls, macro insight, hidden story behind the numbers — NOT generic "stocks up today" headlines.

APPROVED HANDLES (use ONLY these — pick 3 DIFFERENT handles):
@DowdEdward, @RayDalio, @Stocktwits, @StockMKTNewz, @WatcherGuru, @unusual_whales, @TruthGundlach, @LizAnnSonders, @elerianm

Must be stocks, markets, finance, crypto, deals, or macro. NOT geopolitics/military.
Search mode: "Latest" with insight keywords:
"(from:unusual_whales OR from:WatcherGuru OR from:StockMKTNewz OR from:RayDalio OR from:LizAnnSonders OR from:elerianm OR from:Stocktwits OR from:DowdEdward OR from:TruthGundlach) (insight OR analysis OR \"hot take\" OR contrarian OR \"why this matters\" OR underrated OR \"what nobody is saying\") since:$YESTERDAY min_faves:100", mode: "Latest", limit: 20.
ALSO search mode: "Top": "(from:unusual_whales OR from:WatcherGuru OR from:StockMKTNewz OR from:RayDalio OR from:LizAnnSonders OR from:elerianm OR from:DowdEdward OR from:TruthGundlach) since:$YESTERDAY min_faves:500", limit: 15.
FALLBACK: If <3, retry with min_faves:50.

QUALITY BAR: pick posts with data + opinion, contrarian call, or macro framing. REJECT bare earnings numbers, price-only posts, or "line go up" cheerleading.

Pick 3 posts from 3 DIFFERENT approved handles — STRONGEST INSIGHT (highest combined likes+retweets+replies) per handle.
Body: 1 sentence, under 120 chars.
Engagement field MUST contain real numbers (e.g. "12K likes, 3K retweets, 800 replies").
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Notes: say "Fact" or "Opinion" and call out any specific lies.
Return JSON: {"business":[{"headline":"...","handle":"@...","body":"...","engagement":"12K likes, 3K retweets, 800 replies","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- SPORTS ---
cat > /tmp/grok_p_sports.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.

APPROVED HANDLES (use ONLY these):
@ShamsCharania, @wojespn, @ClutchPoints, @BleacherReport, @CourtsideBuzzX, @TheAthletic, @ESPNStatsInfo, @AdamSchefter, @stephenasmith, @TheHerd, @colincowherd

EXACT structure — return EXACTLY 4 posts in this order:
Post 1: Breaking sports news #1 (biggest story today). Search: "from:ShamsCharania OR from:wojespn OR from:BleacherReport OR from:ESPNStatsInfo OR from:TheAthletic OR from:AdamSchefter OR from:ClutchPoints since:$YESTERDAY min_faves:500", mode: "Top", limit: 15
Post 2: Breaking sports news #2 (second biggest, DIFFERENT sport from Post 1). Same search, different story.
Post 3: REQUIRED — Stephen A Smith's most viral take. Search ONLY: "from:stephenasmith since:$YESTERDAY", mode: "Top", limit: 10. Pick HIS HIGHEST-ENGAGEMENT post. If none today, try "since:3 days ago". MUST come from @stephenasmith. NEVER skip this slot — Stephen A is a fixture on this tab.
Post 4: REQUIRED — Colin Cowherd's most viral take. Search ONLY: "from:colincowherd OR from:TheHerd since:$YESTERDAY", mode: "Top", limit: 10. Pick the HIGHEST-ENGAGEMENT post. If none today, try "since:3 days ago". MUST come from @colincowherd or @TheHerd. NEVER skip this slot.

CRITICAL RULES:
- Always 4 posts. NOT 5. NOT 3. EXACTLY 4.
- Post 3 must always be Stephen A. Post 4 must always be Cowherd. Both are required every run.
- Post 1 and Post 2 must be DIFFERENT sports if possible (one NFL, one NBA — or one football, one basketball, one MLB, etc).
- All 4 must be from DIFFERENT handles.

FALLBACK: If weekend and no breaking news, use Friday's posts. ALWAYS produce 4 with both SAS and Cowherd present.

Body: 1 sentence, under 120 chars.
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take.
Return JSON: {"sports":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- PODS ---
cat > /tmp/grok_p_pods.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
CRITICAL MISSION: Find the 3 MOST VIRAL podcast clip moments on X right now. The user specifically complains that we've been returning mediocre clips — they want MASSIVELY VIRAL moments (100K+ views, 5K+ likes minimum for major podcasts, or peak engagement for the day).

APPROVED HANDLES (use ONLY these — 3 DIFFERENT shows):
@joerogan, @joeroganhq, @JREClips, @TuckerCarlson, @theallinpod, @lexfridman, @fridmanclips, @CallHerDaddy, @adamcarolla, @PBDPodcast, @patrickbetdavid, @ShawnRyanShow, @MegynKellyShow, @LouderWithCrowder, @RussellBrand

A clip is a 30-sec to 3-min specific moment that went viral. NOT a full-episode announcement.

PRIMARY SEARCH (broad viral clips from approved shows):
"(from:joerogan OR from:JREClips OR from:TuckerCarlson OR from:lexfridman OR from:fridmanclips OR from:theallinpod OR from:CallHerDaddy OR from:adamcarolla OR from:PBDPodcast OR from:patrickbetdavid OR from:ShawnRyanShow OR from:MegynKellyShow OR from:LouderWithCrowder OR from:RussellBrand) lang:en since:$YESTERDAY min_faves:1000", mode: "Top", limit: 25

SUPPLEMENT WITH per-show searches, prefer high-engagement:
"from:JREClips OR from:joerogan since:$YESTERDAY min_faves:2000"
"from:fridmanclips OR from:lexfridman since:$YESTERDAY min_faves:1000"
"from:theallinpod since:$YESTERDAY min_faves:1000"
"from:TuckerCarlson OR from:RussellBrand OR from:MegynKellyShow since:$YESTERDAY min_faves:2000"
"from:PBDPodcast OR from:patrickbetdavid since:$YESTERDAY min_faves:1000"
"from:ShawnRyanShow since:$YESTERDAY min_faves:1000"
"from:LouderWithCrowder OR from:adamcarolla OR from:CallHerDaddy since:$YESTERDAY min_faves:1000"

FILTERING: REJECT "new episode", "full interview", "full episode", "out now", "tune in", "dropping soon". KEEP specific-moment headlines — someone saying something shocking, a host reaction, a heated exchange, a reveal.

DIVERSITY REQUIREMENT: Each of the 3 selections MUST be from a DIFFERENT podcast/show. No two clips from the same show/handle.

FALLBACK 1: If <3 after above, lower thresholds by half.
FALLBACK 2: If still <3, broaden to last 48 hours (not 24).

Pick 3 from DIFFERENT approved shows — the 3 HIGHEST-ENGAGEMENT (combined likes+retweets+replies) CLIP moments.
Body: 1 sentence describing the specific moment (what was said/happened), under 120 chars. Do NOT describe the episode generally.
Engagement field MUST contain real numbers (e.g. "47K likes, 8K retweets, 3K replies").
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Notes: say "Fact" or "Opinion" and call out any specific lies.
Return JSON: {"pods":[{"headline":"...","handle":"@...","body":"...","engagement":"47K likes, 8K retweets, 3K replies","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- PG6 (Celebrity) ---
cat > /tmp/grok_p_pg6.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: JUICIEST celebrity gossip — SURPRISING reveals, dramatic takes, "wait, what?" moments. NOT red-carpet appearances or generic promo.

APPROVED HANDLES (use ONLY these — pick 3 DIFFERENT handles):
@PopCrave, @enews, @JustJared, @etnow, @TMZ, @DeuxMoi, @PageSix, @Variety

Search mode: "Latest" for fresh + juicy:
"(from:PopCrave OR from:TMZ OR from:DeuxMoi OR from:enews OR from:JustJared OR from:PageSix OR from:Variety OR from:etnow) since:$YESTERDAY min_faves:500", mode: "Latest", limit: 20.
ALSO search mode: "Top" for highest-engagement: "(from:PopCrave OR from:TMZ OR from:DeuxMoi OR from:etnow) since:$YESTERDAY min_faves:1000", limit: 15.
FALLBACK: If <3 from approved handles, retry with min_faves:200.

QUALITY BAR: unexpected reveals, dramatic feuds, surprise engagements/breakups, cryptic posts that went viral, specific quotes from celebs. REJECT magazine-cover announcements and PR-rep releases.

CRIME-BLOTTER REJECTION (HARD RULE): SKIP all sensationalized violent crime posts. This includes:
- Graphic murder details, dismemberment, body disposal
- Crime against minors with explicit details
- "TERRIFYING:", "🚨 DISTURBING:", "ASSUSTADOR:" framing of violent crime
- Mugshot + victim photo combo posts
- Any post whose primary content is a violent crime accusation against a person
The user is explicit: NO crime-blotter content on Pg.6. Pick redemption stories, dramatic feuds, surprise reveals, cultural moments, fashion drama instead.

ENGLISH-ONLY: All posts must be in English OR have a complete English translation in the "translation" field. NO untranslated foreign-language content. If a post body is in Portuguese/Spanish/French/etc and you can't translate, SKIP it.

Pick the 3 HIGHEST-ENGAGEMENT (combined likes+retweets+replies) UNEXPECTED/dramatic celebrity posts. 3 DIFFERENT approved handles.
Body: 1 sentence, under 120 chars.
Engagement field MUST contain real numbers (e.g. "47K likes, 8K retweets, 3K replies").
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Notes: say "Fact" or "Opinion" and call out any specific lies.
Return JSON: {"pg6":[{"headline":"...","handle":"@...","body":"...","engagement":"47K likes, 8K retweets, 3K replies","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- RECIPE ---
cat > /tmp/grok_p_recipe.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
Actual FOOD RECIPES you can cook. NOT product lists, NOT gadget ads.

APPROVED HANDLES (use ONLY these — pick 3 DIFFERENT handles):
@tasteofhome, @FoodNetwork, @thekitchn, @HBHarvest, @halfbakedharvest, @foodandwine, @tasty, @KitchenSanc2ary, @budgetbytes, @BonAppetit, @RecipeTinEats

Search 1: "from:FoodNetwork OR from:tasty OR from:halfbakedharvest OR from:HBHarvest OR from:budgetbytes OR from:foodandwine since:$YESTERDAY", mode: "Top", limit: 15.
Search 2: "from:tasteofhome OR from:KitchenSanc2ary OR from:thekitchn OR from:BonAppetit OR from:RecipeTinEats since:$YESTERDAY", mode: "Top", limit: 15.
FALLBACK: If <3 from approved handles, retry with last 3 days.
Body must name the dish. Skip non-recipe posts.
Body: 1 sentence, under 120 chars.
Engagement field MUST contain real numbers (e.g. "5K likes, 1K retweets, 200 replies").
Return JSON: {"recipe":[{"headline":"...","handle":"@...","body":"...","engagement":"5K likes, 1K retweets, 200 replies","url":"...","honesty":"10/10","notes":"..."},...]}
PROMPT

# --- SCIENCE ---
cat > /tmp/grok_p_science.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: 3 ACTUAL science DISCOVERIES or research findings. NOT award votes, NOT rankings, NOT industry promo.

PRIMARY SEARCH (broader roster):
"(from:NASAWebb OR from:EricTopol OR from:ScienceAlert OR from:ProfFeynman OR from:NatureNews OR from:SciAm OR from:DrEricDing OR from:NASA OR from:NASAJPL OR from:NewScientist OR from:LiveScience OR from:phys_org OR from:ScienceMagazine OR from:NIH OR from:NASAEarth OR from:CDCgov OR from:WHO OR from:NatGeo OR from:NeilTyson OR from:BillNye OR from:michio_kaku OR from:elonmusk OR from:SpaceX OR from:NASAArtemis) since:$YESTERDAY min_faves:50", mode: "Top", limit: 25.

FALLBACK 1: Drop min_faves to 20 if <3.
FALLBACK 2: Open it up — search "(discovery OR research OR breakthrough OR \"new study\" OR scientists OR \"first ever\") (space OR cancer OR climate OR AI OR genetics OR physics OR astronomy OR neuroscience OR fusion OR longevity) since:$YESTERDAY min_faves:1000 lang:en", mode: "Top", limit: 25.
FALLBACK 3: Last resort: "(scientists OR researchers OR study OR discovery) since:$YESTERDAY min_faves:5000 lang:en", limit: 25 — pick anything genuinely science.

PICK 3 from DIFFERENT handles describing 3 DIFFERENT discoveries. Body must name what was actually discovered/found.
Body: 1 sentence under 120 chars.
Return JSON: {"science":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- LOCAL ---
cat > /tmp/grok_p_local.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
ONLY stories physically in Orange County, Newport Beach, Huntington Beach, Irvine, LA, or SoCal.

APPROVED HANDLES (use ONLY these — pick 3 DIFFERENT handles):
@OC_Scanner, @ABC7, @LAist, @KTLA, @OCRegister, @DailyPilot, @NBPDsocial, @CityofNewportBeach

Search: "(\"Orange County\" OR \"Newport Beach\" OR \"Huntington Beach\" OR \"Los Angeles\" OR SoCal) (from:OC_Scanner OR from:ABC7 OR from:KTLA OR from:LAist OR from:OCRegister OR from:DailyPilot OR from:NBPDsocial OR from:CityofNewportBeach) since:$YESTERDAY -Michigan -NYC -\"New York\" -Chicago -Florida -Texas", mode: "Top", limit: 20.
FALLBACK: If <3, broaden: "from:OC_Scanner OR from:KTLA OR from:ABC7 OR from:OCRegister OR from:LAist OR from:DailyPilot since:$YESTERDAY -Michigan -NYC -Florida -Texas -Chicago", mode: "Top", limit: 20.
Every story MUST be about a SoCal location. Verify before including.
Body: 1 sentence, under 120 chars.
Engagement field MUST contain real numbers (e.g. "5K likes, 1K retweets, 200 replies").
Return JSON: {"local":[{"headline":"...","handle":"@...","body":"...","engagement":"5K likes, 1K retweets, 200 replies","url":"...","honesty":"10/10","notes":"..."},...]}
PROMPT

# --- MEMES ---
cat > /tmp/grok_p_memes.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
The 3 MOST VIRAL memes, cartoons, or satirical posts on X right now. Must be humorous or satirical.

IMPORTANT: POLITICAL BALANCE. Do not target any politically-slanted satire account specifically. Pick from a diverse pool. If 2 of the 3 you're about to select lean the same political direction, swap one for a neutral or opposing-lean option to maintain balance.

Search: "(meme OR satire OR cartoon OR parody) lang:en since:$YESTERDAY min_faves:10000", mode: "Top", limit: 20.
FALLBACK 1: If <3, broaden to "lang:en since:$YESTERDAY min_faves:5000 (meme OR satire OR funny)", mode: "Top", limit: 20.
FALLBACK 2: If still <3, drop min_faves to 2000.

Pick the 3 highest-engagement meme/satirical posts from DIFFERENT handles. Prefer variety: one apolitical meme (observational humor, animals, relationships, tech), one political-left-leaning if funny, one political-right-leaning if funny — OR all three apolitical. NEVER 3 that lean the same political direction.

Body: 1 sentence describing what the meme shows or why it's funny, under 120 chars.
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Memes are usually 7-8. Apply scoring equally to all sides — no favoritism.
Return JSON: {"memes":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- COMEDY ---
cat > /tmp/grok_p_comedy.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
The 3 MOST VIRAL comedy clips on X right now — stand-up moments, bits, old legends resurfacing, or new comedians going viral.
Search: "(stand-up OR comedy OR "clip" OR comedian) (Chappelle OR "Eddie Murphy" OR Rogan OR Gaffigan OR Burr OR Schulz OR Kreischer OR Hinchcliffe OR Mulaney OR Seinfeld OR Chris Rock) lang:en since:$YESTERDAY min_faves:2000", mode: "Top", limit: 15.
FALLBACK: If <3, broaden: "("standup" OR "stand-up" OR "comedy clip") lang:en since:$YESTERDAY min_faves:5000", mode: "Top", limit: 15.
Pick the 3 highest-engagement comedy clip posts from DIFFERENT handles.
Body: 1 sentence describing the comedian/moment, under 120 chars.
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Most comedy clips are 8-9 (performative).
Return JSON: {"comedy":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- TIKTOK ---
cat > /tmp/grok_p_tiktok.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
The 3 MOST VIRAL TikTok clips being shared on X right now. ANY subject — news, gossip, comedy, dance, cooking, sports, whatever. Massively viral only.
Search: "tiktok.com lang:en since:$YESTERDAY min_faves:10000", mode: "Top", limit: 20.
FALLBACK: If <3, retry: "tiktok.com lang:en since:$YESTERDAY min_faves:2000", mode: "Top", limit: 20.
Pick the 3 highest-engagement posts from DIFFERENT handles.

ABSOLUTELY CRITICAL RULES:
1. The "url" field MUST start with "https://www.tiktok.com/" or "https://tiktok.com/" — NO OTHER URLS ALLOWED.
2. Do NOT return X profile URLs like "https://x.com/username".
3. Do NOT return X status URLs like "https://x.com/username/status/123".
4. You MUST extract the tiktok.com URL that was embedded or linked in the X post's body.
5. If an X post doesn't contain an extractable tiktok.com URL, SKIP that post and try the next one.
6. If you cannot find 3 posts with real tiktok.com URLs, return fewer posts rather than faking URLs.

The "handle" field should be the TikTok creator's handle (e.g., @khaby.lame) taken from the tiktok.com URL path.

Body: 1 sentence describing the TikTok content and why it went viral, under 120 chars.
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take.
Return JSON: {"tiktok":[{"headline":"...","handle":"@tiktok_creator","body":"...","engagement":"...","url":"https://www.tiktok.com/...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- GOLF ---
cat > /tmp/grok_p_golf.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
Find the 3 MOST VIRAL golf-tip videos being shared on X — swing tips, drills, putting lessons, short game, course management. INSTRUCTIONAL content only (not tournament highlights, not news).

SEARCH STRATEGY (run multiple in parallel, combine results):
1. Top golf instruction accounts (broadened roster): "from:rickshielspga OR from:meandmygolf OR from:GolfMonthlyMag OR from:athletic_motion OR from:GolfDigest OR from:GolfChannel OR from:TheGolfingMachine OR from:GolfIQ OR from:pgatour OR from:NUCLRGOLF OR from:RiggsGolf OR from:Nickolgolf OR from:4golfonline OR from:GolfWeek OR from:noplaceforgolf OR from:thejyhsong OR from:Bryson OR from:Slomoswinglib OR from:golfacademy_eu OR from:mike_dicksongolf OR from:pgaprofessional since:$YESTERDAY min_faves:20", mode: "Top", limit: 30
2. Golf-tip keyword search: "(golf swing tip OR golf drill OR golf fix OR putting tip OR chip shot tip OR golf lesson OR golf instruction) lang:en since:$YESTERDAY min_faves:50", mode: "Top", limit: 25
3. TikTok golf clips reshared: "tiktok.com (golf OR swing OR putting OR chipping OR driving) lang:en since:$YESTERDAY min_faves:30", mode: "Top", limit: 25

FALLBACK 1: If <3 after above, broaden timeframe to last 3 days (since:3 days ago).
FALLBACK 2: If still <3, drop min_faves to 5 for golf instruction handles.
FALLBACK 3: Last resort — search "tiktok.com golf" anywhere in last 7 days; pick 3 most-engaged that show a tip.

Pick the 3 highest-engagement INSTRUCTIONAL golf tips from DIFFERENT handles. A "tip" must contain actionable advice (not "watch me play this hole" or tournament clips).

CRITICAL: If the source is a TikTok being reshared on X, return the ACTUAL TikTok URL (https://www.tiktok.com/...) as the url field, not the X URL. If the source is a YouTube Short, return the YouTube URL. Use the original creator's handle (not the X reposter).

Body: 1 sentence summarizing the specific tip (e.g. "keep your trail elbow tucked for consistent contact"), under 120 chars.
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Instruction tips are usually 8-9 (technique opinions).
Return JSON: {"golf":[{"headline":"...","handle":"@...","body":"...","engagement":"...","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# ============================================================
# GLOBAL RULES — appended to every prompt before it runs
# ============================================================
GLOBAL_RULES=$(cat <<'GRULES'

===== GLOBAL CONTEXT RULE (applies to ALL posts on every tab) =====
A reader landing on the post via our site must UNDERSTAND IT FULLY without clicking out, doing research, or knowing prior context. Apply these rules:

1. STRICT REJECT — pure text replies. Posts that show "Replying to @someone" without the parent tweet visible (i.e. the reader sees only the reply text) MUST BE SKIPPED. The reader cannot guess what the response is to. No exceptions.
2. ACCEPTED post types:
   - Original posts (always self-contained) ✓
   - Quote-tweets (the parent IS embedded and visible inline) ✓
   - Pure text replies WITHOUT visible parent ✗ — REJECT
3. SKIP any post that references "this", "that", "it", or responds to unseen content — the reader must see WHAT is being discussed.
4. SKIP terse reaction posts like "this is wrong", "exactly", "no way", "🔥" — context-free.
5. PREFER posts that explicitly state their topic in the first sentence.

===== ENGLISH-ONLY RULE =====
The site serves English-speaking readers. NO foreign-language content goes out untranslated. Apply:
1. If the post body itself is in a non-English language → SKIP unless you also provide a complete English translation in the "translation" field.
2. If a quote-tweet PARENT TWEET is in a non-English language (the reader will see French/Portuguese/Spanish/etc. in the embedded card) → SET the "translation" field to: "Quoted (translated from <Language>): <full English translation of the parent tweet>. Author caption (English): <their caption>"
3. If you cannot provide a translation and the parent is non-English → SKIP the post. Pick a different one.
4. Reader should NEVER see foreign text without an English translation card visible.

===== NO CRIME-BLOTTER SENSATIONALISM (PG6 + general) =====
SKIP sensationalized violent crime stories, especially:
- Graphic murder details, dismemberment, sexual assault descriptions
- Crime against minors with explicit details
- Mugshot-and-victim-photo "TERRIFYING:" posts
- Crime-blotter clickbait that exists only to shock
PREFER community-interest, surprise reveals, redemption stories, dramatic feuds without violence, cultural moments. The user is explicit: NO crime blotter.

===== BODY-WRITING RULE =====
When summarizing a reply/dispute/reaction post, your "body" field MUST include both the specific thing being responded to AND the response. Example good: "Palmer Luckey disputes Elon Musk claim that AGI arrives by 2026, saying timelines are wrong." Example bad: "Palmer Luckey disputes a claim..." NEVER use vague placeholders like "a claim", "the person", "someone" — if you must use these, the post lacks context and you should SKIP it.

A reader who does not know background context should understand the point of the post from the post alone.
===== END GLOBAL CONTEXT RULE =====
GRULES
)

# Append global rules to every prompt file
for f in /tmp/grok_p_*.txt; do
    echo "$GLOBAL_RULES" >> "$f"
done

# ============================================================
# PHASE 0 — TOPIC LOCK (pre-flight web_search)
# Asks Grok to survey major news outlets and return canonical top stories
# for World + USA. These topics then seed the world/usa searches, so we're
# chasing what AP/Reuters/WSJ/Fox/NYT are actually leading with — not just
# what's trending on X.
# ============================================================
echo "[topic-lock] Surveying news outlets for canonical topics..."
cat > /tmp/grok_p_topic_lock.txt <<TLPROMPT
Current date: $TODAY.

Use web_search to find what major news outlets are leading with TODAY. Two separate searches:

Search 1 — WORLD news (international / foreign affairs, not US domestic):
"site:reuters.com OR site:apnews.com OR site:bbc.com OR site:wsj.com OR site:aljazeera.com world headlines today"
And: "site:cnn.com OR site:foxnews.com OR site:nytimes.com world news today"

Search 2 — USA NATIONAL news (domestic politics, SCOTUS, Congress, federal agencies, US policy — NOT foreign affairs):
"site:apnews.com OR site:reuters.com OR site:wsj.com OR site:washingtonpost.com US politics today"
And: "site:foxnews.com OR site:axios.com OR site:thehill.com national news today"

Extract 3-4 DISTINCT canonical story topics for each category that appear in 2+ of those outlets. For each topic, provide 3-5 search keywords that could be used to find matching X posts.

Return ONLY this JSON:
{
  "world_topics": [
    {"topic": "Short topic name", "keywords": ["kw1", "kw2", "kw3"], "sources": ["reuters.com", "bbc.com"]},
    ...
  ],
  "usa_topics": [
    {"topic": "...", "keywords": [...], "sources": [...]},
    ...
  ]
}
TLPROMPT

# Build payload that uses web_search (not x_search) — different tool for news-site lookup
cat > /tmp/grok_topic_lock_payload.json <<JSONEOF
{
  "model": "grok-4-fast",
  "input": $(python3 -c "import json, sys; print(json.dumps(open('/tmp/grok_p_topic_lock.txt').read()))"),
  "tools": [{"type": "web_search"}],
  "max_output_tokens": 3000,
  "temperature": 0.0
}
JSONEOF

curl -s --max-time 120 https://api.x.ai/v1/responses \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $XAI_API_KEY" \
    -d @/tmp/grok_topic_lock_payload.json > /tmp/grok_raw_topic_lock.json

# Extract the topic-lock JSON and stash it where world/usa prompts can reference it
python3 <<'TLPY' > /tmp/topic_lock.json
import json, re, sys
try:
    with open('/tmp/grok_raw_topic_lock.json') as f: raw = json.load(f)
    if 'error' in raw and raw.get('error'):
        print('{"world_topics": [], "usa_topics": [], "error": "' + str(raw['error'])[:200].replace('"',"'") + '"}')
        sys.exit(0)
    text = ''
    for item in raw.get('output', []):
        if item.get('type') == 'message':
            for c in item.get('content', []):
                if c.get('type') == 'output_text':
                    text = c['text']
    m = re.search(r'\{.*\}', text, re.DOTALL)
    if m:
        parsed = json.loads(m.group(0))
        print(json.dumps(parsed))
    else:
        print('{"world_topics": [], "usa_topics": []}')
except Exception as e:
    print('{"world_topics": [], "usa_topics": [], "error": "' + str(e).replace('"',"'") + '"}')
TLPY

echo "[topic-lock] result:"
cat /tmp/topic_lock.json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for cat in ('world_topics', 'usa_topics'):
    topics = d.get(cat, [])
    print(f'  {cat}: {len(topics)} topics')
    for t in topics[:5]:
        print(f'    - {t.get(\"topic\",\"?\")} [keywords: {\", \".join(t.get(\"keywords\",[])[:4])}]')
if d.get('error'):
    print(f'  error: {d[\"error\"][:120]}')
"

# Re-write world and usa prompts with the locked topics — but as a HINT, not MANDATORY.
# Mandatory injection forces Grok to search for stale topics across multiple crons,
# producing 0 fresh content when those topics are no longer viral on X.
python3 <<'INJECT_EOF'
import json, os
try:
    with open('/tmp/topic_lock.json') as f: tl = json.load(f)
except: tl = {'world_topics': [], 'usa_topics': []}

for tab_key, out_file in [('world_topics', '/tmp/grok_p_world.txt'),
                          ('usa_topics', '/tmp/grok_p_usa.txt')]:
    topics = tl.get(tab_key, [])
    if not topics: continue
    topic_list = '\n'.join(
        f'  - {t.get("topic","?")}'
        for i, t in enumerate(topics[:4])
    )
    injection = (
        f"\n\nFYI — major news outlets are covering these today (use as background context only, not a forced list):\n"
        f"{topic_list}\n"
        f"Feel free to pick from these OR find fresher trending topics on X — whichever has stronger 3-perspective coverage. "
        f"This list is the single source of truth for what's important today.\n"
        f"\n"
    )
    with open(out_file, 'a') as f: f.write(injection)
    print(f'  Injected {len(topics)} topic hints into {os.path.basename(out_file)}', file=__import__("sys").stderr)
INJECT_EOF

# ============================================================
# RUN ALL 16 CALLS IN PARALLEL
# ============================================================
echo "Launching 16 parallel API calls..."

CATEGORIES="world usa elon allin top msm business sports pods pg6 recipe science local memes comedy golf"

for cat in $CATEGORIES; do
    # All tabs run on grok-4-fast. The world/USA prompts have been simplified so the
    # fast model handles them reliably (was hallucinating sequential snowflake IDs on
    # the prior 4000-token multi-step prompts).
    model="grok-4-fast"
    echo "  Starting: $cat (model: $model)"
    grok_call "/tmp/grok_p_${cat}.txt" "/tmp/grok_raw_${cat}.json" "$model" &
done

# TikTok tab uses tikwm.com free trending API, not Grok
echo "  Starting: tiktok via tikwm.com"
python3 $SCRIPT_DIR/fetch_tiktok.py &

echo "Waiting for all calls to complete..."
wait
echo "All calls done."

# ============================================================
# MERGE ALL 12 RESPONSES
# ============================================================
echo "Merging and validating..."

python3 <<'MERGE_EOF' > /tmp/grok_raw.json
import json, sys, re

CATEGORIES = 'world usa elon allin top msm business sports pods pg6 recipe science local memes comedy tiktok golf'.split()

def extract_json_text(raw_file):
    try:
        with open(raw_file) as f:
            r = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f'ERROR reading {raw_file}: {e}', file=sys.stderr)
        return None
    if 'error' in r and r.get('error'):
        print('ERROR from ' + raw_file + ': ' + str(r.get('error','')), file=sys.stderr)
        return None
    candidates = []
    # Grok Responses API format: output[].message.content[].output_text
    for item in r.get('output', []):
        if item.get('type') == 'message':
            for c in item.get('content', []):
                if c.get('type') == 'output_text':
                    candidates.append(c['text'])
    # OpenAI Chat Completions / tikwm wrapper format: choices[0].message.content
    for ch in r.get('choices', []):
        msg = ch.get('message', {}) if isinstance(ch, dict) else {}
        content = msg.get('content')
        if isinstance(content, str) and content:
            candidates.append(content)
    for t in reversed(candidates):
        if '{' in t:
            return t
    return candidates[-1] if candidates else None

def parse_json(text):
    if not text: return {}
    text = text.strip()
    if text.startswith('\`\`\`'):
        text = re.sub(r'\`\`\`json?\s*', '', text)
        text = re.sub(r'\`\`\`\s*$', '', text)
    start = text.find('{')
    if start == -1: return {}
    # Use the FULL remaining text after the first { — let JSON repairs handle structural
    # issues. Bracket-matching on malformed JSON cuts off at the wrong } and produces
    # incomplete chunks.
    raw = text[start:]
    # Trim to last } (may include trailing content)
    last_brace = raw.rfind('}')
    if last_brace > 0: raw = raw[:last_brace+1]

    # Apply repairs in order: simplest first
    for attempt_label, transform in [
        ('raw', lambda x: x),
        ('trailing-commas', lambda x: re.sub(r',(\s*[}\]])', r'\1', x)),
        ('add-missing-{-before-headline', lambda x: re.sub(r'\}\s*,\s*"headline"', r'},{"headline"', re.sub(r',(\s*[}\]])', r'\1', x))),
    ]:
        candidate = transform(raw)
        try: return json.loads(candidate)
        except: pass
    return {}

merged = {}
for cat in CATEGORIES:
    raw_file = f'/tmp/grok_raw_{cat}.json'
    t = extract_json_text(raw_file)
    d = parse_json(t)
    if d:
        print(f'  {cat}: got keys {list(d.keys())}', file=sys.stderr)
        merged.update(d)
    else:
        print(f'  {cat}: FAILED or empty', file=sys.stderr)

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
MERGE_EOF

# ============================================================
# STEP 2.5: oEmbed verification (hard gate at 40%)
# Hits Twitter's oEmbed API for every URL. Logs pass/fail rate.
# If <40% pass, ABORT and preserve old stories.json.
# Also captures tweet text from successful oEmbeds for headline QA.
# ============================================================
echo "[oembed-verify] verifying tweet URLs against publish.twitter.com/oembed..."
python3 <<'OEMBED_EOF'
import json, sys, urllib.request, urllib.parse, re, time, html as htmlmod

def collect_url_nodes(data):
    """Walk merged JSON, return list of (parent_dict, path) where parent has a /status/ url."""
    nodes = []
    def walk(obj, path):
        if isinstance(obj, dict):
            url = obj.get('url')
            if isinstance(url, str) and '/status/' in url:
                nodes.append((obj, path))
            for k, v in obj.items():
                walk(v, path + '.' + k)
        elif isinstance(obj, list):
            for i, v in enumerate(obj):
                walk(v, path + '[' + str(i) + ']')
    walk(data, '')
    return nodes

def check_oembed(url, timeout=8):
    """Returns (status_code, tweet_text or None)."""
    try:
        oembed_url = 'https://publish.twitter.com/oembed?url=' + urllib.parse.quote(url, safe='')
        req = urllib.request.Request(oembed_url, headers={'User-Agent': 'eXpressO/1.0'})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                body = json.loads(resp.read().decode('utf-8'))
                tweet_html = body.get('html', '')
                # Extract tweet text from oEmbed HTML — first <p>...</p> contains the tweet
                m = re.search(r'<p[^>]*>(.*?)</p>', tweet_html, re.DOTALL)
                if m:
                    text = re.sub(r'<[^>]+>', ' ', m.group(1))
                    text = htmlmod.unescape(text)
                    text = re.sub(r'\s+', ' ', text).strip()
                    return (200, text)
                return (200, None)
            return (resp.status, None)
    except urllib.error.HTTPError as e:
        return (e.code, None)
    except Exception:
        return (0, None)

# Load merged data, unwrap
with open('/tmp/grok_raw.json') as f:
    raw = json.load(f)
inner_text = raw.get('output', [{}])[0].get('content', [{}])[0].get('text', '{}')
data = json.loads(inner_text)

nodes = collect_url_nodes(data)
print(f'  Total URLs to verify: {len(nodes)}', file=sys.stderr)

verified = 0
failed = 0
for node, path in nodes:
    url = node.get('url')
    status, tweet_text = check_oembed(url)
    ok = (status == 200 and tweet_text)
    if ok:
        node['_tweet_text'] = tweet_text
        verified += 1
        sym = '+'
    else:
        # Null the URL so parse_grok drops/skips it
        node['url'] = None
        node['_oembed_failed'] = True
        failed += 1
        sym = '-'
    print(f'  {sym} {status} {url}', file=sys.stderr)
    time.sleep(0.08)  # be gentle

total = verified + failed
pct = (verified / total * 100) if total else 0
print(f'  Pass rate: {verified}/{total} = {pct:.0f}%', file=sys.stderr)

# HEADLINE QA: when we have verified tweet_text, fix obviously bad headlines.
# A headline is "bad" if it's mostly a t.co link, suspiciously short, or shares
# no meaningful words with the tweet text. Replace with first 90 chars of tweet text.
def is_bad_headline(headline, tweet_text):
    """Only flag clearly broken headlines — null, t.co-only, or all-caps ticker.
    Don't flag legitimate summaries that happen to use different words than the tweet."""
    if not headline or not isinstance(headline, str): return True
    h = headline.strip()
    if len(h) < 8: return True
    if h.startswith('https://t.co/') or h.startswith('http://t.co/'): return True
    # Headline is just a URL with nothing else
    h_no_url = re.sub(r'https?://\S+', '', h).strip()
    if len(h_no_url) < 8: return True
    if re.match(r'^[A-Z0-9_]{2,}:?$', h): return True  # all-caps ticker like "BREAKING:"
    return False

def trim_to_headline(text, maxlen=90):
    if not text: return ''
    text = re.sub(r'https?://\S+', '', text).strip()
    text = re.sub(r'\s+', ' ', text)
    if len(text) <= maxlen: return text
    cut = text[:maxlen].rsplit(' ', 1)[0]
    return cut + '...'

qa_fixed = 0
for node, path in nodes:
    tt = node.get('_tweet_text')
    if not tt: continue
    h = node.get('headline')
    if is_bad_headline(h, tt):
        new_h = trim_to_headline(tt)
        if new_h:
            node['headline'] = new_h
            qa_fixed += 1
            print(f'  [headline-qa] fixed at {path}: "{(h or "")[:40]}..." -> "{new_h[:40]}..."', file=sys.stderr)

print(f'  Headline QA: {qa_fixed} headlines auto-fixed from tweet text', file=sys.stderr)

# HARD GATE: too few verified URLs means the data is mostly fake. Abort.
# Skip gate if total < 6 (not enough sample to judge)
if total >= 6 and pct < 40:
    print(f'ABORT: oEmbed pass rate {pct:.0f}% below 40% threshold. Likely fake URLs across the board.', file=sys.stderr)
    sys.exit(2)

# Persist corrected data back to /tmp/grok_raw.json so parse_grok sees the cleaned URLs
out = {
    'output': [{
        'type': 'message',
        'content': [{'type': 'output_text', 'text': json.dumps(data)}]
    }]
}
with open('/tmp/grok_raw.json', 'w') as f:
    json.dump(out, f)

print(f'  oEmbed done: {verified} verified, {failed} nulled, {qa_fixed} headlines repaired.', file=sys.stderr)

# ============================================================
# TRANSLATION ENFORCEMENT
# Scan all post bodies + quote texts for non-English content.
# If found and no translation field, mark for translation or rejection.
# ============================================================
import os

def has_heavy_non_english(text):
    """Returns True if text appears to be non-English (>10% non-ASCII letters
    or contains common non-English markers)."""
    if not text or not isinstance(text, str): return False
    # Strip URLs and mentions
    clean = re.sub(r'https?://\S+', '', text)
    clean = re.sub(r'@\w+', '', clean)
    if len(clean) < 30: return False
    # Count non-ASCII alphabetic characters
    letters = [c for c in clean if c.isalpha()]
    if len(letters) < 20: return False
    non_ascii = sum(1 for c in letters if ord(c) > 127)
    if non_ascii / len(letters) > 0.10:
        return True
    # Check for common non-English words/patterns
    foreign_markers = [
        # Portuguese
        r'\b(que|para|com|nao|nao|cantor|comprou|usou|piscina|inflavel|garagem)\b',
        # French
        r"\b(avait|cette|pour|sont|c'est|l'argent|niveau|substance|change|tout|juste)\b",
        # Spanish
        r'\b(para|sobre|cuando|donde|porque|tambien|gobierno)\b',
        # German
        r'\b(und|nicht|haben|werden|durch|sondern|deutschland)\b',
    ]
    text_lower = clean.lower()
    for pattern in foreign_markers:
        matches = len(re.findall(pattern, text_lower))
        if matches >= 3:  # 3+ markers = likely foreign
            return True
    return False

def collect_translatable_nodes(data):
    """Return [(node, body_field, text)] for all nodes that need translation check."""
    out = []
    def walk(obj, path):
        if isinstance(obj, dict):
            for field in ('body', 'quote', '_tweet_text'):
                t = obj.get(field)
                if t and isinstance(t, str):
                    if has_heavy_non_english(t):
                        out.append((obj, field, t, path))
                        break  # one per node is enough
            for k, v in obj.items(): walk(v, path + '.' + k)
        elif isinstance(obj, list):
            for i, v in enumerate(obj): walk(v, path + f'[{i}]')
    walk(data, '')
    return out

translatable = collect_translatable_nodes(data)
print(f'  Translation check: {len(translatable)} non-English nodes detected', file=sys.stderr)

if translatable:
    # For each, check if 'translation' field is already set. If not, ATTEMPT to translate via Grok.
    # If translation can't be obtained, NULL the URL so parse_grok drops the post.
    needs_translation = [(n, f, t, p) for n, f, t, p in translatable if not n.get('translation')]
    print(f'  Need translation: {len(needs_translation)} nodes (others have translation field)', file=sys.stderr)
    if needs_translation:
        # Build a single Grok API call with all texts to translate
        api_key = os.environ.get('XAI_API_KEY', '')
        if not api_key:
            print('  No XAI_API_KEY — nulling untranslated foreign posts', file=sys.stderr)
            for n, f, t, p in needs_translation:
                n['url'] = None
                n['_no_translation'] = True
        else:
            # Build batched translation prompt
            items_for_translation = [
                {'idx': i, 'text': t[:600]}
                for i, (n, f, t, p) in enumerate(needs_translation)
            ]
            tx_prompt = (
                "Translate each of the following non-English texts to clear English. "
                "Output ONLY a JSON array with the same indices, like: "
                '[{"idx":0,"english":"..."},{"idx":1,"english":"..."}]\n\n'
                "Items:\n" + json.dumps(items_for_translation, ensure_ascii=False)
            )
            tx_payload = {
                "model": "grok-4-fast",
                "input": [
                    {"role": "system", "content": "You are a precise translator. Output ONLY valid JSON."},
                    {"role": "user", "content": tx_prompt}
                ],
                "max_output_tokens": 3000,
                "temperature": 0.0
            }
            tx_payload_path = '/tmp/grok_translate_payload.json'
            with open(tx_payload_path, 'w') as f:
                json.dump(tx_payload, f)
            import subprocess
            try:
                r = subprocess.run(
                    ['curl', '-s', '--max-time', '120', 'https://api.x.ai/v1/responses',
                     '-H', 'Content-Type: application/json',
                     '-H', f'Authorization: Bearer {api_key}',
                     '-d', f'@{tx_payload_path}'],
                    capture_output=True, text=True, timeout=130
                )
                resp = json.loads(r.stdout)
                tx_text = ''
                for item in resp.get('output', []):
                    if item.get('type') == 'message':
                        for c in item.get('content', []):
                            if c.get('type') == 'output_text':
                                tx_text = c['text']
                # Extract JSON array
                m = re.search(r'\[.*\]', tx_text, re.DOTALL)
                if m:
                    translations = json.loads(m.group(0))
                    by_idx = {t.get('idx'): t.get('english','') for t in translations if isinstance(t, dict)}
                    fixed = 0
                    nulled = 0
                    for i, (n, f, t, p) in enumerate(needs_translation):
                        eng = by_idx.get(i, '').strip()
                        if eng and len(eng) > 20:
                            n['translation'] = eng
                            fixed += 1
                            print(f'  [translate] +{p}: {eng[:80]}...', file=sys.stderr)
                        else:
                            n['url'] = None
                            n['_no_translation'] = True
                            nulled += 1
                            print(f'  [translate] NULLED {p} (no translation available)', file=sys.stderr)
                    print(f'  Translation done: {fixed} translated, {nulled} nulled', file=sys.stderr)
                else:
                    # Translation call failed to return JSON — null all
                    for n, f, t, p in needs_translation:
                        n['url'] = None
                        n['_no_translation'] = True
                    print(f'  Translation API returned no JSON — nulled {len(needs_translation)} foreign posts', file=sys.stderr)
            except Exception as e:
                print(f'  Translation call failed: {e} — nulling {len(needs_translation)} foreign posts', file=sys.stderr)
                for n, f, t, p in needs_translation:
                    n['url'] = None
                    n['_no_translation'] = True

# Re-persist after translation pass
out = {
    'output': [{
        'type': 'message',
        'content': [{'type': 'output_text', 'text': json.dumps(data)}]
    }]
}
with open('/tmp/grok_raw.json', 'w') as f:
    json.dump(out, f)
OEMBED_EOF

OEMBED_EXIT=$?
if [ $OEMBED_EXIT -eq 2 ]; then
    echo "ABORT: oEmbed hard gate failed. Old stories.json preserved."
    exit 1
fi

XAI_API_KEY="$XAI_API_KEY" cat /tmp/grok_raw.json | XAI_API_KEY="$XAI_API_KEY" python3 parse_grok.py

if [ $? -ne 0 ]; then
    echo "ABORT: Validation failed. Old stories.json preserved."
    exit 1
fi

echo "Parse done."

# ============================================================
# QC CRITIC PASS — second Grok review of curated stories
# Logs concerns to /tmp/expresso_qc_review.log for human review.
# Does NOT block deploy — surfaces concerns for prompt-tuning.
# ============================================================
echo "Running QC critic pass..."
bash $SCRIPT_DIR/qc_critic.sh || echo "QC critic skipped"

# DEPLOY via Netlify API
echo "Deploying via digest API..."
bash $SCRIPT_DIR/deploy.sh

echo "=== v4 Done ===" ; date
