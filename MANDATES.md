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

## M-044 — World/USA `apply_hold` sorts by RAW VIEWS, not velocity (so big late-bloomers win QC dedup ties).
**Date:** 2026-05-24 night
**User said:** "wheres my fucking report of the curated 8 world and USA ... the stories picked and posts chosen suck dick"
**Root cause:** 6.8M @WhiteHouse Trump-Iran story (31h old) was M-026-bypassed for age, then KILLED by within-tab QC dedup. The QC iterated @spectatorindex (324K) FIRST, added `{iran, trump}` to seen, and the later 6.8M story matched as dupe. Why did 324K sort first? Because `curation.story_velocity` returns `-1.0` for stories >24h without `views_at_save` (a Ristretto carry-over field). Late-bloomer viral stories sort to the BOTTOM of velocity rankings.
**Enforcement:**
- World/USA `apply_hold` call now passes `sort_key=curation.story_views` instead of `story_velocity`. Raw view count rules — the 6.8M @WhiteHouse story sorts FIRST, QC adds it to seen first, lower-view duplicates get dropped against it.
- Other tabs unchanged (still velocity).

## M-043 — When Stage 2 returns <2 perspectives on a >=100K-view story, fire a targeted opposing-view follow-up.
**Date:** 2026-05-24
**User said:** "In the World tab, how can you only have one view, the conservative view, for the first story? There have to be at least an independent and a Democrat view on that, especially if it has 315,000 views. Just look for the most viewed retweet with a different perspective criticizing it or critiquing it. That shouldn't be that hard."
**Context:** "Gaza protesters storm JFK airport in NYC" had 315K views but only shipped a Conservative reaction. Grok's first-pass `find_perspectives` returned 1 of 3, and that was the end.
**Enforcement:**
- New `parse_grok.py::find_opposing_perspective(url, headline, existing, target_label)` — targeted second xAI call. Tells Grok "I already have a Conservative take from @X saying Y. NOW FIND a Democrat reaction that CRITIQUES or DISAGREES." Stricter, narrower, easier for Grok to satisfy than the broad 3-slot ask.
- Wired into `_enrich_one`: if first pass returns 0<n<2 perspectives AND story has ≥100K views, iterate through missing labels (`Democrat`, `Conservative`, `Independent`) and call `find_opposing_perspective` for each missing one. Stop at 2 total.
- Logged as `[stage2-fallback]` so the recovery is visible in cron logs.
- Cost: 1-2 extra xAI calls per story missing perspectives. ~5-10 calls per cron tops.

## M-042 — Elon tab: 48h cap, ALL posts get parent fetch, hard rewrite-or-parent-extract for headlines.
**Date:** 2026-05-24
**User said:** "The Elon tab still looks problematic in that it doesn't seem to cover all of his posts, replies, and retweets. It should have them all. The newspaper teaser explanation header titles suck. Why is that the one that is so screwed up? Also, every one of his posts, if he's commenting on something, should have whatever he's commenting on embedded."
**Three-part fix:**
1. **48h age cap for Elon** (was 24h) — Elon's posting cadence is uneven; many posts hit 25-30h before next cron rotates them. 48h gives them a fair shot.
2. **Unconditional parent fetch** — M-030 only fired when body <60 chars or starts with `@`. Quote-tweets with substantive bodies skipped parent fetch. Now EVERY Elon post calls `fetch_parent()`; original posts return None and move on. Cost: 9-16 extra xAI calls per cron, parallelized.
3. **Newspaper-headline rewrite, hard fallback** — `fetch_headline_for_post` prompt strengthened with explicit ❌/✅ examples of reaction-style vs news-style. After xAI returns, if the result is STILL generic, fall back to extracting the first sentence of `parent_text` (truncated, validated). Better to ship the actual news verbatim than ship "Agrees with X."

