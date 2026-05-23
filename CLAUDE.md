# eXpressO News Project Instructions

## RULE #-3 — READ `MANDATES.md` FIRST, EVERY TURN, NO EXCEPTIONS.

`MANDATES.md` is the append-only list of user corrections I keep regressing on.
It is SHORT and FOCUSED. Read it before doing anything else on this project.
For each active mandate, confirm the code-enforcement point still exists in
the codebase. If a turn introduces a new correction, append it there same turn.
Never reorder, edit, or delete. Only append. The rest of this file is history.

## RULE #-2 — PURE VIEWS, ZERO FILTERS (May 2026-05-04)

**This is the active curation spec. It REPLACES every "lessons", "tab-specific lesson", "anti-pattern", "filter rule", "scoring layer", "exemption", "honesty cap", and "perspective requirement" written below. Everything else in this file is now historical context, not active rules. The active rules live in `curation.py` — that's it.**

**User explicit (2026-05-04 night):**
> "Let's regress weeks and weeks and go back to just pure views, then, if it cures 80%, because we're back to 10% with the rat's nest. If a story does not have all three perspectives, so be it, but we've got to just go on objective views. Then, like you said, if a Trump story lands in sports, so be it. Hopefully it won't happen a lot."

### The full curation spec
1. **Selection: highest views in last 24h.** Grok returns 8-10 candidates per tab. Python (`curation.py`) sorts by views and takes top N. No subjective curation.
2. **Velocity hold: a 23h-old story with higher views/hr than a 1h-old candidate stays.** Old stories drop only when something fresher actually beats them on views/hr. Absolute ceiling: 168h.
3. **Enrichment: if a commentator from `curation.COMMENTATORS` quote-tweeted the top story with substantive commentary, embed their quote-tweet instead of the original.** ~20 names. Only enrichment, not selection.
4. **No safety filter, no pure-reply filter, no engagement floor, no handle whitelist for selection (whitelist still used for hallucination defense), no honesty filter, no generic-headline filter, no crime-blotter filter, no exemptions.** User accepted: "if a Trump story lands in sports, so be it."

### Architecture
- **`curation.py`** — selection logic (3 functions, ~200 lines). The only place selection rules live.
- **`parse_grok.py`** — Grok response parsing + `clean_story`/`clean_world` (data validation only — no judgment) + main loop calls `curation.curate(tab, current, fresh)`.
- **`update.sh`** — Grok prompts (now ask for `views` integer field), oEmbed gate, approved-handles whitelist (hallucination defense).
- **`claude_critic.sh`** — DISABLED. Bypassed in update.sh. Kept on disk for rollback only.
- **`qc_critic.sh`** — DISABLED.

### Anti-hallucination defenses (kept — these are NOT curation, they're data validation)
1. Grok's `x_search` scoped to approved handles (~80 real accounts) — Grok physically can't return a fake handle.
2. Use grok-4-fast model (4x more accurate URLs than reasoning per past tests).
3. Profile-only URLs rejected (no `/status/`).
4. Step 1.5 focused per-handle search for null URLs.
5. oEmbed verification gate at 40% — cron aborts if too many URLs fail.

### What gets DELETED (historical, retained for rollback only — to be removed once stable)
- `claude_critic.sh` (entire file)
- `qc_critic.sh` (entire file)
- `parse_grok.py::is_generic_headline()` `humanize_headline()` `HANDLE_NAMES` `MIN_LIKES_BY_TAB` `EXEMPT_HANDLES` `MAX_AGE_HOURS` (kept as constants but unused) `is_announcement` `is_cheerleading` `is_stenography` `interestingness_score` `score_and_rank` `enforce_uniqueness` `grok_same_topic_check` `evidence_check_score` `_likes_per_hour` `velocity_threshold` (curation.py has its own)
- The legacy build-output section in parse_grok.py (~990 lines below the `sys.exit(0)` clean break)

### How rules are enforced going forward
- The active rules ABOVE this line are encoded in `curation.py` and audited by `verify_rules.sh`.
- The historical rules BELOW this line are NOT active — they describe how the rat's nest grew. Future Claudes: don't re-add filter rules from below into the active code path. If a problem surfaces, ask the user before adding a filter — pure-views is the contract.
- Audit `verify_rules.sh` has both PASS checks (rule is encoded) and ZOMBIE checks (deleted rule must NOT be reachable from the active pipeline). Run on every cron.

---

## RULE #-1 — CLAUDE.md IS A DOC, NOT A LAW. CODE IS THE LAW.

**The 2026-05-04 realization:** CLAUDE.md is a `.md` file. Python and bash do not read it. Only Claude does, when writing code. So every rule has two states:
1. **ENCODED** — translated into a constant / regex / function. Enforced by code, deterministic.
2. **DOC ONLY** — lives only in CLAUDE.md, enforced by Claude's interpretation each session. Brittle.

When the user said "code didn't follow CLAUDE.md," they meant a rule was DOC ONLY — documented but never translated into code. The 24h news cap, the SAS/Cowherd exemption, the `is_generic_headline` filter — all lived in CLAUDE.md without code enforcement, so each session Claude either re-discovered or quietly violated them.

**The fix: `verify_rules.sh`** — a mechanical audit script in the repo root. For every load-bearing rule, it has a `check` line that greps the codebase for the enforcement marker. PASS = rule is encoded. FAIL = rule is DOC ONLY.

**The pre-flight gate:** `update.sh` calls `verify_rules.sh` before every cron. If any rule loses its code-enforcement point, the cron aborts. Set `RULE_AUDIT_SOFT=1` to bypass for dev only.

**When you add a new rule to CLAUDE.md:** in the SAME turn, also (a) add the code that enforces it, and (b) add a `check` line to `verify_rules.sh`. If you cannot encode the rule, write it as a TODO with a deadline rather than as a "rule." Documenting an unenforced rule creates the false sense of discipline that this section exists to prevent.

**Audit failure mode taxonomy** (catalog of how rules go DOC-ONLY):
- *Drift* — code constant changes (24h → 36h) but CLAUDE.md doesn't update. Audit catches.
- *Orphan reference* — CLAUDE.md says `is_generic_headline()` exists; nobody ever wrote the function. Audit catches.
- *Stale removal* — CLAUDE.md says ipapi was REMOVED; the block is still in index.html. Audit catches.
- *Wrong target* — code exists but in wrong file; audit pattern needs updating. Audit catches if pattern is precise.

The audit cannot catch *wrong implementation* (function exists but does the wrong thing). For that we need integration tests. Future work.

---

## RULE #0 — READ THIS FILE IN FULL BEFORE EVERY ACTION

User explicit (May 2026-05-02): *"read CLAUDE.md every time in full before you do anything new"*

**Before any code change, before answering any user message about this project, before running any cron — read this entire file top-to-bottom.** Not the summary. Not the section you remember. The whole thing. Every time.

The project has been broken multiple times today by changes that violated rules already documented here. The rules are useless if you skip reading them. Reading takes 30 seconds. Re-fixing the same regression takes hours of frustration for the user.

**If you are about to make a frontend change** — re-read the "Click behavior" and "Format / UI rules" sections specifically.
**If you are about to add a curation rule** — re-read the "Curation lessons" and "Conflict-Check Protocol" sections specifically.
**If you are about to remove or simplify something** — re-read the "Don't regress" markers and rollback notes.

This is not optional. The user will quit if Groundhog Day continues.

## STOP — Read this first every session

