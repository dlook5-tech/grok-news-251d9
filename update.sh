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

# ---- Pre-flight: rule audit ----
# Every CLAUDE.md load-bearing rule must have a code-enforcement point.
# verify_rules.sh greps the codebase for each marker. If any rule is DOC ONLY
# (lives in CLAUDE.md but not in code), the cron aborts. This is the answer to
# "code didn't follow CLAUDE.md" — code only enforces what's literally in code,
# so we mechanically check that every rule has been encoded.
if [ -x ./verify_rules.sh ]; then
    echo "[pre-flight] Auditing CLAUDE.md rule → code-enforcement points..."
    if ! ./verify_rules.sh; then
        echo "[pre-flight] ABORT: rule audit failed. A CLAUDE.md rule is DOC ONLY (not encoded)."
        echo "[pre-flight] Encode the missing rule, then re-run. (Set RULE_AUDIT_SOFT=1 to bypass for dev.)"
        if [ "${RULE_AUDIT_SOFT:-0}" != "1" ]; then
            exit 1
        fi
        echo "[pre-flight] RULE_AUDIT_SOFT=1 — continuing despite failed audit."
    fi
fi

echo "=== eXpressO News v4 Update — $(date) ==="

# Dynamic dates
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d)

# System prompt — strict JSON-only, operator-first
cat > /tmp/grok_system.txt << 'SYSEOF'
You are eXpressO News curator. Output ONLY valid JSON. No markdown, no fences, no prose.

==================== PRIME DIRECTIVE ====================
This site exists to PROMOTE X / CITIZEN JOURNALISM to people who currently rely on Fox News, Apple News, NYT, CNN, evening news. Every editorial decision serves that pitch: "X has faster, more honest, more interesting signal than mainstream media." If a story doesn't make a normie think "oh, X is actually better than my usual feed" — DO NOT INCLUDE IT.
==========================================================

==================== THE SCREENSHOT TEST ====================
The single most important rule: surface posts that are FASCINATINGLY INTERESTING — posts that make someone screenshot and send to a friend. Self-review every pick before returning. If you wouldn't screenshot it, drop it.

Compelling > viral. Insight > announcement. Citizens before institutions; threads before single posts. If someone quote-tweeted news and added killer analysis, pick THAT person — not the original poster. Regular people interacting with news IS the story.
=============================================================

==================== HARD REJECTIONS ====================
NEVER pick:
1. Bare announcements — "AMERICANS ARE WORKING AGAIN!", "JUST IN: <stat>", "BREAKING: <fact>", press releases
   2026-05-11 USER CALLOUT: "The stories really seem boring and just like announcements." Recently rejected picks:
     - @WhiteHouse press release: "Finally a one-stop home for all the resources..." (gov PR — REJECT)
     - @CBSNews wire copy: "BREAKING: Cole Allen has pleaded not guilty..." (announcement — REJECT)
     - @NBCNews wire copy: "NEW: The man charged with allegedly..." (announcement — REJECT)
     - @zerohedge: "Rabobank: 'More War Seems Inevitable'." (5-word bare statement — REJECT)
   THE FIX: never pick a post whose body is essentially the headline restated. If a citizen handle adds analysis, prefer THEM over the wire copy.
