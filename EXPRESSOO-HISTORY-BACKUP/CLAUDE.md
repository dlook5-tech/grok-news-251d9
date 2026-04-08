# eXpressO News — Complete Project Reference

## Project Identity & Mission

**eXpressO News** is a citizen journalism news aggregator that curates trending posts from X (Twitter) so mainstream-news consumers don't have to dig through X themselves. It bridges the gap between X's real-time citizen journalism and people who only read traditional news.

**Prime Directive**: Citizen journalists FIRST — threads, commentary, and viral posts from real people over institutional/MSM accounts. High engagement (likes, replies, retweets) is critical. We want the hottest, most-discussed posts on X.

**Live URL**: https://groknewsx.netlify.app

## Architecture Overview

### Single-File App
- **`index.html`** — The entire site. Single HTML file containing all data (`NEWS_DATA` JavaScript object), styles (CSS), and logic (vanilla JS). No frameworks, no build step.
- Data is hardcoded in `NEWS_DATA` and updated by `update.sh` via regex replacements.

### Update Pipeline (`update.sh`)
A 4-step automated pipeline that runs hourly:

1. **Step 1 — Grok Trending**: Calls Grok API (`grok-4.20-0309-reasoning` model with `web_search` tool) to find trending posts. Constrained to ~80 APPROVED HANDLES to prevent Grok from inventing fake accounts.

2. **Step 1.5 — Null URL Fix**: For any handle where Grok returned `url: null`, makes focused single-handle API calls to find real URLs.

3. **Step 2 — oEmbed Hard Gate**: Verifies EVERY URL via `https://publish.twitter.com/oembed?url=...` (returns 200 for real tweets, 404 for fake). Captures author name and tweet text. **ABORTS entire pipeline if <40% pass verification.**

4. **Step 3 — Assembly**: Only publishes verified stories. Unverified stories are SKIPPED (old content stays). Uses `get_verified_headline()` to auto-correct headlines that don't match actual tweet text. Headlines that are just t.co links or garbage get replaced with tweet text.

5. **Step 4 — Deploy**: `npx netlify-cli deploy --prod` to Netlify.

### Serverless Backend
- **`netlify/functions/custom-stories.js`** — Netlify serverless function for "My Feed" tabs. Calls Grok API with user's custom interests. API key stays server-side.
- **`netlify.toml`** — Netlify config pointing to esbuild bundler.

### Scheduled Task
- **`expressoo-hourly-update`** — Runs at `:05` past every hour via Claude scheduled tasks. Executes `update.sh`, commits, and pushes automatically.

## Content Tabs

| Tab | ID | Content |
|-----|----|---------|
| World | `world` | 1-3 stories with 3 perspectives each (Conservative, Democrat, Independent) with honesty scores and footnotes |
| Business | `business` | Single trending business/markets post |
| Local | `local` | Orange County / Newport Beach / SoCal news ONLY. Must be front-page-worthy (Daily Pilot / OC Register quality) |
| Sports | `sports` | Main sports news + Stephen A Smith + Colin Cowherd takes |
| Elon | `elon` | 3 different recent @elonmusk posts (deduplicated by URL) |
| #1 Pop | `top` | Single most viral post on ALL of X right now |
| ~~MSM~~ | `msm` | Mainstream media accountability / fact-checking |
| $age | `allin` | All-In Podcast crew: @chamath, @DavidSacks, @pmarca, @PalmerLuckey, @friedberg |
| Pg. 6 | `pg6` | Celebrity/entertainment gossip |
| Pods | `pods` | Podcast clips from Rogan, Tucker, All-In, Lex, etc. |
| Recipe | `recipe` | Trending food/recipe posts |
| My Feed 1 | `myfeed1` | User-customizable — type interests in natural language, get personalized stories |
| My Feed 2 | `myfeed2` | Second custom feed slot |
| Post/Replace | `submit` | User can submit story links |

## Key Features

### Tweet Embeds
- "View post" button on every story embeds the actual tweet inline using Twitter's `widgets.js`
- Loaded on-demand via `toggleEmbed()` — no Twitter JS loaded until user clicks
- No X login required to view embedded tweets

### Honesty Scores & Footnotes
- Every story has an honesty score (X/10)
- World tab stories have numbered footnotes `[1][2][3]` as superscripts with hover tooltips
- Collapsible "Honesty footnotes" section at bottom of each story

### My Feed (Custom Tabs)
- Users type interests in natural language (with voice-to-text via Speech Recognition API)
- Stories fetched via Netlify serverless function (keeps API key server-side)
- Stored in `localStorage` (browser-specific, no login)
- Tab label dynamically shows first keyword from user's interests
- Auto-refreshes in background every hour on page load

### Earlier Stories
- When content updates, old stories move to "Earlier" section with timestamps
- Provides a rolling history of coverage

## Approved Handles List

Grok is constrained to only use handles from this approved list (prevents inventing fake accounts):

**World Conservative**: @JackPosobiec, @Cernovich, @RealCandaceO, @benshapiro, @TuckerCarlson, @DonaldJTrumpJr, @charliekirk11, @RealDailyWire, @JDVance1, @SenTedCruz, @TomFitton, @JesseBWatters, @IngrahamAngle, @WarMonitors, @sentdefender, @CriticalThreats, @WhiteHouse

**World Democrat**: @AOC, @Ilhan, @RBReich, @BernieSanders, @RashidaTlaib, @ChrisMurphyCT, @SenWarren, @JoyceWhiteVance, @ProPublica, @DropSiteNews

**World Independent**: @HamidRezaAz, @TheStudyofWar, @vtchakarova, @RayDalio, @dalperovitch, @InsightGL, @KimZetter, @Snowden, @ggreenwald

