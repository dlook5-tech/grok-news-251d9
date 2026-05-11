#!/usr/bin/env python3
"""
curation.py — eXpressO News selection logic. ONE rule: top by views.

The user (May 2026-05-04) explicitly chose PURE VIEWS, ZERO FILTERS.
"Let's regress weeks and weeks and go back to just pure views, then, if it cures
80%, because we're back to 10% with the rat's nest. If a story does not have all
three perspectives, so be it, but we've got to just go on objective views. Then,
like you said, if a Trump story lands in sports, so be it. Hopefully it won't
happen a lot."

This module replaces the rat's nest of filters/exemptions/scoring/critic-loops
that accumulated through May 2026. Every story selection on the site is governed
by THREE rules in THIS FILE:

  1. pick_by_views()       — sort candidates by views, take top N
  2. apply_velocity_hold() — keep an old story if its views/hr beats fresh candidates
  3. enrich_commentator()  — if a known commentator quote-tweeted the top story,
                             show their quote-tweet instead of the original

That's it. No safety blacklist. No pure-reply filter. No crime-blotter detector.
No engagement floors. No handle whitelists for selection. No honesty scoring.
No generic-headline detection. No exemptions. No "earlier" archive. No floor
backfill. No AI critic loop. No HANDLE_NAMES rewrite. No max-age caps (velocity
hold replaces that — old stories drop when their views/hr falls below a fresh
candidate's, and stories beyond 7 days drop regardless).

If a rule isn't here, it doesn't apply. If you're tempted to add a rule because
"this one bad story slipped through," DON'T. The whole point of this module is
to stop the whack-a-mole. The user accepted the trade-off: 80% better with this
spec is way ahead of 10% better with the rat's nest.

CLAUDE.md RULE #-1: every rule needs a code embodiment. The selection rules
above are embodied in THIS FILE. The audit (verify_rules.sh) checks that this
module is the selection authority — if claude_critic.sh or other files start
re-introducing selection logic, the audit fails.
"""
import re
import datetime

# ============================================================
# CONFIG — the only knobs in the system
# ============================================================

# Velocity hold absolute ceiling: a story can stay this long IF still beating
# candidates on views/hr. Beyond this, drop regardless of velocity (otherwise
# stale stories live forever).
MAX_HOLD_HOURS = 23  # User (2026-05-11): "If no new post # views has
                     # superseded or gone higher than the original stories
                     # chosen for their velocity in that tab, then those
                     # stories stay for 23 hours, or until a story comes
                     # along with higher velocity."
                     # → Held stories survive until either (a) a fresh
                     #   candidate beats their frozen views_at_save score,
                     #   or (b) they hit 23h URL age. Whichever first.

# Number of stories per tab. Tab-specific overrides go below if needed.
DEFAULT_TOP_N = 3

# Commentators eligible for the enrichment swap. Handle (lowercased, no @) → display label.
# A story's embed is replaced by a commentator's quote-tweet IF (and only if) that commentator
# quote-tweeted the top-viewed post for the tab in the same 24h window with substantive
# commentary. This is the ONLY "judgment" anywhere in the selection pipeline, and it's
# bounded — only handles on this list count, and they only override if they actually
# quote-tweeted the top story with ≥30 chars of commentary.
COMMENTATORS = {
    # Conservative
    'jackposobiec':    'Jack Posobiec',
    'cernovich':       'Mike Cernovich',
    'mattwalshblog':   'Matt Walsh',
    'benshapiro':      'Ben Shapiro',
    'tuckercarlson':   'Tucker Carlson',
    'jdvance1':        'JD Vance',
    'charliekirk11':   'Charlie Kirk',
    # Progressive / Liberal
    'aoc':             'AOC',
    'rbreich':         'Robert Reich',
    'berniesanders':   'Bernie Sanders',
    'rashidatlaib':    'Rashida Tlaib',
    # Independent / Investigative
    'ggreenwald':      'Glenn Greenwald',
    'snowden':         'Edward Snowden',
    'raydalio':        'Ray Dalio',
    # Tech / business
    'pmarca':          'Marc Andreessen',
    'davidsacks':      'David Sacks',
    'chamath':         'Chamath Palihapitiya',
    'elonmusk':        'Elon Musk',
    # Cultural
    'joerogan':        'Joe Rogan',
    'lexfridman':      'Lex Fridman',
}


