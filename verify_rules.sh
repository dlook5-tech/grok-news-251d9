#!/usr/bin/env bash
# verify_rules.sh — mechanical audit: every CLAUDE.md rule has a code-enforcement point.
#
# Why this exists:
# CLAUDE.md is markdown. Python and bash do not read it. Only Claude does, when
# writing code. Every rule has two states:
#   1. ENCODED   — translated into a constant/regex/function. Enforced by code.
#   2. DOC ONLY  — lives only in the .md, enforced by Claude's interpretation.
# This script greps the codebase for each rule's enforcement marker. PASS = encoded.
# FAIL = the rule lives only in CLAUDE.md and depends on Claude's memory each session.
#
# 2026-05-04 PURE VIEWS REWRITE: the audit is now organized around three groups:
#   A. Selection authority — curation.py is THE selection module
#   B. Zombie checks — old judgment layers must NOT be called by the active pipeline
#   C. Data-validation defenses — keep these (oEmbed gate, approved handles, etc.)
#
# Run this:
#   - On every cron (hooked into update.sh as pre-flight)
#   - Before deploy
#   - After any CLAUDE.md edit, to confirm new rules got encoded
#
# Usage:
#   bash verify_rules.sh           # exit 0 if all pass, 1 if any fail
#   bash verify_rules.sh --soft    # always exit 0 (for dev iteration)

set -u
cd "$(dirname "$0")"

SOFT=0
[[ "${1:-}" == "--soft" ]] && SOFT=1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

PASS=0; FAIL=0
FAILED_RULES=()

check() {
  local rule_id="$1" file="$2" pattern="$3" expectation="$4"
  if [[ "$expectation" == "exists" ]]; then
    if grep -qE "$pattern" "$file" 2>/dev/null; then
      printf "${GREEN}PASS${NC} %-50s %s\n" "$rule_id" "$file"
      PASS=$((PASS+1))
    else
      printf "${RED}FAIL${NC} %-50s %s  (missing: %s)\n" "$rule_id" "$file" "$pattern"
      FAIL=$((FAIL+1)); FAILED_RULES+=("$rule_id")
    fi
  else  # absent
    if grep -qE "$pattern" "$file" 2>/dev/null; then
      printf "${RED}FAIL${NC} %-50s %s  (zombie: %s)\n" "$rule_id" "$file" "$pattern"
      FAIL=$((FAIL+1)); FAILED_RULES+=("$rule_id")
    else
      printf "${GREEN}PASS${NC} %-50s %s\n" "$rule_id" "$file"
      PASS=$((PASS+1))
    fi
  fi
}

echo "=== eXpressO News Rule Audit (pure-views v5) ==="
echo ""

# ============================================================
# A. SELECTION AUTHORITY — curation.py is THE selection module.
# ============================================================
check "curation:module-exists"          curation.py      "def curate"                                          exists
check "curation:pure-views-rule"        curation.py      "story_views|pick_by_views"                           exists
check "curation:velocity-hold"          curation.py      "apply_velocity_hold|story_velocity"                  exists
check "curation:commentator-enrichment" curation.py      "enrich_commentator|COMMENTATORS"                     exists
check "curation:no-safety-filters"      curation.py      "SAFETY_PATTERNS|is_safe|apply_safety"                absent
check "curation:no-pure-reply-filter"   curation.py      "is_pure_reply"                                       absent
check "parse_grok:imports-curation"     parse_grok.py    "^import curation"                                    exists
check "parse_grok:uses-curate-fn"       parse_grok.py    "curation\.curate\("                                  exists
check "parse_grok:clean-break-exit"     parse_grok.py    "PURE VIEWS|pure views v5"                            exists

# ============================================================
# B. ZOMBIE CHECKS — old judgment layers must NOT run in the active pipeline.
# (The legacy code may still exist below the sys.exit(0) clean break, but the
#  ACTIVE path must not invoke these. We check that update.sh / deploy.sh don't
#  call claude_critic, and that no judgment-filter call sites exist BEFORE the
#  pure-views build-output section.)
# ============================================================
check "zombie:claude-critic-bypassed"   update.sh        "^bash \\\$SCRIPT_DIR/claude_critic\\.sh"             absent
check "zombie:qc-critic-bypassed"       update.sh        "^bash \\\$SCRIPT_DIR/qc_critic\\.sh"                 absent

