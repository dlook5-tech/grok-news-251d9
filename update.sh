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
- Elon: return 15-20 candidates (Python takes top 10)
- World/USA: return 5-8 stories. Each story may have 1, 2, or 3 perspectives — ship whatever you find. Don't drop a high-view story because the third perspective is missing.
- Sports: return 8-10 candidates (Python takes top 3)

Each pick MUST have: url, handle, body, views, engagement, honesty score, notes (1-line on score).

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
  (a) substantive commentary body (≥30 chars, real analysis — not "🔥",
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
USER'S EXACT SPEC (2026-05-12) — FOLLOW THIS ORDER LITERALLY. DO NOT REORDER.

STEP 1. STORIES ONLY (no perspectives yet, no politics yet).
        x_search broadly for international news in the last 4 hours:
          "(international OR world OR foreign OR war OR conflict OR
            geopolitics OR Iran OR China OR Russia OR Ukraine OR
            Israel OR Europe OR Asia) lang:en since:4_hours_ago"
          mode:"Top", limit:50.
        Cluster the results BY EVENT (not handle). Identify the top 5-8
        events by total view count of their lead posts. **Do NOT look at
        political perspectives in this step.** This is purely "what are
        the biggest news events on X right now?"

STEP 2. PICK TOP 3 EVENTS BY VIEW COUNT.
        Of the 5-8 events from Step 1, take the 3 with the highest lead-post
        view counts. They must be 3 DIFFERENT subjects (no two framings of
        the same event).

STEP 3. *NOW* search for perspectives — one event at a time.
        For each of the 3 chosen events:
          (a) x_search "(event keywords) (republican OR conservative OR maga
              OR right) min_faves:1 lang:en" mode:Top, limit:30
              → take the highest-viewed conservative-leaning post.
          (b) x_search "(event keywords) (democrat OR liberal OR progressive
              OR left) min_faves:1 lang:en" mode:Top, limit:30
              → take the highest-viewed democrat-leaning post.
          (c) x_search "(event keywords) (analysis OR analyst OR independent
              OR centrist OR nonpartisan) min_faves:1 lang:en" mode:Top,
              limit:30 → take the highest-viewed independent post.
        If a side genuinely doesn't have a post on the event, OMIT THAT
        PERSPECTIVE. Ship the story with 1 or 2 perspectives — user
        explicitly said that's OK.

STEP 4. *THEN* for EACH chosen R/I/D post, find a QT/RT amplifier.
        For each perspective post, run:
          x_search "https://x.com/<handle>/status/<id>" mode:Top, limit:30
          x_search "<status_id>" mode:Top, limit:30
          x_search "<2-3 headline keywords> min_faves:1000" mode:Top, limit:30
              (catches pundit pile-ons — Posobiec/AOC/etc. who QT viral)
        If a QT/RT exists with substantive commentary (>=30 chars body, NOT
        just emoji or "🔥"):
          - swap "url" to the QT URL (Twitter embed shows the original
            quoted inside the QT — user sees both)
          - "handle" = QT author
          - "quote" = QT body (verbatim)
          - "views" = original_views + qt_views (COMBINED)
          - record "original_url", "original_handle", "original_views", "qt_views"
        If no QT meets the bar, return the original post as-is. No
        fabricated QT fields.

STEP 5. REJECT (drop the post, find a different one for that slot):
        - Bare announcements: handle in @WhiteHouse/@POTUS/@CBSNews/
          @NBCNews/@ABCNews/@AP/@Reuters/@nypost/@CNN/@FoxNews AND body
          starts with "BREAKING:"/"JUST IN:"/"NEW:" AND <60 chars after prefix
        - Video-with-few-words: <5 words AND <25 chars of real text body

Each perspective in the output MUST include:
  - "url": the post to display (QT URL if QT was used, else original)
  - "views": total score (original + QT views combined, if QT used)
  - "handle": author of the displayed post
  - "quote": body of the displayed post
  - "original_url" (only if QT used): the post the QT references
  - "original_views" (only if QT used): just-the-original view count
  - "qt_views" (only if QT used): just-the-QT view count


VIEWS REQUIREMENT (HARD CONTRACT):
- Each perspective MUST include `"views": <integer>` from x_search's view_count field
- If you cannot read views for a perspective, OMIT THAT PERSPECTIVE — do NOT omit the entire story
- Never fabricate a view count

CRITICAL — NO HALLUCINATION:
- URLs ONLY from x_search results, format https://x.com/HANDLE/status/NUMERIC_ID exactly as returned
- Verbatim tweet text only
- Never invent URLs, IDs, or handles

Return JSON only. **MUST contain at least 1 story** unless x_search returned literally zero approved-handle results in 24h:
{"world":[
  {"headline":"short topic","conservative":{"handle":"@x","quote":"verbatim","url":"...","views":1234567,"engagement":"47K likes, 12K retweets, 3.2K replies","honesty":"X/10","notes":"why this score"},"democrat":{...},"independent":{...},"footnotes":["why each","..."],"notes":"summary"},
  ...up to 3 stories
]}
PROMPT

