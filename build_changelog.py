#!/usr/bin/env python3
"""
build_changelog.py — produce a layperson-readable change log on Desktop.

User mandate (2026-05-10): "Start a spreadsheet of every log of every change
you've made... Column 1 should be the date and time, Column 3 should be the
edit to Python that you made and the request that it's fulfilling that I've
made via vibe code... a log that a lay person could read and understand what
change was made. Can you update that every day?"

OUTPUT: ~/Desktop/expresso_changelog.csv
  - Date/Time (local)
  - Files Changed (which scripts/files)
  - What Claude Did (short plain-English summary, derived from commit subject)
  - Why / Your Request (extracted from the commit body — pulls user quotes
    when present, otherwise the body's first paragraph)
  - Commit Hash (for engineers; lay readers can ignore)

Runs once a day from daily_backup.sh. Safe to run anytime: it rebuilds the
full file from git log every time.
"""
import csv, os, subprocess, re, datetime, sys

REPO = "/Users/lookhome/grok-news-251d9/grok-news-251d9"
OUT = os.path.expanduser("~/Desktop/expresso_changelog.csv")

# Pull commit metadata (hash|iso-timestamp|subject|body) — no files yet.
# %x1f = unit separator; %x1e = record separator (handles multi-line bodies cleanly).
fmt = "%H%x1f%aI%x1f%s%x1f%b%x1e"
result = subprocess.run(
    ["git", "-C", REPO, "log", "--pretty=format:" + fmt],
    capture_output=True, text=True, check=True,
)
raw = result.stdout

commits = []
for chunk in raw.split("\x1e"):
    chunk = chunk.strip()
    if not chunk: continue
    parts = chunk.split("\x1f")
    if len(parts) < 4: continue
    sha, ts, subject, body = parts[0], parts[1], parts[2], parts[3].strip()
    commits.append((sha, ts, subject, body))

# Get files for each commit via separate git call (slower but reliable parsing)
def get_files(sha):
    try:
        r = subprocess.run(
            ["git", "-C", REPO, "show", "--pretty=format:", "--name-only", sha],
            capture_output=True, text=True, check=True, timeout=5,
        )
        return [ln.strip() for ln in r.stdout.split("\n") if ln.strip()]
    except Exception:
        return []
commits = [(sha, ts, subject, body, get_files(sha)) for sha, ts, subject, body in commits]

def clean_subject(s):
    """Strip prefixes like 'QC:', 'Cron:', 'Pods 12/24h, ...' so the column
    reads as a sentence to a lay person."""
    s = re.sub(r"^(QC|Cron|Fix|Add|Update|Refactor|Debug|Wire|Build|Daily|Submissions|Age caps|Two-tier|3 bugs|Reference tabs|Elon[^\s]*|Pods[^\s]*|World[^\s]*|Deploy)[\s:—-]+", "", s, flags=re.IGNORECASE)
    return s[0].upper() + s[1:] if s else s

def extract_user_request(body):
    """Find the user's quoted instruction in the commit body. Falls back to
    the first non-bullet paragraph if no quote found."""
    # Look for "User: ..." or "User mandate: \"...\"" patterns
    quote_patterns = [
        r'User[^:]*:\s*"([^"]{15,400})"',         # User: "..."
        r'User mandate[^:]*:\s*"([^"]{15,400})"', # User mandate: "..."
        r'user[^:]*:\s*"([^"]{15,400})"',         # user: "..."
        r'User caught[^:]*:\s*"([^"]{15,400})"',  # User caught: "..."
        r'\(user[^)]*\)?\s*"([^"]{15,400})"',     # (user) "..."
    ]
    for pat in quote_patterns:
        m = re.search(pat, body)
        if m:
            return m.group(1).strip()
    # Look for any quoted string ≥15 chars (likely a user instruction)
    m = re.search(r'"([^"]{15,300})"', body)
    if m:
        return m.group(1).strip()
    # Fall back: first non-bullet line that mentions "user" or sounds like a directive
    for line in body.split("\n"):
        line = line.strip()
        if not line or line.startswith(("-", "*", "Co-", "1.", "2.", "3.", "[")): continue
        if re.search(r'\b(user|caught|wants?|needs?|asked|complained|caught it)\b', line, re.IGNORECASE):
            return line[:300]
    # Last resort: return first paragraph stripped of code formatting
    first_para = body.split("\n\n")[0] if body else ""
    return first_para[:300]

def summarize_files(files):
    """Group changed files into a short readable string."""
    if not files: return ""
    # Show up to 4 files, then "and N more"
    if len(files) <= 4:
        return ", ".join(files)
    return ", ".join(files[:4]) + f" + {len(files)-4} more"

# Skip the auto-cron commits (just refresh stamps; not human-meaningful changes)
def is_human_change(subject, body):
    if subject.startswith("Cron:"): return False
    if "expresso-cron" in body.lower(): return False
    return True

filtered = [c for c in commits if is_human_change(c[2], c[3])]
filtered.sort(key=lambda c: c[1], reverse=True)  # newest first

REPO_URL = "https://github.com/dlook5-tech/grok-news-251d9"
LIVE_URL = "https://expresso-news.netlify.app"

with open(OUT, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["Date/Time", "Files Changed", "What Claude Did", "Why / Your Request",
                "View Code (link)", "Commit"])
    # Top row: today's snapshot — quick access to live site + current code, one
    # entry per day so a lay reader can see "site as of today = this code".
    today = datetime.datetime.now().strftime("%Y-%m-%d")
    head_sha = filtered[0][0] if filtered else ""
    w.writerow([
        f"{today} (TODAY'S SITE)",
        "—",
        f"Live site: {LIVE_URL}",
        "Click 'View Code' to see the codebase as it is right now.",
        f"{REPO_URL}/tree/{head_sha}" if head_sha else REPO_URL,
        head_sha[:7] if head_sha else "",
    ])
    for sha, ts, subject, body, files in filtered:
        # Reformat ISO timestamp → local-readable
        try:
            dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
            local = dt.astimezone().strftime("%Y-%m-%d %I:%M %p")
        except Exception:
            local = ts
        w.writerow([
            local,
            summarize_files(files),
            clean_subject(subject),
            extract_user_request(body),
            f"{REPO_URL}/commit/{sha}",  # full URL — clickable in Numbers/Excel
            sha[:7],
        ])

print(f"[changelog] wrote {len(filtered)} commits to {OUT}", file=sys.stderr)
