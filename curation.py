#!/usr/bin/env python3
"""
curation.py — Pure Views + Velocity Hold (Final Clean Version)
One rule: highest views, with smart hold for still-hot stories.
"""
import re
import datetime
from typing import Dict, List

MAX_HOLD_HOURS = 23
DEFAULT_TOP_N = 3

COMMENTATORS = {
    'jackposobiec': 'Jack Posobiec', 'cernovich': 'Mike Cernovich',
    'mattwalshblog': 'Matt Walsh', 'benshapiro': 'Ben Shapiro',
    'tuckercarlson': 'Tucker Carlson', 'jdvance1': 'JD Vance',
    'charliekirk11': 'Charlie Kirk', 'aoc': 'AOC', 'rbreich': 'Robert Reich',
    'berniesanders': 'Bernie Sanders', 'rashidatlaib': 'Rashida Tlaib',
    'ggreenwald': 'Glenn Greenwald', 'pmarca': 'Marc Andreessen',
    'davidsacks': 'David Sacks', 'chamath': 'Chamath Palihapitiya',
    'elonmusk': 'Elon Musk', 'joerogan': 'Joe Rogan', 'lexfridman': 'Lex Fridman',
}

def parse_metric(s: str, metric: str = 'views') -> int:
    if not s: return 0
    m = re.search(r'([\d.,]+)\s*([kmb])?\s*' + re.escape(metric), str(s).lower())
    if not m: return 0
    n = float(m.group(1).replace(',', ''))
    suffix = (m.group(2) or '').lower()
    if suffix == 'k': n *= 1000
    elif suffix == 'm': n *= 1_000_000
    elif suffix == 'b': n *= 1_000_000_000
    return int(n)

def _int_or_zero(x) -> int:
    try: return int(x)
    except: return 0

def story_views(s: Dict) -> int:
    """Max view count from top-level OR any perspective (integer field OR engagement string)."""
    v = max(_int_or_zero(s.get('views', 0)), parse_metric(s.get('engagement', '')))
    for p in s.get('perspectives', []) or []:
        v = max(v, _int_or_zero(p.get('views', 0)), parse_metric(p.get('engagement', '')))
    return v

def _age_of_url(url: str) -> float:
    m = re.search(r'/status/(\d+)', url or '')
    if not m: return float('inf')
    try:
        ts = (int(m.group(1)) >> 22) + 1288834974657
        return (datetime.datetime.now() - datetime.datetime.fromtimestamp(ts / 1000)).total_seconds() / 3600
    except: return float('inf')

def story_age_hours(s: Dict) -> float:
    """Age of the FRESHEST url in the story (top-level OR any perspective)."""
    ages = [_age_of_url(s.get('url',''))]
    for p in s.get('perspectives', []) or []:
        ages.append(_age_of_url(p.get('url','')))
    finite = [a for a in ages if a != float('inf')]
    return min(finite) if finite else 0.0

def story_velocity(s: Dict) -> float:
    age = max(story_age_hours(s), 0.1)
    views = story_views(s)
    saved = s.get('views_at_save')
    saved_age = s.get('age_at_save_hours')
    if saved is not None and saved_age is not None:
        return (float(saved) / max(float(saved_age), 0.1)) * 4.0
    if age <= 24 and views > 0:
        return (float(views) / age) * 4.0
    return -1.0

def apply_hold(current: List[Dict], candidates: List[Dict], top_n=DEFAULT_TOP_N, sort_key=None) -> List[Dict]:
    """Generic hold-and-rank. sort_key defaults to velocity; pass story_views for raw-views ranking."""
    if sort_key is None:
        sort_key = story_velocity
    seen = {}
    for s in (candidates or []):
        if story_age_hours(s) > 24: continue
        key = s.get('url') or s.get('headline', str(id(s)))
        seen[key] = s
    for s in (current or []):
        if story_age_hours(s) > MAX_HOLD_HOURS: continue
        key = s.get('url') or s.get('headline', str(id(s)))
        if key not in seen or sort_key(s) > sort_key(seen[key]):
            seen[key] = s
    pool = list(seen.values())
    return sorted(pool, key=sort_key, reverse=True)[:top_n]

# Back-compat alias.
def apply_velocity_hold(current, candidates, top_n=DEFAULT_TOP_N):
    return apply_hold(current, candidates, top_n, sort_key=story_velocity)

def curate(tab: str, current: List, fresh: List, top_n=DEFAULT_TOP_N) -> List:
    # Top tab = absolute most-viewed, period (memes welcome). Raw views, not velocity.
    # Every other tab keeps velocity sort so fresh-but-rising content can beat stale leaders.
    if tab == 'top':
        return apply_hold(current, fresh, top_n, sort_key=story_views)
    return apply_hold(current, fresh, top_n, sort_key=story_velocity)

def stamp_view_history(stories: List) -> List:
    for s in stories or []:
        s['views_at_save'] = story_views(s)
        s['age_at_save_hours'] = round(story_age_hours(s), 2)
    return stories