# ============================================================
# C. DATA-VALIDATION DEFENSES (keep — these are NOT curation; they guarantee
#    we have real data to apply pure-views to).
# ============================================================
check "validation:oembed-gate"          update.sh        "publish.twitter.com/oembed|check_oembed"             exists
check "validation:oembed-threshold"     update.sh        "OEMBED_EXIT|threshold|< 40|0\.40|0\.4"               exists
check "validation:approved-handles"     update.sh        "approved handles|APPROVED HANDLES"                   exists
check "validation:no-profile-fallback"  parse_grok.py    "is_valid_url|/status/"                               exists
check "validation:fast-model"           update.sh        "grok-4-fast|grok-fast"                               exists
check "validation:freespeech-overlay"   deploy.sh        "freespeech\.json"                                    exists
check "validation:sw-build-stamp"       deploy.sh        "BUILD|sw\.js"                                        exists

# ============================================================
# D. UI / FRONTEND RULES (independent of curation logic).
# ============================================================
check "ui:inline-expand-toggle"         index.html       "toggleEmbed|toggle\\('open'\\)"                       exists
check "ui:no-view-on-x-link"            index.html       ">View on X<|>Watch on TikTok<|>View source<"        absent
check "ui:no-ipapi-geolocation"         index.html       "ipapi\.co/json"                                      absent
check "ui:conspiracy-image"             index.html       "conspiracy\.webp|conspiracy\.jpg"                    exists

# ============================================================
# E. SETTINGS — bypass permissions at all 3 levels.
# ============================================================
# Settings audits — skip on CI (the user-global Mac path doesn't exist on Linux).
# These checks are dev-mode only (ensure Claude Code can run without permission prompts).
if [[ -f .claude/settings.json ]]; then
  check "settings:project-bypass"         .claude/settings.json                              "bypassPermissions" exists
fi
if [[ -f /Users/lookhome/.claude/settings.json ]]; then
  check "settings:user-global-bypass"     /Users/lookhome/.claude/settings.json              "bypassPermissions" exists
fi

# ============================================================
# F. NEW PROMPT REQUIREMENTS — Grok must be told to return views.
# ============================================================
check "prompt:views-as-metric"          update.sh        "VIEWS REQUIREMENT|VIEWS IS THE METRIC|views.*integer" exists
check "prompt:pure-views-spec"          update.sh        "PURE VIEWS SPEC"                                     exists

