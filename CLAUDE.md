# eXpressO News Project Instructions

## STOP — Read this first every session

The user has lived through **multiple iterations of the same fixes**. Before proposing ANY fix, ctrl-F the symptom in the "Recurring Issues" section below. If it's there, the previous iterations are listed. Don't re-invent.

**After shipping a fix:** append a numbered iteration with date to the relevant section here. This file IS the running history.

**After 5+ iterations on the same problem:** stop adding code. Discuss whether the platform is the bottleneck (e.g., "iOS Safari caching is unsolvable beyond what we've done").

---

## User preferences (loaded from ~/.claude memory)

- Auto-approve everything (no permission prompts) — settings.json has `mcp__*` blanket allow
- World/Business/Local: 1-3 stories per cron based on quality, NEVER pad
- Curation: compelling/insightful/re-shareable > raw likes
- Local tab: Newport Beach / OC / SoCal only, never random US
- Honesty rubric: lies poison the post; news+commentary band = 8-9 (not 7)
- 2-call pipeline split for 35+ stories vs 13-15 with single call
- Code pushed to GitHub to prevent old theme redeploying from other Macs

---

## Project structure

- `update.sh` — full pipeline: 16 parallel Grok calls + topic-lock + oEmbed verify + post-hoc translate + parse + deploy
- `parse_grok.py` — JSON repair, validation, dedup, never-empty top-up, semantic verifier
- `index.html` — single-page frontend, TABS array (lines ~265-285), service worker registration, auto-refresh listeners
- `sw.js` — service worker (BUILD stamp updated per deploy by deploy.sh)
- `deploy.sh` — Netlify digest deploy + snapshot to `~/Desktop/expresso_snapshots/<date>/` + handoff doc
- `qc_critic.sh` — second-pass critic, suggests engagement-based replacements (auto-applied)

---

## Recurring Issues — READ BEFORE FIXING

### 1. Browser shows old stories (caching)

**Why it recurs:** iOS Safari and Chrome aggressively cache HTML and JS even with `Cache-Control: no-cache, no-store, must-revalidate` headers. Every layer is a partial fix.

**Iterations (current = v9, 2026-05-01):**
1. Service worker network-first for HTML/JSON
2. BUILD stamp in `sw.js` per deploy (deploy.sh stamps via sed)
3. `version.txt` polled every 60s by `checkVersion()` in index.html
4. Meta tags `Cache-Control: no-cache` + `Pragma: no-cache` + `Expires: 0`
5. `loadStories()` fetches with `?t=` cache-bust + `cache: 'no-store'`
6. `setInterval(loadStories, 5min)` polls fresh stories.json
7. SW activate handler nukes all caches + posts `SW_UPDATED` to clients → page reloads
8. **2026-05-01:** `visibilitychange` / `pageshow` / `focus` listeners re-fetch on tab return
9. **2026-05-01:** `<meta http-equiv="refresh" content="900">` 15-min hard reload backstop

**Current state:** v9. After ONE manual reload to pick up new index.html, listeners + meta-refresh keep tabs fresh forever.

**If user reports recurrence:** Run `curl -sI https://expresso-news.netlify.app/` to verify Netlify headers. Run `curl ... | grep BUILD` on sw.js. If both match the latest deploy and user STILL sees old content, it's pure browser cache and only a hard reload escapes — explain this honestly, don't add a 10th layer.

### 2. Honesty scores don't match reasoning

**Iterations (current = v7, 2026-04-30):**
1. Politician honesty cap at 7/10 (rejected — too rigid)
2. `_is_politician_handle()` + `_cap_honesty()` Python override (rejected)
3. `evidence_check_score()` per-claim track record (rejected — too mechanical)
4. Elon-specific accusation override (rejected — partisan)
5. Holistic Grok gestalt judgment, no Python overrides
6. **2026-04-30:** "Lies poison the post" — score the worst claim, not the average
7. **2026-04-30:** Added KEY INSIGHT: news+commentary = 8-9 (was undervaluing accurate news with opinion at 7)

