#!/bin/bash
# TEST MODE (M-032): re-runs parse_grok.py against the LAST cached Grok output.
# Skips the 17 xAI selection calls (saves ~$0.50 of tokens per iteration).
# Stage 2 perspectives + honesty scoring + parent fetch + headline rewrite
# DO still fire because they need live data. Cost per test ≈ $0.05.
#
# Use this when iterating on a parse_grok.py or prompt change. Only run a
# real `bash run_cron_with_report.sh` when you actually want to deploy.

set -e
cd "$(dirname "$0")"
[ -f .env ] && source .env

if [ ! -f /tmp/grok_raw.json ]; then
  echo "ERROR: /tmp/grok_raw.json not found. Run a real cron first to seed the cache." >&2
  exit 1
fi

echo "TEST MODE — using cached Grok selection from $(stat -f '%Sm' /tmp/grok_raw.json)"
echo "(Stage 2 + honesty + parent fetch will still hit xAI live — Selection is the only cached layer.)"
echo ""

python3 parse_grok.py < /tmp/grok_raw.json

echo ""
echo "======================================================"
echo "       cron_report.md (test run, NOT deployed)         "
echo "======================================================"
cat cron_report.md
echo "======================================================"
echo ""
echo "Note: stories.json was overwritten by this test but NOT deployed."
echo "To deploy: bash run_cron_with_report.sh   (runs the full pipeline)"