# --- ABSOLUTE BLOCKER: news tabs 24h cap, reference tabs 24h cap ---
# 2026-05-09: User caught Claude removing the 24h cap silently in conflict with
# CLAUDE.md line 274. This audit makes the rule un-bypassable. parse_grok.py MUST
# pass max_age_h to curation.curate, and _BACKFILL_AGE_BY_TAB must define the right
# values. If any of these checks fail, the cron aborts pre-flight.
# 2026-05-10: Reference tabs tightened from 72h → 24h after Comedy showed a 2d-old
# story. Cascade still extends to 72h internally if floor unmet, but the configured
# preference is 24h.
check "freshness:news-tabs-24h"         parse_grok.py    "'world':\s*(24|MAX_AGE_HOURS)"                       exists
check "freshness:reference-24h-recipe"  parse_grok.py    "'recipe':\s*24"                                      exists
check "freshness:reference-24h-science" parse_grok.py    "'science':\s*24"                                     exists
check "freshness:reference-24h-comedy"  parse_grok.py    "'comedy':\s*24"                                      exists
# 2026-05-10: TAB_AGE_OVERRIDE single source of truth — anti-leak audit.
# Previously two tables existed and disagreed (elon=96 vs elon=12), leaking 25h-old
# Elon posts. Lock the values in TAB_AGE_OVERRIDE so any future loosening trips this.
check "freshness:tab-age-elon-12h"      parse_grok.py    "'elon':\s*12"                                        exists
check "freshness:elon-hard-cap-24h"     parse_grok.py    "TAB_HARD_CAP.*\n.*'elon':\s*24|'elon':\s*24"         exists
check "freshness:pods-soft-12h"         parse_grok.py    "'pods':\s*12"                                        exists
check "freshness:pods-hard-24h"         parse_grok.py    "'pods':\s*24"                                        exists
# 2026-05-10 evening: Elon no-promo filter (user: "No promo post like Drake's")
check "elon:no-promo-filter"            parse_grok.py    "_is_elon_promo|_ELON_PROMO_KEYWORDS"                 exists
# 2026-05-10 evening: User submissions ingestion + Claude review
check "submit:netlify-form-schema"      index.html       "post-replace.*data-netlify|data-netlify.*post-replace" exists
check "submit:cron-pulls-from-netlify"  update.sh        "pull_netlify_submissions"                            exists
check "submit:claude-reviews-fit"       claude_qc.sh     "sub-review|EVALUATABLE_TABS"                         exists
# 2026-05-10 night: Overflow + cluster dedup for World refill
check "world:overflow-saved"            parse_grok.py    "_overflow.*=\s*\[\]|_overflow\[:5\]"                  exists
check "world:overflow-promotion"        claude_qc.sh     "promoted_overflow|_overflow"                          exists
check "world:cluster-dedup"             claude_qc.sh     "cluster_re|cluster dup"                              exists
# 2026-05-10 night: Pods fresher search (min_faves lowered, mode:Latest primary)
check "pods:mode-latest-search"         update.sh        "mode:\s*\"Latest\""                                  exists
# 2026-05-10 night: User mandate "highest velocity, not a favor" — prompts must
# use neutral "STARTING SEARCH SEEDS" language, not "SUGGESTED HANDLES (prefer)".
check "no-favoritism:no-prefer-handles" update.sh        "SUGGESTED HANDLES \(prefer"                          missing
check "no-favoritism:seeds-language"    update.sh        "STARTING SEARCH SEEDS"                               exists
# 2026-05-11: anti-announcement filter (user "no announcements"). Per-perspective
# and per-story view minimums were removed per user "Why do you keep making up your
# own mind? I want the most watched in the last four hours."
check "quality:wire-copy-filter"        parse_grok.py    "_is_wire_copy|_WIRE_COPY_PREFIXES"                   exists
# 2026-05-11: user "no video with a few words" → body-prose-length filter
check "quality:few-words-filter"        parse_grok.py    "_is_few_words|_MIN_PROSE_CHARS"                      exists
# 2026-05-11: user "add original + QT views for total score" — combined scoring
check "quality:combined-qt-score"       curation.py      "combined_score|qt_views"                             exists
# 2026-05-11: user "the next story must overcome the combined X plus Y score
# to make it to a block." Hold rule = past picks stay until beaten.
check "quality:hold-rule-views-saved"   curation.py      "views_at_save"                                       exists
check "quality:hold-rule-24h-ceiling"   curation.py      "MAX_HOLD_HOURS\s*=\s*24"                             exists
check "prompt:no-≥10-views"             update.sh        "≥10 views"                                           missing
# 2026-05-11: news tabs use 4h window per user "most watched in last four hours"
check "freshness:world-4h-window"       parse_grok.py    "'world':\s*4"                                        exists
check "freshness:business-4h-window"    parse_grok.py    "'business':\s*4"                                     exists
check "freshness:hard-expire-sweep"     parse_grok.py    "_final_hard_expire"                                  exists
check "freshness:rebuild-age-check"     parse_grok.py    "_rebuild_fresh|REBUILD-SKIP"                         exists
# 2026-05-10: Local min-views threshold (user: "Drake's at 3382 views, really?")
check "quality:local-min-views"         parse_grok.py    "LOCAL_MIN_VIEWS\s*=\s*10000"                         exists
# 2026-05-10: Semantic dedup regex fix — old regex matched inner array only, missing dups.
check "qc:semantic-dedup-cluster"       claude_qc.sh     "cluster_re\s*=\s*re\.compile"                        exists
# 2026-05-10: Floor list excludes Elon and Local (both user mandates — quality > pad)
check "floor:elon-not-in-floor-tabs"    claude_qc.sh     "FLOOR_TABS\s*=\s*\([^)]*'elon'"                      missing
check "floor:local-not-in-floor-tabs"   claude_qc.sh     "FLOOR_TABS\s*=\s*\([^)]*'local'"                     missing
# Use Python to check every curation.curate() call has max_age_h argument.
# Skips comments. Walks paren-matching for multi-line calls.
if python3 -c "
import sys
text = open('parse_grok.py').read()
# Strip comments line by line so we don't match curation.curate inside docstrings/comments
lines = []
for line in text.split('\n'):
    stripped = line.lstrip()
    if stripped.startswith('#'): continue
    lines.append(line)
