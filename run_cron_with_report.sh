#!/bin/bash
# M-022 enforcement helper: runs update.sh, then ALWAYS cats cron_report.md
# at the end so the report can't be forgotten. Use this instead of `bash
# update.sh` anywhere we want a cron + auto-report in one shot.

set -e
cd "$(dirname "$0")"
bash update.sh
echo ""
echo "======================================================"
echo "        cron_report.md (auto-printed per M-022)        "
echo "======================================================"
cat cron_report.md
echo "======================================================"