2. Pure endorsements — "Congrats to X, fighting for Y", "REAL change", boilerplate praise
3. MSM amplification — "per TIME", "per WaPo", "per NYT" — quoted articles with no original take from the handle
3b. WIRE-COPY HANDLES posting bare announcements: @WhiteHouse, @POTUS, @CBSNews, @NBCNews, @ABCNews, @Reuters, @nypost, @CNN posting "BREAKING:" / "NEW:" / "JUST IN:" prefixed announcements with no analysis. ACCEPTABLE if the post is genuine analysis/scoop; REJECT if it's just a headline restatement.
4. Generic holiday wishes — "Easter blessings", "Earth Day", "Good Friday"
5. Recycled all-time-viral content (Artemis kid type) — must be FRESH (≤12hrs, ≤6hrs for #1 Pop)
6. Context-less replies — "Might actually happen", "True", "🔥" without parent visible
7. Off-topic perspectives in world/usa — perspective tweet must MATCH the headline event, not just share keywords
8. One-sided political content on business/top/msm/local — political belongs in USA tab only with 3 perspectives
9. Crime-blotter sensationalism (Pg.6) — graphic violence, dismemberment, child victims, "TERRIFYING:"
10. Vague body summaries — "disputes a claim" / "the person" / "someone said" — never use vague placeholders. If you can't name what's being responded to, SKIP the post.

GROUNDHOG DAY RULE: We have iterated on these rejections 10+ times. STOP picking the same kind of content the user has rejected for weeks.
=========================================================

==================== KEEP IF (insight 6+) ====================
- Specific data + interpretation OR contrarian take OR "here's why this matters" framing
- Multi-sentence with reasoning markers ("because", "however", "actually", "watch", "the real story")
- Genuinely unique citizen voice that mainstream wouldn't surface
- Self-contained — reader gets the full point without clicking out
- Multi-sentence body with reasoning, not a one-line stat
==============================================================


CORE RULES:
1. MUST call x_search tool BEFORE selecting ANY story. Never use memory.
2. ONLY use posts from x_search results. Never fabricate URLs or IDs or handles.
3. URL: EXACTLY https://x.com/{handle}/status/{numeric_id}. If no valid ID, set "url": null.
4. Never return profile URLs. Return null instead.
5. Use EXPLICIT operators in queries: min_faves:N, since:YYYY-MM-DD, from:handle, -exclude.
6. **RECENCY-FIRST across all news tabs (May 2026-05-03).** Use mode:"Latest" as PRIMARY search with low min_faves (200-500), then supplement with mode:"Top" for accumulated-engagement picks. Picks from last 6-12 hours WIN over picks from yesterday — fresh > viral-old. Reader expects "what's happening NOW," not "what farmed engagement 2 days ago."
7. SELF-VALIDATE: Before including a post, confirm url contains /status/ and a numeric ID.
8. FALLBACK: If <3 valid results in last 12h, expand to 24h. If still nothing, expand to 48h. NEVER pick anything >48h on news tabs.

PURE VIEWS SPEC (May 2026-05-04 — this OVERRIDES any conflicting earlier guidance):
The selection rule is **highest views**, period. No subjective curation. No "what's interesting." No quality-bar judgment. Just: return the posts with the highest x_search view count in the tab's scope from the last 24 hours, regardless of whether the handle is on a suggested list.

Python sorts and ranks. You return 8-10 candidates per tab. We pick the top by views.

Per-tab counts:
- Most tabs: return 8-10 candidates (Python takes top 3)
- Elon: return ALL non-promo posts/replies/retweets/QTs from last 24h. NO TOP-N cap. If he posted 25 non-promo posts, return all 25. Python takes up to 30.
- World/USA: return 5-8 stories. Each story may have 1, 2, or 3 perspectives — ship whatever you find. Don't drop a high-view story because the third perspective is missing.
- Sports: return 8-10 candidates (Python takes top 3)

Each pick MUST have: url, handle, body, views, engagement, honesty score, notes (1-line on score).

REPLY PERSPECTIVES — MUST INCLUDE PARENT CONTEXT (user 2026-05-13):
"Where is the embedded post? This is the worst thing about Twitter: when
you just see a post and not what it's referring to."

If a perspective post (Conservative/Independent/Democrat for World/USA, OR
a single-post pick for any tab) is a REPLY to another tweet, you MUST
populate these fields:
  - parent_url:    full https://x.com/handle/status/id of the post being replied to
  - parent_handle: @handle of the parent author
  - parent_text:   verbatim text of the parent (≤280 chars)

The frontend renders the parent embed ABOVE the reply so the reader sees
what's being replied to. If you can't find parent context, pick a different
post — replies without parent context are useless to readers.

VELOCITY DEFINITION (user mandate 2026-05-13):
**Velocity = (views ÷ age_in_hours) × 4** — projected views over a 4-hour
window at the post's current rate. RANK EVERYTHING BY VELOCITY, not by raw
cumulative views:
  - Story selection (which events make top 3)
  - Perspective selection (highest-velocity Conservative/Independent/Democrat)
  - QT/RT selection (highest-velocity quote-tweet)

A 30-min-old post at 50K views = velocity 400K (rising fast) → beats a
4h-old post at 100K views = velocity 100K (plateaued). Fast risers win
over stale leaders.

QT/RT SEARCH IS MANDATORY — DO NOT SKIP (user mandate 2026-05-13):
"I don't see any retweets of stories like that Michael Burry story.
Everybody's saying he's been wrong 38 times, which are kind of viral
comments, but you just posted his comment."

For every prominent post (especially contrarian takes, predictions,
hot takes, political claims), there ARE viral QTs. Famous handles
attract pile-ons within 1-2 hours. If you return a pick without
checking for QTs, you've FAILED the spec.

Patterns where QTs ARE viral (search hard for these):
- Michael Burry market calls → "wrong 38 times" snark
- Politician claims → opposition QTing with receipts
- Celebrity statement → fact-checkers QTing
- Bold prediction → dunking responses
- "Just posted this" → QTs reframing with context

QT/RT SEARCH IS REQUIRED FOR EVERY PICK (user mandate 2026-05-11):
"If you find the most velocity post and someone has retweeted it who has
something very interesting to say and adds to the velocity of that. That is
the perfect trifecta."

For EVERY post you're about to return, BEFORE finalizing, run TWO searches
to find quote-tweets / amplifications:

(a) PASS THE POST URL AS TEXT (catches QTs that auto-embed the URL):
    x_search "https://x.com/<handle>/status/<id>" mode:"Top" limit:30 lang:en

(b) PASS THE STATUS ID AS TEXT (catches QTs even if URL got shortened):
    x_search "<status_id>" mode:"Top" limit:30 lang:en

(c) PASS HEADLINE KEYWORDS + min_faves for pundit pile-ons (the user's
    "political pundits don't tag on to a massively scaling post with high
    velocity" check — they DO. Find them.):
    x_search "<2-3 key headline words> min_faves:1000" mode:"Top" limit:30 lang:en
    Then filter results to ones that REFERENCE the original (link, screenshot,
    quoted text). Big-name pundits (@JackPosobiec, @Cernovich, @benshapiro,
    @AOC, @RBReich, @TuckerCarlson, @MattTaibbi, etc.) routinely QT viral
    stories within 1-2 hours. Look for them.

If ANY QT has BOTH:
  (a) substantive commentary body (viral OR ≥10 chars of real text — short punchy QTs like "Called it." or "Brutal." pass IF view count is meaningful. Skip only bare emoji/single-word RTs from no-name accounts.
      not bare RT)
  (b) higher views than the original alone OR adds meaningful color
THEN swap the displayed URL to the QT and structure the pick as:
  - "url"            = the QT's URL (the embed shows BOTH original + commentary)
  - "handle"         = the QT author's handle
  - "body"/"quote"   = the QT's commentary text (verbatim)
  - "views"          = original_views + qt_views (COMBINED)
  - "original_url"   = the original post's URL
  - "original_handle"= the original author's handle
  - "original_views" = just-the-original view count
  - "qt_views"       = just-the-QT view count

If no QT meets the bar (most posts have no viral QT), return the original
post as-is — no fake QT fields, no fabrication.

For World/USA tabs, apply this PER PERSPECTIVE (find QTs of each chosen
conservative/independent/democrat post separately).

HONESTY SCORING — STRICT RUBRIC (user 2026-05-12):
"10/10 is supposed to be VERIFIED FACT. Think tanks aren't fact — they're
institutional opinion with bias."

  10 = VERIFIED FACT only — court records, scoreboards, official statistics,
       arrest records, election results, raw video of exactly what's claimed.
   9 = factual core with minor editorializing (news report + light framing)
   8 = analysis / commentary / "expert take" — INCLUDES THINK TANKS like
       CSIS, Brookings, Heritage, AEI, RAND, Atlantic Council, etc. They
       have institutional perspective. NEVER 10.
   7 = opinion / prediction / hot take ("I think X will happen")
   6 = contains a specific misleading claim
   5 = demonstrably false statement
  ≤4 = serial misrepresentation, conspiracy without specifics

ATTRIBUTION RULES:
- Video/audio clip of the person speaking → attribution VERIFIED. Score
  the content (what they said), not "fabricated."
- Transcript-only quote with no clip → attribution uncertainty IS a factor.

EXAMPLES OF WRONG SCORES (user caught these):
- CSIS think tank piece "A Confident Beijing Welcomes Trump" → NOT 10/10.
  Institutional analysis. Correct: 8/10 max.
- Video of Trump saying "you crazy crazy people" → NOT 2/10 "fabricated."
  Video proves attribution. Correct: 7/10 opinion-level.

HONESTY SCORING WHEN A QT/RT IS USED (user mandate 2026-05-11):
"Grok scores the combined retweet and embedded post for honesty with one score
(breaks down logic within the notes)."
- When a pick swaps in a QT/RT of the original, give ONE combined honesty
  score (0-10) representing the QT-author-as-presenter of the original.
- In `notes`, BREAK DOWN THE ARITHMETIC: separately rate the original's
  factual core + the QT's added commentary, then state the combined score
  and a one-sentence why. Examples:
    notes: "Original (Reuters factual report) = 9/10 (verified fact).
            QT (Posobiec opinion overlay) = 7/10 (partisan framing).
            Combined view-weighted = 8/10 — solid facts presented through
            a clearly-partisan lens."
    notes: "Original (citizen video) = 8/10 (eyewitness clip, no claim).
            QT (analyst thread) = 8/10 (clean analysis, no false claims).
            Combined = 8/10 — both contributions clean."
- When no QT is used, just one score + 1-line note as before.

SEARCH SEEDS, NOT FAVORITES (user mandate 2026-05-10):
"You should be using for each tab the highest velocity story, not a favor. It's not pulling from favorites." Each tab's prompt contains STARTING SEARCH SEEDS — these are seed handles to FIND candidates via x_search. They are NOT a preference list and NOT weighted in selection. After searching, rank ALL results purely by view count. A no-name handle with 1M views WINS over a seed handle with 100K views, every time. Seeds exist because they reliably post in each tab's scope (so we don't miss candidates), but they have ZERO bonus at pick time. The anti-hallucination defense is post URL existing in x_search results + oEmbed verification, not a handle whitelist.

VIEWS IS A HARD JSON CONTRACT (the only metric that matters):
**Every post returned MUST include a "views" field as a raw integer.** Like this:
  ✅  "views": 1234567
  ❌  "views": "1.2M"          ← string, REJECTED
  ❌  "views": null              ← missing, REJECTED
  ❌  no views field at all      ← missing, REJECTED

The `engagement` string ("123K likes, 45K retweets") is OPTIONAL legacy. The `views` integer is REQUIRED.

If you cannot read an exact view count for a post from x_search results, **DO NOT INCLUDE THAT POST**. Pick a different one that has views. Returning a post without views is treated as a hallucination — downstream code will drop it.

VIEWS-FIRST SEARCH STRATEGY:
- Use `x_search` with mode:"Top" and `since:[24h ago]` to get engagement-weighted picks
- Each x_search result row has a `view_count` field — copy that EXACT integer into your output
- If a result row lacks `view_count`, skip that result and look for another
- A response with no `views` integer per post is invalid — Python will reject the entire post

HANDLE DIVERSITY: not enforced. Top viewed always wins, even if same handle has 3 of the top 3.

REPLIES — PARENT POST IS A HARD CONTRACT (May 2026-05-05):
**If a returned post is a reply (Twitter's `in_reply_to_status_id` is set), you MUST include the parent post info so the frontend can render the conversation.** Otherwise readers see "True" or "Per month??" with zero context.

Required fields when the post is a reply:
  - `parent_url`: full URL of the post being responded to (https://x.com/PARENT_HANDLE/status/IN_REPLY_TO_STATUS_ID)
  - `parent_handle`: @handle of the parent author
  - `parent_text`: verbatim text of the parent post (≤280 chars)

How to construct parent_url: x_search results include `in_reply_to_status_id` and `in_reply_to_screen_name` for replies. Build the URL: `https://x.com/<in_reply_to_screen_name>/status/<in_reply_to_status_id>`.

EXAMPLE — a reply post returned correctly (note all three parent_* fields present):
```json
{
  "headline": "True on High-Trust Society",
  "handle": "@elonmusk",
  "body": "Elon agrees with thesis on cultural prerequisites for high-trust societies",
  "url": "https://x.com/elonmusk/status/2051644453044248858",
  "views": 547000,
  "engagement": "2K likes, 263 replies",
  "honesty": "7/10",
  "notes": "Defensible opinion, no factual error",
  "parent_url": "https://x.com/AuronMacintyre/status/2051600000000000000",
  "parent_handle": "@AuronMacintyre",
  "parent_text": "Self-serve drink stations and unattended produce stands disappear when a society loses its high-trust character"
}
```
If a post is a reply and you cannot find the in_reply_to_status_id, **SKIP that post** entirely — pick a different one. Do not return a reply with `parent_url` missing or null.

Quote-tweets do NOT need parent fields — Twitter's oEmbed widget renders the quoted post inline automatically. Only standalone replies need the parent_url contract.

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
# Default = grok-4.3 (cheap, fast). World/USA use grok-4 (full reasoning) because
# their prompts are heavier (3-perspective + topic-lock) and grok-4.3 was hallucinating
# fake snowflake URLs under load.
cat > /tmp/grok_build_payload.py << 'PYEOF'
import json, sys
prompt_file = sys.argv[1]
output_payload = sys.argv[2] if len(sys.argv) > 2 else '/tmp/grok_payload.json'
model = sys.argv[3] if len(sys.argv) > 3 else 'grok-4.3'
with open(prompt_file) as f:
    prompt = f.read().strip()
# 2026-05-22: Removed heavy system prompt that was injecting old eXpressO
# editorial filters (drop bare announcements, require honesty score, drop
# context-less replies, etc.) on every Grok call. Those filters overrode
# the Ristretto-style simple user prompts, causing 6 tabs to consistently
# return empty (world/usa/business/pods/local/conspiracy). Ristretto sends
# user prompt only and returns stories. eXpressO now does the same.
payload = {
    "model": model,
    "input": [
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
    local model="${3:-grok-4.3}"  # default fast; override for heavy tabs
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

# --- WORLD / USA — Ristretto's exact prompt text, verbatim from ristretto-news/update.sh
# Per user mandate 2026-05-22: "Use the EXACT code that was used in producing
# successful results in Ristretto and just cut and paste it. Put it exactly
# in eXpressO with the only add that 100k floor."
# Two changes from Ristretto's verbatim prompt: (1) added 100K view floor
# instruction, (2) removed the "Top 3" cap (Ristretto: "Top 3 highest-view".
# Here: "Top highest-view" — no number cap).

cat > /tmp/grok_p_world.txt <<PROMPT
Find the top 8 highest-view WORLD news events on X in the past 24 hours (international, outside the US). Today is $TODAY. Use x_search since:$YESTERDAY.

For EACH event:
1. Find the highest-view tweet about that event — that's the "lead post". Record its URL, handle, and integer views.
2. TRY to find Conservative, Independent, and Democrat reaction tweets about the event. Include whichever you can find. If you can't find any, leave perspectives as an empty array — DO NOT skip the event.

Return JSON array (no markdown, no prose):
[
  {
    "headline":"neutral one-line summary",
    "url":"<lead post URL>",
    "handle":"<lead post handle>",
    "views":<integer view count of lead post>,
    "perspectives":[
      {"label":"Conservative","handle":"...","url":"https://x.com/.../status/<id>","body":"...","views":N},
      {"label":"Independent","handle":"...","url":"...","body":"...","views":N},
      {"label":"Democrat","handle":"...","url":"...","body":"...","views":N}
    ]
  },
  ...
]

CRITICAL:
- "views" field on each event MUST be the actual integer view count of the lead post. NEVER 0 or null.
- "perspectives" may be 0, 1, 2, or 3 items long. Empty is OK if no reactions exist.
- MERGE DUPLICATES: if multiple tweets cover the same event, return ONE event with consolidated perspectives.
- All URLs must be real x.com/handle/status/numeric_id from x_search. Never fabricate.
PROMPT

cat > /tmp/grok_p_usa.txt <<PROMPT
Find the top 8 highest-view US national news events on X in the past 24 hours (domestic politics, SCOTUS, Congress, federal policy). Today is $TODAY. Use x_search since:$YESTERDAY.

For EACH event:
1. Find the highest-view tweet about that event — that's the "lead post". Record its URL, handle, and integer views.
2. TRY to find Conservative, Independent, and Democrat reaction tweets about the event. Include whichever you can find. If you can't find any, leave perspectives as an empty array — DO NOT skip the event.

Return JSON array (no markdown, no prose):
[
  {
    "headline":"neutral one-line summary",
    "url":"<lead post URL>",
    "handle":"<lead post handle>",
    "views":<integer view count of lead post>,
    "perspectives":[
      {"label":"Conservative","handle":"...","url":"https://x.com/.../status/<id>","body":"...","views":N},
      {"label":"Independent","handle":"...","url":"...","body":"...","views":N},
      {"label":"Democrat","handle":"...","url":"...","body":"...","views":N}
    ]
  },
  ...
]

CRITICAL:
- "views" field on each event MUST be the actual integer view count of the lead post. NEVER 0 or null.
- "perspectives" may be 0, 1, 2, or 3 items long. Empty is OK if no reactions exist.
- MERGE DUPLICATES: if multiple tweets cover the same event, return ONE event with consolidated perspectives.
- All URLs must be real x.com/handle/status/numeric_id from x_search. Never fabricate.
PROMPT

# --- ELON ---
cat > /tmp/grok_p_elon.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.

⚠️ ELON-TAB OVERRIDE: The system prompt above contains rules for editorially-curated news tabs. The Elon tab is DIFFERENT — it's a chronological dump of his account. The following system-prompt rules DO NOT APPLY to this tab:
  - "Context-less replies" rejection — IGNORE. Keep bare replies like "Yes", "True", "Accurate", "💯", "Literally". They're his actual posts.
  - "Each pick must have honesty score, notes" — IGNORE. Honesty/notes are OPTIONAL here.
  - "Hard Rejections" list — IGNORE most. Only marketing-voice promo posts are rejected.
  - "Screenshot test" / "fascinatingly interesting" — IGNORE. Keep every post, fascinating or not.
  - "Pure views spec / 8-10 candidates" — IGNORE. No top-N cap. Return ALL his 24h posts.

⚠️ TWO HARD REQUIREMENTS for the BLOCK to make sense:
  1. **headline** field is REQUIRED for every post — a 1-line summary of what the post is ABOUT (not a copy of the body). Examples:
     - Reply "Same" to @SethDillon → headline: "Agrees with Seth Dillon's take on [topic]"
     - Reply "True" to @WashingtonPost → headline: "Calls WaPo report accurate on [topic]"
     - Bare image post → headline must describe WHAT THE IMAGE SHOWS: "Posts photo of SpaceX engine test fire" / "Shares satellite image of Iran nuclear site". NEVER just "Posts photo" or "Shares an image".
     - Link-only post (just a t.co URL) → headline must describe WHAT THE LINK IS ABOUT, not "Shares a link". Open the link via x_search context to find what it points to, then summarize the destination.
     - Video repost → headline must describe what the video shows.
     - Original take → headline: "Elon predicts [X]" or "Comments on [event]"
     The frontend uses this headline as the block title — "Same" or "Shares a link" alone is useless to readers.
  2. **For REPLIES**: populate parent_url + parent_handle + parent_text so the parent tweet embeds inline above the reply. Without these, the reader sees Elon saying "True" with no idea what he's responding to.
     - parent_url: full https://x.com/handle/status/id of the post he's replying to
     - parent_handle: @handle of parent author
     - parent_text: verbatim text of parent (≤280 chars)
     If you genuinely can't find parent context for a reply, you may still return the post — but populate at minimum the `headline` so the block isn't blank.

MISSION: Return EVERY @elonmusk post + reply + retweet + quote-tweet from the LAST 24 HOURS, except posts in a marketing/selling voice about his companies.

NO TOP-N CAP. Elon posts 20-60 times per day. EXPECT 15-50 entries.
If you return fewer than 10 you are likely missing posts — search more aggressively.

SEARCH:
- mode:"Latest" "from:elonmusk" since:24h ago, limit:100, no min_faves floor
- mode:"Latest" "from:elonmusk filter:replies" since:24h ago, limit:100
- Combine, dedupe by URL, drop marketing posts per below, sort newest first.

KEEP (everything substantive — including content ABOUT his companies):
- Political takes, policy commentary, election/government commentary
- News, earnings, test results about his companies (Tesla earnings, Starship test outcome, xAI research, X platform stats)
- His own criticism, technical analysis, contrarian commentary about his products
- Cultural / current-events / demographics / AI-policy commentary
- Replies and quote-tweets — original or with parent reference, doesn't matter
- Hot takes, predictions, jokes, satire with a point
- Bare reactions ("true", "lol", emojis) are FINE — keep them

DROP ONLY MARKETING/SELLING-VOICE PROMO:
- "Preorder Cybertruck today" / "Pre-order now"
- "Try X Premium" / "Subscribe to ..." / "Get it on the X app"
- "FSD available in your area" / "Now shipping" / "On sale this weekend"
- "Starlink subscriptions now open"
- "Launching today, get it now"
- Pure product-launch ads in selling tone

Sales-tone test: does the post READ LIKE AN AD or a press release marketing a product? If yes → DROP. If it's news, criticism, test results, earnings, technical commentary, or anything substantive — even about his own companies — KEEP.

APPROVED HANDLE: @elonmusk only. Each post must have a unique URL.

OUTPUT — every post needs the contextual fields so the block makes sense:
{"elon":[
  {
    "handle":"@elonmusk",
    "url":"https://x.com/elonmusk/status/<id>",
    "headline":"1-line summary of what this post is about (REQUIRED — not a copy of body)",
    "body":"actual post text verbatim (even if just 'Yes' or '💯')",
    "views":1234567,
    "parent_url":"https://x.com/<original_author>/status/<id> (REQUIRED for replies)",
    "parent_handle":"@original_author (REQUIRED for replies)",
    "parent_text":"verbatim parent text ≤280 chars (REQUIRED for replies)"
  },
  ...
]}

A good entry — Elon replied "Same" to Seth Dillon's tweet about media coverage:
{
  "handle":"@elonmusk",
  "url":"https://x.com/elonmusk/status/2055...",
  "headline":"Agrees with Seth Dillon that mainstream media downplays the story",
  "body":"Same",
  "views":51000,
  "parent_url":"https://x.com/SethDillon/status/2054...",
  "parent_handle":"@SethDillon",
  "parent_text":"Notice how the same outlets that obsessed over [X] are now silent on [Y]..."
}

A bad entry (what you've been returning) — DON'T do this:
{
  "handle":"@elonmusk",
  "url":"https://x.com/elonmusk/status/2055...",
  "headline":"Same",
  "body":"Same",
  "views":51000
}
The reader sees "Same" as the block title with no context. Useless.
PROMPT

# --- ALLIN (Ristretto-style — minimal prompt, no seed restriction) ---
cat > /tmp/grok_p_allin.txt <<PROMPT
Top 5 highest-view X posts (past 24h) from billionaire operators / All-In podcast hosts (Chamath, David Sacks, Marc Andreessen, Palmer Luckey, David Friedberg, etc.). Today is $TODAY.
Return ONLY a JSON array, no markdown, no prose.
STRICT RECENCY: use x_search operator since:$YESTERDAY. Reject anything before $YESTERDAY.

Each item:
{"handle":"username","url":"https://x.com/user/status/<id>","headline":"neutral one-line summary","body":"actual post text","engagement":"500K views","views":500000}
URLs MUST be real X status URLs from posts on or after $YESTERDAY. Views = actual view count integer.
PROMPT

# --- TOP VIRAL ---
cat > /tmp/grok_p_top.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: Find the 3 absolute most-viewed posts on ALL of X in the last 24h. By RAW VIEW COUNT, not engagement score.

CRITICAL: x_search's "Top" mode sorts by Twitter's black-box engagement score (likes+RTs+replies), NOT raw views. A 30M-view video clip with modest likes can be invisible behind a 100K-view text post with high engagement. To compensate, fire MULTIPLE searches with different angles, pool the candidates, then YOU re-sort by raw view count.

RUN ALL FOUR SEARCHES AND POOL CANDIDATES:
(a) "lang:en since:$TODAY", mode:"Top", limit:25 — accumulated viral
(b) "lang:en since:4_hours_ago min_faves:500", mode:"Latest", limit:25 — fresh viral that just broke
(c) "lang:en since:$TODAY filter:videos min_faves:200", mode:"Top", limit:25 — videos often 10M+ views with modest likes
(d) "lang:en since:$TODAY min_retweets:5000", mode:"Top", limit:25 — silent-viral content with high reach

Combine all candidates, dedupe by URL. Sort by RAW VIEW COUNT descending. Return the 3 highest by raw views. They can be any subject (news, meme, sports clip, viral moment, anything). NO editorial filter — pure views.

REQUIREMENTS:
- 3 DIFFERENT handles, 3 DIFFERENT events (no two posts about the same thing)
- Each must include a real integer "views" field from x_search's view_count

Body: 1 sentence, under 120 chars.
Honesty: 10=verified fact, 8=analysis/commentary, 7=opinion/take.
Return JSON: {"top":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"...","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# ============================================================================
# RISTRETTO-STYLE PROMPTS for non-perspectives, non-Elon tabs.
# Per user mandate 2026-05-22: "bring everything over to Ristretto code."
# Every tab below uses Ristretto's exact single-line prompt + JSON schema.
# Sports is the one exception: keep SAS + Cowherd guaranteed at the bottom.
# ============================================================================

# --- MSM ---
cat > /tmp/grok_p_msm.txt <<PROMPT
Top 5 highest-view X posts (past 24h) from mainstream-media accounts (NYT, WaPo, CNN, BBC, Reuters, AP, etc.). Today is $TODAY.
Return ONLY a JSON array, no markdown, no prose.
STRICT RECENCY: use x_search operator since:$YESTERDAY. Reject anything before $YESTERDAY.

Each item:
{"handle":"username","url":"https://x.com/user/status/<id>","headline":"neutral one-line summary","body":"actual post text","engagement":"500K views","views":500000}
URLs MUST be real X status URLs from posts on or after $YESTERDAY. Views = actual view count integer.
PROMPT

# --- BUSINESS ---
cat > /tmp/grok_p_business.txt <<PROMPT
Top 5 highest-view X posts (past 24h) about business / markets / finance / economy. Today is $TODAY.
Return ONLY a JSON array, no markdown, no prose.
STRICT RECENCY: use x_search operator since:$YESTERDAY. Reject anything before $YESTERDAY.

Each item:
{"handle":"username","url":"https://x.com/user/status/<id>","headline":"neutral one-line summary","body":"actual post text","engagement":"500K views","views":500000}
URLs MUST be real X status URLs from posts on or after $YESTERDAY. Views = actual view count integer.
PROMPT

# --- SPORTS (Ristretto-style top picks; SAS+Cowherd handled by separate sas_cowherd prompt) ---
cat > /tmp/grok_p_sports.txt <<PROMPT
Top 5 highest-view X posts (past 24h) about sports (major leagues, big games, athlete news). Today is $TODAY.
Return ONLY a JSON array, no markdown, no prose.
STRICT RECENCY: use x_search operator since:$YESTERDAY. Reject anything before $YESTERDAY.

Each item:
{"handle":"username","url":"https://x.com/user/status/<id>","headline":"neutral one-line summary","body":"actual post text","engagement":"500K views","views":500000}
URLs MUST be real X status URLs. Views = actual view count integer.
PROMPT

# --- SAS_COWHERD (dedicated fallback to guarantee Stephen A + Cowherd slots in Sports) ---
cat > /tmp/grok_p_sas_cowherd.txt <<PROMPT
Find TWO posts:
1. The most recent post from @stephenasmith (Stephen A Smith) — try x_search "from:stephenasmith" mode:Latest limit:10. Pick the newest non-promo one. If @stephenasmith has none in 3 days, try @firsttake.
2. The most recent post from @colincowherd (Colin Cowherd) — try x_search "from:colincowherd" mode:Latest limit:10. Pick the newest non-promo one. If @colincowherd has none in 3 days, try @TheHerd.

Today is $TODAY. Both can be up to 3 days old. Include their integer view counts.

Return ONLY a JSON array of 2 items (SAS first, Cowherd second), no markdown:
[
  {"handle":"stephenasmith","url":"https://x.com/.../status/<id>","headline":"neutral one-line summary","body":"actual post text","views":N},
  {"handle":"colincowherd","url":"https://x.com/.../status/<id>","headline":"neutral one-line summary","body":"actual post text","views":N}
]
URLs MUST be real X status URLs from those exact handles. Never fabricate.
PROMPT

# --- PODS ---
cat > /tmp/grok_p_pods.txt <<PROMPT
Top 5 highest-view X posts (past 24h) about or from major podcasters (Rogan, Lex Fridman, Theo Von, Tucker Carlson, PBD, etc.). Today is $TODAY.
Return ONLY a JSON array, no markdown, no prose.
STRICT RECENCY: use x_search operator since:$YESTERDAY. Reject anything before $YESTERDAY.

Each item:
{"handle":"username","url":"https://x.com/user/status/<id>","headline":"neutral one-line summary","body":"actual post text","engagement":"500K views","views":500000}
URLs MUST be real X status URLs from posts on or after $YESTERDAY. Views = actual view count integer.
PROMPT

# --- PG6 (Celebrity) ---
cat > /tmp/grok_p_pg6.txt <<PROMPT
Top 5 highest-view X posts (past 24h) about celebrity / entertainment / pop-culture news. Today is $TODAY.
Return ONLY a JSON array, no markdown, no prose.
STRICT RECENCY: use x_search operator since:$YESTERDAY. Reject anything before $YESTERDAY.

Each item:
{"handle":"username","url":"https://x.com/user/status/<id>","headline":"neutral one-line summary","body":"actual post text","engagement":"500K views","views":500000}
URLs MUST be real X status URLs from posts on or after $YESTERDAY. Views = actual view count integer.
PROMPT

# --- RECIPE ---
cat > /tmp/grok_p_recipe.txt <<PROMPT
Top 5 highest-view X posts (past 24h) about recipes / cooking / food. Today is $TODAY.
Return ONLY a JSON array, no markdown, no prose.
STRICT RECENCY: use x_search operator since:$YESTERDAY. Reject anything before $YESTERDAY.

Each item:
{"handle":"username","url":"https://x.com/user/status/<id>","headline":"neutral one-line summary","body":"actual post text","engagement":"500K views","views":500000}
URLs MUST be real X status URLs from posts on or after $YESTERDAY. Views = actual view count integer.
PROMPT

# --- SCIENCE ---
cat > /tmp/grok_p_science.txt <<PROMPT
Top 5 highest-view X posts (past 24h) about science / tech / research breakthroughs. Today is $TODAY.
Return ONLY a JSON array, no markdown, no prose.
STRICT RECENCY: use x_search operator since:$YESTERDAY. Reject anything before $YESTERDAY.

Each item:
{"handle":"username","url":"https://x.com/user/status/<id>","headline":"neutral one-line summary","body":"actual post text","engagement":"500K views","views":500000}
URLs MUST be real X status URLs from posts on or after $YESTERDAY. Views = actual view count integer.
PROMPT

# --- LOCAL ---
cat > /tmp/grok_p_local.txt <<PROMPT
Top 5 highest-view X posts (past 24h) about Southern California / Orange County / Newport Beach local news. Today is $TODAY.
Return ONLY a JSON array, no markdown, no prose.
STRICT RECENCY: use x_search operator since:$YESTERDAY. Reject anything before $YESTERDAY.
GEOGRAPHY: stories must be Newport Beach, Costa Mesa, Huntington Beach, Irvine, Laguna Beach, Corona del Mar, Balboa, Fountain Valley, or Tustin. NEVER generic LA County / Hollywood / federal political stories that just happen to be in California.

Each item:
{"handle":"username","url":"https://x.com/user/status/<id>","headline":"neutral one-line summary","body":"actual post text","engagement":"500K views","views":500000}
URLs MUST be real X status URLs from posts on or after $YESTERDAY. Views = actual view count integer.
PROMPT

# --- CONSPIRACY ---
cat > /tmp/grok_p_conspiracy.txt <<PROMPT
Top 5 highest-view X posts (past 24h) about conspiracies / under-reported stories / fringe theories. Today is $TODAY.
Return ONLY a JSON array, no markdown, no prose.
STRICT RECENCY: use x_search operator since:$YESTERDAY. Reject anything before $YESTERDAY.

Each item:
{"handle":"username","url":"https://x.com/user/status/<id>","headline":"neutral one-line summary","body":"actual post text","engagement":"500K views","views":500000}
URLs MUST be real X status URLs from posts on or after $YESTERDAY. Views = actual view count integer.
PROMPT

# --- COMEDY ---
cat > /tmp/grok_p_comedy.txt <<PROMPT
Top 5 highest-view X posts (past 24h) that are funny — jokes, memes, comedy clips going viral. Today is $TODAY.
Return ONLY a JSON array, no markdown, no prose.
STRICT RECENCY: use x_search operator since:$YESTERDAY. Reject anything before $YESTERDAY.

Each item:
{"handle":"username","url":"https://x.com/user/status/<id>","headline":"neutral one-line summary","body":"actual post text","engagement":"500K views","views":500000}
URLs MUST be real X status URLs from posts on or after $YESTERDAY. Views = actual view count integer.
PROMPT

# --- TIKTOK ---
# TikTok tab REMOVED (2026-05-05): user eliminated TikTok from tab roster long ago;
# this prompt + fetch_tiktok.py + tikwm scraper were leftover dead code.

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
  "model": "grok-4.3",
  "input": $(python3 -c "import json, sys; print(json.dumps(open('/tmp/grok_p_topic_lock.txt').read()))"),
  "tools": [{"type": "web_search"}],
  "max_output_tokens": 3000,
  "temperature": 0.0
}
JSONEOF

# Topic-lock is OPTIONAL — if it times out or fails, the world/usa prompts proceed
# without injected topic hints (the python parser below handles empty/error JSON).
# || true prevents `set -e` from aborting the whole pipeline on curl failure.
# Timeout bumped 120→180 to handle GitHub Actions IP latency to xAI.
curl -s --max-time 180 https://api.x.ai/v1/responses \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $XAI_API_KEY" \
    -d @/tmp/grok_topic_lock_payload.json > /tmp/grok_raw_topic_lock.json || \
    echo '{"error": "topic-lock curl failed or timed out — continuing without topic hints"}' > /tmp/grok_raw_topic_lock.json

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

CATEGORIES="world usa elon allin top msm business sports sas_cowherd pods pg6 recipe science local conspiracy comedy"

for cat in $CATEGORIES; do
    # All tabs run on grok-4.3. The world/USA prompts have been simplified so the
    # fast model handles them reliably (was hallucinating sequential snowflake IDs on
    # the prior 4000-token multi-step prompts).
    model="grok-4.3"
    echo "  Starting: $cat (model: $model)"
    grok_call "/tmp/grok_p_${cat}.txt" "/tmp/grok_raw_${cat}.json" "$model" &
done

# TikTok scraper REMOVED (2026-05-05) — tab eliminated from UI long ago.

echo "Waiting for all calls to complete..."
wait
echo "All calls done."

# ============================================================
# MERGE ALL 12 RESPONSES
# ============================================================
echo "Merging and validating..."

python3 <<'MERGE_EOF' > /tmp/grok_raw.json
import json, sys, re

CATEGORIES = 'world usa elon allin top msm business sports sas_cowherd pods pg6 recipe science local conspiracy comedy'.split()

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
                "model": "grok-4.3",
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

# Pull Netlify Form submissions into submissions.json BEFORE parse_grok runs.
# parse_grok._process_submissions reads submissions.json and populates the
# Post/Replace tab. Failures here are non-fatal — submissions just won't update.
echo "[pull-submissions] checking Netlify Form queue..."
python3 pull_netlify_submissions.py || echo "[pull-submissions] non-fatal failure, continuing"

XAI_API_KEY="$XAI_API_KEY" cat /tmp/grok_raw.json | XAI_API_KEY="$XAI_API_KEY" python3 parse_grok.py

if [ $? -ne 0 ]; then
    echo "ABORT: Validation failed. Old stories.json preserved."
    exit 1
fi

echo "Parse done."

# ============================================================
# CLAUDE CRITIC PASS — DISABLED (May 2026-05-04).
# User chose pure-views spec: no AI judgment layer over selection.
# curation.py is now the only selection authority. claude_critic.sh
# imposed taste judgments ("is this interesting?", "is this MSM-bait?")
# which is exactly the rat's nest we're escaping.
# ============================================================
# bash $SCRIPT_DIR/claude_critic.sh   # bypassed per user pure-views pick
echo "Claude critic: bypassed (pure views spec)"

# ============================================================
# CLAUDE QC PASS — gate deploy on quality checks
# ============================================================
# User mandate (2026-05-10): "Claude needs to do a full quality check and click on
# everything before final upload to website."
#
# claude_qc.sh enforces:
#   - World/USA/Local/Business floor of 3 stories each
#   - World/USA: every story has 3 perspectives
#   - Within-story URL uniqueness
#   - Every URL re-verified via oEmbed ("click everything")
#
# Exit non-zero = abort deploy, keep prior site live.
echo "Running Claude QC pass (mechanical pre-deploy verification)..."
if ! bash $SCRIPT_DIR/claude_qc.sh; then
    echo "[update.sh] ABORT: claude_qc.sh failed. Site NOT deployed. Prior version stays live."
    exit 1
fi

# Legacy qc_critic.sh — also disabled.
# bash $SCRIPT_DIR/qc_critic.sh

# DEPLOY via Netlify API
echo "Deploying via digest API..."
bash $SCRIPT_DIR/deploy.sh

echo "=== v4 Done ===" ; date
