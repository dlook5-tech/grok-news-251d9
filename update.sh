#!/bin/bash
# eXpressO News — exact copy of Ristretto's pipeline (verbatim from
# /Users/lookhome/ristretto-news/update.sh) with ONLY the user-authorized deltas:
#
#   DELTA #1: World/USA prompts include 100K view floor instruction
#   DELTA #2: Sports has extra `sas_cowherd` Grok call to guarantee SAS + Cowherd
#   DELTA #3: Elon prompt is "ALL 24h posts/replies/RTs, drop only company promo"
#   DELTA #4: World←USA promotion lives in parse_grok.py
#
# eXpressO additions (tabs Ristretto doesn't have):
#   - allin (billionaire-podcaster tab) — uses Ristretto-style simple prompt
#   - sas_cowherd (helper for Sports — not a frontend tab)

set -e
cd "$(dirname "$0")"

[ -f .env ] && source .env
: "${XAI_API_KEY:?XAI_API_KEY required}"

echo "=== eXpressO Update $(date) ==="

# ============================================================================
# MANDATE PRE-FLIGHT — runs verify_mandates.sh in HARD-FAIL mode.
# If any user-corrected mandate has regressed in code, the cron aborts BEFORE
# burning xAI tokens on a Grok run that would deploy a broken site.
# This script has NO soft-mode bypass. To skip it, the user has to delete the
# mandate from MANDATES.md AND its check from verify_mandates.sh manually.
# ============================================================================
echo ""
echo "--- Mandate pre-flight ---"
if ! bash verify_mandates.sh; then
  echo ""
  echo "ABORTING CRON: mandate regression detected. See failures above." >&2
  echo "Fix the code so the failing mandate's enforcement check passes, then retry." >&2
  exit 1
fi
echo ""

TABS=(world usa business top msm sports sas_cowherd elon pods pg6 recipe science local conspiracy comedy allin)

needs_perspectives() {
    # 2026-05-22: TEMPORARY — perspectives requirement removed from World/USA
    # per user "take away the three perspectives requirement and return all eight
    # for both world and USA, and look at the view counts so we can dial in the
    # algorithm. Maybe we get those, choose those, then sequentially do the three
    # requirements." STAGE 1: get top 8 events by raw views, no perspectives.
    # STAGE 2 (later): add perspectives to chosen events.
    false
}

prompt_for() {
    local tab=$1
    case "$tab" in
        world)    echo "Top 8 highest-view WORLD news EVENTS on X in the past 24h. "World" = international events, US foreign policy, US-international relations (Trump-Iran, US-China trade, NATO, etc.), global events involving any country. Include US-international topics — DON'T exclude just because Trump is mentioned. Return all 8 candidates — even ones under 50K views — so we can see the full pool. Python applies the 50K filter, not you." ;;
        usa)      echo "Top 8 highest-view US NATIONAL news EVENTS on X in the past 24h (politics, federal events). Return all 8 candidates — even ones under 50K views — so we can see the full pool. Python applies the 50K filter, not you." ;;
        business) echo "Top 5 highest-view X posts (past 24h) about business / markets / finance / economy." ;;
        top)      echo "Top 5 highest-view X posts (past 24h) — the absolute most-viewed across the platform." ;;
        msm)      echo "Top 5 highest-view X posts (past 24h) from mainstream-media accounts (NYT, WaPo, CNN, BBC, Reuters, AP, etc.)." ;;
        sports)   echo "Top 5 highest-view X posts (past 24h) about sports — major leagues, big games, athlete news." ;;
        elon)     echo "Return EVERY @elonmusk post + reply + retweet + quote-tweet from the LAST 24 HOURS. NO TOP-N CAP — typically 20-60/day. If you return fewer than 10 you are missing posts." ;;
        pods)     echo "Top 5 highest-view X posts (past 24h) about or from major podcasters (Rogan, Lex, Theo Von, etc.)." ;;
        pg6)      echo "Top 5 highest-view X posts (past 24h) about celebrity / entertainment / pop-culture news." ;;
        recipe)   echo "Top 5 highest-view X posts (past 24h) about recipes / cooking / food." ;;
        science)  echo "Top 5 highest-view X posts (past 24h) about science / tech / research breakthroughs." ;;
        local)    echo "Top 5 highest-view X posts (past 24h) about Southern California / Orange County / Newport Beach local news." ;;
        conspiracy) echo "Top 5 highest-view X posts (past 24h) about conspiracies / under-reported stories / fringe theories." ;;
        comedy)   echo "Top 5 highest-view X posts (past 24h) that are funny — jokes, memes, comedy clips going viral." ;;
        allin)    echo "Top 5 highest-view X posts (past 24h) from billionaire operators / All-In podcast hosts (Chamath, David Sacks, Marc Andreessen, Palmer Luckey, David Friedberg)." ;;
        sas_cowherd) echo "Find TWO posts: the most recent post from @stephenasmith (Stephen A Smith) AND the most recent post from @colincowherd (Colin Cowherd). If either has nothing in 24h, search up to 3 days back." ;;
    esac
}