# --- USA (national US news — 3-perspective like World) ---
cat > /tmp/grok_p_usa.txt <<'PROMPT'
USER'S EXACT SPEC (2026-05-11) — FOLLOW LITERALLY, ADD NOTHING:

STEP 1. Find the top 5-8 US national news stories (domestic politics, SCOTUS, Congress, federal policy). Identify which have the
        HIGHEST VELOCITY (most views in the last 4 hours). Curate the top 3
        and **make sure they're not about the same subject matter** (no two
        framings of the same event — e.g. don't return 3 Iran-ceasefire posts).

STEP 2. For EACH of the 3 topics, find the HIGHEST-VELOCITY coverage from
        each viewpoint:
          - Conservative viewpoint
          - Independent viewpoint
          - Democrat viewpoint

STEP 3. Once the (R, I, D) highest-velocity posts are found, go ONE STEP
        FURTHER: check if any commentator on that same side of the political
        spectrum has quote-tweeted/retweeted that post AND added substantive
        commentary (not just an emoji or "fire").
        - If YES, the QT/RT is the "perfect trifecta." Use the QT's URL
          (the embed shows both the original AND the new commentary).
        - Score the perspective as: original_views + QT_views (TOTAL).
        - Keep the QT's body as the displayed text.

STEP 4. Reject ANY post — original OR QT — with telltale signs of:
        - Announcements (e.g. "BREAKING:", "JUST IN:", "NEW:", press release)
        - Wire copy from @WhiteHouse, @POTUS, @CBSNews, @NBCNews, @ABCNews,
          @AP, @Reuters, @nypost, @CNN, @FoxNews when their body is just a
          headline restatement
        - Just a video clip with a few words ("Watch this", "Look at her",
          one-line captions on top of an attached video — under ~50 chars of
          text). User: "That's not interesting."

SEARCH SEEDS (NOT preferences — just where to start looking, pick by velocity):
  Conservative: @JackPosobiec, @Cernovich, @benshapiro, @DonaldJTrumpJr,
    @charliekirk11, @JDVance1, @SenTedCruz, @SenTomCotton, @JesseBWatters,
    @IngrahamAngle, @TuckerCarlson, @NEWSMAX, @FoxNews, @OANN, @BreitbartNews,
    @nypost
  Democrat: @AOC, @Ilhan, @RBReich, @BernieSanders, @RashidaTlaib,
    @ChrisMurphyCT, @SenWarren, @SenSchumer, @ProPublica, @MSNBC, @TheAtlantic,
    @MotherJones
  Independent / Analyst: @MattTaibbi, @bariweiss, @FareedZakaria, @ggreenwald,
    @semaforpolitics, @PunchbowlNews, @axios, @thehill, @SCOTUSblog, @Snowden,
    @RayDalio, @TheStudyofWar, @CNN, @Reuters

EXECUTION:
  a. x_search "(US politics, SCOTUS, Congress, Trump, federal policy, ICE, DOJ, FBI) lang:en since:4_hours_ago"
     mode:Top, limit:50 → identify candidate events.
  b. Cluster results by EVENT (not handle, not framing). Pick top 3 EVENTS
     by combined view count.
  c. For each event, run 3 sided searches (conservative/dem/indep keyword
     filters) → find the highest-viewed take from each side.
  d. For each chosen R/I/D post, look for QT/RTs of it with substantive bodies
     (>=30 chars of real commentary). If found, swap URL to the QT and report
     combined views (original + QT).
  e. Apply Step 4 rejects. If a slot fails after enrichment, find a different
     post for that slot.

Each perspective in the output MUST include:
  - "url": the post to display (QT URL if QT was used, else original)
  - "views": total score (original + QT views combined, if QT used)
  - "handle": author of the displayed post
  - "quote": body of the displayed post
  - "original_url" (only if QT used): the post the QT references
  - "original_views" (only if QT used): just-the-original view count
  - "qt_views" (only if QT used): just-the-QT view count

[OLD USA PROCESS BELOW — SUPERSEDED BY THE 4-STEP SPEC ABOVE]
Find the TOP 3 US NATIONAL news stories by views in the last 24 hours (domestic politics, SCOTUS, Congress, federal policy — NOT foreign affairs).

3-PERSPECTIVE REQUIREMENT (user 2026-05-11): "3 perspectives always, no 5k filter."
  - Each story MUST have 3 perspectives (Conservative + Independent + Democrat).
  - NO minimum view threshold per perspective. The highest-viewed take on
    that side wins, even if low. (Wire-copy filter still drops "BREAKING:"
    bare announcements from major news handles — but legitimate citizen
    posts at any view level qualify.)
  - If a topic truly can't have 3 perspectives (e.g., a side genuinely
    didn't comment), pick a different topic.

GOAL: 3 different stories, each with 3 perspectives. **DO NOT return fewer than 3 stories** unless x_search literally returns nothing for major news.

