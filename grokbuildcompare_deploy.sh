#!/bin/bash
# grokbuildcompare deploy — one-shot redeploy of the sister site.
#
# Usage:
#   bash grokbuildcompare_deploy.sh <folder-containing-the-site>
#
# Example:
#   bash grokbuildcompare_deploy.sh /tmp/grokbuildcompare-site
#   bash grokbuildcompare_deploy.sh ~/Desktop/grokbuildcompare
#
# The folder must contain at least index.html and data/stories.json.
# Whatever else lives in the folder gets uploaded too.

set -eu
cd "$(dirname "$0")"
source .env

GBC_SITE_ID="3c2d5ff9-f5af-4d24-9344-88fabf37e180"   # grokbuildcompare.netlify.app
SITE_DIR="${1:?usage: bash grokbuildcompare_deploy.sh <site-folder>}"

if [ ! -f "$SITE_DIR/index.html" ]; then
  echo "[gbc-deploy] ERROR: $SITE_DIR/index.html not found" >&2
  exit 1
fi
if [ ! -f "$SITE_DIR/data/stories.json" ]; then
  echo "[gbc-deploy] ERROR: $SITE_DIR/data/stories.json not found" >&2
  exit 1
fi

echo "[gbc-deploy] deploying $SITE_DIR → https://grokbuildcompare.netlify.app"

# Build manifest of every file (recursive) under the site dir.
FILES_JSON=$(SITE_DIR="$SITE_DIR" python3 <<'PY'
import hashlib, json, os, sys
root = os.environ['SITE_DIR']
manifest = {}
paths_by_hash = {}
for dirpath, dirnames, filenames in os.walk(root):
    # Skip dotfiles + DS_Store + node_modules
    dirnames[:] = [d for d in dirnames if not d.startswith('.') and d != 'node_modules']
    for fname in filenames:
        if fname.startswith('.') or fname == '.DS_Store':
            continue
        full = os.path.join(dirpath, fname)
        rel = '/' + os.path.relpath(full, root).replace(os.sep, '/')
        h = hashlib.sha1(open(full, 'rb').read()).hexdigest()
        manifest[rel] = h
        paths_by_hash[h] = full
json.dump(paths_by_hash, open('/tmp/gbc_paths_by_hash.json','w'))
print(json.dumps({'files': manifest}))
PY
)

# Create digest deploy
DEPLOY_RESP=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $NETLIFY_AUTH_TOKEN" \
  -d "$FILES_JSON" \
  "https://api.netlify.com/api/v1/sites/$GBC_SITE_ID/deploys")
echo "$DEPLOY_RESP" > /tmp/gbc_deploy_resp.json
DEPLOY_ID=$(echo "$DEPLOY_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")
if [ -z "$DEPLOY_ID" ]; then
  echo "[gbc-deploy] ERROR: no deploy_id" >&2
  echo "$DEPLOY_RESP" | head -c 500 >&2
  exit 1
fi
REQ=$(echo "$DEPLOY_RESP" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('required',[])))")
TOTAL=$(echo "$FILES_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['files']))")
echo "[gbc-deploy] deploy_id=$DEPLOY_ID  uploading $REQ of $TOTAL files"

# Upload only required hashes
if [ "$REQ" -gt 0 ]; then
  python3 <<'PY'
import json, os, subprocess, sys
resp = json.load(open('/tmp/gbc_deploy_resp.json'))
deploy_id = resp['id']
required = resp.get('required', [])
paths_by_hash = json.load(open('/tmp/gbc_paths_by_hash.json'))
token = os.environ['NETLIFY_AUTH_TOKEN']
bytes_up = 0
for sha in required:
    path = paths_by_hash.get(sha)
    if not path: continue
    bytes_up += os.path.getsize(path)
    r = subprocess.run([
        'curl','-s','-X','PUT',
        '-H','Content-Type: application/octet-stream',
        '-H', f'Authorization: Bearer {token}',
        '--data-binary', f'@{path}',
        f'https://api.netlify.com/api/v1/deploys/{deploy_id}/files/{sha}'
    ], capture_output=True, text=True)
    if r.returncode != 0:
        print(f'[gbc-deploy] upload failed: {r.stderr}', file=sys.stderr)
        sys.exit(1)
print(f'[gbc-deploy] uploaded {bytes_up/1024:.1f} KB')
PY
fi

# Verify
sleep 2
curl -s -H "Authorization: Bearer $NETLIFY_AUTH_TOKEN" \
  "https://api.netlify.com/api/v1/deploys/$DEPLOY_ID" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'[gbc-deploy] state={d.get(\"state\")} url={d.get(\"ssl_url\")}')"
