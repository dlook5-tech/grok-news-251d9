# MANDATES — append-only, never delete

Every user correction that I (Claude) keep regressing on. Each entry has the
date, the user's actual words, and the code-enforcement point so the rule
cannot quietly die in a future session.

**Rule for me, in every turn, before I touch this project:**
1. Read this file (`MANDATES.md`).
2. For every active mandate below, confirm the code-enforcement point still exists.
3. If any mandate is at risk in what I'm about to do, stop and re-read it.
4. If I get corrected on something, append the new mandate here in the same turn.
5. Never reorder, edit, or delete mandates. Only append.

---

## M-001 — Story blocks are DIRECT LINKS to source. No expand. No toggle. No embed-on-click.
**Status:** SUPERSEDED 2026-05-23 evening by M-017. Active design is now inline-expand-with-embed + honesty score (same as the pre-M-001 design). M-001's "direct link" instruction is no longer active.
**Date:** 2026-05-23
**User said:** "I don't want anything where you have to click it to say 'open on X'. We've talked about this. Why do I keep repeating myself?"
**Enforcement:**
- `index.html::renderAutoEmbedBlock` returns `<a class="story story-link" target="_blank">`. NEVER `classList.toggle('open')` or `toggleEmbed(...)` inside the active function.
- `deploy.sh` aborts deploy if `class="story story-link"` is missing OR if the active `renderAutoEmbedBlock` contains `classList.toggle` / `toggleEmbed`.
- Big USER MANDATE comment block above the function.

## M-002 — Cron writes `cron_report.md` every run. Never depend on chat-side rendering.
**Date:** 2026-05-23
**User said:** "Include it in the code if you miss it once."
**Enforcement:**
- `parse_grok.py` writes `cron_report.md` at the end of every run with the locked REPORT_FORMAT.md format.
- `.github/workflows/cron.yml` includes `cron_report.md` in its `git add`.
- Report contains: WORLD + USA 8-candidate audit (each with ✅/❌ + drop-reason) + per-tab summary table.

## M-003 — Per-tab age caps must apply at the curation layer, not just be declared.
**Date:** 2026-05-23
**User said:** [empty tabs in screenshots] "What the fuck?"
**Root cause:** `curation.apply_hold()` had a HARDCODED 24h cap that ran before `parse_grok.py::PER_TAB_AGE_CAP`. Allin/Science/Conspiracy shipped 0 stories because everything >24h was killed by apply_hold before per-tab caps could spare them.
**Enforcement:**
- `curation.py::PER_TAB_MAX_AGE` dict mirrors `parse_grok.py::PER_TAB_AGE_CAP`.
- `curation.curate(tab, ...)` passes the per-tab cap to `apply_hold(..., max_age_hours=cap)`.
- `apply_hold` accepts `max_age_hours` kwarg; default 24h. No more hardcoded literal `> 24`.

## M-004 — Headlines are NEWS-STYLE. Few words. Clearly describe the story. NEVER "shares clip / video / link / replies / agrees".
**Date:** repeated 1000s of times; locked 2026-05-23
**User said:** "treat like news story as few words as can clearly describe, y am i explaining common sense stuff ive repeat 1000s of time"
**Enforcement:**
- `parse_grok.py::_GENERIC_HEADLINE_PATTERNS` is the regex list of forbidden patterns.
- `parse_grok.py::fetch_headline_for_post()` fires an xAI call to rewrite when a generic headline lands in the data.
- Applied to ALL tabs (Elon + every other tab) post-Grok, before stories.json is written.

## M-005 — In the Elon tab, headlines NEVER start with "Elon" or "Elon Musk". The reader knows it's his tab.
**Date:** repeated; locked 2026-05-22
**Enforcement:**
- Elon-tab Grok prompt: "DO NOT start with 'Elon' or 'Elon Musk'."
- `_GENERIC_HEADLINE_PATTERNS` includes `r'^elon(\s+musk)?\s+(shares?|posts?|comments?|replies)'`.