STARTING SEARCH SEEDS (use ONLY to find candidates — DO NOT prefer these handles. Final pick is purely by view count, regardless of who posted):
  Conservative (incl. mainstream conservative media): @JackPosobiec, @Cernovich, @RealCandaceO, @benshapiro, @DonaldJTrumpJr, @charliekirk11, @RealDailyWire, @JDVance1, @SenTedCruz, @SenTomCotton, @LindseyGrahamSC, @SecPompeo, @TomFitton, @JesseBWatters, @IngrahamAngle, @WhiteHouse, @MariaBartiromo, @SteveScalise, @SpeakerJohnson, @LeaderMcConnell, @NEWSMAX, @FoxNews, @OANN, @BreitbartNews, @nypost, @DailyCaller, @theblaze, @townhallcom, @washingtonexaminer
  Democrat (incl. left-leaning major media): @AOC, @Ilhan, @RBReich, @BernieSanders, @RashidaTlaib, @ChrisMurphyCT, @SenWarren, @JoyceWhiteVance, @ProPublica, @DropSiteNews, @SenSchumer, @SpeakerPelosi, @SenSanders, @repjayapal, @SenCoryBooker, @SenWhitehouse, @MSNBC, @TheAtlantic, @MotherJones, @TheNation, @NewYorker, @nytimes, @washingtonpost
  Independent/Analyst (centrist news + non-interventionist right + investigative): @TuckerCarlson, @MattTaibbi, @bariweiss, @FareedZakaria, @semaforben, @axios, @thehill, @mediaite, @PunchbowlNews, @semaforpolitics, @SCOTUSblog, @KimZetter, @Snowden, @ggreenwald, @InsightGL, @TheStudyofWar, @CNN, @Reuters, @AP

If a handle isn't on the list but is clearly a major news outlet you can correctly classify (e.g. you know its editorial slant from training), you may include it — but ONLY if you would stake your accuracy on the classification. When in doubt, stick to the list.

PROCESS (find topics that have all 3 perspectives — this is HARDER but required):
1. x_search broadly: "(politics OR Congress OR SCOTUS OR Trump OR Senate OR DOJ OR FBI OR ICE OR \"White House\") lang:en since:$YESTERDAY", mode:Top, limit:50
2. From results, identify candidate topics with high view counts.
3. For each candidate topic, run THREE focused searches — one per perspective:
   a. Conservative search: "(topic_keywords) (from:JackPosobiec OR from:WhiteHouse OR from:SenTomCotton OR from:JesseBWatters OR ...) since:$YESTERDAY", mode:Top
   b. Democrat search: "(topic_keywords) (from:AOC OR from:RBReich OR from:BernieSanders OR from:SenWarren OR ...) since:$YESTERDAY", mode:Top
   c. Independent search: "(topic_keywords) (from:axios OR from:thehill OR from:semaforpolitics OR from:MattTaibbi OR from:FareedZakaria OR ...) since:$YESTERDAY", mode:Top
4. ONLY ship a topic if all 3 searches return a viable post with a real /status/ URL and view_count.
5. If a topic only has 1 or 2 perspective slots filled, **DROP IT and try a different topic.** Repeat until you find topics with full 3-perspective coverage.
6. **Centrist news outlets (@axios, @thehill, @semaforpolitics, @PunchbowlNews, @mediaite) post about EVERY major US politics story** — they are the easiest way to fill the Independent slot. Use them aggressively when you can't find a substantive opinion-side independent.

VIEWS REQUIREMENT (HARD CONTRACT):
- Each perspective MUST include `"views": <integer>` from x_search's view_count field
- If you cannot read views for a perspective, find a different post for that slot — do not skip the perspective
- Never fabricate a view count

CRITICAL — NO HALLUCINATION:
- URLs ONLY from x_search results, format https://x.com/HANDLE/status/NUMERIC_ID
- Verbatim tweet text only
- Never invent URLs, IDs, or handles

Return JSON only. **MUST contain at least 1 story** with all 3 perspectives. If you genuinely cannot find ANY topic with 3-perspective coverage after a thorough search, return at least the BEST attempt as a single-story array — the empty array is the worst possible outcome:
{"usa":[
  {"headline":"short","conservative":{"handle":"@x","quote":"verbatim","url":"...","views":1234567,"engagement":"47K likes","honesty":"X/10","notes":"why this score"},"democrat":{...},"independent":{...},"footnotes":[...],"notes":"..."},
  ...up to 3 stories
]}
PROMPT

# --- ELON ---
cat > /tmp/grok_p_elon.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION (UPDATED 2026-05-11): Return EVERY Elon post and reply from the LAST 4 HOURS that isn't self-promotion of his companies. Python merges these fresh posts into the existing 24h rolling list (newest prepended chronologically; anything past 24h ages out).
- If Elon hasn't posted in the last 4h, return an empty array. The tab will stay unchanged.
- Do NOT pad with older posts to "fill" — Python handles continuity.
- No top-N cap. Return ALL non-promo posts/replies he made in the last 4h, even if there are 10.

