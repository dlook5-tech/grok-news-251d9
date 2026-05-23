#!/bin/bash
# 2026-05-22: Disabled per user mandate "have the code exactly like ristetto,
# only with the changes i gave you." Ristretto has no claude_qc.sh — it just
# runs update.sh → parse_grok.py → deploy. The old eXpressO claude_qc.sh ran
# 8+ post-processing checks that filtered stories with editorial rules
# (honesty scoring, semantic dedup, perspective-count enforcement, etc.).
# Those filters caused empty tabs and prompt-override conflicts.
#
# This file now exits 0 immediately so the cron workflow doesn't fail on it,
# but does nothing to stories.json.
exit 0
