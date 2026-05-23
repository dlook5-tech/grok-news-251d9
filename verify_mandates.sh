#!/usr/bin/env bash
# verify_mandates.sh — HARD-FAIL audit of every MANDATES.md rule.
#
# This script is wired into update.sh as pre-flight AND deploy.sh as the
# last gate before pushing to Netlify. If any check fails, the cron aborts
# and nothing gets deployed.
#
# Add a new check here in the SAME turn you add a new mandate to MANDATES.md.
# Never make this script soft. Never add RULE_AUDIT_SOFT bypass logic here.
# If a mandate becomes obsolete, the user removes it explicitly — not the agent.

set -u
cd "$(dirname "$0")"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
PASS=0; FAIL=0
FAILED=()

check() {
  local id="$1" file="$2" pattern="$3" expectation="$4"
  if [[ ! -f "$file" ]]; then
    printf "${RED}FAIL${NC} %-44s  %s  (file missing)\n" "$id" "$file"
    FAIL=$((FAIL+1)); FAILED+=("$id"); return
  fi
  if [[ "$expectation" == "exists" ]]; then
    if grep -qE "$pattern" "$file" 2>/dev/null; then
      printf "${GREEN}PASS${NC} %-44s  %s\n" "$id" "$file"
      PASS=$((PASS+1))
    else
      printf "${RED}FAIL${NC} %-44s  %s  (missing pattern: %s)\n" "$id" "$file" "$pattern"
      FAIL=$((FAIL+1)); FAILED+=("$id")
    fi
  else  # absent
    if grep -qE "$pattern" "$file" 2>/dev/null; then
      printf "${RED}FAIL${NC} %-44s  %s  (forbidden pattern present: %s)\n" "$id" "$file" "$pattern"
      FAIL=$((FAIL+1)); FAILED+=("$id")
    else
      printf "${GREEN}PASS${NC} %-44s  %s\n" "$id" "$file"
      PASS=$((PASS+1))
    fi
  fi
}

# --- Function-body-scoped check: pattern must NOT appear inside the active
# function body, even if the same pattern appears elsewhere in the file. ---
check_not_in_function() {
  local id="$1" file="$2" fn_name="$3" forbidden="$4"
  python3 - "$file" "$fn_name" "$forbidden" <<'PY'
import sys, re
path, fn, forbidden = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
m = re.search(r'function ' + re.escape(fn) + r'\(s\) \{(.*?)^\}', src, re.DOTALL | re.MULTILINE)
if not m:
    print(f"function {fn} not found", file=sys.stderr); sys.exit(2)
body = m.group(1)
if forbidden in body:
    print(f"forbidden pattern '{forbidden}' found inside {fn}", file=sys.stderr); sys.exit(3)
sys.exit(0)
PY
  if [[ $? -eq 0 ]]; then
    printf "${GREEN}PASS${NC} %-44s  %s  (no '%s' in %s)\n" "$id" "$file" "$forbidden" "$fn_name"
    PASS=$((PASS+1))
  else
    printf "${RED}FAIL${NC} %-44s  %s  ('%s' found inside %s)\n" "$id" "$file" "$forbidden" "$fn_name"
    FAIL=$((FAIL+1)); FAILED+=("$id")
  fi
}

echo "=== MANDATES.md hard-fail audit ==="
echo ""

# M-001 — story blocks are direct links, no expand/toggle in active renderer
check                  "M-001a:blocks-anchor-class"       index.html       'class="story story-link"'       exists
check_not_in_function  "M-001b:no-toggle-in-active-fn"    index.html       renderAutoEmbedBlock              classList.toggle
check_not_in_function  "M-001c:no-embed-in-active-fn"     index.html       renderAutoEmbedBlock              toggleEmbed

# M-002 — cron writes cron_report.md every run + workflow commits it
check  "M-002a:report-written"           parse_grok.py    "cron_report\.md"                                          exists
check  "M-002b:report-in-workflow"       .github/workflows/cron.yml  "cron_report\.md"                               exists

