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

## M-013 — Mandate checks are HARD-FAIL. No soft-mode bypass. Mandate regression blocks the cron + deploy.
**Date:** 2026-05-23 ("How about just hard-code it so you stop forgetting things that we've talked about?")
**Enforcement:**
- `verify_mandates.sh` is a hard-fail audit script (no `RULE_AUDIT_SOFT` equivalent — it cannot be silenced).
- `update.sh` calls `bash verify_mandates.sh` as pre-flight; failure aborts BEFORE the Grok run starts.
- `deploy.sh` calls it again as the final gate before pushing to Netlify; failure aborts the deploy.
- If any check fails, the cron literally cannot reach Netlify until the enforcement point is restored.
- The old `verify_rules.sh` stays for the legacy graveyard checks but remains in SOFT mode — only `verify_mandates.sh` blocks.