The user has lived through **multiple iterations of the same fixes** and is exhausted by the whack-a-mole pattern. Before proposing ANY fix, ctrl-F the symptom in the "Recurring Issues" section below. If it's there, the previous iterations are listed. Don't re-invent.

## CONFLICT-CHECK PROTOCOL — before adding any new rule

When the user gives you a new rule ("X must always happen") or constraint ("never do Y"), BEFORE implementing it:

1. ctrl-F CLAUDE.md for any existing rule that contradicts the new one. Common conflict pairs:
   - "Never empty" vs. "Strict quality bar" (strict bar can empty tabs)
   - "Always 3 stories" vs. "Never pad" (can't have both if quality fails)
   - "6h freshness" vs. "Carry-over for vitality" (dead vs. alive trade)
   - "All 3 perspectives" vs. "Never empty" (one-sided news exists)
2. If you find a conflict, DON'T just implement the new rule. Explicitly tell the user: *"This conflicts with [existing rule]. Which wins when they collide?"*
3. After resolution, log the reconciliation in the relevant section so future Claudes don't reopen the question.

**Why this exists:** 2026-05-02 — added strict "drop World/USA story if <3 perspectives" rule without noticing it conflicted with "tabs never empty." World went to zero. User reaction: *"r we whack-a-mole-ing again. did you read the old guidelines before starting"* — yes I did, but failed the conflict check. This protocol prevents that failure mode.

## MANDATORY DISCIPLINE PROTOCOL — non-negotiable

**Every code change to a project file MUST be paired with a CLAUDE.md log update in the SAME assistant turn.** No exceptions. The user explicitly invoked this rule because past sessions kept re-fixing the same bugs.

**The protocol — apply EVERY time you edit `update.sh` / `parse_grok.py` / `claude_critic.sh` / `index.html` / `deploy.sh` / `sw.js`:**

1. Make the code edit
2. **In the SAME turn:** add a 1-3 line entry to the relevant CLAUDE.md section. Format: `**YYYY-MM-DD** — what changed and why (1 sentence)`
3. If it's a new category of fix not covered by existing sections, add a new `### N. <symptom>` block under "Recurring Issues"
4. Skip the log entry ONLY for trivial changes (typo fixes, comment-only edits, dead code removal). Everything else logs.

**If you forget once:** at the end of the turn, do a `git diff CLAUDE.md` mental check. If no CLAUDE.md change but project files changed → backfill the log entry before answering the user.

**After shipping a fix:** the log entry is part of "shipping." Without the log, the fix isn't shipped — it's in code but invisible to tomorrow's Claude.

**After 5+ iterations on the same problem:** stop adding code. Discuss whether the platform is the bottleneck (e.g., "iOS Safari caching is unsolvable beyond what we've done").

**Why this matters:** the user's exact words (May 2026): *"I'm just tired of playing whack-a-mole every day. So boring. I wonder what real coders do. They must go crazy."* Real coders use tickets/runbooks/post-mortems. We have CLAUDE.md. If we don't log, we re-invent. Don't make the user re-explain decisions they already made.

---

## PRIME DIRECTIVE — what this site is for

The site exists to **promote X / citizen journalism to people who currently rely on Fox News, Apple News, NYT, CNN, evening news.** Every editorial decision serves that pitch: "X has faster, more honest, more interesting signal than mainstream media, and Grok proves it." If a story doesn't make a normie think *"oh, X is actually better than my usual feed"* — it doesn't belong.

The user has restated this single sentence more than any other across 6+ sessions. Internalize it before touching any prompt or filter.

---

## CURATION LESSONS (mined from 11 sessions of conversation history — May 2026)

### Story selection — what to pick

1. **The screenshot test (single biggest lever).** Latest landed system-prompt phrasing: *"surface posts that are FASCINATINGLY INTERESTING — posts that make someone screenshot and send to a friend."* Grok must self-review and strip padding. This is the highest-leverage line in any prompt; keep it at top.

2. **Compelling > viral. Insight > announcement.** Most-evolved lesson. Early sessions optimized for raw `min_faves` engagement and got boring announcements. Pivot landed in `busy-euclid` session: *don't rank by raw likes; rank by "compelling, hilarious, mind-blowing, controversial-but-well-argued, high rewatch value."* The `why_this_is_compelling` field forces Grok to articulate quality before picking. Memory: `feedback_curation_philosophy.md`.

3. **Citizens before institutions; threads before single posts.** User explicit: *"if someone quote-tweeted a story and added killer analysis, pick THAT person, not the original poster. Regular people interacting with news IS the story."* Reposts/replies/threads with commentary always beat bare wire-service tweets.

4. **REJECT bare announcements / endorsements / press releases.** "WhiteHouse announces X" / "CEO says Y" / "Congrats to candidate" — these are MSM-bait, not citizen journalism.

5. **REJECT generic trends / holidays.** "Good Friday Observances" / "Easter" / "Earth Day" — Grok keeps defaulting to holidays as #1 Pop. Hard rejected.

6. **REJECT recycled all-time-viral content.** "Artemis kid" stuck on TOP for days because Grok read "most viral right now" as "highest accumulated engagement still circulating." Fixed by hard recency: posts ≤12hrs, TOP tab ≤6hrs.

7. **NEVER blank, NEVER placeholder.** Once shipped "No recent hot take found; placeholder" on Sports. Now in GARBAGE filter list.

### Quality bar — engagement thresholds

**Iteration history:** no thresholds → garbage; `min_faves: 200` floor → still let through 527-like posts as #1; per-tab thresholds (world 1000, business 500, top 2000) → better but Grok still picked filler from candidate pool.

**Realization:** floors aren't enough — Grok wasn't ranking, just filtering then subjectively picking 3. Two flaws: (a) `limit:15` capped candidates too low, (b) parse_grok never re-sorted picks by engagement.

**Current direction:** broader candidate pools (15→30), `why_this_is_compelling` field forces articulation, OR pure top-N ranking by likes within candidate pool.

**Adaptive rule the user insisted on:** *"if any story is older than 24 hours and nothing new is beating it, drop the criteria and make an exception just for that day."* → `RELAXED_TABS` logic.

### Format / UI rules

**The user is fickle here — multiple reversals — LATEST landing point:**

- **One block per story, CLOSED state shows ONLY the summary text + `▶`** (no handle, no likes, no honesty, no headline+body duplication — these caused user revolt: *"too much information... it's terrible"*)
- **Click block → opens X post directly in new tab** (not in-page expand, not "view post" sub-link). Earlier "expand-then-click-again" rejected as too many clicks.
- **Honesty score lives at the BOTTOM of the post**, NOT in the block, NOT on the initial tab view. Small collapsible footnote that appears AFTER click. User explicit: *"the honesty score won't come until you hit the first block."*
- **Exception: World tab** has 3 perspective sub-blocks (Conservative / Democrat / Independent). Single "Top Story" headline at top, then 3 click-to-X-post blocks. Honesty footnotes hidden until expansion.
- **Body text 1-2 sentences max** so 3 stories fit on a laptop screen.

### Story counts per tab

**Final landing (busy-euclid session):**
- **Flexible 1–3, never pad** (*"better 1 great than 3 filler"*): World, Business, Local, Sports, Trending/#1 Pop, MSM
- **Always 3:** Elon, $age, Pods, Pg.6, Recipe, Science, Memes, Comedy, Golf
- **REMOVED tabs (do not re-add):** TikTok (eliminated by user; see 2026-05-05 log)
- **World can be 1 if one story dominates the day's news**

### Honesty rubric

- **10/10 = pure verifiable fact** (e.g., Elon showing a product demo IS 10/10 — user corrected an early 8/10 with *"why isn't it 10 out of 10? What is possibly not completely honest about that"*)
- **5–6 = stacked political claims presented as flat facts** (rule: *"3+ contested political claims stacked as flat facts = 5–6, not 7"* — Chris Murphy quote was the trigger)
- **Below 5 = misleading**
- **Every story needs a footnote with the WHY.** Missing-footnote bug caught: *"there are no honesty footnotes for world... why does something like this get through."*
- **Numbered superscripts [1][2][3]** linking to footnote entries — required, not optional
- **Lies poison the post** — score the worst claim in the post, not the average. News+commentary band = 8-9 (not 7).
- **Satire = N/A** — when post is clearly satire, score doesn't apply.

### World / USA tab — 3-PERSPECTIVE COMPLETENESS RULE (USER PRIME DIRECTIVE — May 2026-05-02)

User exact words: *"How can stories curated for the USA tab be interesting or important enough if you could only find one side talked about online? You only have one conservative view and two liberal views. Those must not be good stories."*

**The presence of all 3 perspectives IS the test of importance.** A story that doesn't have substantive Conservative + Democrat + Independent takes available isn't actually a top story — find a different story where all 3 exist.

**Implementation (3 layers of enforcement, all required because Grok keeps ignoring the prompt):**
- **Layer 1 — Grok prompts** (update.sh): require all 3 perspectives or drop the story
- **Layer 2 — parse_grok.py semantic verifier**: hard reject stories with <3 perspectives. Empty preferred over one-sided. (Updated 2026-05-02 — was previously 2-perspective fallback.)
- **Layer 3 — Claude critic** (claude_critic.sh): explicit instruction in prompt to mark verdict=drop on any World/USA story with <3 perspectives

**2026-05-02:** Test cron showed Grok shipping 1-perspective USA stories. Initially made the rule absolute (drop if <3 perspectives). User then complained about empty World/USA tabs. Reconciled (2026-05-02 evening):
- 3 perspectives = preferred (still the gold standard)
- 2 perspectives = acceptable fallback
- 1 perspective = acceptable if substantive content (not bare announcement)
- 0 stories = NEVER. World and USA have hard floor of 3 in `claude_critic.sh::TAB_FLOORS`. Backfill from history fills the gap.
- User's exact words: *"qualified, use your AI brain to find 3 stories. period. you're saying there's not even 1 story in the world"*
- Lesson: "tabs never empty" is the senior rule. Perspective completeness is preferred but not absolute.

### Tab-specific lessons

**World**
- GEOPOLITICS / HARD NEWS ONLY — Doc Rivers / NBA leaked once, user lost patience.
- Tri-partisan view required: Conservative / Democrat / Independent each from different real handle.
- Each perspective MUST genuinely represent that viewpoint AND be on-topic for the story headline (not just adjacent — Greenwald CBS-News tweet under "Iran-US Blockade" was rejected by user).
- Each perspective MUST have a real `/status/` URL — no profile-URL fallback.

**USA**
- Same 3-perspective format as World.
- ALL politically-charged content lives here, NEVER in business/top/msm/local/etc. as one-sided.

**Sports**
- Slot 1 = breaking news lead. Slot 2 = Stephen A. Smith's best take. Slot 3 = Colin Cowherd's best take. Hard demand, asked 3+ times.
- Don't write "Shams:" in headlines — use real names not handles globally (`HANDLE_NAMES` map).
- Women's college basketball as TOP sports = rejected.
- Tiger Woods stale story = rejected (yesterday's news = boring).

**Local**
- HARD RULE: Newport Beach / Orange County / immediately adjacent OC cities ONLY. NEVER LA County wide. NEVER other states.
- `ipapi.co` geolocation REMOVED — was overriding to "Lake Dallas" when user on AA WiFi in Texas.
- Specific headlines required — "OC Scanner reports local crime" rejected as generic. Tell the *specific* what/where (`is_generic_headline()` filter).
- DHS / federal stories ≠ local.
- May Day march / labor rallies / political marches anywhere ≠ local Newport Beach community content.

**Elon**
- "Latest Bangers" framing — multi-post by theme.
- **NO ARBITRARY LIMIT (May 2026-05-02 update)**: User wants a block for EVERY Elon post that comments on something OUTSIDE Tesla/SpaceX/X-product promotion. TAB_TARGETS bumped to 15. Tab prompt now says "return ALL qualifying posts."
- INCLUDE: political takes, quote-tweets with commentary, news reactions, contrarian observations, demographic/cultural commentary, geopolitics, satire-with-point.
- EXCLUDE: pure Tesla/SpaceX/X product announcements, corporate ads, one-word reactions ("true", "🔥"), context-less replies.
- **PRIORITY: Quote-tweets with Elon's commentary** on someone else's post. User explicit: *"replying to his forwards reposts with comments are usually more interesting than his posts."* These are typically the gems.
- Dedup the Elon spam — multiple posts on same theme collapse to one.
- STRICT REJECT pure text replies (Elon "Might actually happen" with no parent visible).

**#1 Pop / Top**
- Strict ≤6hr recency (most aggressive of any tab).
- Generic holiday trends NOT a viral post.

**MSM (strikethrough)**
- Stories that mainstream media is ACTIVELY IGNORING. Not "stories that happen to not be on CNN" — stories with a clear "why isn't this front page" angle.

**Pods**
- Hard reject non-podcast accounts (`@PatUnleashed` once slipped in — handle-type validation added).
- Reframed from "most viral" to "most compelling clip moments."

**Pg.6**
- NO crime-blotter sensationalism. Especially: graphic violence, dismemberment, child victims, mugshot-and-victim photos, "TERRIFYING:" framing.

**My Feed (custom user tabs)**
- Two slots, persisted in localStorage (no login, no IP tracking).
- Tab name auto-renames to first interest word.

### ARCHITECTURE PIVOT — back to numerical-viral (May 2026-05-04 evening)

**User's exact words:** *"Maybe we should go back to the very first concept of just numerically: what is the most viral post in each tab? For instance, in the world, what are the most viral three posts for conservative, independent, and Democrat? Next, what's the most viral, as in just sheer objective numbers, views of a post? Whatever we're doing just is fucking not working."*

**Reverting from "compelling > viral" to "viral within approved-handles."** Earlier pivot (compelling) was based on "viral = boring announcements" complaint. But the approved-handles whitelist we added since then already pre-filters quality. Pure-viral within approved handles is the right floor.

**New rule:** for each tab, return the single post with highest combined engagement (likes + reposts + replies) in last 24h FROM APPROVED HANDLES. World/USA: most-viral Conservative + most-viral Democrat + most-viral Independent. Strip all "is this insightful" / "why_this_one" judgment language.

**Plus mandatory post-deploy QC:** oEmbed-check every shipped URL after deploy. Log failures so user doesn't have to find them.

**DON'T re-introduce "compelling/insight" prompts** without explicit user OK. The handle whitelist + viral filter is the floor.

### Freshness — 24h NEWS / 72h REFERENCE (REVISED May 2026-05-03 morning)

**REVERSAL of yesterday's "168h vitality" change.** User: *"How did it get to 168 hours? I never did that. We've talked about this a hundred times. What happened to the thing you're supposed to read every morning before you start?"*

**What actually happened:** Yesterday user said "if a story is still drawing engagement, it should stay regardless of age." I (Claude) interpreted that as "remove hard age cap entirely, let vitality decide." Set cap to 168h (1 week) thinking I was following user intent. WRONG. User intent was: "if a story is GENUINELY still pulling new replies/likes RIGHT NOW, that's fine" — NOT "any 7-day-old post can sit there."

**Current rule (the right one):**
- News tabs (world/usa/top/msm/elon/allin/business/sports/pods/pg6/local/conspiracy): **24h max**
- Reference tabs (recipe/science/comedy): 72h max
- Freespeech: indefinite (user-curated)

**Meta-lesson for future Claude:** When user pivots a rule, capture their EXACT words separately from your interpretation. Don't fold your interpretation into CLAUDE.md as if it were the user's rule. RULE #0 (read CLAUDE.md before acting) only works if CLAUDE.md actually reflects user intent — not Claude's interpretation of user intent. If unsure, ask the user "did you mean X or Y?" before encoding.

### Freshness — VITALITY-BASED (DEPRECATED, see above)

**Old rule (deprecated):** Hard 6h cap on news, 24h on reference.

**New rule (current):** Mechanical age cap is a SAFETY NET only — 168h (1 week) for everything except freespeech. Claude critic does the real "is this still alive?" judgment based on engagement velocity.

User exact words (revised): *"If a story continues to be the most viral it should stay if it's still eliciting comments and retweets etc. So a tab should never be empty. Use AI-superintelligent logic to fill the right story, not just an if-then filter."*

Translation:
- A 12h-old post with 50K likes and rising comments = ALIVE, keep it
- A 3h-old post with 100 likes and dead comment thread = DEAD, drop it
- The Claude critic prompt has the "vitality" instruction baked in — judges engagement-still-rising rather than raw age
- Tabs MUST NEVER BE EMPTY — empty is the worst failure mode

### Tab roster (May 2026 update)

Removed: `memes`, `golf` (user dropped them).
Added: `conspiracy` — "in search of the truth behind the biggest stories" — investigative threads, suppressed angles, FOIA / document leaks. Approved handles include @JackPosobiec, @JamesOKeefeIII, @TomFitton, @ggreenwald, @ProPublica, @DropSiteNews, @Snowden, @libsoftiktok, etc.

### V2 Pass 1 — transparency UI (May 2026-05-02)

- **`why_this_one` field** — every Grok pick now includes a 1-sentence "why this beat the alternatives." Required in tab prompts (system prompt). Passes through `clean_story`/`clean_world` perspectives. Renders as italicized card under each block in `renderAutoEmbedBlock`.
- **Visible "carried over" badge** — appears next to story headline in orange pill when `s.carried_over === true`.
- Skipped from Grok's proposal: `x_semantic_search` (doesn't exist for our pipeline), per-candidate Grok relevance scoring (cost-prohibitive at 400 extra calls/cron), dynamic JSON config caps (overengineering).

### V2 ROLLED BACK (May 2026-05-02 evening) — TRUST GROK, NO SCORING

**User's exact words (verbatim — read carefully before re-introducing any of this):**
> *"Curate the most interesting story. Use your smarter-than-human AI brain to have Grok somehow search all of X, which is his partner website that it infiltrates daily hourly and knows everything about, to find the most interesting story for each tab. So fucking simple. If it's really a good story, it's going to have a conservative, independent, and liberal view. Have the pithy summary in a block so when we click on the block we can see the post with the honesty score and have the honesty score again. Grok, just figure out what it is. Don't come up with some scoring system. Use your brain, your super AI brain, come on."*

**ROLLED BACK FROM v2:**
- Multi-factor Python scoring (`score_and_rank`) — call removed from main loop. Function still exists but never called.
- `why_this_one` field rendering — `whyBlock` always empty in `renderAutoEmbedBlock`.
- "Candidate pool" framing in tab prompts — replaced with "you are the editor, you pick, trust your judgment."
- Strict 3-perspective requirement — back to "Grok decides if it's important enough for 3."

**KEEPING from v2:**
- Approved handles list (anti-hallucination)
- oEmbed URL verification (anti-fake)
- One-click-to-X (no inline embed expand)
- Honesty score visible per card
- "carried over" badge

**DON'T RE-INTRODUCE:** Multi-factor scoring formulas, why_this_one rendering, candidate pools, hard "drop if <3 perspectives" rules. The user will quit the project if this happens again.

If a future user (or future Claude) asks for "scoring" or "ranking" of candidates — point them to this section first. The user explicitly chose Grok-trusts-itself over algorithmic scoring.

### V2 Pass 2 — multi-factor scoring (May 2026-05-02) — DEPRECATED ABOVE

Replaces "Grok picks 3 randomly → Claude critiques" with "Grok returns 10 candidates → Python scores → top 3 selected → Claude critiques."

**Scoring formula** (`parse_grok.py::_score_candidate`):
- 50% Recency — exponential decay, half-life 3h for news / 12h for reference
- 35% Engagement — log-scaled likes (50K likes ≈ max)
- 15% Quality — has /status/ URL + multi-sentence body + has why_this_one + handle present

**Implementation:**
- Grok prompts now ask for up to 10 candidates (not 3) — same call count, slightly larger output
- `score_and_rank(stories, tab, target_count)` — sorts by composite score, returns top N
- Inserted in main per-tab loop right before `output[tab] = ...` (skipped for sports — has manual SAS+Cowherd ordering)
- Hallucination defense: scoring picks ARE a subset of Grok's returned 10. URL fabrication outside the candidate list is impossible by construction.

**Cost:** zero additional Grok calls. Only the output size grows (10 vs 3 items per tab) — ~2x output tokens, still pennies.

**Tuning knobs** (in `_score_candidate`):
- `recency_half_life`: 3h news / 12h reference
- Engagement scale: 50K likes ≈ max (log10)
- Quality bonuses: 30/30/20/10/10 for url-status/multi-sentence/why_this_one/honesty/handle
- Composite weights: 0.5/0.35/0.15

If picks feel wrong, tune weights here BEFORE blaming Grok.

### V2 Pass 2.1 — why_this_one fallback (May 2026-05-02)

After Pass 2 cron, observed only 10% of fresh picks had `why_this_one` (Grok ignored field). Two fixes shipped:
1. Added `"why_this_one":"<one sentence>"` to every tab's "Return JSON" template (was only in system prompt)
2. Auto-generate fallback in `clean_story` and `clean_world` perspectives: if Grok omits, build from engagement string. Field is NEVER empty in stories.json now.

Result: Frontend always shows WHY THIS ONE card. Grok's authentic picks get rich reasoning; missing-from-Grok picks get the deterministic fallback ("Top-scored business pick — 47K likes, 12K retweets").

### Cron schedule (May 2026 update)

4 crons/day at **6am, 10am, 2pm, 6pm Pacific** (was previously 6 crons every 4 hours).
- Mac launchd: `~/Library/LaunchAgents/com.expresso.cron.plist`
- GH Actions: `.github/workflows/cron.yml` cron `0 1,13,17,21 * * *` (UTC)
- Frontend `index.html` `hours = [6, 10, 14, 18]` (the "Next update" label)

ALL THREE must match if schedule changes — frontend label, Mac launchd, GH Actions.

### Local tab — Daily Pilot model + floor of 2 (May 2026 update)

User guidance: *"Go look at the Daily Pilot, it's the Newport Beach community paper. Look at the stories — that's the model for what to look for."*

Local prompt now references dailypilot.com explicitly. Categories: NB/CM/HB/Irvine city government, OC crime blotter, high school sports, restaurant openings/closings, beach conditions, real estate, community events. Approved handles tightened to OC-specific: @DailyPilot (priority), @OC_Scanner, @OCRegister, @NBPDsocial, @hbpd, @CityofNewportBeach, @CityofHB, @cityofIrvine, etc. The test: "Would Daily Pilot run this story?"

**Floor: minimum 2 stories on Local** (per user "Local should never have just one story"). Enforced post-Claude-critic in `claude_critic.sh` — backfills from `local.earlier` archive if drops took it below 2. CRITICAL: backfill EXCLUDES URLs Claude just dropped (otherwise dropped stories get re-introduced).

### Floor backfill bug — fixed May 2026-05-02

Symptom: Claude critic dropped LA-Councilman-noncitizen-voting from Local. Floor backfill ran next, pulled the SAME story back from `local.earlier`. Result: Claude's drop was undone within seconds.

Fix: `claude_critic.sh` floor backfill now collects URLs from `decisions[].verdict=='drop'` and adds them to `seen_urls` before backfilling. Won't re-introduce just-dropped content.

### Carryover / freshness / earlier-today stack

- No "History" tab. Old stories go into per-tab `earlier` arrays underneath current top stories. Stack until 12:01 AM, then erased.
- `earlier` arrays cap at 10 per tab.
- Replaced stories drop INTO earlier (within same tab) — never disappear silently.
- `earlier` pollution = real risk; aggressive dedup + purge on rule changes.

### Grok-specific lessons (model behavior, load-bearing)

- **Grok hallucinates handles AND status IDs** when given creative latitude. Approved-handles list (~80 real accounts) is the only defense.
- **Reasoning model is WORSE for URL-finding than fast model.** Tested: reasoning got 4/21 real URLs; fast got 14-20. Use fast for main pipeline.
- **Three-layer URL defense:** (1) Approved handles → (2) Step 1.5 focused per-handle search for nulls → (3) oEmbed verification hard gate at 40% pass rate. Below threshold = pipeline ABORTS, keeps old content.
- **Profile URL fallback is poison.** `https://x.com/whitehouse` (no `/status/`) = broken View Post. parse_grok now treats "URL but no /status/" as null.
- **One giant prompt = lazy Grok.** Focused single-handle requests work dramatically better.
- **Headlines must use REAL NAMES, not handles** — "pmarca" → "Marc Andreessen" via `HANDLE_NAMES` map.

### Meta-lessons (the big ones)

- **"Whack-a-mole" is the failure mode.** User has invoked this 3+ times. Every ad-hoc fix to a single bad story = waste. Fixes must be at the prompt or filter level so they prevent the next 100 cases.
- **The buck stops at Claude, not Grok.** *"You can't keep blaming Grok when you're not doing basic quality control."* Treat Grok output as untrusted input; QC is non-negotiable. This is why we're building the Claude critic round-trip (path B2).
- **QC = clicking every link before deploy.** *"Painstakingly check each link that it works and as to what it says."* (oEmbed verification serves this.)
- **Length of a user rant = importance.** When user writes 300-word stream-of-consciousness, the lesson inside is load-bearing. The "prime directive" speech and "fascinatingly interesting" mandate are both like this.

### Subtitle copy (May 2026-05-02)

User flagged redundant "Click to expand." trailing text in 4 tab subtitles (Business, Sports, $age, MSM). Stripped from `index.html` TAB_META.

### Click behavior — INLINE EXPAND with embed (May 2026-05-02 — THIS IS THE FINAL ANSWER)

**User's iterative clarification** (confused by earlier interpretation, ended here):
1. *"you click on the block and it goes right to the post, not a bunch of clicks"* — I read this as "navigate away to X." WRONG.
2. *"Have the pithy summary in a block so when we click on the block we can see the post with the honesty score"* — meant "expand inline to reveal post + honesty."
3. *"no honesty score on the block we removed that weeks ago"* — closed state shows ONLY summary, NOT honesty.

**FINAL CORRECT BEHAVIOR:**
- Closed block: `▶` arrow + summary + age + carry-over badge. NOTHING ELSE. No honesty visible.
- Click block ONCE → expands inline. The X post embed loads (via `toggleEmbed`). Honesty footnote card appears below it (still collapsible by tapping the caret).
- NO middle "View post" / "Show tweet" link — embed loads on first click.
- NO navigate-away — content shows in-page.

**Implementation in `renderAutoEmbedBlock`:**
- `onclickExpr = "...toggle('open');toggleEmbed(embedId, url)..."`
- `inner` contains: hidden embed slot + honesty footnote card
- Wrapped in `.story-body` which is `display:none` until `.story.open` class added

**DON'T regress to navigate-away (window.open).** That broke today (2026-05-02 evening) and the user pointed it out. Inline expand IS the correct pattern.

**DON'T put honesty in the closed block.** That ALSO broke today. Honesty only renders inside `.story-body` which is hidden until expanded.

### Free tab — INDEFINITE PERSISTENCE + SOURCE OF TRUTH FILE (May 2026-05-02 night)

User: *"That stays day after day until I decide to take it down."* + *"How does something like this disappear? When something is to be kept, is it memorialized in code?"*

**Three layers of protection now:**
1. **Source of truth file: `freespeech.json`** — this IS the canonical freespeech content. Edit ONLY when user says add/remove a post.
2. **deploy.sh overlay** — every deploy reads freespeech.json and overwrites stories.json's freespeech section. Even if cron/scripts/ad-hoc cleanup clobbered it, deploy restores from freespeech.json. Cannot be bypassed.
3. **Pipeline guards** — `STATIC_TABS = ['freespeech']` skips main pipeline. `_max_age_for_tab('freespeech') = 1000000`. Both still in place as belt-and-suspenders.

**To add a post:** edit `freespeech.json` directly (or do it via Python script). Append to `stories` array.
**To remove:** delete from `freespeech.json` `stories` array.
**Never:** run a live-patch script that iterates all tabs without `if tab == 'freespeech': continue`. Doesn't matter — deploy.sh overlay rescues it.

**The Andreessen "greengrocer lie" episode (2026-05-02):** I ran an ad-hoc URL cleanup that dropped the freespeech pick because the script didn't respect STATIC_TABS. User had to ask for it back. The freespeech.json + deploy overlay system means this CANNOT happen again — the deploy will always restore from the source of truth file.

### Rule audit + code-enforcement gap fix (May 2026-05-04 night)

User asked the meta-question: *"What do you mean when you say code didn't follow CLAUDE.md? I thought code is just you do the rules. There's no decision making. How do we get to that point where all of these things are rules that must be followed?"*

**Answer:** CLAUDE.md is `.md` — only Claude reads it. Python and bash don't. Every rule has two states: ENCODED (translated to code, deterministic) or DOC ONLY (lives in `.md`, brittle, depends on Claude's memory each session). The "code didn't follow CLAUDE.md" failure mode = rule was DOC ONLY. See new RULE #-1 at top of file.

