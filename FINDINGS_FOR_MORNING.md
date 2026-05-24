# Findings for morning — Ristretto-diff audit + overnight QC

Generated overnight after crons #29 and #30 both completed cleanly.

## TL;DR of what's working now

- **Stability:** crons #29 and #30 both deployed cleanly, all tabs populated, no errors.
- **M-040 oEmbed verification is catching real hallucinations.** Cron #29 alone dropped:
  - Jan 6 / @hannahgais story (URL pointed to @edward_bernayz's Azealia Banks tweet)
  - Mahmoud Khalil USA story (URL hallucinated)
  - BBC Taiwan story (URL hallucinated)
  - Kyle Busch death (URL hallucinated)
  - 3 perspective URLs (@carlwheless, @NancyMace, @LiberalAchaean)
  - **Roughly 6 of 90 URLs = ~7% Grok hallucination rate.** This filter is now permanent.
- **M-026 500K bypass fired** on the AI EO / David Sacks USA story (1.4M views, 40h old) — exactly the late-bloomer case you described with the Barilla pasta plant.
- **M-037 newspaper headlines** rewrote 7 of 10 Elon emoji-reaction posts into real headlines using parent context. Example: `"Praises Sikh community"` → `"Henry Nowak stabbed to death by Sikh man, handcuffed while dying"`.
- **Stage 2 perspectives explode**: ~23 perspectives across World+USA (was ~2 before M-034/M-035/M-036).

---

## Ristretto-diff audit — features pre-Ristretto eXpressO had that current code does NOT

The Ristretto port stripped to bare minimum; eXpressO-specific features were never in Ristretto and got lost. Already restored as M-series mandates:

| Pre-Ristretto feature | Restored as |
|---|---|
| `_build_earlier()` | M-033 |
| `_process_submissions()` | M-038 (Netlify Forms pull) |
| `verify_url()` / `url_handle()` | M-040 (oEmbed handle check) |
| Parent fetch for SAS/Cowherd | already in code |
| Parent fetch for Elon | M-030 |
| Honesty scoring + rubric | M-020 → M-021 (separate pass) |
| Earlier tab schema | (already in frontend) |

**Still missing** (high → low value):

### HIGH value — would meaningfully improve current site

1. **`fix_json()` + `bracket_repair()`** — Grok JSON malformation recovery.
   - Pre-Ristretto location: `parse_grok.py` lines 354–460 of commit `41fbf89`.
   - Current state: update.sh's merge step uses bare `re.search(r'\[.*\]') + json.loads()`. When Grok returns a trailing comma, missing brace, or stray label, the whole tab silently returns `[]`. Could be losing 1–3 stories per cron without us knowing.
   - Risk if restored: zero — pure parse-time recovery, no behavior change.
   - Effort: paste 100 lines into update.sh's merge python.

2. **`humanize_headline()` + `HANDLE_NAMES` map** — display names instead of @handles.
   - Pre-Ristretto location: `parse_grok.py` lines 54–153 of commit `41fbf89`.
   - Current state: headlines that say `"pmarca on AI bubble"` ship as-is. Should be `"Marc Andreessen on AI bubble"`. Same for Shams → Shams Charania, etc.
   - Risk if restored: zero — display-only, no curation impact.
   - Effort: paste 100 lines + apply in headline post-processing.

### MEDIUM value — depends on your preference

3. **`is_recently_seen()` cross-day dedup via `seen_history.json`** — never repeat same URL within 72h.
   - Pre-Ristretto location: `parse_grok.py` lines 186–245.
   - Pro: same Newsom OC emergency story has shipped in Local every cron since #25 — would force fresh content.
   - Con: when there's genuinely only one good story (e.g. Local in SoCal), seen_history forces shipping inferior alternatives. Might empty Local entirely.
   - Risk: moderate — could empty thin tabs (Local, Conspiracy).
   - Effort: 60 lines + integration.

4. **`TAB_AGE_OVERRIDE` (soft cap) + `TAB_HARD_CAP` (absolute)** — two-tier age system.
   - Current: per-tab single cap (24h news / 48h pods / 72h science) + M-026 500K bypass for World/USA.
   - Pro: more flexibility — could let Sports show a 30h Premier League goal if nothing fresher.
   - Con: more knobs, more confusion.
   - Risk: low if defaults match current.
   - Effort: 30 lines.

### LOW value or intentionally not restored (Ristretto philosophy)

These were explicitly removed by your mandate ("just pure views, no judgment"):
- `_score_candidate()` / multi-factor scoring
- `interestingness_score()`
- `enforce_uniqueness()` / `headline_similarity()`
- `is_cheerleading()` / `is_stenography()` / `is_announcement()`
- `_is_wire_copy()` / `_is_few_words()`
- `evidence_check_score()` / `honesty_consistency_review()`
- All `clean_story()` validators

If you want these back, that's a bigger architectural choice. Don't recommend.

---

## Patterns I noticed in cron #29 and #30 that may need new mandates

1. **TOP tab is gaming/celeb-heavy** — Dead by Daylight Jason teaser dominated 4 crons in a row. By design (most-viewed wins), but you might want a news-vs-meme split.

2. **LOCAL tab stuck on one story** — Newsom OC emergency hasn't rotated since cron #25. SoCal X content is just thin.

3. **TOP tab consistently at 2 stories** — last 3 crons show only 2 ✅ (cap is `top_n=3`). Probably oEmbed verification dropping 1 hallucinated URL each time. Worth investigating: are some Top-tab Grok results hallucinated more often?

4. **WHITE HOUSE Coast Guard speech (52h, 346K views) keeps appearing as a USA candidate** but gets dropped under the 500K M-026 bypass threshold. If you want it to ship, lower bypass to 250K.

5. **MSM Kyle Busch death story** has shipped 5 crons in a row at 2.1M views. Same story refreshing. seen_history (#3 above) would rotate it.

---

## Recommended morning workflow

1. Look at the two cron reports (#29 and #30) at the top of this conversation.
2. Open `expresso-news.netlify.app` and tap through tabs.
3. Tell me which of the 4 medium-or-higher-value Ristretto restorations you want.
4. I'll implement, push, and run a verifying cron.

Site is stable and shipping good content. The whack-a-mole period is winding down — most remaining issues are editorial preferences, not bugs.