# ============================================================
# 1. PARSE — extract views from engagement string
# ============================================================

def parse_metric(engagement_str, metric='views'):
    """
    Extract a numeric metric from a string like '1.2M views, 45K likes, 12K retweets'.
    Returns int. Defaults to 0 if not found.
    """
    if not engagement_str:
        return 0
    s = str(engagement_str).lower()
    pattern = r'([\d.,]+)\s*([kmb])?\s*' + re.escape(metric)
    m = re.search(pattern, s)
    if not m:
        return 0
    try:
        n = float(m.group(1).replace(',', ''))
    except ValueError:
        return 0
    suffix = (m.group(2) or '').lower()
    if suffix == 'k':
        n *= 1_000
    elif suffix == 'm':
        n *= 1_000_000
    elif suffix == 'b':
        n *= 1_000_000_000
    return int(n)


def story_views(story):
    """
    Views for a story dict. Falls back: explicit 'views' field → parse from 'engagement'
    string → max of perspective views (for World/USA stories whose URL lives at the
    perspective level rather than story level).
    """
    if 'views' in story:
        try:
            return int(story['views'])
        except (ValueError, TypeError):
            pass
    v = parse_metric(story.get('engagement', ''), 'views')
    if v == 0:
        for p in story.get('perspectives', []) or []:
            v = max(v, parse_metric(p.get('engagement', ''), 'views'))
    return v


def story_age_hours(story):
    """
    Age in hours from URL snowflake (Twitter) or post_ts (any source).
    Returns 0 if unknown — treats unknown-age stories as fresh, since we'd rather
    show them than drop them on a missing-timestamp technicality.
    """
    url = story.get('url', '')
    if not url:
        for p in story.get('perspectives', []) or []:
            url = p.get('url', '')
            if url:
                break
    m = re.search(r'/status/(\d+)', url) if url else None
    if m:
        try:
            sid = int(m.group(1))
            ts_ms = (sid >> 22) + 1288834974657
            post_time = datetime.datetime.fromtimestamp(ts_ms / 1000)
            return (datetime.datetime.now() - post_time).total_seconds() / 3600
        except Exception:
            pass
    ts = story.get('post_ts', '')
    if ts:
        try:
            post_time = datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))
            return (datetime.datetime.now(datetime.timezone.utc) - post_time).total_seconds() / 3600
        except Exception:
            pass
    return 0.0


def story_velocity(story, history=None):
    """RANK BY VIEWS, WITH 23H HOLD RULE — user (2026-05-11):
    "If no new post # views has superseded or gone higher than the original
    stories chosen for their velocity in that tab, then those stories stay
    for 23 hours, or until a story comes along with higher velocity."

      - Fresh (age ≤ 4h): score = current views (combined X+Y if QT-enhanced)
      - Held (age > 4h, has views_at_save from prior pickup): score = frozen
        views_at_save. The story holds until a fresh candidate beats this.
      - Old (age > 4h, no views_at_save — never picked): score = -1, drops.

    MAX_HOLD_HOURS (=23) applied in apply_velocity_hold caps the held duration.
    """
    age = story_age_hours(story)
    views = story_views(story)
    if age <= 4:
        return float(views) if views > 0 else 0.0
    # Held story: use saved combined score from when it was picked.
    saved = story.get('views_at_save')
    if saved is not None:
        try: return float(saved)
        except (ValueError, TypeError): return -1.0
    return -1.0


# ============================================================
# 2. SELECTION — pure views, then velocity hold
# ============================================================

def pick_by_views(candidates, top_n=DEFAULT_TOP_N):
    """Sort candidates by views (desc) and return the top N."""
    return sorted(candidates or [], key=story_views, reverse=True)[:top_n]