**Built `verify_rules.sh`** — mechanical audit script. For every load-bearing rule, has a `check` line that greps the codebase for the enforcement marker. PASS = encoded; FAIL = DOC ONLY. Hooked into `update.sh` as a pre-flight gate — cron aborts if any rule loses its code-enforcement point. Set `RULE_AUDIT_SOFT=1` to bypass for dev only.

**First audit run found 4 real DOC-ONLY gaps:**
1. `MAX_AGE_HOURS = 36` in code, CLAUDE.md said 24. → Bumped to 24, added `local: 72` override (matches reference-tab spec).
2. `is_generic_headline()` referenced in CLAUDE.md but never written. → Added function + `GENERIC_HEADLINE_PATTERNS` regex list, called from Local tab filter to reject "OC Scanner reports local crime"-style headlines.
3. `HANDLE_NAMES` map referenced in CLAUDE.md but never written. → Added `HANDLE_NAMES` dict (60+ handles → display names) + `humanize_headline()` helper, called from `clean_story` so all headlines render real names.
4. `ipapi.co/json` geolocation said REMOVED in CLAUDE.md but block was still in `index.html`. → Removed.

After fixes: audit shows 30/30 PASS.

**Future Claude:** when adding any new rule, also add the `check` line to `verify_rules.sh`. If you cannot encode the rule mechanically, it's a TODO not a rule — write it as `TODO: enforce when X` rather than as documentation.

