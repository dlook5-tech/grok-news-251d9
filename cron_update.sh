#!/bin/bash
# eXpressO News hourly update — runs every hour 6 AM to midnight, skips 1-5 AM
cd /Users/lookhome/grok-news-251d9/grok-news-251d9
source .env
bash update.sh >> /tmp/expresso_cron.log 2>&1
