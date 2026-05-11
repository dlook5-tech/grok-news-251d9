#!/bin/bash
# daily_backup.sh — pull latest from GitHub + snapshot full repo to Desktop.
#
# WHY: Cron now runs on GitHub Actions, so the old `cron_update.sh` (which
# included a snapshot step) no longer fires locally. This is a standalone
# daily job whose ONLY purpose is to keep a current copy of the repo on
# Desktop in case GitHub goes sideways.
#
# Runs via ~/Library/LaunchAgents/com.expresso.backup.plist (daily, noon).
# Also safe to run manually: `bash daily_backup.sh`.
#
# Snapshots: ~/Desktop/expresso_snapshots/YYYY-MM-DD_HH-MM-SS/
# Retention: 14 most recent snapshots; older auto-pruned.

set -e
REPO="/Users/lookhome/grok-news-251d9/grok-news-251d9"
SNAP_ROOT="$HOME/Desktop/expresso_snapshots"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
SNAP_DIR="$SNAP_ROOT/$STAMP"
LOG="/tmp/expresso_daily_backup.log"

echo "=== daily_backup $STAMP ===" | tee -a "$LOG"

# 1. Pull latest from GitHub so the snapshot reflects what's actually deployed.
#    Bypasses osxkeychain — uses the embedded PAT from the cron pipeline.
cd "$REPO"
git fetch origin main 2>&1 | tee -a "$LOG"
# Don't risk a merge conflict — just hard-reset working tree to origin/main.
# Local edits are intentionally NOT preserved here; this is a snapshot job, not a
# dev workflow. (User edits land via commits, not uncommitted working tree.)
git reset --hard origin/main 2>&1 | tee -a "$LOG"

# 2. Snapshot. Exclude heavy/regenerable stuff.
mkdir -p "$SNAP_DIR"
rsync -a \
  --exclude '.git/' \
  --exclude '.netlify/' \
  --exclude '.claude/' \
  --exclude 'node_modules/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  "$REPO/" "$SNAP_DIR/" 2>&1 | tee -a "$LOG"

echo "  snapshot written: $SNAP_DIR" | tee -a "$LOG"

# 3. Retention: keep last 14 snapshots, drop older.
cd "$SNAP_ROOT"
ls -1dt */ 2>/dev/null | tail -n +15 | xargs -I{} rm -rf "{}" 2>/dev/null || true
echo "  retained: $(ls -1d */ 2>/dev/null | wc -l | tr -d ' ') snapshot(s)" | tee -a "$LOG"

echo "=== daily_backup OK ===" | tee -a "$LOG"
