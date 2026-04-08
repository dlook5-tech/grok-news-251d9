# eXpressO News — Development History (April 2026)

## Thread 1: Initial Build & Core Architecture

### Problem
User wanted a news aggregation site that curates citizen journalism from X (Twitter), bridging the gap for people who rely on mainstream news. The site should showcase trending posts across multiple categories with honesty scores.

### Solution Built
- Single-file HTML app (`index.html`) with hardcoded `NEWS_DATA` JavaScript object
- 14 content tabs: World, Business, Local, Sports, Elon, #1 Pop, MSM, $age, Pg. 6, Pods, Recipe, My Feed 1, My Feed 2, Post/Replace
- `update.sh` pipeline calling Grok API to find trending posts
- Deployed to Netlify at groknewsx.netlify.app

### Key Design Decisions
- Vanilla HTML/CSS/JS — no frameworks, no build step
- All data hardcoded in JS object, updated via Python regex in update.sh
- World tab shows 3 perspectives (Conservative, Democrat, Independent) per story

---

## Thread 2: The Fake URL Crisis

### Problem
Grok consistently fabricated handles AND tweet URLs. Handles like @WarMonitor3, @PeaceNowThread, @HoopsCitizen, @HomeCookVibes didn't exist. Even real handles got fake status IDs.

### Root Cause
Even `grok-4.20-0309-reasoning` with `web_search` tool invents plausible-sounding accounts and URLs. This is an inherent limitation of the model.

### Fix: Three-Layer Defense
1. **Approved Handles List** (~80 known-real handles) — constrains Grok to only use verified accounts
2. **Step 1.5 Focused Search** — for any null URLs, makes focused per-handle API calls that consistently find real URLs
3. **oEmbed Verification Hard Gate** — verifies every URL via `publish.twitter.com/oembed`, aborts if <40% pass

### Result
Verification rates improved from ~15% to 65-83%.

---

## Thread 3: Pipeline Reliability & Hourly Updates

### Problem
Pipeline kept crashing due to fake URLs, JSON parse errors, and unhandled edge cases. Hourly scheduled task would fire but update.sh would crash silently.

### Fixes
- Added JSON repair logic (fix unclosed quotes, brackets, braces)
- Added error handling at every step with clear abort conditions
- Hard quality gate: abort if <40% URLs pass verification
- Keep old content on failure rather than publishing garbage
- Scheduled task at `:05` past every hour

### User Frustration
User expressed extreme frustration about pipeline reliability: "It's always crashed and you always make excuses. There's not one time it's gone once I've walked away from the computer." This led to comprehensive pipeline overhaul.

---

## Thread 4: Tweet Embeds & UI Improvements

### Problem
- Original design had both "Show tweet" and "View on X" buttons — user said "too confusing just use 1"
- Footnotes weren't showing numbered superscripts

### Fixes
- Merged into single "View post" button that embeds tweet inline using Twitter's `widgets.js`
- Twitter JS loaded on-demand (not at page load) via `toggleEmbed()`
- Added numbered footnote superscripts [1][2][3] with hover tooltips
- Collapsible "Honesty footnotes" section

---

## Thread 5: My Feed Custom Tabs

### Problem
User wanted personalized news feeds based on custom interests, with voice input.

### Solution
- Two "My Feed" tab slots stored in `localStorage`
- Users type interests in natural language (or use voice-to-text via Speech Recognition API)
- Stories fetched via Netlify serverless function (`custom-stories.js`) — keeps API key server-side
- Tab labels dynamically show first keyword from user's interests
- Auto-refreshes in background every hour on page load
- No login required — browser-specific via localStorage

### XAI_API_KEY on Netlify
- CLI and PUT API both failed to set env var
- Fixed by using POST to `/api/v1/accounts/dlook5/env` endpoint

---

## Thread 6: Story Quality & Engagement (Latest)

### Problem
User complained about low-quality stories: "Why are the stories in world so shitty... the story you chose only got 1.2 thousand likes... 95 replies... pick better stories"

Also complained about:
- Duplicate Elon stories (same tweet shown 3 times)
- Local tab showing garbage like Dockweiler Beach instead of OC/Newport Beach news
- Headlines that were just t.co links

### Fixes
1. **Engagement Requirements in Grok Prompt**: Added explicit minimum thresholds — 5,000+ likes OR 500+ replies OR 1,000+ retweets. Added "VIRAL posts are KING" language throughout prompt.

2. **Elon Deduplication**: Added URL dedup in Step 3 — if Grok returns same tweet 3 times, only first is published. Also told Grok "3 DIFFERENT posts, each with DIFFERENT URL and DIFFERENT topic."

3. **Local Tab Quality**: Rewrote Local prompt to say "stories that would be FRONT PAGE of the Daily Pilot or OC Register." Added handles: @OCRegister, @DailyPilot, @NBPDsocial, @CityofNewportBeach.

4. **Headline Quality Filter**: If headline is a t.co URL or <5 chars, auto-replace with actual tweet text from oEmbed verification.

### Result
Pipeline ran at 5:26 PM: 65% verification, 10 tabs updated, deployed live.

---

## Thread 7: Automation & User Preferences

### Key Rules (Established Through User Feedback)
- **AUTO-APPROVE EVERYTHING** — user said this dozens of times with escalating frustration
- **Never ask permission** — "don't ask me to commit changes. Just do it. Stop asking me shit you know what to do."
- **World stories**: 1-3 based on importance, simple and clean
- **Local tab**: MUST be Orange County / Newport Beach / SoCal only
- **Quality over quantity** — nothing published until verified

### Scheduled Task
- `expressoo-hourly-update` runs at `:05` past every hour
- Executes update.sh, commits changes, pushes to GitHub
- No human intervention needed

---

## Technical Notes for Future Development

### oEmbed API
- URL: `https://publish.twitter.com/oembed?url=ENCODED_URL`
- Returns 200 + JSON (author_name, html with tweet text) for real tweets
- Returns 404 for fake/deleted tweets
- Free, unauthenticated, no rate limits encountered
- Tweet text extracted via regex from HTML in response

### Grok API Quirks
- Model frequently returns same content multiple times when asked for "different" items
- `web_search` tool helps but doesn't prevent all fabrication
- Focused single-handle queries (Step 1.5) are more reliable than bulk queries
- Temperature 0.2 for main query, 0 for focused URL searches

### Deployment
- Netlify CLI: `npx netlify-cli deploy --prod --dir=. --functions=netlify/functions`
- Auth via `NETLIFY_AUTH_TOKEN` and `NETLIFY_SITE_ID` from `.env`
- Site ID: `groknewsx`

### Git Workflow
- Main branch: `main`
- Working branch: `claude/ecstatic-pike` (worktree)
- Repo: `github.com/dlook5-tech/grok-news-251d9`

---

## Timestamp Log

| Time | Event |
|------|-------|
| Early April 2026 | Initial build — single HTML file, basic Grok integration |
| Mid April | Discovered fake URL problem, added oEmbed verification |
| April 7, 10:27 AM | Last update before pipeline fixes |
| April 7, 1:26 PM | Pipeline run with partial fixes |
| April 7, 5:01 PM | First successful run with full pipeline overhaul (83% verification) |
| April 7, 5:19 PM | Second run with engagement prompt improvements (41% verification) |
| April 7, 5:26 PM | Third run with dedup + quality fixes (65% verification, 10 tabs updated) |
| April 7, 5:33 PM | Deployed live, pushed to main |