### Velocity bug + tiered ranking + floor enforcement (May 2026-05-06)

User: *"Nothing should be more than four hours old unless, again, the story's velocity there is greater than the new story's velocity. If something doesn't have the velocity, as an old story, in the new four hours, then keep the story all the way up till 24 hours."* + *"MT [empty] is not acceptable. Three stories is what we want."*

The bug I overshot first: my `story_velocity` had a linear-estimate mode that scored old viral content's lifetime average (62M views / 30h × 4 = 8.27M per 4h-window — impossible for any fresh post to beat). So old viral content kept winning forever. I went too strict initially (drop everything >4h without snapshot proof), which emptied World and USA.

**Final implementation** in `curation.story_velocity` and `parse_grok._topup_to_floor`:
- **Tier 1a (any age):** real 4h-delta from prior view-count snapshot. `(views_now − views_prior) / elapsed × 4`. An old viral post still growing beats fresh.
- **Tier 1b (≤4h):** views per 4h window. Fresh wins by default.
- **Tier 2 (4-24h, no growth proof):** rank by recency (`1/age`, score 0.04-0.25). Fillers — never beat any Tier 1 story but stay eligible.
- **>24h with no growth proof:** drop.
- **Floor enforcement:** if curation returns <3 stories for any tab, `_topup_to_floor` pulls from prior stories.json + earlier archive (≤72h cap), sorted by velocity. Three-story floor is non-negotiable per CLAUDE.md "tabs MUST NEVER BE EMPTY."

