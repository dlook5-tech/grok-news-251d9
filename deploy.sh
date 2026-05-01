#!/bin/bash
# deploy.sh — digest-based deploy: only uploads files Netlify doesn't already have.
# Saves 99% bandwidth on typical deploys (images rarely change, so they skip re-upload).
#
# - Always uses absolute paths
# - Always stamps a fresh build version
# - Computes sha1 for every file, sends digest to Netlify
# - Only PUTs the files whose hashes Netlify asks for
# - Sanity-checks for bad content strings before upload

set -euo pipefail

MAIN="/Users/lookhome/grok-news-251d9/grok-news-251d9"
SITE_ID="3e9d07ef-77d8-404a-8dad-413fa633ff16"

source "$MAIN/.env"

cd "$MAIN"

BUILD=$(date +%Y%m%d%H%M%S)
echo "[deploy] Build version: $BUILD"

# Stamp fresh version
sed -i.bak -E "s|THIS_VERSION = \"[0-9_]*\"|THIS_VERSION = \"$BUILD\"|; s|__BUILD_VERSION__|$BUILD|g" "$MAIN/index.html"
# Stamp sw.js too — every deploy gets unique sw.js content so browsers detect a new SW.
# This is the fix for stale iOS Safari that holds onto the old service worker.
sed -i.bak -E "s|__BUILD_VERSION__|$BUILD|g; s|BUILD = '[0-9_]*'|BUILD = '$BUILD'|" "$MAIN/sw.js"
rm -f "$MAIN/sw.js.bak"
rm -f "$MAIN/index.html.bak"
echo "$BUILD" > "$MAIN/version.txt"

# Sanity checks — fail loudly if critical content is missing (prevents regression to old version)
if grep -q "Yesterday's stories shown below" "$MAIN/index.html"; then
  echo "[deploy] ABORT: stale banner string detected in index.html" >&2
  exit 1
fi
if [ ! -s "$MAIN/stories.json" ]; then
  echo "[deploy] ABORT: stories.json missing or empty" >&2
  exit 1
fi
# Required tabs — if any are missing, something has reverted the file
for tab_check in 'id: "memes"' 'id: "golf"' 'id: "comedy"' 'id: "you"' 'id: "world"' 'id: "usa"' 'id: "business"' 'id: "submit"' 'id: "freespeech"'; do
  if ! grep -q "$tab_check" "$MAIN/index.html"; then
    echo "[deploy] ABORT: missing required tab definition '$tab_check' in index.html — possible regression" >&2
    exit 1
  fi
done
# Size floor — if the HTML has shrunk dramatically, something deleted content
HTML_SIZE=$(wc -c < "$MAIN/index.html" | tr -d ' ')
if [ "$HTML_SIZE" -lt 55000 ]; then
  echo "[deploy] ABORT: index.html unusually small ($HTML_SIZE bytes, expected >= 55000) — possible content loss" >&2
  exit 1
fi

# Build the file manifest: path -> sha1
echo "[deploy] Computing file hashes..."
FILES_JSON=$(python3 <<'PYEOF'
import hashlib, json, os
MAIN = "/Users/lookhome/grok-news-251d9/grok-news-251d9"
root_files = ["index.html", "stories.json", "_headers", "version.txt", "sw.js"]
manifest = {}
paths_by_hash = {}
for rel in root_files:
    full = os.path.join(MAIN, rel)
    if not os.path.isfile(full):
        continue
    h = hashlib.sha1(open(full, "rb").read()).hexdigest()
    manifest["/" + rel] = h
    paths_by_hash[h] = full
img_dir = os.path.join(MAIN, "images")
if os.path.isdir(img_dir):
    for f in sorted(os.listdir(img_dir)):
        full = os.path.join(img_dir, f)
        if not os.path.isfile(full):
            continue
        h = hashlib.sha1(open(full, "rb").read()).hexdigest()
        manifest["/images/" + f] = h
        paths_by_hash[h] = full
with open("/tmp/deploy_paths_by_hash.json", "w") as o:
    json.dump(paths_by_hash, o)
print(json.dumps({"files": manifest}))
PYEOF
)

