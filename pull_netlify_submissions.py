#!/usr/bin/env python3
"""
pull_netlify_submissions.py — fetch Netlify Form submissions, merge into submissions.json.

Runs as part of the cron pipeline (called from update.sh BEFORE parse_grok.py).
The frontend's "Post/Replace" form is wired to Netlify Forms via a hidden static
form in index.html (data-netlify="true" name="post-replace"). Every user submission
hits Netlify's form storage. This script:

  1. GET /api/v1/sites/<SITE>/submissions — list pending form submissions
  2. For each unread "post-replace" entry, build a submissions.json record
  3. Merge into submissions.json (dedup by URL)
  4. Mark the Netlify submission processed (DELETE so it doesn't reappear)

User mandate (2026-05-10): "Krons should pick up every submitted post, replace,
and put it there so they can click on the block and see the suggestions."

submissions.json format consumed by parse_grok._process_submissions():
  [{"url": "...", "note": "...", "submitted_at": ISO_TIMESTAMP, "votes": 1, ...}, ...]
"""
import json, os, sys, urllib.request, urllib.error

TOKEN = os.environ.get('NETLIFY_AUTH_TOKEN')
SITE = os.environ.get('NETLIFY_SITE_ID', '3e9d07ef-77d8-404a-8dad-413fa633ff16')

if not TOKEN:
    print("[pull-submissions] NETLIFY_AUTH_TOKEN not set — skipping", file=sys.stderr)
    sys.exit(0)

def _api(method, path):
    url = f"https://api.netlify.com/api/v1{path}"
    req = urllib.request.Request(url, method=method,
                                  headers={'Authorization': f'Bearer {TOKEN}'})
    try:
        r = urllib.request.urlopen(req, timeout=15)
        return json.loads(r.read()) if method == 'GET' else None
    except urllib.error.HTTPError as e:
        print(f"[pull-submissions] {method} {path} → HTTP {e.code}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"[pull-submissions] {method} {path} → {e}", file=sys.stderr)
        return None

# Load existing submissions.json (may be empty list)
try:
    with open('submissions.json') as f:
        existing = json.load(f)
    if not isinstance(existing, list):
        existing = []
except (FileNotFoundError, json.JSONDecodeError):
    existing = []

seen_urls = {e.get('url') for e in existing if isinstance(e, dict) and e.get('url')}

# Fetch pending Netlify form submissions
pending = _api('GET', f'/sites/{SITE}/submissions?state=unread&per_page=100') or []
added = 0
for s in pending:
    if not isinstance(s, dict): continue
    if s.get('form_name') != 'post-replace': continue
    # Extract field values — Netlify sends them as "data" object
    data = s.get('data') or {}
    url = (data.get('url') or '').strip()
    note = (data.get('note') or '').strip()
    if not url:
        # Silent skip — note-only submission has no anchor URL
        continue
    if url in seen_urls:
        # Existing entry — bump vote (treat resubmission as upvote)
        for e in existing:
            if e.get('url') == url:
                e['votes'] = (e.get('votes') or 1) + 1
                if note and note not in (e.get('notes') or []):
                    e.setdefault('notes', []).append(note)
                break
    else:
        existing.append({
            'url': url,
            'note': note,
            'notes': [note] if note else [],
            'submitted_at': s.get('created_at') or '',
            'votes': 1,
            'netlify_id': s.get('id'),
            'source': 'netlify-form',
        })
        seen_urls.add(url)
        added += 1
    # Mark processed — DELETE removes from Netlify "unread" queue.
    # We've already persisted to submissions.json so it won't be lost.
    if s.get('id'):
        _api('DELETE', f'/submissions/{s["id"]}')

if added or pending:
    with open('submissions.json', 'w') as f:
        json.dump(existing, f, indent=2)
    print(f"[pull-submissions] merged {added} new + processed {len(pending)} total", file=sys.stderr)
else:
    print(f"[pull-submissions] no new submissions in Netlify queue", file=sys.stderr)