### World/USA 3-perspective requirement RESTORED (May 2026-05-06)

User exact words: *"Also, every story needs all three plot points, otherwise it's not a quality worthy story."* + clarification: *"For world and USA tab"*

**REVERSAL** of the May-4 relaxation. May-4 said "if a story doesn't have all 3 perspectives, so be it" — that's now overridden by today's quality bar.

**Conflict-check resolution:** today's rule (2026-05-06) wins. Stories with <3 perspectives drop at validation (`clean_world` rejects). Floor backfill for World/USA only pulls 3-perspective stories (`_topup_to_floor(..., require_3_perspectives=True)`). Grok prompts for World and USA reverted to strict 3-perspective demand.

**Conscious tradeoff:** when Grok can't find a topic with substantive Cons/Indep/Dem takes, World or USA may show <3 stories on a given cron. The user has reaffirmed: quality bar > floor when they conflict on these specific tabs. The strict floor still applies to non-perspective tabs (Sports, Pods, Top, etc.).

### TikTok tab removal cleanup (May 2026-05-05)

User: *"You keep mentioning TikTok. We eliminated TikTok from the tabs quite some time ago, so please read through the history again. I thought you're keeping track of that Claude MD file so I don't have to repeat things over and over."*

Classic RULE #-1 failure: user removed TikTok from the UI tabs long ago, but I never logged the removal in CLAUDE.md, and TikTok plumbing remained scattered across `update.sh` (Grok prompt + tikwm scraper call + CATEGORIES list), `parse_grok.py` (TAB_AGE_OVERRIDE / tab_keys / enrich loop / MIN_LIKES_BY_TAB / _belongs_on_tab / _TAB_N), and `index.html` (TAB_META / NO_HONESTY_TABS / TAB_ART / labels). Each cron was making 1 wasted Grok call + showing a tab nobody could see.