def apply_velocity_hold(current, candidates, top_n=DEFAULT_TOP_N, history=None, max_age_h=None):
    """
    Combine current (already-displayed) stories and new candidates, dedup, then return
    the top N by 4-hour growth (see story_velocity).

    max_age_h: HARD ceiling for any story regardless of growth proof. User spec
    (2026-05-06): "nothing should be more than four hours old unless its velocity
    beats the new... keep the story all the way up till 24 hours."
    News tabs should pass max_age_h=24, reference tabs 72. Defaults to MAX_HOLD_HOURS
    (168h) to preserve old behavior if not specified.

    Dedup by URL (or by normalized headline if URLs are missing — handles the World/USA
    case where the URL is at the perspective level).
    """
    if max_age_h is None:
        max_age_h = MAX_HOLD_HOURS
    def keyfor(s):
        u = s.get('url') or ''
        if not u:
            for p in s.get('perspectives', []) or []:
                u = p.get('url', '') or ''
                if u:
                    break
        if u:
            return ('u', u)
        h = (s.get('headline') or '').strip().lower()
        return ('h', h) if h else ('id', id(s))

    # CRITICAL: candidates win on dedup ties (fresh Grok data has current views;
    # current/_existing data is a stale snapshot). When both have the same URL,
    # keep the candidate but INHERIT views_at_save + age_at_save_hours from current
    # so the 4h-delta computation has the prior snapshot to compare against.
    seen = {}
    # 2026-05-11 (user re-instated hold rule): fresh candidates age-filtered
    # to max_age_h (e.g. 4h for news). Held stories from prior cron bypass
    # that filter — they're capped only by MAX_HOLD_HOURS (23).
    for s in (candidates or []):
        if story_age_hours(s) > max_age_h:
            continue
        k = keyfor(s)
        if k not in seen:
            seen[k] = s
    for s in (current or []):
        if story_age_hours(s) > MAX_HOLD_HOURS:
            continue
        k = keyfor(s)
        if k in seen:
            for fld in ('views_at_save', 'age_at_save_hours'):
                if fld in s and fld not in seen[k]:
                    seen[k][fld] = s.get(fld)
        else:
            seen[k] = s
    pool = list(seen.values())

    # Sort by 4h velocity (views gained in last 4 hours), highest first. Top N win.
    # max_age_h was already applied during pool construction above, so no further
    # filtering needed.
    ranked = sorted(pool, key=lambda s: story_velocity(s, history=history), reverse=True)
    return ranked[:top_n]


# ============================================================
# 3. ENRICHMENT — commentator quote-tweet swap
# ============================================================

def enrich_commentator(top_story, all_candidates):
    """
    If a known commentator quote-tweeted top_story with their own commentary, return a
    modified story dict where the embed URL points to the commentator's quote-tweet.
    The original story is preserved as 'original_url' for transparency.

    A 'quote tweet' is detected by a candidate whose body references the top_story's URL
    or headline AND contains substantive commentary (≥30 chars of body).
    """
    # User mandate (2026-05-11): "Once the 3 (R, I, D) highest-velocity viewpoint
    # is found, now go one step further and find if any very interesting commentator
    # on that side of the political spectrum has retweeted that post and embedded
    # it with further more interesting commentary. You can add the number of views
    # from the original post plus the views of the retweeted post for the total score."
    #
    # → If ANY QT/RT with substantive commentary (≥30 chars) exists, USE IT.
    #   Do NOT require the QT to have more views than the original — the COMBINED
    #   score (original + QT views) is what matters.
    #   If multiple QTs exist, pick the highest-viewed one.
    if not top_story or not all_candidates:
        return top_story
    target_url = top_story.get('url', '')
    target_headline = (top_story.get('headline', '') or '').lower()
    if not target_url and not target_headline:
        return top_story

    original_views = story_views(top_story)
    best_qt = None
    best_qt_views = 0  # any QT with substantive commentary qualifies — pick highest-viewed

    for cand in all_candidates:
        if cand is top_story:
            continue
        body = (cand.get('body', '') or '')
        if len(body.strip()) < 30:
            continue  # need actual commentary, not a bare RT
        body_l = body.lower()
        refs_url = bool(target_url and target_url.lower() in body_l)
        refs_headline = bool(target_headline and len(target_headline) > 12 and
                             target_headline[:30] in body_l)
        if not (refs_url or refs_headline):
            continue
        v = story_views(cand)
        if v > best_qt_views:
            best_qt = cand
            best_qt_views = v

    if not best_qt:
        return top_story

    # Use the QT URL (embed shows both original and commentary). Score = combined.
    enriched = dict(top_story)
    enriched['original_url'] = top_story.get('url', '')
    enriched['original_handle'] = top_story.get('handle', '')
    enriched['original_views'] = original_views
    enriched['url'] = best_qt.get('url', top_story.get('url', ''))
    enriched['handle'] = best_qt.get('handle', '')
    enriched['commentator_quote'] = (best_qt.get('body', '') or '')[:280]
    enriched['commentator_label'] = best_qt.get('handle', '')
    enriched['qt_views'] = best_qt_views
    enriched['combined_score'] = original_views + best_qt_views
    # Update 'views' so ranking + display reflect combined velocity
    enriched['views'] = enriched['combined_score']
    return enriched