INCLUDE (one block per qualifying post):
- Political takes, policy commentary, election/government posts
- Quote-tweets / replies on news stories (with parent visible)
- Contrarian observations on culture, society, demographics, AI policy
- Sharp critiques of media, journalists, MSM, government agencies
- Policy predictions, geopolitical commentary, foreign affairs
- Satire / humor with a substantive point
- Replies to other public figures with insight (when reply restates context)
- Comments on someone else's reporting / leak / investigation
- Reactions to current events that go beyond emoji or single-word

EXCLUDE — ABSOLUTE NO-PROMO RULE (user mandate 2026-05-10 evening):
"No promo post like Drake's. Post everything except posts where he's marketing
one of his companies."
- Tesla / Cybertruck / Model Y / FSD / Optimus / Roadster announcements (DROP)
- SpaceX / Falcon 9 / Starship / Starlink launch updates (DROP)
- xAI / Grok / Colossus product news (DROP)
- X platform / X Premium / X feature marketing (DROP)
- Boring Company / Neuralink product news (DROP)
- ANY post that promotes/markets his companies (DROP) — even if substantive,
  even if quote-tweeting praise, even if announcing new feature
- Pure text replies WITHOUT visible parent context (DROP)
- One-word reactions, emoji-only ("true", "agreed", "🔥") (DROP)

WINDOW — LAST 4 HOURS ONLY (user mandate 2026-05-11):
"post all of his posts and replies for that four-hour span, only removing
tweets where he's promoting one of his companies. If nothing has been posted
by Elon in that four-hour window, then everything should remain unchanged on
the tab."

Python merges these fresh posts into a rolling 24h list (newest prepended,
anything past 24h ages out). YOUR job here is JUST the fresh-4h fetch.

APPROVED HANDLE: @elonmusk only. Each post must be a DIFFERENT URL.

SEARCH:
1. PRIMARY: mode:"Latest" "from:elonmusk" — return everything he's posted
   in the last 4 hours (filter on your end by created_at if needed; only
   include posts ≤4h old). Limit 50, no min_faves floor.
2. INCLUDE REPLIES: Elon's replies count. Search "from:elonmusk
   filter:replies" or simply include replies in the primary search results.

RETURN POLICY:
- If he posted ≥1 non-promo post/reply in last 4h → return them ALL.
- If he posted 0 in last 4h → return empty array []. Python will keep the
  existing tab unchanged.
- Sort the returned posts chronologically NEWEST FIRST (Python re-sorts but
  consistency helps).

POST TYPE GUIDANCE (Elon tab — no preference between originals and quote-tweets, judge each on its own merits):
1. **Original substantive posts** (predictions, announcements, contrarian observations) — kept.
2. **Quote-tweets** with commentary — kept. Twitter's embed renders the parent post inline.
3. **REPLIES ARE OK** if you populate parent_url / parent_handle / parent_text (see system prompt). The frontend will render the parent post embed ABOVE the reply so readers see the conversation. Without parent_url, drop the post.
4. **REJECT: Pure ads / Tesla/X marketing** ("Try X Premium today!") — boring corporate.

CRITICAL — RENDERED CARD TEST: The site renders posts via Twitter's oEmbed. For pure replies, the embedded card shows ONLY the reply text — NOT the parent tweet that Elon is responding to. So even if YOU know what he's replying to (from your search results), the READER will see only Elon's words. Apply the test: if the reply text alone, in isolation, would not make sense to a reader who has no context, REJECT. Examples to REJECT:
- "Might actually happen" (replying to a Newsom satire video — reader has no clue what)
- "True" (replying to a claim — reader has no clue what claim)
- "This is how an economy actually works" replying to a French parent that's not auto-translated — reader sees French
- Any reply where you wrote a body like "Replying to X about Y" — that body context isn't shown to the reader; only the bare tweet text is shown via oEmbed embed

Rule of thumb: if you find yourself writing "Replying to..." in the body field, the post FAILS the test. Skip it.

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
Return JSON: {"elon":[{"headline":"...","handle":"@elonmusk","body":"...","views":1234567,"engagement":"147K likes, 22K retweets, 8K replies","url":"...","honesty":"X/10","notes":"why this score"},...]}
PROMPT

# --- ALLIN ---
cat > /tmp/grok_p_allin.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: Find the 3 MOST THOUGHT-PROVOKING posts from billionaire operators — ORIGINAL INSIGHT, contrarian takes, deep framing. NOT generic "interesting" or "agree" reactions.

STARTING SEARCH SEEDS (use ONLY to find candidates — DO NOT prefer these handles. Final pick is purely by view count, regardless of who posted):
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

