// Scheduled Netlify function — fires every 4h and POSTs to GitHub Actions
// to trigger the eXpressO News cron pipeline. Mac-independent: runs on
// Netlify's servers regardless of whether the user's laptop is on.
//
// User mandate (2026-05-12): "Please make it Mac independent. It's usually
// closed."
//
// Requires Netlify env var: GITHUB_PAT (token with workflow_dispatch scope).
// Set via Netlify dashboard or API.

export default async (req, context) => {
  const token = Netlify.env.get('GITHUB_PAT');
  if (!token) {
    console.error('GITHUB_PAT not set in Netlify env');
    return new Response('Missing GITHUB_PAT', { status: 500 });
  }

  const url = 'https://api.github.com/repos/dlook5-tech/grok-news-251d9/actions/workflows/cron.yml/dispatches';
  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      'Authorization': `token ${token}`,
      'Accept': 'application/vnd.github.v3+json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ ref: 'main' }),
  });

  const stamp = new Date().toISOString();
  if (resp.status === 204) {
    console.log(`[expresso-trigger ${stamp}] cron dispatched OK`);
    return new Response('OK', { status: 200 });
  } else {
    const txt = await resp.text();
    console.error(`[expresso-trigger ${stamp}] HTTP ${resp.status}: ${txt.slice(0, 200)}`);
    return new Response(`GitHub HTTP ${resp.status}`, { status: 502 });
  }
};

// Schedule: every 4 hours at :17 (matches the existing GitHub schedule pattern).
// 6 fires/day in UTC: 01:17, 05:17, 09:17, 13:17, 17:17, 21:17.
export const config = {
  schedule: '17 1,5,9,13,17,21 * * *',
};