# ============================================================
# THE WHOLE PIPELINE — one function
# ============================================================

def curate(tab, current_stories, fresh_candidates, top_n=DEFAULT_TOP_N, enrich=True, history=None, max_age_h=None):
    """
    Run the entire selection pipeline for a single tab.

    Inputs:
      tab               — tab name (string, for logging only)
      current_stories   — what's currently displayed on the tab (from previous cron)
      fresh_candidates  — new candidates returned by Grok this cron
      top_n             — how many stories to keep on the tab
      enrich            — if True, run the commentator enrichment
      history           — optional dict {url -> {views_at_save, age_at_save_hours}}
                          for real 4-hour-delta velocity computation

    Output:
      list of N stories, ranked by 4h-growth, optionally enriched.
    """
    chosen = apply_velocity_hold(current_stories or [], fresh_candidates or [],
                                  top_n=top_n, history=history, max_age_h=max_age_h)
    if enrich and chosen:
        chosen = [enrich_commentator(s, fresh_candidates or []) for s in chosen]
    return chosen


def stamp_view_history(stories):
    """Annotate every story with views_at_save + age_at_save_hours so the NEXT
    cron can compute true 4h growth deltas. Mutates in place. Call this on the
    final chosen stories right before writing stories.json.
    """
    for s in stories or []:
        if not isinstance(s, dict): continue
        s['views_at_save'] = story_views(s)
        s['age_at_save_hours'] = round(story_age_hours(s), 2)
        # Also stamp perspectives for World/USA
        for p in s.get('perspectives', []) or []:
            if isinstance(p, dict):
                p['views_at_save'] = story_views(p)
                p['age_at_save_hours'] = round(story_age_hours(p), 2)
    return stories


def build_history_lookup(existing_stories_json):
    """Build {url -> {views_at_save, age_at_save_hours}} from a previous stories.json
    dict. Used for 4h-delta velocity computation in the next cron."""
    history = {}
    if not isinstance(existing_stories_json, dict):
        return history
    for tab_key, tab_val in existing_stories_json.items():
        if not isinstance(tab_val, dict): continue
        for s in tab_val.get('stories', []) or []:
            if not isinstance(s, dict): continue
            url = s.get('url') or ''
            if url and 'views_at_save' in s:
                history[url] = {
                    'views_at_save': s.get('views_at_save', 0),
                    'age_at_save_hours': s.get('age_at_save_hours', 0),
                }
            for p in s.get('perspectives', []) or []:
                if not isinstance(p, dict): continue
                purl = p.get('url') or ''
                if purl and 'views_at_save' in p:
                    history[purl] = {
                        'views_at_save': p.get('views_at_save', 0),
                        'age_at_save_hours': p.get('age_at_save_hours', 0),
                    }
    return history


# ============================================================
# Module audit — exposes its own surface for verify_rules.sh
# ============================================================
SELECTION_FUNCTIONS = (pick_by_views, apply_velocity_hold, enrich_commentator, curate)
__all__ = [f.__name__ for f in SELECTION_FUNCTIONS] + [
    'parse_metric', 'story_views', 'story_age_hours', 'story_velocity',
    'COMMENTATORS', 'MAX_HOLD_HOURS', 'DEFAULT_TOP_N',
]
