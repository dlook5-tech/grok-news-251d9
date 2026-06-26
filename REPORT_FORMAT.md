# Per-cron auto-report format (locked 2026-05-23)

User mandate: "This log format is perfect. I want to see this every time you do a cron."

## Required output structure

```
=== CRON {run_id_or_lastUpdated} @ {timestamp UTC} {✅/❌} ===

({status note — e.g. "Same data as last hour — no new scheduled cron has fired yet;
next scheduled cron is on a 4h cadence", or "NEW DATA — cron just fired"})

WORLD — 8 candidates Grok returned
1. {views_formatted} {✅/❌} @{handle} — {headline}  {filter_reason if dropped}
2. ...
...
8. ...

USA — 8 candidates Grok returned
1. ...
...
8. ...

| TAB        | N | Age   | Top Views | Top Headline                 |
|------------|---|-------|-----------|------------------------------|
| world      | 5 | 8.3h  | 3.5M      | Iran shuts down airspace     |
| usa        | 5 | ...   | ...       | ...                          |
| top        | 3 | ...   | ...       | ...                          |
| business   | ? | ...   | ...       | ...                          |
| msm        | ? | ...   | ...       | ...                          |
| sports     | ? | ...   | ...       | ...                          |
| elon       | ? | ...   | ...       | ...                          |
| pods       | ? | ...   | ...       | ...                          |
| pg6        | ? | ...   | ...       | ...                          |
| recipe     | ? | ...   | ...       | ...                          |
| science    | ? | ...   | ...       | ...                          |
| local      | ? | ...   | ...       | ...                          |
| conspiracy | ? | ...   | ...       | ...                          |
| comedy     | ? | ...   | ...       | ...                          |
| allin      | ? | ...   | ...       | ...                          |
```

## Format rules

- **Views formatting**: `28M`, `3.5M`, `394K`, `45K` — no decimals for whole millions/thousands, 1 decimal otherwise
- **✅ on candidate** = shipped this cron (passed all filters)
- **❌ on candidate** = filtered out — append brief reason in parens, e.g. `(<50K)`, `(>24h cap)`, `(dup of @nicksortor)`, `(no /status/ url)`
- **WORLD/USA list** = top 8 by combined views, exactly as Grok returned (read `_candidates` field in stories.json container)
- **Tab table N column** = shipped story count (length of `stories` array)
- **Tab table Age column** = age of the freshest story in the tab
- **Tab table Top Views column** = views of the highest-view shipped story
- **Tab table Top Headline column** = headline of highest-view shipped story (truncated to fit)

## When to render

- Every recurring-wakeup fire
- Whether or not a new cron has actually run (note "Same data as last hour" if `lastUpdated` unchanged)
- After any manual cron trigger

## Data sources

- `stories.json` `lastUpdated` field → header timestamp
- `stories.json` `{tab}._candidates` array → WORLD/USA 8-candidate list (populated by parse_grok.py after Stage 1 landed at commit 2ec1687)
- `stories.json` `{tab}.stories` array → ship status (any candidate URL appearing in `stories` = ✅, otherwise ❌)
- Snowflake-decoded URL timestamp → Age column