# M-003 — per-tab age caps apply at curation layer, NOT hardcoded 24h in apply_hold
check  "M-003a:per-tab-cap-dict"         curation.py      "PER_TAB_MAX_AGE"                                          exists
check  "M-003b:max-age-kwarg"            curation.py      "max_age_hours"                                            exists
check  "M-003c:no-hardcoded-24"          curation.py      "story_age_hours\(s\) > 24\b"                              absent

# M-004 — generic-headline rewrite enforced in Python (not prompt-only)
check  "M-004a:generic-pattern-list"     parse_grok.py    "_GENERIC_HEADLINE_PATTERNS"                               exists
check  "M-004b:headline-rewrite-fn"      parse_grok.py    "fetch_headline_for_post"                                  exists

# M-005 — Elon prompt forbids "Elon" name prefix
check  "M-005:elon-no-name-prefix"       update.sh        "DO NOT start with 'Elon'|NOT start with 'Elon'"           exists

# M-007 — 50K floor for World/USA, never lowered without user OK
check  "M-007:wu-50k-floor"              parse_grok.py    "WU_VIEW_FLOOR\s*=\s*50_?000"                              exists

# M-008 — Local tab is SoCal/OC/Newport in prompts
check  "M-008:local-is-socal"            update.sh        "Southern California|Orange County|Newport"                exists

# M-009 — cross-tab dedup (URL-exact + event-signature)
check  "M-009a:xtab-url-dedup"           parse_grok.py    "CROSS-TAB DEDUP|xtab-dedup"                               exists
check  "M-009b:qc-event-dedup"           parse_grok.py    "FINAL QC|qc-dupe"                                         exists

# M-014 — cross-tab needs 3 tokens; LLM semantic backstop
check  "M-014a:min-shared-kwarg"         parse_grok.py    "min_shared"                                               exists
check  "M-014b:cross-tab-threshold"      parse_grok.py    "min_shared = 2 if _prev_tab == _qc_tab else 3"            exists
check  "M-014c:llm-dedup-fn"             parse_grok.py    "_qc_llm_semantic_dedup"                                   exists
check  "M-014d:llm-dedup-called"         parse_grok.py    "_qc_llm_semantic_dedup\(output\)"                         exists

# M-012 — MANDATES.md exists and is referenced from CLAUDE.md
check  "M-012a:mandates-file"            MANDATES.md      "^## M-001"                                                exists
check  "M-012b:claude-md-points-here"    CLAUDE.md        "MANDATES\.md"                                             exists

# Deploy guard mandate (added in deploy.sh as belt-and-suspenders for M-001)
check  "deploy:guard-direct-link"        deploy.sh        'class="story story-link"'                                 exists

# M-013 — this audit itself must be wired into BOTH update.sh and deploy.sh
check  "M-013a:wired-in-update"          update.sh        "bash verify_mandates\.sh"                                 exists
check  "M-013b:wired-in-deploy"          deploy.sh        "bash .*verify_mandates\.sh"                               exists
check  "M-013c:hard-fail-on-failure"     verify_mandates.sh  "exit 1$"                                                  exists

echo ""
echo "=== Summary ==="
printf "  ${GREEN}PASS${NC}: %d   ${RED}FAIL${NC}: %d\n" "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "${RED}MANDATE REGRESSION DETECTED.${NC} The cron will refuse to deploy until these are fixed."
  echo "Failed mandates:"
  for r in "${FAILED[@]}"; do echo "  - $r"; done
  echo ""
  echo "Open MANDATES.md, find the mandate ID, restore its enforcement point in code,"
  echo "and re-run this script. Do NOT bypass with a soft flag — this script has none."
  exit 1
fi

echo "All mandates hard-encoded. Cron may proceed."
exit 0