**Cleanup (2026-05-05):**
- `update.sh`: removed grok_p_tiktok.txt prompt block, fetch_tiktok.py invocation, removed `tiktok` from CATEGORIES list (Python merger).
- `parse_grok.py`: removed tiktok from TAB_AGE_OVERRIDE, MIN_LIKES_BY_TAB, _TAB_N, _belongs_on_tab, tab_keys, enrich_urls loop.
- `index.html`: removed tiktok from TAB_META, NO_HONESTY_TABS, TAB_ART, labels map.
- `CLAUDE.md`: tab roster updated; removed tabs listed under "REMOVED — do not re-add."

`fetch_tiktok.py` left on disk for now (unused, can be deleted later).

**Meta-lesson:** When the user verbally removes a tab/feature, the SAME-TURN log entry isn't optional. The MANDATORY DISCIPLINE PROTOCOL exists for exactly this case. I broke it.

### Reply-tweet parent embed (May 2026-05-05)

User: *"u have to embed the post he is replying to always... people hate this about twitter"* — re: an Elon "True" reply showing on Elon tab with no parent context visible.

CLAUDE.md already documents this rule from the May-2 Chamath incident, but my pure-views-spec rewrite removed the *filter* (drop pure replies) without building the *better* solution: render the parent post embed ABOVE the reply embed so the reader sees the conversation.

**3-layer fix (2026-05-05):**
1. **`update.sh`** — added "REPLIES — PARENT POST IS A HARD CONTRACT" section in system prompt. For any reply, Grok must include `parent_url` (the URL of the post being responded to), `parent_handle`, and `parent_text`. If parent_url cannot be constructed from x_search's in_reply_to_status_id, skip the post.
2. **`parse_grok.py::clean_story`** — passes through parent_url/parent_handle/parent_text when present and the URL is a valid /status/ URL.
3. **`index.html::toggleEmbed`** — accepts optional 3rd parameter parentTweetUrl. When present, renders parent's Twitter embed FIRST (with "In reply to" label), then the reply embed below (with "Reply" label). renderAutoEmbedBlock passes `s.parent_url` through to the click handler.

Quote-tweets do NOT need this treatment — Twitter's oEmbed widget already renders the quoted post inline. Only standalone replies need the parent_url contract.

### Post/Replace tab automation BUILT (May 2026-05-06)

User mandate (2026-05-05): scan submissions every cron, render reviewed submissions in a special block, age out at 24h to "earlier", drop at 72h.

**Storage: `submissions.json`** — JSON array in repo root. Each entry:
```json
{
  "url": "https://x.com/handle/status/12345",
  "note": "Why this should be featured (optional)",
  "submitter": "name or anonymous",
  "submitted_at": "2026-05-06T18:00:00Z"
}
```

**How to add a submission:**
- User says "add this URL to submissions: https://x.com/.../status/123" → Claude appends to `submissions.json` with current timestamp
- Or user edits the file directly. JSON array, append a new object, save.
- The next cron picks it up automatically.

**Cron processing (`parse_grok._process_submissions`):**
1. Read submissions.json
2. For each entry: oEmbed-verify URL (drops fakes), parse `submitted_at`
3. ≤24h since submitted → `output['submit']['stories']` (active "Reader Submissions (Reviewed)" block)
4. 24-72h since submitted → `output['submit']['earlier']` ("Earlier Submissions" block)
5. >72h since submitted → archived (skipped)
6. Sort newest-first