**Current state:** v7 holistic rubric in `update.sh` `/tmp/grok_system.txt`. 5 anchor examples. Most posts now correctly score 8/10.

**Known gaps:** `honesty_consistency_review()` second-pass auditor function exists in `parse_grok.py` (~line 791) but NOT wired in. Wiring it would catch score-vs-notes mismatches like "9/10 but notes describe a fabrication."

**If user complains about a specific score:** read post + notes carefully. Is it 8-9 (factual core + commentary), 5-7 (pure opinion no facts), 3-4 (1 demonstrable lie), or 1-2 (multiple lies)? If borderline, add another rubric example or wire in the consistency reviewer.

### 3. Foreign-language posts not translated

**Iterations (current = v4, 2026-04-30):**
1. System prompt told Grok to set `translation` field (Grok ignored ~30% of the time)
2. `parse_grok.py` passes through `translation` field
3. `index.html` renders translation card in story cards
4. **2026-04-30:** Post-hoc Grok translation step in `update.sh` oEmbed block — detects non-ASCII heavy bodies via `has_heavy_non_english()`, batches them into a single Grok translate call, injects `translation` field. Nulls posts where translation fails.

**Current state:** v4 working. French Brivael parent now has full English translation in card.

**If recurs:** Add language markers to `has_heavy_non_english()` in update.sh.

### 4. Empty tabs ("USA has 0 stories")

**Iterations (current = v5):**
1. Never-empty top-up carries from yesterday's snapshot
2. Snapshot history at `~/Desktop/expresso_snapshots/`
3. Semantic verifier rejects off-topic perspectives
4. Bar raise: 3-perspective stories preferred over 2-perspective
5. **Recurring `WARNING: had no valid fresh stories, rebuilding from existing`** — working as designed

**Current state:** v5 working. Tabs always populate.

**If recurs:** Check semantic verifier rejection log in `/tmp/expresso_test_run*.log`.

### 5. Reply posts without visible parent context

**Iterations (current = v3, 2026-04-30):**
1. SKIP rule in GLOBAL_RULES (loose — Grok ignored)
2. PREFER quote-tweets language
3. **2026-04-30:** STRICT REJECT pure text replies. Only originals + quote-tweets allowed. Removed Elon prompt's "if reply restates" exception.

**Current state:** v3 working. Caught `@lovecat.0338: 'Cats without rules'` on last cron.

### 6. Fake URLs / fabricated handles

**Iterations (current = v3, 2026-04-30):**
1. URL format validation in parse_grok
2. **2026-04-30:** Approved-handles whitelist embedded in each tab's prompt
3. **2026-04-30:** oEmbed verification with 40% hard-gate abort (preserves old stories.json on failure)

**Current state:** v3 working. 100% pass rate on last 3 crons (54/54, 48/48, 49/49).

### 7. Cron reliability (Mac sleep) — RESOLVED via GitHub Actions

**Iterations:**
1. `launchd` plist with StartCalendarInterval
2. `pmset wakeorpoweron MTWRFSU 05:55:00` so Mac wakes for 6am cron
3. **2026-05-01:** GitHub Actions migration — `.github/workflows/cron.yml` runs every 2 hours regardless of Mac state. Mac launchd should be disabled once GH Actions verified working.

**Current state:** v3 GitHub Actions. Cron schedule: every 2 hours UTC (`0 */2 * * *`).

**Required GitHub Secrets** (set via repo Settings → Secrets and variables → Actions):
- `XAI_API_KEY`
- `NETLIFY_AUTH_TOKEN`
- `NETLIFY_SITE_ID` (optional; defaults to embedded value)

**To disable Mac launchd once GH Actions confirmed:**
```bash
launchctl unload ~/Library/LaunchAgents/com.expresso.cron.plist
```

### 8. Crime-blotter content (sensationalized violent crime)

**Iterations (v1, 2026-04-30):**
1. PG6 prompt explicit reject: "TERRIFYING:", graphic dismemberment, mugshots, crime against minors

**Current state:** v1, untested — needs a few cron cycles to confirm Grok obeys.