# Create deploy (digest)
echo "[deploy] Creating digest deploy..."
DEPLOY_RESP=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $NETLIFY_AUTH_TOKEN" \
  -d "$FILES_JSON" \
  "https://api.netlify.com/api/v1/sites/$SITE_ID/deploys")

DEPLOY_ID=$(echo "$DEPLOY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))")
if [ -z "$DEPLOY_ID" ]; then
  echo "[deploy] ERROR: no deploy_id returned"
  echo "$DEPLOY_RESP" | head -c 500 >&2
  exit 1
fi

# Get list of required hashes (only files Netlify doesn't already have)
REQUIRED_COUNT=$(echo "$DEPLOY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('required',[])))")
TOTAL_COUNT=$(echo "$FILES_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['files']))")
echo "[deploy] deploy_id=$DEPLOY_ID  uploading $REQUIRED_COUNT of $TOTAL_COUNT files"

# Upload only required files
if [ "$REQUIRED_COUNT" -gt 0 ]; then
  python3 <<PYEOF
import json, subprocess, os, sys
resp = json.loads('''$DEPLOY_RESP''')
deploy_id = resp['id']
required = resp.get('required', [])
paths_by_hash = json.load(open('/tmp/deploy_paths_by_hash.json'))
token = os.environ.get('NETLIFY_AUTH_TOKEN') or '$NETLIFY_AUTH_TOKEN'
uploaded_bytes = 0
for sha in required:
    local_path = paths_by_hash.get(sha)
    if not local_path:
        print(f"[deploy] WARN: required sha {sha[:10]} has no local file", file=sys.stderr)
        continue
    size = os.path.getsize(local_path)
    uploaded_bytes += size
    r = subprocess.run([
        'curl', '-s', '-X', 'PUT',
        '-H', 'Content-Type: application/octet-stream',
        '-H', f'Authorization: Bearer {token}',
        '--data-binary', f'@{local_path}',
        f'https://api.netlify.com/api/v1/deploys/{deploy_id}/files/{sha}'
    ], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"[deploy] upload failed for {local_path}: {r.stderr}", file=sys.stderr)
        sys.exit(1)
print(f"[deploy] uploaded {uploaded_bytes/1024:.1f} KB total")
PYEOF
fi

# Verify deploy state
sleep 2
FINAL=$(curl -s -H "Authorization: Bearer $NETLIFY_AUTH_TOKEN" \
  "https://api.netlify.com/api/v1/deploys/$DEPLOY_ID")
echo "$FINAL" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'[deploy] id={d.get(\"id\",\"?\")} state={d.get(\"state\",\"?\")} url={d.get(\"ssl_url\",\"?\")}')"
echo "[deploy] Done at $(date)"

# ---- Auto-snapshot to Desktop after every successful deploy ----
SNAP_DIR="$HOME/Desktop/expresso_snapshots/$(date +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$SNAP_DIR/code" "$SNAP_DIR/images"
cp "$MAIN/index.html" "$MAIN/update.sh" "$MAIN/parse_grok.py" "$MAIN/cron_update.sh" "$MAIN/deploy.sh" "$MAIN/sw.js" "$MAIN/_headers" "$MAIN/version.txt" "$MAIN/fetch_tiktok.py" "$SNAP_DIR/code/" 2>/dev/null
cp "$MAIN/stories.json" "$SNAP_DIR/code/stories.example.json" 2>/dev/null
cp "$MAIN/seen_history.json" "$SNAP_DIR/code/seen_history.example.json" 2>/dev/null
[ -d "$MAIN/images" ] && cp -r "$MAIN/images/"* "$SNAP_DIR/images/" 2>/dev/null
echo "[deploy] Snapshot: $SNAP_DIR"

# Keep only the last 20 snapshots so the Desktop doesn't fill up
ls -1dt "$HOME/Desktop/expresso_snapshots/"*/ 2>/dev/null | tail -n +21 | xargs -I{} rm -rf "{}" 2>/dev/null || true