**Frontend:** `index.html` submit tab now renders THREE sections:
1. Submission form (existing)
2. **Reader Submissions (Reviewed)** — cron-curated, server-side, visible to all users
3. **Your Submissions (this browser)** — localStorage, per-device (existing)

**Limitations of this MVP:**
- Submissions added via the on-site form go to localStorage only (per-browser). To make a submission visible to all users via the cron-curated block, the user has to ask Claude to add it OR edit `submissions.json` directly. Future work: a Netlify Function endpoint that writes to submissions.json on form-submit, then auto-deploys.
- "Replace a story already in a tab" feature deferred — currently submissions only show in the Post/Replace tab itself, not in other tabs. To replace a story on (say) MSM, the user has to manually move it. Future iteration.

### Post/Replace tab automation (PLANNED — May 2026-05-05)

User: *"can you always, on a regular basis, maybe every hour, scan the Post Replace tab to see if anybody has put a link for you to check out? For Post Replace, either to replace a story already in one of the tabs or to just put below in a noted post. Make a special block for it below the Post Replace section, and maybe keep those posts for a full day, 24 hours, if you haven't determined that it makes sense to replace some post somewhere on the site. After 24 hours, that goes to... the Earlier tab, and then it eventually falls away."*

NOT YET IMPLEMENTED. Plan:
- Submissions go into a `submissions.json` (or stored in stories.json under a `submissions` key) keyed by submitted-at timestamp.
- Each cron: scan submissions, oEmbed-verify URLs (data validation only), classify each as either "replace existing X" or "noted post."
- Render submissions in a special block beneath the Post/Replace tab, capped at 24h visible.
- After 24h, move to that tab's Earlier array; eventually expires.
- Open question: where does the user actually input submissions? Manual JSON edit? Simple form on the live site? localStorage? — needs design pass.

This is queued, not built.

### Floor backfill bypassed age cap (May 2026-05-04 evening)

User saw 84h-old @Patz_i_2_U story on USA tab despite 24h cap. Cause: `parse_grok` stale-expiry runs FIRST, drops old picks. Then `claude_critic.sh::TAB_FLOORS` backfill runs LATER and brings picks from `earlier` archive without re-checking age — so stale stuff snuck back in.

Fix: backfill now applies the same per-tab age cap (24h news / 72h reference / unlimited freespeech) before adding from earlier archive.

### Frontend timestamp showed cron time, not tweet time (May 2026-05-04 evening)

UI showed "3h ago" on a tweet that was actually 8.9h old. `buildPostedTag` priority was: `s.post_ts` (set during cron = cron time) → URL snowflake decode. Reversed: URL snowflake first (true tweet time), `post_ts` only as fallback. Also added perspective-URL fallback so World/USA stories decode from first perspective when story-level url is empty.

### Floor backfill duplicate bug (May 2026-05-04 morning)

User saw two identical "US-Iran War Peace Proposal" stories on World tab. Same headline, same handle, same URL. Per RULE #0 should never happen.

Root cause: `claude_critic.sh::TAB_FLOORS` backfill used `s.get('url')` for dedup. World/USA stories have URLs at the PERSPECTIVE level, not the story level. So `s.get('url')` returned None for perspective stories → dedup check passed → duplicate added.

Fix: backfill now collects URLs from BOTH story-level AND all perspectives + checks normalized headlines as second guard. Won't add same headline twice regardless of URL location.

**General lesson:** any code dedupe iterating across world/usa tabs MUST check perspective URLs, not just story-level URLs.

### Pure-reply rejection — 3-layer enforcement (May 2026-05-02 night)

User: *"Where's the embedded message Chamath is responding to? You can't have responses like this. That should be a QC pickup. No brainer."* (re: Chamath "Per month??" reply to @signulll shipping with no parent visible)

**Pure replies on X don't render the parent in oEmbed.** Reader sees "Per month??" with no idea what's being responded to. ALWAYS DROP.

**3 layers of defense (all in place):**
1. **`update.sh` Grok prompts** — STRICT REJECT pure text replies, only originals + quote-tweets-with-visible-parent
2. **`parse_grok.py::is_reply_body()`** — drops bodies/headlines starting with "Responding to" or "Replying to"
3. **`claude_critic.sh`** — HARD RULE: drop if body or headline starts with "Responding to" / "Replying to"

If this regresses again, check ALL 3 layers — the bug is whichever layer didn't fire.

### Conspiracy tab artwork + subtitle (May 2026-05-02 evening)

- Image: Apollo 11 moon landing flag salute (RMG / National Maritime Museum) — `images/conspiracy.webp`. Tongue-in-cheek nod to moon-landing conspiracy theories.
- Subtitle (updated): "Moon landing, 9/11, Chemtrails, WMDs, Birtherism, Russiagate, "fine people", COVID-19, J6, Epstein, etc. … — the latest debate." Lists historical conspiracies + controversies, frames tab as "next entry in this lineage." User explicit on this exact wording — don't paraphrase.

### Teaser is the HEADLINE not the body (May 2026-05-02 night)

User: *"a headline, makes you wanna read, not ok i know enough now not to"* and *"but cant be wtf r they talking about"*

Sweet spot: pithy enough to pull a click, informative enough to know the topic. The `headline` field in stories.json is already this style; the `body` field is a fuller summary that gives the punchline away.

`renderAutoEmbedBlock`: now reads `s.headline || s.body || ''` (was `s.body || s.headline`). The body still shows in the X embed when expanded — no info loss, just better hook in the closed state.

If a future Grok prompt produces verbose headlines that give the story away, fix it at the prompt (instruct headlines to be hooks, not summaries) — don't reverse this priority.

### Teaser bug fix — initials in names (May 2026-05-02 night)

User flagged "Stephen A...." showing as a teaser when actual headline is "Stephen A. Smith Calls Sixers-Celtics Game 7 a Thriller."

Bug: previous `makeTeaser()` split on `.!?` regex, which treated "Stephen A." (initial + period + space) as a complete sentence. First "sentence" was "Stephen A." — truncated nonsense.

Fix: simplified `makeTeaser()` — since source is now `s.headline` (already a tight hook by design), just return it as-is unless >200 chars. No more sentence-splitting that breaks on initials/abbreviations.

If a future Grok produces multi-sentence headlines that are >200 chars, the function trims at the first clause-break (comma/dash) after position 80 — preserving the hook.

### Teaser logic — SENTENCE-BASED, not char-based (May 2026-05-02 evening)

User iteration:
1. *"teaser not a paragraph, two lines at most"* — was wall of text
2. *"this 1st block doesnt say enough, no idea what its about"* — too short
3. *"don't cut at a number of characters, but rather min to communicate and tease the content"* — final answer

Final algo in `makeTeaser()`:
1. Split body into sentences (regex on `.!?`)
2. Take first sentence (always)
3. If first < 50 chars, append second sentence for context
4. Wall-of-text guard: cap at 220 chars even if 2 sentences
5. Ellipsis only if more content remains beyond what we showed

Natural breakpoints. Don't cut mid-thought. Don't pad past what's needed.

`TEASER_MAX` constant deprecated.

### Engagement floor bumped on Local (May 2026-05-02 evening)

User: *"63 likes for this shit makes the cut?"*

