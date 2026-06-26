#!/usr/bin/env bash
# safety_backup.sh — never-strand-work safety net for eXpressO.
#
# WHY THIS EXISTS (2026-06-26): a cloud (claude.ai/code) session got stuck with
# days of uncommitted work. Cloud sessions run in their own sandbox and do NOT
# push to this Mac unless told to. This script makes it trivial to snapshot ANY
# working-tree changes to git + the remote so nothing is ever stranded again.
#
# Usage:
#   ./safety_backup.sh            # commit any changes to main and push
#   ./safety_backup.sh branch     # commit to a timestamped safety/<ts> branch instead
#
# It is a no-op (exits 0, pushes nothing) when the working tree is clean.

set -euo pipefail
cd "$(dirname "$0")"

if [ -z "$(git status --porcelain)" ]; then
  echo "[safety_backup] working tree clean — nothing to back up."
  exit 0
fi

TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
MODE="${1:-main}"

git add -A

if [ "$MODE" = "branch" ]; then
  BR="safety/${TS}"
  git checkout -b "$BR"
  git commit -m "safety backup ${TS}"
  git push -u origin "$BR"
  echo "[safety_backup] pushed work to branch ${BR}"
else
  git commit -m "safety backup ${TS}"
  git push origin HEAD
  echo "[safety_backup] committed + pushed working-tree snapshot to $(git rev-parse --abbrev-ref HEAD)"
fi