# ---- Auto-handoff doc to Desktop (for continuing on iPhone via Claude app) ----
# Refreshed each deploy. Read-only summary of project state. Paste into Claude
# mobile app to brief any Claude on where the project is.
HANDOFF="$HOME/Desktop/expresso_handoff.md"
python3 - "$BUILD" "$DEPLOY_ID" "$MAIN" <<'HANDOFF_PYEOF' > "$HANDOFF" 2>/dev/null
import sys, json, os, datetime
build, deploy_id, main = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
out.append(f"# eXpressO News — Project Handoff")
out.append(f"_Auto-generated by deploy.sh — last refreshed {datetime.datetime.now().strftime('%Y-%m-%d %I:%M %p %Z')}_")
out.append("")
out.append(f"**Live site:** https://expresso-news.netlify.app")
out.append(f"**Build:** `{build}` · **Last deploy ID:** `{deploy_id}`")
out.append(f"**Project root (on Mac):** `{main}`")
out.append("")
out.append("## Quick orientation for mobile Claude")
out.append("This is a Grok-AI-curated news site. Cron runs every 4 hours via macOS launchd, fires `update.sh` which calls xAI API for 17 tabs in parallel, parses with `parse_grok.py`, deploys to Netlify via `deploy.sh`. Stories live in `stories.json`. Frontend is a single `index.html` (vanilla JS, no framework). Service worker (`sw.js`) is network-first for HTML/JSON, network-first refresh logic auto-bumps users on each deploy. Honesty scoring is fully Grok's holistic judgment now (no Python overrides) — see `grok_system.txt` template inside `update.sh` for the criteria.")
out.append("")
# Tab counts
try:
    d = json.load(open(os.path.join(main, 'stories.json')))
    out.append(f"## Current tab state")
    out.append(f"_lastUpdated: {d.get('lastUpdated','?')}_")
    out.append("")
    out.append("| Tab | Stories | Carried-over |")
    out.append("|---|---|---|")
    for tab in ['world','usa','business','local','sports','top','elon','pods','allin','msm','science','pg6','memes','comedy','recipe','golf','earlier','you','submit','freespeech','tiktok']:
        v = d.get(tab, {})
        if not isinstance(v, dict): continue
        st = v.get('stories', [])
        co = sum(1 for s in st if s.get('carried_over'))
        out.append(f"| {tab} | {len(st)} | {co} |")
except Exception as e:
    out.append(f"_(could not read stories.json: {e})_")
out.append("")
out.append("## Recent changes (last 10 deploys)")
try:
    snaps = sorted(os.listdir(os.path.expanduser('~/Desktop/expresso_snapshots')), reverse=True)[:10]
    for s in snaps:
        out.append(f"- {s}")
except: pass
out.append("")
out.append("## Key files")
out.append("- `update.sh` — cron orchestrator, all 17 Grok prompts, system prompt with honesty criteria")
out.append("- `parse_grok.py` — JSON repair, validation, dedup, never-empty fallback, carry-over logic")
out.append("- `deploy.sh` — Netlify digest deploy, auto-snapshot, this handoff doc")
out.append("- `qc_critic.sh` — second-pass Grok review, applies replacements with validation")
out.append("- `index.html` — frontend (vanilla JS, ~70KB)")
out.append("- `sw.js` — service worker (cache-busts each deploy)")
out.append("- `stories.json` — current content for the live site")
out.append("- `seen_history.json` — 72h dedup memory across runs")
out.append("- `~/Library/LaunchAgents/com.expresso.cron.plist` — schedule (6/10/14/18/22)")
out.append("")
out.append("## Common commands")
out.append("- Run cron now: `bash $MAIN/update.sh`")
out.append("- Deploy only (no fresh content): `bash $MAIN/deploy.sh`")
out.append("- Check next launchd run: `launchctl print gui/$(id -u)/com.expresso.cron`")
out.append("- Tail launchd log: `tail -50 /tmp/expresso_launchd.log`")
out.append("")
out.append("## Open issues / next steps")
out.append("- macOS launchd occasionally misses 22:00 / 06:00 cron when Mac is asleep — `pmset wakepoweron 5:55am` is set but not 100% reliable. Real fix: move cron to GitHub Actions (free) — pending user decision.")
out.append("- Honesty scoring just switched to holistic Grok judgment (Apr 30); watch first few cron cycles for sanity-check.")
out.append("- Foreign-language translation field added (Apr 30); will populate on next cron's foreign quote-tweets.")
print('\n'.join(out))
HANDOFF_PYEOF
echo "[deploy] Handoff doc: $HANDOFF"
