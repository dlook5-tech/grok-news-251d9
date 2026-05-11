#!/bin/bash
# trigger_cron.sh — POST workflow_dispatch to GitHub Actions cron.yml.
#
# WHY: GitHub Actions free-tier scheduled crons are unreliable. As of
# 2026-05-11, only 2 of 4 expected daily scheduled runs actually fired.
# User reported: "every time, unless I do a manual cron, it fails."
#
# This script fires the dispatch endpoint, which is far more reliable than
# the schedule event. Mac launchd (~/Library/LaunchAgents/com.expresso.trigger.plist)
# runs this every 4h. If Mac is on, cron runs. If Mac is off, the next time it
# wakes, launchd fires the missed run automatically.
#
# We KEEP the schedule in cron.yml as a backup — if launchd doesn't fire (Mac
# off), GitHub's scheduled run might still fire (eventually). Belt-and-suspenders.

# Token loaded from .env or env var — never hardcoded (GitHub secret-scanning).
REPO_DIR="/Users/lookhome/grok-news-251d9/grok-news-251d9"
if [ -z "$GITHUB_PAT" ] && [ -f "$REPO_DIR/.env" ]; then
    # shellcheck disable=SC1090,SC1091
    source "$REPO_DIR/.env"
fi
TOKEN="${GITHUB_PAT:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
    echo "trigger_cron: no token (set GITHUB_PAT in .env or env)" >&2
    exit 1
fi
LOG="/tmp/expresso_cron_trigger.log"

echo "=== trigger_cron $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$LOG"
HTTP_CODE=$(curl -sS -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/dlook5-tech/grok-news-251d9/actions/workflows/cron.yml/dispatches \
    -d '{"ref":"main"}' \
    -w "%{http_code}" \
    -o /dev/null)
echo "  → HTTP $HTTP_CODE" >> "$LOG"
if [ "$HTTP_CODE" = "204" ]; then
    echo "  ✓ cron triggered" >> "$LOG"
    exit 0
else
    echo "  ✗ trigger failed" >> "$LOG"
    exit 1
fi