Pick 3 posts from 3 DIFFERENT handles — strongest ORIGINAL INSIGHT (highest combined likes+retweets+replies among substantive posts) from each.
Body: 1 sentence, under 120 chars.
Engagement field MUST contain real numbers (e.g. "5.2K likes, 800 retweets, 200 replies").
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Notes: say "Fact" or "Opinion" and call out any specific lies.
Return JSON: {"allin":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"5.2K likes, 800 retweets, 200 replies","url":"...","honesty":"X/10","notes":"..."},...]}
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
Return JSON: {"top":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"...","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- MSM ---
cat > /tmp/grok_p_msm.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: Stories blowing up on X that MSM is IGNORING or UNDERREPORTING — the juicier, more suppressed the better. Prefer NOVEL ANGLES, exposé-style reporting, undercover footage, data that contradicts official narratives.

STARTING SEARCH SEEDS (use ONLY to find candidates — DO NOT prefer these handles. Final pick is the most viral recipe, regardless of who posted):
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

PICK 3 posts from 3 DIFFERENT handles — HIGHEST ENGAGEMENT post from each. Verify the 3 handles are not identical before returning.

Body: 1 sentence, under 120 chars.
Engagement field MUST contain real numbers (e.g. "47K likes, 12K retweets, 3.2K replies").
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Notes: say "Fact" or "Opinion" and call out any specific lies.
Return JSON: {"msm":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"47K likes, 12K retweets, 3.2K replies","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- BUSINESS ---
cat > /tmp/grok_p_business.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: 3 MOST THOUGHT-PROVOKING business/markets posts. Original analysis, contrarian calls, macro insight, hidden story behind the numbers — NOT generic "stocks up today" headlines.

STARTING SEARCH SEEDS (use ONLY to find candidates — DO NOT prefer these handles. Final pick is purely by view count, regardless of who posted):
@DowdEdward, @RayDalio, @Stocktwits, @StockMKTNewz, @WatcherGuru, @unusual_whales, @TruthGundlach, @LizAnnSonders, @elerianm

Must be stocks, markets, finance, crypto, deals, or macro. NOT geopolitics/military.
Search mode: "Latest" with insight keywords:
"(from:unusual_whales OR from:WatcherGuru OR from:StockMKTNewz OR from:RayDalio OR from:LizAnnSonders OR from:elerianm OR from:Stocktwits OR from:DowdEdward OR from:TruthGundlach) (insight OR analysis OR \"hot take\" OR contrarian OR \"why this matters\" OR underrated OR \"what nobody is saying\") since:$YESTERDAY min_faves:100", mode: "Latest", limit: 20.
ALSO search mode: "Top": "(from:unusual_whales OR from:WatcherGuru OR from:StockMKTNewz OR from:RayDalio OR from:LizAnnSonders OR from:elerianm OR from:DowdEdward OR from:TruthGundlach) since:$YESTERDAY min_faves:500", limit: 15.
FALLBACK: If <3, retry with min_faves:50.

QUALITY BAR: pick posts with data + opinion, contrarian call, or macro framing. REJECT bare earnings numbers, price-only posts, or "line go up" cheerleading.

POLITICAL CONTENT REJECTION (HARD RULE): Business is markets/finance/macro ONLY. REJECT any post that is:
- A political proposal, voting rights debate, immigration policy, social policy
- A politician praising/criticizing another politician
- A media outlet quoting a politician on policy (TIME on Washington, etc.)
- An MSM-quote about "what most Americans think" of policy
- Any content where the primary subject is partisan politics rather than markets/business
If the topic is political, it belongs in the USA tab (which has 3-perspective format with Conservative/Democrat/Independent), NOT business. Single-perspective political content is explicitly forbidden — the user wants balance on every political story.

QUOTED-MSM REJECTION: REJECT any post whose body is primarily a quoted passage from TIME, NY Times, WaPo, Washington Post, NPR, Reuters, AP, etc. (look for "per TIME" / "per NYT" / "per WaPo" patterns or text that opens with a quote). These are amplifications, not analysis.

Pick 3 posts from 3 DIFFERENT handles — STRONGEST INSIGHT (highest combined likes+retweets+replies) per handle.
Body: 1 sentence, under 120 chars.
Engagement field MUST contain real numbers (e.g. "12K likes, 3K retweets, 800 replies").
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Notes: say "Fact" or "Opinion" and call out any specific lies.
Return JSON: {"business":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"12K likes, 3K retweets, 800 replies","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- SPORTS ---
cat > /tmp/grok_p_sports.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.

STARTING SEARCH SEEDS (use ONLY to find candidates — DO NOT prefer these handles. Final pick is the most viral recipe, regardless of who posted):
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
Return JSON: {"sports":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"...","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- PODS ---
cat > /tmp/grok_p_pods.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
CRITICAL MISSION: Find the 3 MOST VIRAL podcast clip moments on X right now. The user specifically complains that we've been returning mediocre clips — they want MASSIVELY VIRAL moments (100K+ views, 5K+ likes minimum for major podcasts, or peak engagement for the day).

STARTING SEARCH SEEDS (use ONLY to find candidates — DO NOT prefer these handles. Final pick is the most viral clip, regardless of which show):
@joerogan, @joeroganhq, @JREClips, @TuckerCarlson, @theallinpod, @lexfridman, @fridmanclips, @CallHerDaddy, @adamcarolla, @PBDPodcast, @patrickbetdavid, @ShawnRyanShow, @MegynKellyShow, @LouderWithCrowder, @RussellBrand

A clip is a 30-sec to 3-min specific moment that went viral. NOT a full-episode announcement.

FRESHNESS REQUIREMENT (user mandate 2026-05-10 evening):
"Are you telling me there's no other podcast posts today?" — when prior crons
returned 25h+ clips, the user pushed back hard. Search MUST find clips ≤12h
old as the primary target. Only fall back to 24h if 12h truly empty. NEVER
return clips ≥24h old — parse_grok will drop them anyway and the tab goes
empty.

PRIMARY SEARCH (mode:Latest first — fresh clips that haven't accumulated likes yet):
"(from:joerogan OR from:joeroganhq OR from:JREClips OR from:TuckerCarlson OR from:lexfridman OR from:fridmanclips OR from:theallinpod OR from:CallHerDaddy OR from:adamcarolla OR from:PBDPodcast OR from:patrickbetdavid OR from:ShawnRyanShow OR from:MegynKellyShow OR from:LouderWithCrowder OR from:RussellBrand) lang:en", mode: "Latest", limit: 50

SECONDARY (mode:Top for accumulated engagement on 12-24h-old clips):
"(from:joerogan OR from:joeroganhq OR from:JREClips OR from:TuckerCarlson OR from:lexfridman OR from:fridmanclips OR from:theallinpod OR from:CallHerDaddy OR from:adamcarolla OR from:PBDPodcast OR from:patrickbetdavid OR from:ShawnRyanShow OR from:MegynKellyShow OR from:LouderWithCrowder OR from:RussellBrand) lang:en since:$YESTERDAY min_faves:100", mode: "Top", limit: 30

LOWERED min_faves to 100 (was 300-500): high thresholds biased toward older
accumulated-engagement posts and missed fresh clips. Lower bar lets recent
viral content through. The dedup + Python-side curation handles quality.

SUPPLEMENT — per-show fresh search:
"from:JREClips OR from:joerogan OR from:joeroganhq", mode: "Latest", limit: 15
"from:theallinpod", mode: "Latest", limit: 15
"from:TuckerCarlson", mode: "Latest", limit: 15
"from:PBDPodcast OR from:patrickbetdavid", mode: "Latest", limit: 15
"from:fridmanclips OR from:lexfridman", mode: "Latest", limit: 15
"from:ShawnRyanShow OR from:MegynKellyShow OR from:RussellBrand OR from:adamcarolla OR from:LouderWithCrowder OR from:CallHerDaddy", mode: "Latest", limit: 25

CRITICAL: prefer ANY fresh clip (≤12h) over older ones (12-24h). A 5h-old
clip with 50 likes BEATS a 23h-old clip with 5000 likes.

FILTERING: REJECT "new episode", "full interview", "full episode", "out now", "tune in", "dropping soon". KEEP specific-moment headlines — someone saying something shocking, a host reaction, a heated exchange, a reveal.

DIVERSITY REQUIREMENT: Each of the 3 selections MUST be from a DIFFERENT podcast/show. No two clips from the same show/handle.

FALLBACK 1: If <3 after above, lower thresholds by half.
FALLBACK 2: If still <3, broaden to last 48 hours (not 24).

Pick 3 from DIFFERENT approved shows — the 3 HIGHEST-ENGAGEMENT (combined likes+retweets+replies) CLIP moments.
Body: 1 sentence describing the specific moment (what was said/happened), under 120 chars. Do NOT describe the episode generally.
Engagement field MUST contain real numbers (e.g. "47K likes, 8K retweets, 3K replies").
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Notes: say "Fact" or "Opinion" and call out any specific lies.
Return JSON: {"pods":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"47K likes, 8K retweets, 3K replies","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- PG6 (Celebrity) ---
cat > /tmp/grok_p_pg6.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: JUICIEST celebrity gossip — SURPRISING reveals, dramatic takes, "wait, what?" moments. NOT red-carpet appearances or generic promo.

STARTING SEARCH SEEDS (use ONLY to find candidates — DO NOT prefer these handles. Final pick is purely by view count, regardless of who posted):
@PopCrave, @enews, @JustJared, @etnow, @TMZ, @DeuxMoi, @PageSix, @Variety

Search mode: "Latest" for fresh + juicy:
"(from:PopCrave OR from:TMZ OR from:DeuxMoi OR from:enews OR from:JustJared OR from:PageSix OR from:Variety OR from:etnow) since:$YESTERDAY min_faves:500", mode: "Latest", limit: 20.
ALSO search mode: "Top" for highest-engagement: "(from:PopCrave OR from:TMZ OR from:DeuxMoi OR from:etnow) since:$YESTERDAY min_faves:1000", limit: 15.
FALLBACK: If <3 strong picks, retry with min_faves:200.

QUALITY BAR: unexpected reveals, dramatic feuds, surprise engagements/breakups, cryptic posts that went viral, specific quotes from celebs. REJECT magazine-cover announcements and PR-rep releases.

CRIME-BLOTTER REJECTION (HARD RULE): SKIP all sensationalized violent crime posts. This includes:
- Graphic murder details, dismemberment, body disposal
- Crime against minors with explicit details
- "TERRIFYING:", "🚨 DISTURBING:", "ASSUSTADOR:" framing of violent crime
- Mugshot + victim photo combo posts
- Any post whose primary content is a violent crime accusation against a person
The user is explicit: NO crime-blotter content on Pg.6. Pick redemption stories, dramatic feuds, surprise reveals, cultural moments, fashion drama instead.

ENGLISH-ONLY: All posts must be in English OR have a complete English translation in the "translation" field. NO untranslated foreign-language content. If a post body is in Portuguese/Spanish/French/etc and you can't translate, SKIP it.

Pick the 3 HIGHEST-ENGAGEMENT (combined likes+retweets+replies) UNEXPECTED/dramatic celebrity posts. 3 DIFFERENT handles.
Body: 1 sentence, under 120 chars.
Engagement field MUST contain real numbers (e.g. "47K likes, 8K retweets, 3K replies").
Honesty: 10=verified fact, 9=fact with minor editorializing, 8=fact+opinion mix, 7=opinion/prediction/take. Notes: say "Fact" or "Opinion" and call out any specific lies.
Return JSON: {"pg6":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"47K likes, 8K retweets, 3K replies","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- RECIPE ---
cat > /tmp/grok_p_recipe.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
Actual FOOD RECIPES you can cook. NOT product lists, NOT gadget ads.

STARTING SEARCH SEEDS (use ONLY to find candidates — DO NOT prefer these handles. Final pick is purely by view count, regardless of who posted):
@tasteofhome, @FoodNetwork, @thekitchn, @HBHarvest, @halfbakedharvest, @foodandwine, @tasty, @KitchenSanc2ary, @budgetbytes, @BonAppetit, @RecipeTinEats

Search 1: "from:FoodNetwork OR from:tasty OR from:halfbakedharvest OR from:HBHarvest OR from:budgetbytes OR from:foodandwine since:$YESTERDAY", mode: "Top", limit: 15.
Search 2: "from:tasteofhome OR from:KitchenSanc2ary OR from:thekitchn OR from:BonAppetit OR from:RecipeTinEats since:$YESTERDAY", mode: "Top", limit: 15.
FALLBACK: If <3 strong picks, retry with last 3 days.
Body must name the dish. Skip non-recipe posts.
Body: 1 sentence, under 120 chars.
Engagement field MUST contain real numbers (e.g. "5K likes, 1K retweets, 200 replies").
Return JSON: {"recipe":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"5K likes, 1K retweets, 200 replies","url":"...","honesty":"10/10","notes":"..."},...]}
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
Return JSON: {"science":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"...","url":"...","honesty":"X/10","notes":"..."},...]}
PROMPT

# --- LOCAL ---
cat > /tmp/grok_p_local.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.

THE QUALITY MODEL — DAILY PILOT (https://www.dailypilot.com/)
The user's exact guidance: "Go look at the Daily Pilot, it's the Newport Beach community paper. Look at the stories — that's the model for what to look for."

Use web_search FIRST: "site:dailypilot.com" or visit dailypilot.com to see what types of stories are running THIS WEEK. Then find X posts that cover the SAME categories of stories. The Daily Pilot covers:
- Newport Beach / Costa Mesa / Huntington Beach / Irvine / Laguna Beach city government (council meetings, mayor, planning commission, school board votes)
- Local crime blotter (NBPD, OCSD reports — non-graphic, just specific incidents)
- High school sports (Corona del Mar, Newport Harbor, Sage Hill, Estancia, etc.)
- Local business openings/closings (restaurants, retail, small business stories)
- Beach conditions, surf reports, water quality, ocean life
- Real estate / housing development / zoning
- Restaurant reviews and food scene
- Community events (Newport Beach Film Festival, Boat Parade, Concerts on the Green)
- Local non-profits and charities
- Specific people (mayors, council members, school principals, business owners, athletes)
- Traffic / road closures specific to OC

GEOGRAPHY RULE (STRICT): Stories MUST be Newport Beach, Costa Mesa, Huntington Beach, Irvine, Laguna Beach, Corona del Mar, Balboa, Fountain Valley, Tustin. NEVER:
- Generic LA County (Compton, Watts, downtown LA, Hollywood) unless directly affects OC
- Political marches, labor rallies, protests anywhere
- LA-wide breaking-news tickers
- Federal political stories that just happen to be in California

STARTING SEARCH SEEDS (use ONLY to find candidates — DO NOT prefer these handles. Final pick is purely by view count, regardless of who posted):
@DailyPilot, @OC_Scanner, @OCRegister, @NBPDsocial, @CityofNewportBeach, @hbpd, @CityofHB, @cityofIrvine, @CMPD_NewsInfo, @oclnews, @CdMHigh, @newportharborhs

PRIORITY ORDER:
1. @DailyPilot direct posts — these ARE the model
2. @OC_Scanner / @NBPDsocial / @hbpd for incidents
3. @OCRegister for OC-wide stories
4. @CityofNewportBeach / @cityofHB / @cityofIrvine for civic news

Search:
"from:DailyPilot since:$YESTERDAY", mode: "Top", limit: 20
"from:OC_Scanner OR from:OCRegister OR from:NBPDsocial OR from:CityofNewportBeach OR from:hbpd OR from:CityofHB since:$YESTERDAY", mode: "Top", limit: 20
"(\"Newport Beach\" OR \"Costa Mesa\" OR \"Huntington Beach\" OR \"Corona del Mar\" OR Irvine OR Laguna) since:$YESTERDAY min_faves:50", mode: "Top", limit: 20

FALLBACK: If <3 fresh OC stories, broaden to last 3 days from same handles. Better to have a 2-day-old Newport Beach city council vote than a fresh LA story.

THE TEST: "Would the Daily Pilot run this story?" If yes — pick it. If no (because it's LA, federal, partisan rant, MSM-bait) — skip it.

Body: 1 sentence describing the specific local story, under 140 chars. Name the city, the people, or the place.
Engagement field MUST contain real numbers (e.g. "1.2K likes, 200 retweets, 50 replies").
Return JSON: {"local":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"1.2K likes, 200 retweets, 50 replies","url":"...","honesty":"10/10","notes":"..."},...]}
PROMPT

# --- CONSPIRACY ---
cat > /tmp/grok_p_conspiracy.txt <<PROMPT
Current date: $TODAY. Yesterday: $YESTERDAY.
MISSION: 3 posts going DEEP behind the biggest stories of the day — investigative threads, suppressed angles, undercover footage, court documents, document dumps, FOIA results, contradictions in official narratives, things mainstream media is NOT asking. The vibe is "in search of the truth behind the biggest stories."

STARTING SEARCH SEEDS (use ONLY to find candidates — DO NOT prefer these handles. Final pick is purely by view count, regardless of who posted):
@JackPosobiec, @JamesOKeefeIII, @TomFitton, @WallStreetApes, @TheRabbitHole84, @CollinRugg, @libsoftiktok, @EndWokeness, @DropSiteNews, @Snowden, @ggreenwald, @ProPublica, @KimZetter, @disclosetv, @megynkelly, @SecularTalk, @MariaBartiromo, @JulianAssange, @BillMelugin_

QUALITY BAR — what counts as a "conspiracy / truth-behind" post:
- Investigative threads with specific evidence (documents, video, leaked memos)
- Undercover footage (Project Veritas style)
- Documented contradictions between official narrative and evidence
- FOIA results, court filings, financial disclosures revealing things
- Suppressed angles on viral stories ("the part nobody is talking about")
- Specific people, places, dates, dollar amounts — NOT vague "they don't want you to know"
- Tied to a CURRENT BIG STORY — not random rabbit holes

REJECT:
- Pure rant / "wake up sheeple" with no evidence
- Vague "they're hiding something" without specifics
- UFO / Bigfoot / aliens unless tied to actual document release
- Anti-vax / flat earth — those are old conspiracies, not "truth behind today's stories"
- Content older than 6 hours (must be tied to current news cycle)
- MSM amplification ("per CNN") — these are people DOING reporting MSM isn't doing

Search:
"(from:JackPosobiec OR from:JamesOKeefeIII OR from:TomFitton OR from:WallStreetApes OR from:TheRabbitHole84 OR from:CollinRugg OR from:libsoftiktok OR from:EndWokeness OR from:DropSiteNews OR from:Snowden OR from:ggreenwald OR from:ProPublica OR from:KimZetter OR from:disclosetv OR from:BillMelugin_) since:$YESTERDAY min_faves:1000", mode: "Top", limit: 30
FALLBACK 1: If <3 strong picks, drop to min_faves:500.
FALLBACK 2: Add "(receipts OR documents OR leaked OR exposed OR investigation OR FOIA OR \"court filing\")" to narrow toward actual evidence-based posts.

Pick 3 from 3 DIFFERENT approved handles — strongest evidence/investigation posts.
Body: 1 sentence naming the SPECIFIC angle being investigated, under 140 chars.
Engagement field MUST contain real numbers (e.g. "12K likes, 3K retweets, 800 replies").
Honesty: score on the specific evidence presented. Score-with-evidence = 8-10. Pure speculation = 4-6. Conspiracy without specifics = 2-3.
Return JSON: {"conspiracy":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"12K likes, 3K retweets, 800 replies","url":"...","honesty":"X/10","notes":"why this score"},...]}
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
Return JSON: {"comedy":[{"headline":"...","handle":"@...","body":"...","views":1234567,"engagement":"...","url":"...","honesty":"X/10","notes":"..."},...]}
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
  "model": "grok-4-fast",
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

CATEGORIES="world usa elon allin top msm business sports pods pg6 recipe science local conspiracy comedy"

for cat in $CATEGORIES; do
    # All tabs run on grok-4-fast. The world/USA prompts have been simplified so the
    # fast model handles them reliably (was hallucinating sequential snowflake IDs on
    # the prior 4000-token multi-step prompts).
    model="grok-4-fast"
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

CATEGORIES = 'world usa elon allin top msm business sports pods pg6 recipe science local conspiracy comedy'.split()

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