## M-006 — World/USA flexible 1-3 stories. NEVER pad. Quality bar = "most interesting of the day."
**Date:** memory entry `feedback_world_stories.md`
**Enforcement:**
- Stage 1 in `parse_grok.py`: no fixed top_n, ships whatever clears the 50K floor + 24h cap. Empty world/usa is acceptable if there's nothing worth shipping.

## M-007 — 50K view floor stays for World/USA. Working as intended.
**Date:** 2026-05-23 (user pushback: "It seems to be working.")
**Enforcement:**
- `parse_grok.py::WU_VIEW_FLOOR = 50_000`. Do not lower without explicit user authorization.

## M-008 — Local tab is SoCal / Orange County / Newport Beach. Never random US.
**Date:** memory entry `feedback_local_tab.md`
**Enforcement:**
- `update.sh::prompt_for('local')` — prompt is hardcoded for SoCal/OC/Newport.

## M-009 — Cross-tab dedup. Same TWEET URL never appears in two tabs. Same EVENT (different tweets) caught by QC.
**Date:** 2026-05-22 ("dont we have a QC check to stop duplicate stories"); 2026-05-23 ("cant u just do a QC at the end looking for dups")
**Enforcement:**
- `parse_grok.py::CROSS-TAB DEDUP` block — URL-exact dedup with intl-keyword routing (intl→World, US-only→USA).
- `parse_grok.py::FINAL QC` block — signature-based event dedup across all news tabs.

## M-010 — Do NOT confabulate. If the data isn't loaded, say so. Never invent view counts, handles, or drop reasons.
**Date:** 2026-05-23 ("That's a lie in the USA tab. Both number six and seven had over 300,000 views. Get your facts straight.")
**Enforcement:** behavioral — when reporting numbers, always pull from `stories.json` or `cron_report.md`, never from memory of a previous chat render. If those files don't have what's needed, say so explicitly instead of guessing.

## M-011 — Stop sycophantic acknowledgments. No "you're right" when the user has had to repeat themselves.
**Date:** 2026-05-23 ("Quit saying you're right when I do ask for something for the fifth time. Include it in the code if you miss it once.")
**Enforcement:** behavioral — just do the work; if I missed something, write the structural fix, don't soothe.

## M-012 — Before EVERY response on this project, read this file. New corrections get appended same turn.
**Date:** 2026-05-23 ("If you would just write down everything we discuss, like we've talked about hundreds of times before, and review those things that we've discussed already, I wouldn't have to keep repeating and correcting the same fucking problems every day.")
**Enforcement:**
- This file referenced from `CLAUDE.md` as REQUIRED first read.
- `verify_rules.sh` checks that every mandate's "Enforcement" code-point grep still passes.

## M-023 — Elon tab: NO promo filter, NO cross-tab QC dedup. Ship every post Grok returns within 24h.
**Date:** 2026-05-23 evening
**User said:** "for Elon Tab, don't cut off anything where he talks about one of his companies. If he has over a million views on the story, post it. Make the Python code that simple."
**Enforcement:**
- `parse_grok.py` Elon branch: removed `_is_elon_promo` filter. `elon_kept = list(cleaned)` ships every post Grok returned.
- `_DEDUP_ORDER` no longer includes `'elon'` — QC dedup never touches Elon stories (his multi-take threads on the same topic all ship; e.g. multiple Starship reactions, multiple Grok-build follow-ups).
- 24h age cap still applies (per general news-tab freshness rule).
- Generic-headline rewrite still runs (Elon often posts "Shares video" stubs that need real headlines).

## M-022 — After any cron, ALWAYS paste cron_report.md verbatim. Never summarize from memory.
**Date:** 2026-05-23 evening
**User said:** "Where's the last cron report on the eight stories, how they were curated, and why they were passed? Can you hard code that into the Python so you stop forgetting it each time?"
**Root cause:** The file has been auto-generated since M-002 (2026-05-23 morning). The structural piece is done. What I kept doing wrong was summarizing the run from memory in chat instead of pasting the cron_report.md contents directly. The user shouldn't have to ask where it is.
**Enforcement:**
- Behavioral rule for me: after ANY cron completes (locally OR via GitHub Actions), the first thing in my response is `cat cron_report.md` output, pasted in chat verbatim. THEN any commentary.
- Recurring wakeup prompt (ScheduleWakeup) updated to require reading and pasting `cron_report.md` literally as the first step.
- M-002 already enforces that the file gets written + committed. M-022 adds the "always show it" rule on top.

