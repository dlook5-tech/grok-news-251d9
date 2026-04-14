#!/bin/bash
# eXpressO News update — runs every 4 hours
cd /Users/lookhome/grok-news-251d9/grok-news-251d9
source .env
bash update.sh >> /tmp/expresso_cron.log 2>&1

# Daily backup — one folder per date
BACKUP_DIR="/Users/lookhome/Desktop/xnews_backups/$(date +%Y-%m-%d)"
mkdir -p "$BACKUP_DIR"
cp index.html "$BACKUP_DIR/"
cp stories.json "$BACKUP_DIR/"
cp update.sh "$BACKUP_DIR/"
cp parse_grok.py "$BACKUP_DIR/"
cp cron_update.sh "$BACKUP_DIR/"
cp /tmp/grok_raw.json "$BACKUP_DIR/grok_raw_$(date +%H%M).json" 2>/dev/null
echo "Backup saved to $BACKUP_DIR at $(date)" >> /tmp/expresso_cron.log