## M-041 — Nested comments: every shipped PERSPECTIVE gets parent context fetched + embedded above its reply.
**Date:** 2026-05-24
**User said:** "I thought we were working on nesting comments so we know what context comments like these are speaking to. Otherwise, it's useless. No sense even posting stuff like this." (re: @AdamKinzinger perspective "If Foxnews admits it's bad, it's bad" — meaningless without the FoxNews/TreyYingst post he's replying to)
**Context:** M-030 wired parent fetch for top-level Elon stories. Earlier code wired it for SAS/Cowherd top-level. But Stage 2 perspectives (Conservative/Democrat/Independent reactions) never had parent fetch. So a reply perspective ships without the post it's responding to, and the reader sees a punchline with no setup.
**Enforcement:**
- In the World/USA branch, AFTER Stage 2's `find_perspectives` populates each chosen story, iterate every shipped perspective and call `fetch_parent(p.url)`.
- If a parent is found: attach `parent_url`, `parent_handle`, `parent_text` to the perspective dict.
- Frontend (`renderWorldStory` in index.html) already passes `parent_url` through to `toggleEmbed`, which renders the parent embed ABOVE the perspective embed.
- Parallelized via `ThreadPoolExecutor(max_workers=10)` — adds ~3-5s wall time per cron (15-20 extra parent-fetch calls).
- Log line `[persp-parent]` shows each successful enrichment.

## M-040 — Hallucination guard: verify every shipped URL via X's oEmbed API.
**Date:** 2026-05-23 night
**User said:** [screenshot] Conspiracy tab story "Jan 6 defendants now admitting to seditious conspiracy after previously blaming antifa or feds" — but the X embed loaded a totally unrelated @edward_bernayz tweet about Azealia Banks and Elon Musk.
**Root cause:** Grok hallucinated the URL. Status ID 2058169975551021412 actually belongs to @edward_bernayz but Grok paired it with @hannahgais's handle + the Jan 6 body text. The handle/status-ID combo was inconsistent. Pre-Ristretto we had oEmbed verification that caught this; it was lost in the migration.
**Enforcement:**
- New `parse_grok.py::verify_url_handle(url)` — calls `publish.twitter.com/oembed?url=...`, extracts `author_url`, compares to handle in the original URL. Returns True only if both resolve AND handle matches.
- Final sweep runs on ALL shipped stories AND perspectives across news tabs, parallelized via ThreadPoolExecutor.
- Drops any story where URL handle ≠ actual author. Drops individual perspectives that fail (without killing the parent story).
- Fail-safe: if oEmbed API errors or times out, the URL is considered unverifiable and DROPPED (better to ship less than ship wrong content).
- ~10 API calls per cron, ~1-2s wall time.

## M-038 — Post/Replace submissions: 24h public window, then private-forever in submitter's browser.
**Date:** 2026-05-23 night
**User said:** "Why don't you just put it on the post that everyone sees at least for 24 hours, and then, whoever created it, it stays in their post replace forever until they delete it?"
**Architecture (clean two-tier):**
- **Public:** for 24 hours after submission, the post shows on EVERY user's Post/Replace tab under "Reader Submissions" (server-side via cron-pull from Netlify Forms API).
- **Private:** after 24 hours, the post drops off the public list but stays in the SUBMITTER's localStorage forever (existing "Your Submissions (this browser)" section), until they manually delete it.
**Root cause this fixes:** Cron-pull from Netlify Forms got dropped in the Ristretto migration. Submissions were captured server-side but never made it to stories.json. Users (including the submitter on a different device) never saw them.
**Enforcement:**
- `parse_grok.py::pull_netlify_submissions()` — calls Netlify Forms API with `NETLIFY_SITE_ID` + `NETLIFY_AUTH_TOKEN`, filters to form name `post-replace`, drops anything older than 24h, returns list of story-shaped dicts.
- Main loop writes `output['submit'] = {'stories': [...], 'earlier': []}` AFTER the freespeech preservation step (so cron-pull doesn't get clobbered).
- `'submit'` REMOVED from the `manual_tab` preserve list — the cron now owns this tab.
- Frontend's "Your Submissions (this browser)" localStorage section is independent and unchanged.

## M-037 — Headlines are NEWSPAPER-STYLE. Generic-reaction phrasings auto-trigger a parent-aware rewrite.
**Date:** 2026-05-23 night
**User said:** "'affirming statement, this is a newspaper with attention getting headlines...does that seem like it?'"
**Context:** Stephen A Smith Sports post shipped as "Affirming a statement with Instagram reel link" — completely useless, not a headline. Same problem with emoji-only Elon replies that show up as "Reacts with target emoji".
**Enforcement:**
- `_GENERIC_HEADLINE_PATTERNS` extended: now catches `affirm(ing|s)`, `confirms a statement`, `(affirms|denies|confirms|endorses|disagrees) (a|with a|the) (statement|post|claim|video|reel|link...)`, and `with/via (an) (instagram|tiktok|youtube) (reel|video|link|clip|post)`.
- `fetch_headline_for_post` now takes optional `parent_text` and `parent_handle`. When the post is a reply/QT and we have the parent, the rewrite uses the PARENT'S content as the news hook — describes what's actually being reacted to, not the reaction itself.
- Elon branch reordered: parent fetch runs BEFORE headline rewrite (so the rewrite has parent context).
- Generic-rewrite loop for all other tabs also passes `parent_text`/`parent_handle` through.
- Prompt rewritten: explicit "newspaper headline" framing with good/bad examples ("Cybertruck photographed at Starbase launch pad" vs "Shares video link").

## M-036 — ONE perspective per label, top-viewed only. No fallback to lower-viewed alternatives.
**Date:** 2026-05-23 night
**User said:** "honesty 5 is ok if its the highest viewed [democrat] perspective. if its not, 5 is way too low"
**Interpretation:** Only the single highest-viewed reaction per label ships. If that pick fails the honesty 5 floor, the side ships empty — we do NOT fall back to the #2 or #3 viewed alternative (those would need a much higher honesty bar to count, and the simpler rule is just "top or nothing").
**Enforcement:**
- `find_perspectives` final step: group validated perspectives by label, keep only the highest-viewed per label, return in fixed order (Conservative, Democrat, Independent).
- Honesty floor (M-034: <5 drops) still applies — but to the top pick only, no substitutions.

## M-035 — Perspectives: highest-viewed wins per side. NO character minimum. NO "analysis quality" curation.
**Date:** 2026-05-23 night
**User said:** "why 80 char i never said that. shouldbe the highest viewed post for (dem) perspective for that story"
**Root cause:** I added a hidden 80-character body minimum AND framed the Stage 2 prompt around "substantive citizen-journalism analysis." Both were my overreach — user never asked for either. Combined with the prime-directive prompt, Grok was returning 0 perspectives on stories where the actual top reactions were short or non-analytical (e.g. Khalil deportation: lots of Democrat replies, all blunt, all under 80 chars and not "analytical" — Grok rejected them all per my prompt and shipped nothing).
**Enforcement:**
- `find_perspectives` Python validation: removed `len(body_text) < 80` check.
- Prompt rewritten to ask for "HIGHEST-VIEWED reaction per side" — Grok ranks by views, picks the winner.
- Auto-reject narrowed to actual abuse: vulgar slurs/personal-attacks-without-substance, pure-emoji posts, spam. No more "must be analytical" requirement.
- View floor stays (1K). Account quality floor stays (1K followers + real bio). Those are anti-Yahoo, not editorial.

## M-033 — Earlier tab restored: stories displaced this cron go into `earlier`. (Regression from Ristretto migration.)
**Date:** 2026-05-23 night
**User said:** "Why doesn't the earlier tab work anymore? You might have to go back to the expresso before you put Restratto in. You probably wiped it out during that refresh."
**Root cause:** Pre-Ristretto parse_grok.py had `_build_earlier()` that populated `output[tab]['earlier']`. The Ristretto rewrite dropped it. `earlier` was never set, so the Earlier tab on the frontend showed "No earlier stories yet today" every time.
**Enforcement:**
- New loop in `parse_grok.py` after per-tab curation: for each tab, take stories that were in the PREVIOUS cron's `stories` array but got displaced this cron, cap at 10, exclude items >24h old, write to `output[_e_tab]['earlier']`.
- Frontend Earlier tab already reads from `NEWS_DATA[tab].earlier` — no JS change needed.

## M-034 — Perspective honesty floor relaxed back to 5 from 7.
**Date:** 2026-05-23 night
**User said:** "How is there not a Democrat perspective on this story? I can't believe there's not." (re: Mahmoud Khalil deportation, 1.7M views — no Democrat take shipped)
**Root cause:** I tightened `_PERSP_HONESTY_FLOOR` from 5 → 7 in M-028 to catch vulgar attacks. That ALSO killed legit partisan reactions that scored 5-6 (specific misleading claim / demonstrably false but still a real political angle). Combined with the 80-char body min and the prime-directive prompt's auto-reject list, 7 was overkill.
**Enforcement:**
- `_PERSP_HONESTY_FLOOR` back to 5. Drops conspiracy / serial misrep (≤4) only.
- The vulgar-attack rejection still happens upstream via the prime-directive prompt (M-029) — that's what catches the "First Lady was a hooker" content, NOT the honesty floor.
- The 80-char body min still applies, killing one-liners and emoji-only reactions.

## M-032 — Test mode: test_parse.sh re-runs parse_grok against cached Grok output (saves tokens).
**Date:** 2026-05-23 evening
**User said:** "Also, instead of running a full cron, can we do like a test cron? Or you just show me the results, so we don't use so many tokens?"
**Enforcement:** `test_parse.sh` reads cached `/tmp/grok_raw.json` instead of firing the 17 selection xAI calls. Stage 2 perspectives + honesty scoring + parent fetch + headline rewrite still run live (they need fresh data). Cost per test ≈ $0.05 vs $0.50 for a full cron. Use this when iterating on prompt/filter changes; only run `run_cron_with_report.sh` when you actually want to deploy.

## M-031 CORRECTED — cron_report.md per-tab summary IS a table. (Earlier "no table" version was a misread of the user.)
**Date:** 2026-05-23 evening (originally wrong, corrected same day)
**Original misread:** I interpreted "no post report as a table" as "do not post the report as a table" and removed the table format. User clarified: "ive never said dont make a table, your halucinating ... write the table into your Python coding so you don't forget. Leave it in the exact form in this table; that's what I like."
**Correct enforcement:** `parse_grok.py` writes the per-tab summary as the EXACT markdown table the user approved: `| TAB | N | Top Views | Age range | Top Headline |` — DO NOT regress this.

## M-030 — Python-enforced PARENT FETCH for Elon replies (post what he's reacting to).
**Date:** 2026-05-23 evening
**User said:** "this is useless, post what hes reacting to embedded" (re: Elon "🎯 emoji" reply to @KonstantinKisin shown without the parent post)
**Root cause:** Elon's posts that are replies have meaning ONLY when you can see what he's replying to. The Elon prompt asks Grok to fill `parent_url/parent_handle/parent_text` but Grok ignores it ~80% of the time. Same Python-enforcement pattern we already use for SAS/Cowherd needs to apply to Elon.
**Enforcement:**
- After Elon's generic-headline rewrite, fire `fetch_parent(url)` for any Elon post where `parent_url` is missing AND body looks like a reply (starts with `@` or is <60 chars).
- Parallelized via ThreadPoolExecutor(max_workers=6).
- Frontend `toggleEmbed` already renders parent embed ABOVE reply embed when `parent_url` is populated — no frontend change needed.
- Log line `[elon-parent]` shows successful parent fetches.

## M-029 — PRIME DIRECTIVE: this site promotes CITIZEN JOURNALISM, not freaks online.
**Date:** 2026-05-23 evening
**User said:** "remember the prime directive - to promote citizen journalism, this promotes freeks online"
**Context:** The previous perspective pipeline asked for "highest-view Conservative/Democrat reactions" and Grok returned whatever was loudest — which on X is usually vulgar attacks (@taradublinrocks pedophile-rapist line, @smc429 "First Lady was a hooker" line) and substance-free cheerleading ("Way to go!" / "Congratulations!"). That's the OPPOSITE of citizen journalism. The mission is to surface substantive, thoughtful citizen voices that ADD to the story, not viral garbage.
**Enforcement:**
- `find_perspectives` prompt rewritten with PRIME DIRECTIVE framing as the FIRST line. Explicit AUTO-REJECT list (personal attacks, cheerleading, one-liners, emoji-only, generic dunks, meme-only, profanity-only). Explicit qualification criteria (original analysis, context, factual additions, first-person expertise, substantive reasoning, investigative threads).
- Quality floors raised: body must be ≥80 characters of substantive commentary. Account ≥1K followers + real bio + real posting history.
- Honesty floor of 7 (M-028) stays — combined effect: vulgar/cheerleading/short reactions get cut by both the upstream prompt AND the downstream honesty filter.
- Python-side validation in find_perspectives now drops any perspective with `len(body) < 80`.
- This mandate sits ABOVE all other Stage 2 mandates — if anything conflicts, citizen journalism wins.

## M-028 — Perspectives with honesty < 5 get dropped (post-scoring, not pre-selection).
**Date:** 2026-05-23 evening
**User said:** "honesty 3 is that even news?" — flagged @taradublinrocks Democrat reply scored honesty=3 ("But he's protecting a pedophile rapist..." — personal attack on Modi/Rubio with no facts) as not-news.
**Reconciles with M-021 (honesty separate from selection):** M-021 says honesty must NOT bias Grok's initial selection. M-028 fires AFTER honesty scoring is done — it's an editorial floor on already-scored items, not a selection bias.
**Enforcement:**
- `parse_grok.py` after honesty-scoring pass: iterate all shipped stories' perspectives, drop those with `honesty < 5` (per the rubric: 5+ keeps "demonstrably false and up"; <5 = serial misrep/conspiracy).
- Stories themselves are NEVER dropped on honesty — selection stays pure-views.
- Threshold lives in `_PERSP_HONESTY_FLOOR` constant for easy tuning.
- Log line `[honesty-floor]` shows each drop with handle, label, score, body excerpt.

## M-027 — cron_report.md timestamp shows Pacific Time (user reads in PT).
**Date:** 2026-05-23 evening
**User said:** "time stamp pacific time going forward"
**Enforcement:** `parse_grok.py` report header uses `zoneinfo.ZoneInfo("America/Los_Angeles")` to convert `lastUpdated` to PT. Format: `=== CRON @ 2026-05-23 5:49 PM PT  (2026-05-24T00:49:57Z) ===`. UTC kept in parens for traceability.

## M-026 — Big-views age exception: World/USA stories ≥500K views bypass the 24h cap.
**Date:** 2026-05-23 evening
**User said:** "yes 500k exception if late growth"
**Context:** White House @WhiteHouse Barilla pasta plant story (1.4M views) showed up in cron #13's candidate list at 49.6h old and got killed by the 24h USA age cap. The story was clearly viral but late-blooming — most likely it crossed 1M views only after the 24h freshness window. User wants those late-blooming viral hits to still ship.
**Enforcement:**
- `parse_grok.py` age-cap loop now has a per-story exception: if `_tab in {'world','usa'}` and `views >= 500_000`, the 24h cap is bypassed and the story ships even when older.
- Log line `[age-cap-bypass]` shows when this fires, with view count and actual age.
- Floor stays at 500K (not 100K) — keeps the small-fish stories on the strict 24h timeline.
- Other tabs unaffected.

## M-022 STRENGTHENED — Always cat cron_report.md after cron, no exceptions. Wrapper added.
- New helper `run_cron_with_report.sh` runs `update.sh` then `cat cron_report.md`. Use it any time we want to be SURE the report prints.
- Wakeup prompt updated to require pasting the file contents verbatim as the FIRST element of the response, no preamble.

## M-025 — Don't post anything not in English. Drop non-English stories AND perspectives.
**Date:** 2026-05-23 evening
**User said:** "dont post anything not translated"
**Root cause:** @yunuspaksoy was shipping as a World story / Perspective with a Turkish-language body. Headline read English ("Trump praises Erdogan") but the embedded tweet was entirely in Turkish — unreadable to the user.
**Enforcement:**
- `parse_grok.py::_is_non_english(text)` — heuristic: if >5% of alphabetic chars in body are non-ASCII letters (Turkish ş/ğ/ü, Cyrillic, Arabic, Chinese, etc.), treat as non-English.
- Final sweep before stories.json write: drop any shipped story where `_is_non_english(body)` is true. Drop any perspective inside surviving stories where its body is non-English.
- Headlines NOT checked — Grok always writes English summaries even for foreign posts.
- Future enhancement (NOT yet wired): auto-translate non-English bodies via xAI, attach as `translation` field, ship instead of dropping. Defer until user asks.

## M-024 — MSM tab: NEVER blank. No QC dedup. top_n bumped to 5. Low views are fine.
**Date:** 2026-05-23 evening
**User said:** "msm should not be blank, so many choices, low views makes sense, the opposite"
**Root cause:** Mainstream media accounts (NYT, WaPo, CNN, BBC, AP, Reuters, etc.) cover the same big stories that are in World/USA — that's literally what "mainstream media" means. The QC cross-tab dedup was emptying the MSM tab because every MSM story shared tokens with the World/USA shipped story it was reporting on. Cron #15 saw 5 MSM items from Grok, dedup killed 3 directly + the rest got dropped, MSM shipped 0.
**Enforcement:**
- `_DEDUP_ORDER` no longer includes `'msm'` — QC dedup never touches MSM stories.
- `top_n=5` for MSM (default is 3) — show more mainstream coverage angles per cron.
- No view floor (MSM never had one). Wire-service and beat-reporter posts often sit at 30-80K views; that's fine.
- 24h age cap still applies (MSM should be fresh news, not yesterday's coverage).

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