## M-021 — Honesty scoring is a SEPARATE LABELING PASS. Never inside selection or perspective fetch.
**Date:** 2026-05-23 evening
**User said:** "The honesty score should not affect any picking of stories or picking of the perspective sub-stories. What the fuck are you doing?"
**Root cause:** When I restored honesty (M-020), I put the rubric inside the Grok selection prompts (update.sh) AND inside the Stage 2 perspective-fetch prompt (find_perspectives). Grok then used the rubric to filter — picking high-honesty items and dropping the rest. Cron at 22:10 UTC shipped only 2 World / 1 USA / 0 Business. WRONG architecture: selection and scoring must be independent passes.
**Enforcement:**
- Selection prompts (update.sh news-tabs + top tab) have honesty REMOVED. Note added: "Honesty scoring happens downstream — do NOT score honesty here, do NOT filter by honesty."
- `find_perspectives` prompt has honesty REMOVED with the same note. Validation no longer accepts honesty/notes fields from Grok's perspective response.
- New `score_honesty(url, body, headline)` function in parse_grok.py: one xAI call per item, returns `{honesty, notes}` only. Never drops, never filters — returns `{honesty: None}` if scoring fails.
- New scoring pass after all selection + perspective work: iterates every shipped story AND every shipped perspective across news tabs, scores in parallel (ThreadPoolExecutor max_workers=10), and writes honesty + notes onto each item.
- M-020's "every story has honesty" goal achieved via the new pass — but selection counts are no longer suppressed because Grok never sees the rubric during selection.

## M-020 — Honesty scores 1-10 on every news story + perspective. Restored 2026-05-23.
**Date:** 2026-05-23 evening
**User said:** "Make sure you include honesty scores. We've had that for well over a month, and all of a sudden it's disappeared. I think that disappeared when you did Restretto."
**Root cause:** The Ristretto pipeline swap (commit 6ed5a87) stripped the honesty rubric from update.sh's Grok prompts. Grok stopped returning a `honesty` field. Frontend renders honesty only when `s.honesty` exists, so the score footnote silently went blank. The pre-Ristretto rubric was in update.sh from commit 47cd960 era — restored from `git show 41fbf89:update.sh`.
**Enforcement:**
- `update.sh` news-tab schema now requires `"honesty": <1-10 integer>` + `"notes": "<one-line plain-English justification>"` on every item.
- Rubric in the prompt: 10=verified fact only; 9=factual report with light framing; 8=analysis/commentary/think tanks (CSIS, Brookings, Heritage, RAND, AEI etc. NEVER 10, max 8); 7=opinion/take; 6=specific misleading claim; 5=demonstrably false; ≤4=serial misrep. Video/audio of person speaking = attribution verified.
- Both the news-tab schema (`if/elif/else` branch) and the `call_grok_top_multi` schema carry the rubric.
- Stage 2 `find_perspectives` already requests honesty per perspective.
- Frontend `renderAutoEmbedBlock` renders the Honesty footnote card at the bottom of the expanded body when `s.honesty` is set and the tab isn't entertainment-only (`NO_HONESTY_TABS`).

