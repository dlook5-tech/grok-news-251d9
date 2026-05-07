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