call_grok() {
    local tab=$1
    local today since
    today=$(date -u +%Y-%m-%d)
    since=$(date -u -v-2d +%Y-%m-%d 2>/dev/null || date -u -d "2 days ago" +%Y-%m-%d)
    local schema return_what
    return_what="array"
    if needs_perspectives "$tab"; then
        schema="STRICT RECENCY: use x_search operator since:${since}. Reject anything posted before ${since}.

Each item is one EVENT with three sided reactions:
{
  \"headline\":\"neutral one-line summary of the event\",
  \"url\":\"https://x.com/user/status/<id>\",
  \"handle\":\"username\",
  \"perspectives\":[
    {\"label\":\"Conservative\",\"handle\":\"...\",\"url\":\"https://x.com/.../status/<id>\",\"body\":\"actual post text\",\"engagement\":\"500K views\",\"views\":500000},
    {\"label\":\"Independent\",\"handle\":\"...\",\"url\":\"https://x.com/.../status/<id>\",\"body\":\"...\",\"engagement\":\"...\",\"views\":...},
    {\"label\":\"Democrat\",\"handle\":\"...\",\"url\":\"https://x.com/.../status/<id>\",\"body\":\"...\",\"engagement\":\"...\",\"views\":...}
  ]
}
For each event: TRY to find highest-view Conservative, Independent, and Democrat reactions on X — ALL from the last 24 hours. All URLs MUST be real X status URLs from posts on or after ${since}.

CRITICAL: Return the event REGARDLESS of how many perspectives you find — even ZERO perspectives is fine. If you can only find the original story tweet with no political reactions, RETURN IT with an empty perspectives array []. NEVER drop an event because perspectives are missing. We want all 8 candidates, no matter how thin the perspectives are. Python decides what ships.

MERGE DUPLICATES: If multiple high-view tweets cover the SAME news event, MERGE them into ONE event block with all perspectives consolidated.

VIEW FLOOR (DELTA): Each event's TOP perspective must have at least 50,000 COMBINED views (see QT/RT BOOST below). Drop any event below that. No fixed cap on count.

QT/RT BOOST: For each perspective, also look for the biggest retweet or quote-tweet of that post. If found, set the perspective's \"views\" field to (original_views + qt_views) — the COMBINED total. Also include original_url + original_handle + original_views + qt_views fields so the data is auditable. This lets a 70K-view post that has a 50K-view retweet clear the 100K floor (combined = 120K). If no notable QT/RT exists, just leave views as the original count."
    elif [ "$tab" == "elon" ]; then
        schema="DROP ONLY marketing/selling-voice posts about his companies (Tesla / SpaceX / xAI / X-platform / Neuralink commercials). KEEP everything else — news, criticism, contrarian takes, bare replies ('Yes', 'True', '💯'), emoji reactions, anything.

⚠️ TWO HARD REQUIREMENTS for the BLOCK to make sense:
  1. headline field is REQUIRED for every post — a 1-line news-style description of what the post is ABOUT (not a copy of the body). DO NOT start with 'Elon' or 'Elon Musk' — the reader knows it's his tab. Just describe the substance.
     - Reply 'True' to a Hegseth post on military → headline: 'Agrees with Hegseth on military rebuild'
     - Reply 'Same' to Seth Dillon → headline: 'Agrees with Seth Dillon on media coverage'
     - Bare image of Cybertruck at Starbase → headline: 'Photo of Cybertruck at Starbase launch site'
     - Video of Starship test → headline: 'Starship engine test fires successfully'
     - Original take → 'Predicts AI will outpace human intelligence by 2030'
     NEVER: 'Shares video link' / 'Replies True' / 'Comments on X' / 'Posts photo' / starts with 'Elon ...'
  2. For REPLIES: populate parent_url + parent_handle + parent_text so the parent tweet embeds inline above the reply.
     If you can't find parent context for a reply, still return the post but DO populate the headline so the block isn't blank.

OUTPUT — every post needs the contextual fields:
{\"elon\":[
  {
    \"handle\":\"@elonmusk\",
    \"url\":\"https://x.com/elonmusk/status/<id>\",
    \"headline\":\"1-line news-style summary, no 'Elon' name prefix\",
    \"body\":\"actual post text verbatim\",
    \"views\":1234567,
    \"parent_url\":\"https://x.com/<handle>/status/<id> (REQUIRED for replies)\",
    \"parent_handle\":\"@<handle>\",
    \"parent_text\":\"verbatim parent text ≤280 chars\"
  },
  ...
]}"
    elif [ "$tab" == "sas_cowherd" ]; then
        return_what="object"
        schema="Return ONLY a JSON object with key \"sas_cowherd\" holding a 2-item array:
{\"sas_cowherd\":[
  {\"handle\":\"stephenasmith\",\"url\":\"https://x.com/stephenasmith/status/<id>\",\"headline\":\"one-line summary\",\"body\":\"post text\",\"views\":N,
   \"parent_url\":\"https://x.com/<original_handle>/status/<id>\",\"parent_handle\":\"@original_handle\",\"parent_text\":\"verbatim text of post being replied to or quote-tweeted (≤280 chars)\"},
  {\"handle\":\"colincowherd\",\"url\":\"https://x.com/colincowherd/status/<id>\",\"headline\":\"one-line summary\",\"body\":\"post text\",\"views\":N,
   \"parent_url\":\"https://x.com/<original_handle>/status/<id>\",\"parent_handle\":\"@original_handle\",\"parent_text\":\"verbatim text\"}
]}
URLs MUST be real X status URLs. IF the post is a reply or quote-tweet, POPULATE the parent_url + parent_handle + parent_text fields — these let the frontend embed the original post above the reply so readers see what's being responded to. If the post is original (not a reply/QT), OMIT those three fields."
    else
        schema="STRICT RECENCY: use x_search operator since:${since}. Reject anything before ${since}.

Each item:
{\"handle\":\"username\",\"url\":\"https://x.com/user/status/<id>\",\"headline\":\"neutral one-line summary\",\"body\":\"actual post text\",\"engagement\":\"500K views\",\"views\":500000,\"honesty\":8,\"notes\":\"one-line plain-English honesty justification\"}
URLs MUST be real X status URLs from posts on or after ${since}. Views = actual view count integer.

HONESTY SCORING (REQUIRED on every item, 1-10 integer, restored 2026-05-23 — user mandate):
  10 = VERIFIED FACT only (court records, scoreboards, official stats, raw video of exactly what's claimed)
   9 = factual core with minor editorializing (news report + light framing)
   8 = analysis / commentary / institutional perspective (think tanks CSIS/Brookings/Heritage/RAND/AEI are NEVER 10 — max 8)
   7 = opinion / prediction / hot take ('I think X will happen')
   6 = contains a specific misleading claim
   5 = demonstrably false statement
  ≤4 = serial misrepresentation, conspiracy without specifics
Attribution: video/audio clip of person speaking = attribution VERIFIED (score what they said, not 'fabricated'). Transcript-only quotes have attribution uncertainty.
'notes' field: one short plain-English line explaining the score (e.g. 'Reuters factual report with light framing' or 'Hot take, no specific facts'). REQUIRED."
    fi
    local user_prompt="$(prompt_for "$tab") Today is ${today}.
Return ONLY a JSON ${return_what}, no markdown, no prose.
${schema}"

    local payload
    payload=$(python3 -c '
import json, sys
print(json.dumps({
    "model": "grok-4.3",
    "input": [{"role": "user", "content": sys.argv[1]}],
    "tools": [{"type": "x_search"}],
    "max_output_tokens": 6000
}))
' "$user_prompt")

    curl -s --max-time 240 https://api.x.ai/v1/responses \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $XAI_API_KEY" \
        -d "$payload" > "/tmp/grok_raw_${tab}.json" \
      || echo '{"error":"curl failed"}' > "/tmp/grok_raw_${tab}.json"
    echo "  [done] $tab"
}

# Top tab uses Ristretto's multi-query (4 parallel angles, raw-views sort).
call_grok_top_multi() {
    local today since
    today=$(date -u +%Y-%m-%d)
    since=$(date -u -v-2d +%Y-%m-%d 2>/dev/null || date -u -d "2 days ago" +%Y-%m-%d)

    local schema="STRICT RECENCY: use x_search since:${since}.
Each item:
{\"handle\":\"username\",\"url\":\"https://x.com/user/status/<id>\",\"headline\":\"neutral one-line summary\",\"body\":\"actual post text\",\"engagement\":\"500K views\",\"views\":500000,\"honesty\":8,\"notes\":\"one-line plain-English honesty justification\"}
URLs MUST be real X status URLs from posts on or after ${since}. Views = actual view count integer.

HONESTY SCORING (REQUIRED, 1-10 integer): 10=verified fact only; 9=factual report with light framing; 8=analysis/commentary/think tanks (CSIS/Brookings/Heritage/RAND etc are max 8, never 10); 7=opinion/take; 6=specific misleading claim; 5=demonstrably false; ≤4=serial misrepresentation. Video/audio clip = attribution verified. notes = one short line."

    local prompts=(
        "Top 10 highest-view X posts globally in the past 24 hours. Sort by raw view count. Today is ${today}. Return ONLY a JSON array, no markdown. ${schema}"
        "Top 10 highest-view X posts globally in the past 6 hours — fresh viral that just broke. Today is ${today}. Return ONLY a JSON array, no markdown. ${schema}"
        "Top 10 highest-view VIDEO posts on X in the past 24 hours — video clips with millions of views even if likes are modest. Today is ${today}. Return ONLY a JSON array, no markdown. ${schema}"
        "Top 10 X posts in the past 24 hours that have over 1M views but UNDER 50K likes — silent-viral content the regular top-of-feed misses. Today is ${today}. Return ONLY a JSON array, no markdown. ${schema}"
    )

    local i=0
    for p in "${prompts[@]}"; do
        local payload
        payload=$(python3 -c '
import json, sys
print(json.dumps({
    "model": "grok-4.3",
    "input": [{"role": "user", "content": sys.argv[1]}],
    "tools": [{"type": "x_search"}],
    "max_output_tokens": 4000
}))
' "$p")

        curl -s --max-time 240 https://api.x.ai/v1/responses \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $XAI_API_KEY" \
            -d "$payload" > "/tmp/grok_top_sub_${i}.json" \
          || echo '{"error":"curl failed"}' > "/tmp/grok_top_sub_${i}.json" &
        i=$((i+1))
    done
    wait

    python3 << 'PY' > /tmp/grok_raw_top.json
import json, re, os, sys

def extract_text(resp):
    if isinstance(resp.get('output'), list):
        chunks = []
        for o in resp['output']:
            for c in o.get('content', []) or []:
                t = c.get('text') if isinstance(c, dict) else None
                if t: chunks.append(t)
        if chunks: return '\n'.join(chunks)
    return ''

pool, seen = [], set()
for i in range(4):
    path = f'/tmp/grok_top_sub_{i}.json'
    if not os.path.exists(path): continue
    try:
        with open(path) as f: resp = json.load(f)
        if resp.get('error'): continue
        text = extract_text(resp)
        text = re.sub(r'^```[a-zA-Z]*\s*', '', text.strip())
        text = re.sub(r'\s*```\s*$', '', text)
        m = re.search(r'\[.*\]', text, re.DOTALL)
        if not m: continue
        for item in json.loads(m.group(0)):
            url = (item.get('url') or '').strip()
            if not url or url in seen: continue
            seen.add(url)
            pool.append(item)
    except Exception as e:
        print(f"  [top-sub-{i}-warn] {e}", file=sys.stderr)

def vw(it):
    try: return int(it.get('views', 0) or 0)
    except: return 0
pool.sort(key=vw, reverse=True)
pool = pool[:15]
synthetic = {'output': [{'content': [{'text': json.dumps(pool)}]}]}
print(json.dumps(synthetic))
PY
    echo "  [done] top (4 parallel subqueries merged)"
}

export -f call_grok call_grok_top_multi prompt_for needs_perspectives
export XAI_API_KEY

echo "Calling Grok for ${#TABS[@]} tabs in parallel..."
for tab in "${TABS[@]}"; do
    if [ "$tab" = "top" ]; then
        call_grok_top_multi &
    else
        call_grok "$tab" &
    fi
done
wait
echo "All Grok calls complete."

# Merge per-tab responses into single JSON keyed by tab.
python3 << 'PY' > /tmp/grok_raw.json
import json, re, sys

TABS = ['world','usa','business','top','msm','sports','elon','pods',
        'pg6','recipe','science','local','conspiracy','comedy','allin','sas_cowherd']

def extract_text(resp):
    if isinstance(resp.get('output'), list):
        chunks = []
        for o in resp['output']:
            for c in o.get('content', []) or []:
                t = c.get('text') if isinstance(c, dict) else None
                if t: chunks.append(t)
        if chunks: return '\n'.join(chunks)
    if isinstance(resp.get('choices'), list) and resp['choices']:
        msg = resp['choices'][0].get('message', {})
        if isinstance(msg, dict): return msg.get('content', '') or ''
    return ''

out = {}
for tab in TABS:
    try:
        with open(f'/tmp/grok_raw_{tab}.json') as f:
            resp = json.load(f)
        if resp.get('error'):
            out[tab] = []
            continue
        text = extract_text(resp)
        text = re.sub(r'^```[a-zA-Z]*\s*', '', text.strip())
        text = re.sub(r'\s*```\s*$', '', text)
        if tab == 'sas_cowherd':
            m = re.search(r'\{.*\}', text, re.DOTALL)
            if m:
                parsed = json.loads(m.group(0))
                out[tab] = parsed.get('sas_cowherd', []) if isinstance(parsed, dict) else []
            else:
                out[tab] = []
        else:
            m = re.search(r'\[.*\]', text, re.DOTALL)
            out[tab] = json.loads(m.group(0)) if m else []
    except Exception as e:
        print(f"  [merge-warn] {tab}: {e}", file=sys.stderr)
        out[tab] = []
print(json.dumps(out))
PY

echo "Running parse_grok.py..."
python3 parse_grok.py < /tmp/grok_raw.json

echo "Deploying to Netlify..."
bash deploy.sh

echo "=== Update Complete $(date) ==="