## M-019 — Perspective search drills into REPLIES/QTs of the source tweet, not the whole platform. Tiered view minimums.
**Date:** 2026-05-23 evening
**User said:** "Are you sure we're searching that correctly? Not just stories, but someone who's taken a story and we retweeted it with a negative comment? ... I want it to always be clean and objective by number of views. Maybe lower the perspective below 5K if you don't have any Democrat contrasting view, as long as it's not some Yahoo."
**Root cause:** Initial Stage 2 prompt asked Grok to find "reaction tweets ABOUT this story" anywhere on the platform. That surfaces the loudest right-leaning accounts who post their own takes — but misses the contrarian replies and quote-tweets sitting directly underneath the source tweet, which is where the political diversity actually lives. Cron #7 result: 8 of 9 perspectives were Conservative, 0 Democrat takes on USA stories.
**Enforcement:**
- `parse_grok.py::find_perspectives` prompt now restricts search to "REPLIES and QUOTE-TWEETS of the source URL" — explicitly NOT the whole platform.
- Per-label view minimums (`_PERSPECTIVE_MIN_VIEWS`): Conservative 5K, Democrat 1K, Independent 1K. Lower Democrat floor compensates for typical lower-engagement contrarian replies on right-favoring stories.
- Quality floor: account must have ≥1K followers + real bio + substantive comment (no "lol"/emoji/spam).
- Self-quote guard: perspective URL can't equal `story_url`.
- NO curated handle list — search is open and view-driven (user mandate: "I don't want a rat's nest of looking for specific people").

## M-018 — Stage 2 perspectives: Conservative + Democrat for every World/USA story. Independent optional. NEVER block a story.
**Date:** 2026-05-23 evening
**User said:** "To find the three perspectives once the stories are chosen, if they have over 50,000 views, I have to believe you're going to be able to find the top-viewing stories from each political perspective: Conservative, Independent, and Democrat. Definitely no failure mode here. A bigger story should not be scrapped if you can't find all three perspectives. I would even go down to: if you can only find one perspective, that's okay."
**Refinement (same turn):** Independent is nebulous — drop the always-find-Independent requirement. Conservative + Democrat are the primary two slots; Independent ships only when a genuinely unique non-partisan take exists. Re-fetch every cron, no caching.
**Enforcement:**
- `parse_grok.py::find_perspectives(url, headline)` — one xAI call per chosen World/USA story. Asks for Conservative + Democrat (required slots) and Independent (only if genuinely non-partisan). Returns up to 3 valid perspectives; missing slots are fine.
- Each perspective validated: must have `/status/` URL, label in {Conservative, Democrat, Independent}, ≥5K views. Bodies clipped to 600 chars.
- Wired into the World/USA branch AFTER `chosen` is finalized. Parallelized via `concurrent.futures.ThreadPoolExecutor(max_workers=6)`. Stories without perspectives ship as inline-embed-with-honesty blocks (per M-017).
- ANY exception during perspective fetch is caught, logged, and the story ships with 0 perspectives.
- Re-fetched every cron — `_s.pop('perspectives', None)` clears stale data when nothing's found this cycle.

## M-017 — Click block -> expand inline -> X embed loads + honesty score at bottom (REVERSAL of M-001).
**Date:** 2026-05-23 evening
**User said:** "Going backwards, do it like we had it before, where you click on the block and it opens the X post within the block with an honesty score."
**Supersedes:** M-001 (direct-link blocks) and M-015 (perspective-guard branch). M-016's no-icons rule is still active — no badges, no "X ↗" — just the embed loading inline.
**Enforcement:**
- `index.html::renderAutoEmbedBlock` is the inline-expand version: `<div class="story"><div class="story-header" onclick="toggle+toggleEmbed">▶ headline</div><div class="story-body">[X embed slot][honesty footnote card]</div></div>`.
- World/USA tab render: when no perspectives, calls `renderAutoEmbedBlock(s)` (which now expands inline). When perspectives exist, calls `acc(headline, renderWorldStory(s))` for the 3-way split.
- `deploy.sh` direct-link guard REMOVED.
- `verify_mandates.sh` M-001a/b/c checks REMOVED, replaced by M-017a/b/c which require `classList.toggle`, `toggleEmbed`, and the honesty footnote card to be present.
- If the embed fails to load within 6 seconds, `toggleEmbed`'s built-in fallback shows an "Open on X →" link as graceful degradation (no other place in the code displays that text).

