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

# M-001 — SUPERSEDED 2026-05-23 evening by M-017 (user reverted to inline embed).
# Old direct-link checks removed. The active renderAutoEmbedBlock now DOES use
# classList.toggle and toggleEmbed — that's the correct behavior under M-017.

# M-017 — Inline embed expansion + honesty score at bottom (latest preference)
check  "M-017a:active-uses-toggle"     index.html  "classList.toggle\('open'\)"       exists
check  "M-017b:active-uses-embed"      index.html  "toggleEmbed\("                    exists
check  "M-017c:honesty-card-renders"   index.html  "footnote-card.*Honesty"           exists

# M-018 — Stage 2 perspective enrichment for World/USA stories
check  "M-018a:find-perspectives-fn"   parse_grok.py  "def find_perspectives"           exists
check  "M-018b:stage2-wired-in-WU"     parse_grok.py  "STAGE 2: find Conservative"      exists
check  "M-018c:thread-pool-parallel"   parse_grok.py  "ThreadPoolExecutor"              exists
check  "M-018d:exception-caught"       parse_grok.py  "stage2-warn"                     exists
check  "M-018e:clears-stale-persp"     parse_grok.py  "_s.pop\('perspectives'"          exists

# M-019 — Replies/QT-of-source search + tiered view floors
check  "M-019a:replies-QTs-and-takes"  parse_grok.py  "Direct replies to"               exists
check  "M-019b:tiered-view-floors"     parse_grok.py  "_PERSPECTIVE_MIN_VIEWS"          exists
check  "M-019c:no-curated-handles"     parse_grok.py  "curated handle"                  absent
check  "M-019d:self-quote-guard"       parse_grok.py  "url == story_url"                exists

# M-020 SUPERSEDED by M-021: honesty rubric moved OUT of selection prompts into a separate scoring pass.
# Old M-020a/b/c checks removed — selection prompts must NOT contain the rubric now.

# M-021 — Honesty is a separate labeling pass; never inside selection or perspective fetch
check  "M-021a:no-honesty-in-update"   update.sh      "HONESTY SCORING"                  absent
check  "M-021b:score-honesty-fn"       parse_grok.py  "def score_honesty"                exists
check  "M-021c:scoring-pass-wired"     parse_grok.py  "honesty-score.*scoring.*items"    exists
check  "M-021d:persp-prompt-no-honesty" parse_grok.py "DO NOT score honesty here"        exists

# M-023 — Elon: no promo filter, no QC dedup
check  "M-023a:elon-no-promo-filter"   parse_grok.py  "elon_kept = list\(cleaned\)"     exists
check  "M-023b:elon-not-in-dedup"      parse_grok.py  "'recipe','comedy'\]"             exists

# M-024 — MSM tab: no dedup, top_n=5
check  "M-024a:msm-not-in-dedup"       parse_grok.py  "'world','usa','top','business'" exists
check  "M-024b:msm-top-n-5"            parse_grok.py  "'msm': 5"                       exists

# M-025 — Drop non-English stories and perspectives
check  "M-025a:non-english-fn"         parse_grok.py  "def _is_non_english"             exists
check  "M-025b:lang-filter-applied"    parse_grok.py  "lang-filter"                     exists

# M-026 — Big-views age exception (World/USA only)
check  "M-026a:bypass-tabs-defined"    parse_grok.py  "_BIG_VIEW_BYPASS_TABS"           exists
check  "M-026b:bypass-floor-500K"      parse_grok.py  "_BIG_VIEW_BYPASS_FLOOR = 500_000" exists
check  "M-026c:bypass-log-line"        parse_grok.py  "age-cap-bypass"                  exists

# M-022 strengthened: cron report wrapper exists
check  "M-022-helper:wrapper-script"   run_cron_with_report.sh  "cat cron_report.md"     exists

# M-027 — Report header in Pacific Time
check  "M-027:report-pt-timestamp"     parse_grok.py  "America/Los_Angeles"             exists

# M-028 — Perspective honesty floor (drops conspiracy / serial misrep)
check  "M-028a:persp-honesty-floor"    parse_grok.py  "_PERSP_HONESTY_FLOOR ="          exists
check  "M-028b:honesty-floor-log"      parse_grok.py  "honesty-floor"                   exists

# M-029 PRIME DIRECTIVE — citizen journalism, not freaks online
check  "M-029a:prime-directive-prompt" parse_grok.py  "PRIME DIRECTIVE.*CITIZEN JOURNALISM"  exists
check  "M-029b:auto-reject-vulgar"     parse_grok.py  "AUTO-REJECT"                     exists
# M-029c REMOVED — 80-char min was my overreach (M-035). User never asked for it.

# M-035: NO character minimum, highest-viewed wins
check  "M-035a:no-80-char-min"         parse_grok.py  "len\(body_text\) < 80"           absent
check  "M-035b:highest-viewed-prompt"  parse_grok.py  "HIGHEST-VIEWED political reaction"  exists

# M-030 — Elon parent fetch (Python-enforced)
check  "M-030a:elon-parent-fn"         parse_grok.py  "_enrich_parent"                  exists
check  "M-030b:elon-parent-log"        parse_grok.py  "elon-parent"                     exists

# M-031 CORRECTED — Report per-tab summary IS the table format user approved
check  "M-031:table-format-present"    parse_grok.py  "Top Views \| Age range"          exists
check  "M-031:table-mandate-comment"   parse_grok.py  "M-031 CORRECTED"                 exists

# M-032 — Test mode helper exists
check  "M-032:test-mode-script"        test_parse.sh  "TEST MODE"                       exists

# M-033 — Earlier tab populated from previous-cron displaced stories
check  "M-033a:earlier-loop-present"   parse_grok.py  "M-033: Restore EARLIER tab"      exists
check  "M-033b:earlier-key-written"    parse_grok.py  "_e_container\['earlier'\]"       exists

# M-034 — Perspective honesty floor at 5
check  "M-034:floor-relaxed-to-5"      parse_grok.py  "_PERSP_HONESTY_FLOOR = 5"        exists

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

# M-015 — World/USA tabs use direct-link block when no perspectives (clicks open X)
check  "M-015a:world-uses-direct-link"   index.html       "renderAutoEmbedBlock\(s\)"                                exists
check  "M-015b:world-perspective-guard"  index.html       "perspectives && s\.perspectives\.length"                  exists

# M-016 — No host-label icons / arrows / badges in the block header. Just the headline.
# Patterns look for actual code use (var X) not comment mentions.
check_not_in_function  "M-016a:no-hostLabel-var"  index.html  renderAutoEmbedBlock  "var hostLabel"
check_not_in_function  "M-016b:no-openIcon-var"   index.html  renderAutoEmbedBlock  "var openIcon"
check_not_in_function  "M-016c:no-arrow-entity"   index.html  renderAutoEmbedBlock  "&#8599;"

# M-012 — MANDATES.md exists and is referenced from CLAUDE.md
check  "M-012a:mandates-file"            MANDATES.md      "^## M-001"                                                exists
check  "M-012b:claude-md-points-here"    CLAUDE.md        "MANDATES\.md"                                             exists

# Deploy direct-link guard REMOVED 2026-05-23 evening (M-001 superseded by M-017).

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