**Business**: @DowdEdward, @RayDalio, @Stocktwits, @StockMKTNewz, @WatcherGuru, @unusual_whales, @TruthGundlach, @LizAnnSonders, @elerianm

**Sports**: @ShamsCharania, @wojespn, @ClutchPoints, @BleacherReport, @CourtsideBuzzX, @TheAthletic, @ESPNStatsInfo, @stephenasmith, @TheHerd, @colincowherd

**Elon**: @elonmusk (always 3 different posts)

**Pods**: @joerogan, @joeroganhq, @TuckerCarlson, @theallinpod, @lexfridman, @CallHerDaddy, @adamcarolla, @JREClips, @enews

**All-In**: @chamath, @DavidSacks, @pmarca, @PalmerLuckey, @friedberg

**MSM**: @BillMelugin_, @MattWalshBlog, @TimcastNews, @TheRabbitHole84, @SCOTUSblog, @InsightGL, @JamesOKeefeIII

**Recipe**: @tasteofhome, @FoodNetwork, @thekitchn, @HBHarvest, @foodandwine, @tasty, @KitchenSanc2ary, @budgetbytes

**Local**: @OC_Scanner, @ABC7, @LAist, @KTLA, @OCRegister, @DailyPilot, @NBPDsocial, @CityofNewportBeach

**Pg. 6**: @PopCrave, @enews, @JustJared, @etnow, @TMZ

## Environment Variables

| Variable | Location | Purpose |
|----------|----------|---------|
| `XAI_API_KEY` | `.env` file + Netlify env | Grok/xAI API key |
| `NETLIFY_AUTH_TOKEN` | `.env` file | Netlify deploy auth |
| `NETLIFY_SITE_ID` | `.env` file | Value: `groknewsx` |

**IMPORTANT**: `.env` file is NOT committed to git. Must be recreated on new machines.

## Key Decisions & Lessons Learned

### Why Approved Handles?
Grok fabricates handles. Even the best model (`grok-4.20-0309-reasoning`) with `web_search` enabled invents plausible-sounding accounts like @WarMonitor3, @HomeCookVibes, @OCCitizenWatch that don't exist on X. The approved list prevents this.

### Why oEmbed Verification?
Grok also fabricates status IDs. A URL like `x.com/realhandle/status/FAKE_ID` looks real but the tweet doesn't exist. oEmbed (`publish.twitter.com/oembed`) is a free, unauthenticated API that returns 200 for real tweets and 404 for fake ones. It also returns the tweet text, which we use to verify/correct headlines.

### Why 40% Hard Gate?
Without a quality gate, the pipeline would happily publish pages full of broken links. 40% is the minimum — if more than 60% of URLs are fake, something is seriously wrong and we keep old content.

### Why Single HTML File?
Simplicity. No build step, no framework, no dependencies. The entire site is one file that `update.sh` modifies via Python regex. Easy to deploy, easy to debug, easy to back up.

### Why Dedup Elon Posts?
Grok consistently returns the same Elon tweet 3 times when asked for "3 different posts." Step 3 now deduplicates by URL.

### Engagement Quality Rule
User explicitly requires HIGH ENGAGEMENT posts. Minimum 5,000 likes OR 500 replies OR 1,000 retweets. Viral threads with massive interaction are the priority. Low-engagement posts (1.2K likes, 95 replies) are unacceptable.

### Local Tab Rules
- MUST be Orange County / Newport Beach / SoCal
- Must be front-page-worthy (Daily Pilot / OC Register quality)
- Real local NEWS: crime, politics, development, community issues, weather, school board, city council
- NOT random beach photos or fluff

### World Tab Story Count
- 1-3 stories based on importance
- Simple and clean over stockpiling

## Coding Conventions

- **No frameworks** — vanilla HTML/CSS/JS only
- **No build step** — everything runs directly
- **Data in JS object** — `NEWS_DATA` hardcoded in index.html
- **Python for pipeline logic** — inline heredocs in update.sh
- **All URLs verified** — nothing published without oEmbed check
- **Regex-based updates** — Step 3 uses Python `re.sub()` to update index.html

## Automation Rules

- **AUTO-APPROVE EVERYTHING** — Never ask for permission, confirmation, or approval
- **Never ask "want me to merge?" or "should I proceed?"** — just do it
- **Hourly updates run autonomously** — no babysitting required
- **If pipeline fails, keep old content** — never publish garbage
- **Commit and push automatically** — no manual steps

## File Structure

```
/
├── index.html              # The entire site (single file)
├── update.sh               # 4-step update pipeline
├── netlify.toml             # Netlify build config
├── netlify/
│   └── functions/
│       └── custom-stories.js  # My Feed serverless function
├── .env                    # API keys (NOT in git)
└── CLAUDE.md               # This file
```

## How to Restore on Another Machine

1. Clone the repo: `git clone https://github.com/dlook5-tech/grok-news-251d9.git`
2. Create `.env` with `XAI_API_KEY`, `NETLIFY_AUTH_TOKEN`, `NETLIFY_SITE_ID`
3. Run `bash update.sh` to test the pipeline
4. Set up Claude scheduled task for hourly runs at `:05`
5. Site deploys to Netlify automatically via the pipeline

## API Details

- **Grok API**: `https://api.x.ai/v1/responses`
- **Model**: `grok-4.20-0309-reasoning`
- **oEmbed**: `https://publish.twitter.com/oembed?url=ENCODED_URL`
- **Netlify Deploy**: `npx netlify-cli deploy --prod --dir=. --functions=netlify/functions`
- **Netlify Site**: `groknewsx`
- **GitHub Repo**: `dlook5-tech/grok-news-251d9`