## M-016 — NO host-label icons in block headers. NO "X ↗" / "YT ↗" badges. JUST the headline.
**Date:** 2026-05-23
**User said:** "I said get those fucking X with the arrow links to go to the X website. We've talked about that probably a thousand fucking times. I just want to be able to click the block and go to the site, so stop it."
**Root cause:** I added an `openIcon` / `hostLabel` rendering ("X ↗", "YT ↗", "TikTok ↗", "IG ↗") to the block header thinking it would help users see where the link goes. The user has said repeatedly: no ornaments. The block itself is the link. Tap = open. Don't put a visual click target inside the block.
**Enforcement:**
- `index.html::renderAutoEmbedBlock` returns only `<a class="story story-link"><div class="story-header"><span>{body+postedTag}</span></div></a>` — no openIcon, no hostLabel, no arrows.
- `verify_mandates.sh` checks the active function body for absence of `hostLabel`, `openIcon`, and `&#8599;` (the ↗ entity). Regression aborts cron + deploy.

## M-015 — World/USA tabs use the direct-link block when there are no perspectives.
**Date:** 2026-05-23
**User said:** "I noticed when I click on any block in the world tab, it still doesn't show me anything from X."
**Root cause:** World/USA tabs render via `acc(headline, renderWorldStory(s))`. `renderWorldStory` returns `""` when `s.perspectives` is missing (always true in Stage 1). `acc()` then produces a block with an empty `.story-body`. Clicking expanded the body but there was nothing in it — no embed, no link, no way to reach X. The direct-link fix in M-001 ONLY touched `renderAutoEmbedBlock`, not `renderWorldStory`/`acc`. World tab still broke.
**Enforcement:**
- `index.html` World/USA render path: `if (s.perspectives && s.perspectives.length) { acc(...) } else { renderAutoEmbedBlock(s) }`. Both the live `.stories` loop and the `earlier` loop use this pattern.
- When Stage 2 ships perspectives back, the `renderWorldStory` perspective blocks themselves also need to be direct links (deferred — flag this mandate then).

## M-014 — Cross-tab dedup needs 3+ shared tokens; LLM semantic backstop catches the rest.
**Date:** 2026-05-23
**User said:** "#2 seems more inclusive, but if we could also add to the backend of that an AI intelligence QC check where it reads all the stories to make sure none are the same."
**Root cause:** Rule-based QC with 2-token threshold killed USA #2 "Trump admin finalizing AI deal with Anthropic for US spy agencies" because it shared `{trump, deal}` with World #3 (Iran deal). Two completely different deals, but Trump+deal is background noise in political news.
**Enforcement:**
- `parse_grok.py::_qc_is_dupe` now takes `min_shared` kwarg. Caller passes `2` if `prev_tab == this_tab` (within-tab), `3` otherwise (cross-tab). Stops generic-word false positives crossing tabs while staying strict on within-tab clusters.
- `parse_grok.py::_qc_llm_semantic_dedup(output)` — single xAI call after the rule pass, sends all shipped news-tab headlines, asks it to flag pairs that are the SAME event despite different wording. Drops lower-priority tab's story. Graceful fallback if xAI errors (logs, never blocks the cron).
- Log lines tag each rule-based drop as `within-tab` or `cross-tab` so the audit shows scope; LLM drops are tagged `[qc-llm]`.

## M-013 — Mandate checks are HARD-FAIL. No soft-mode bypass. Mandate regression blocks the cron + deploy.
**Date:** 2026-05-23 ("How about just hard-code it so you stop forgetting things that we've talked about?")
**Enforcement:**
- `verify_mandates.sh` is a hard-fail audit script (no `RULE_AUDIT_SOFT` equivalent — it cannot be silenced).
- `update.sh` calls `bash verify_mandates.sh` as pre-flight; failure aborts BEFORE the Grok run starts.
- `deploy.sh` calls it again as the final gate before pushing to Netlify; failure aborts the deploy.
- If any check fails, the cron literally cannot reach Netlify until the enforcement point is restored.
- The old `verify_rules.sh` stays for the legacy graveyard checks but remains in SOFT mode — only `verify_mandates.sh` blocks.