clean = '\n'.join(lines)
# Find each call and check for max_age_h
i = 0; missing = []
while True:
    idx = clean.find('curation.curate(', i)
    if idx == -1: break
    depth = 1; j = idx + len('curation.curate(')
    while j < len(clean) and depth > 0:
        if clean[j] == '(': depth += 1
        elif clean[j] == ')': depth -= 1
        j += 1
    call = clean[idx:j]
    if 'max_age_h' not in call:
        missing.append(call[:150])
    i = j
sys.exit(0 if not missing else 1)
" 2>/dev/null; then
  printf '${GREEN}PASS${NC} %-50s %s\n' "freshness:every-curate-has-cap" "parse_grok.py"
  PASS=$((PASS+1))
else
  printf '${RED}FAIL${NC} %-50s %s\n' "freshness:every-curate-has-cap" "parse_grok.py"
  FAIL=$((FAIL+1)); FAILED_RULES+=("freshness:every-curate-has-cap")
fi

# --- HARD-CODED RULES from user explicit mandates ---
check "qc:script-exists"                claude_qc.sh    "FLOOR_TABS"                                         exists
check "qc:enforces-3-floor"             claude_qc.sh    "n < 3"                                              exists
check "qc:enforces-3-perspectives"      claude_qc.sh    "len.valid. < 3"                                     exists
check "qc:reverifies-urls"              claude_qc.sh    "publish.twitter.com/oembed"                         exists
check "qc:wired-into-update"            update.sh       "bash \\\$SCRIPT_DIR/claude_qc.sh"                    exists
check "qc:elon-exempt-from-floor"       claude_qc.sh    "FLOOR_TABS.*=.*\\("                                 exists

# --- ABSOLUTE BLOCKER: no git merge conflict markers in any deployed file ---
# 2026-05-07: a leftover `<<<<<<<` in index.html broke JavaScript parsing for ALL visitors.
# Site showed "Loading stories..." forever. This check makes that mistake un-shippable.
for f in index.html parse_grok.py update.sh deploy.sh curation.py; do
  if [[ -f "$f" ]] && grep -qE '^<<<<<<< |^>>>>>>> |^=======$' "$f"; then
    printf "${RED}FAIL${NC} %-50s %s  (git merge conflict markers present!)\n" "no-merge-markers:$f" "$f"
    FAIL=$((FAIL+1)); FAILED_RULES+=("no-merge-markers:$f")
  else
    printf "${GREEN}PASS${NC} %-50s %s\n" "no-merge-markers:$f" "$f"
    PASS=$((PASS+1))
  fi
done

echo ""
echo "=== Summary ==="
printf "  ${GREEN}PASS${NC}: %d   ${RED}FAIL${NC}: %d\n" "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failed rules:"
  for r in "${FAILED_RULES[@]}"; do echo "  - $r"; done
  echo ""
  echo "${YELLOW}Each failure means a CLAUDE.md rule is DOC ONLY${NC} and depends on Claude's"
  echo "memory each session. Encode the rule into code, then re-run."
  if [[ $SOFT -eq 1 ]]; then
    echo ""
    echo "(soft mode — exiting 0 anyway)"
    exit 0
  fi
  exit 1
fi

echo "All audited rules have a code-enforcement point."
exit 0