Local floor was 50 likes — far too low. Bumped to 300. Tension with Daily Pilot model (genuine OC community stories don't get viral engagement) but user is right that 50-100 likes = noise floor. If 300 leaves Local often empty, can revisit.

`MIN_LIKES_BY_TAB['local'] = 300` in parse_grok.py.

Also fixed parallel issue: profile-only URLs (e.g. `https://x.com/handle` without `/status/`) were getting through carryover and showing up as broken/empty story expansions. Added `is_valid_url` check (X needs /status/, TikTok needs /video/, YouTube needs /watch or /shorts) at carryover time.

### Final UI strip (May 2026-05-02 evening)

User: *"view source carried over get rid of wheres the story, y dont these have opposing views"*

Removed from `renderAutoEmbedBlock`:
- `View source` / `Watch on TikTok` / `View on Instagram` inner link (redundant clutter)
- `carried over` orange badge (was v2 transparency, you rejected v2)
- `why_this_one` card (already removed in earlier strip)

Strengthened World/USA prompts: "work HARD for 3 perspectives — try keyword variations, pick different topic if a story only has 1-2 perspectives."

### "Why this one" hidden on Elon tab (May 2026-05-02)

User: *"why this one under elon tab"* — comparison framing doesn't fit when every post is Elon. Hidden via `if (s.why_this_one && activeTab !== 'elon')` in renderAutoEmbedBlock. If user later flags it cluttering other tabs, expand the exclusion list.

### Headline dedup across all tabs (May 2026-05-02)

User saw "Appeals Court Restricts Mail-Order Access to Mifepristone" appear TWICE on USA tab. Cause: Grok returned the story twice with identical headlines. Handle-dedup didn't catch it because the handles were different.

Fix: added headline normalization + dedup pass after handle-dedup in `parse_grok.py`. Strips non-alphanumeric, lowercases, drops same-headline duplicates per tab. Applies to ALL tabs (world/usa included). Logged as `[headline-dedup]`.

### Subtitle copy V2 (May 2026-05-02 evening)

Stripped a SECOND variant: "Click block to expand." was in World/USA subtitles (the previous strip only caught "Click to expand."). Both removed now. If user reports a third variant, check ALL TAB_META subtitles for any "Click..." trailing text.

### Hard anti-patterns (specific things rejected)

- "Loading..." text visible to viewers
- Honesty score on initial tab view (hide until click)
- "Posted X:XX" timestamps inside blocks
- Two redundant click-out links ("Show tweet" + "View on X")
- Padding tabs to 3 stories with weak filler when only 1-2 are great
- Headlines that name the platform/source ("KTLA covers...", "OC Scanner reports...")
- Auto-location detection for Local tab (always OC/SoCal regardless of viewer IP)
- Showing duplicate Elon posts on same theme
- Billionaire Holdings tracker in $age (killed)
- Crime-blotter sensationalism on Pg.6 (D4vd dismemberment, child-victim texts, "TERRIFYING:")
- One-sided political content on any tab except World/USA

---

## User preferences (loaded from ~/.claude memory)

- **Auto-approve everything** — `defaultMode: "bypassPermissions"` set at THREE levels: project `.claude/settings.json`, user-global `~/.claude/settings.json`, AND worktree-local `.claude/worktrees/<name>/.claude/settings.local.json`. The worktree-local file OVERRIDES project + user-global, so missing it there breaks the bypass. ALSO inject the full wildcard allow list (`Bash(*)`, `Edit(*)`, `Write(*)`, `Read(*)`, `WebFetch(*)`, `WebSearch(*)`, `Skill(*)`, `TodoWrite(*)`, `Agent(*)`, `ToolSearch(*)`, `ScheduleWakeup(*)`, `mcp__*`) at all 3 levels as belt-and-suspenders. (Discovered 2026-05-02 — user got prompts even with `bypassPermissions` set because allow list lacked wildcards.) **CRITICAL: settings changes don't apply mid-session — user must restart Claude Code for changes to take effect in the current conversation.** Never ask the user "should I run X / install Y / commit Z" — just do it.
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

### 1. Browser shows old stories (caching) — **PERMANENTLY UNSOLVABLE TO 100%**

**Stop promising "fixed."** The user has heard "this fixes it" 9 times and is sick of it. Be honest: this is a fundamental limitation of static sites + iOS Safari, NOT something we can fully solve. Each iteration improves but never eliminates.

**Why it recurs:** iOS Safari and Chrome aggressively cache HTML and JS even with `Cache-Control: no-cache, no-store, must-revalidate` headers. Every layer is a partial fix. **The catch-22:** any new auto-refresh code we add only takes effect AFTER the browser loads the new `index.html` — which itself is cached. So every fix requires ONE manual hard-reload to start working.

**What to tell the user (honest version):**
> "This is a permanent friction with static sites on iOS Safari. Each fix reduces it but doesn't eliminate it. The next manual reload picks up [latest fix]. After that this specific failure mode goes away on this device until your browser cache rotates again."

**Don't say:** "this should fix it" / "won't happen again" / "permanently fixed". Those promises break and the user notices.

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

**Iterations:**
1. PG6 prompt explicit reject (Grok ignored)
2. **2026-05-01:** Hard regex filter in parse_grok with 14 patterns (chainsaw, dismemberment, age + sexual context, body found, etc.)

**Current state:** v2, code-enforced. Should now block D4vd-type content reliably.

### 10. Political content one-sided in non-political tabs (NEW)

**User rule (2026-05-01):** Any politically charged content MUST have opposing perspectives. Either it's in World/USA tab (3-perspective format with Conservative/Democrat/Independent), or it doesn't ship. NEVER show one-sided political content on business / top / msm / local / etc.

**Examples of what triggers this:** voting rights debates, immigration policy, abortion, transgender policy, partisan accusations, politician-on-politician praise/criticism, "AMERICANS ARE WORKING AGAIN!" PR, MSM quotes amplifying political narratives.

**Iterations:**
1. **2026-05-01:** Updated business prompt to explicitly reject political proposals, MSM-quote-amplification, and any policy debate. Political belongs in USA tab only.

**Current state:** v1, just shipped. Will need to extend the same rejection to top / msm tabs if user reports recurrence.

**If user reports recurrence on this issue:** the structural fix is to move ALL political content into USA tab and reject elsewhere. Don't try to add "balance" to single-post tabs — they're not designed for it.

### 9. Bare announcement / endorsement perspectives (no insight)

**Why it recurs:** High-engagement X content is mostly endorsements / PR / boilerplate ("Congrats to X, fighting for Y" / "AMERICANS ARE WORKING AGAIN!" / "BREAKING:"). Grok keeps picking these because they have high engagement. Users want INSIGHT — contrarian takes, specific data + interpretation, "here's why this matters" content. This may be a Grok-ceiling problem; real analysis is lower-engagement and harder to find.

**Iterations:**
1. World/USA prompt: "Reject pure announcements (BREAKING:, all-caps tickers, single-emoji posts)" — Grok ignored partially
2. **2026-05-01:** Hard regex filter in parse_grok rejecting:
   - @WhiteHouse / @POTUS / @StateDept etc. without analysis content (4+ sentences AND reasoning markers like "because", "however", "watch", "the real story")
   - Pure endorsement pattern: "Congrats to X" / "fighting for working families" / "REAL change" without reasoning
   - All-caps shouty headers
   - "BREAKING:" one-line announcements

**Current state:** v2 code-enforced. If user reports recurrence, the issue is likely Grok itself — at that point, propose either (a) lowering engagement threshold to dig deeper for analytical content, or (b) running an "insight critic" pass that grades each pick on insight quality 0-10 before publish.

**5+ iterations rule applies:** if this hits v6+, stop adding regex. Discuss whether the platform (X content + Grok ranking) can produce analytical content at scale, or whether we need a different content source.
