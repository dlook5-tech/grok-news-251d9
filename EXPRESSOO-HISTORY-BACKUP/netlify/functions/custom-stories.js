// Netlify serverless function — calls Grok API with user's custom interests
// API key stays server-side, never exposed to the browser

exports.handler = async function(event) {
  // CORS headers
  const headers = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type",
    "Content-Type": "application/json"
  };

  if (event.httpMethod === "OPTIONS") {
    return { statusCode: 200, headers, body: "" };
  }

  if (event.httpMethod !== "POST") {
    return { statusCode: 405, headers, body: JSON.stringify({ error: "POST only" }) };
  }

  let interests;
  try {
    const parsed = JSON.parse(event.body);
    interests = parsed.interests;
  } catch (e) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: "Invalid JSON" }) };
  }

  if (!interests || interests.trim().length < 3) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: "Interests too short" }) };
  }

  // Cap interests length to prevent abuse
  interests = interests.slice(0, 500);

  const XAI_API_KEY = process.env.XAI_API_KEY;
  if (!XAI_API_KEY) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: "API key not configured" }) };
  }

  try {
    const response = await fetch("https://api.x.ai/v1/responses", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + XAI_API_KEY
      },
      body: JSON.stringify({
        model: "grok-4.20-0309-reasoning",
        input: [
          {
            role: "system",
            content: "You are Grok, the AI of X. Find the most interesting, viral, and engaging posts on X right now matching the user's interests. Prioritize citizen journalists, threads, and commentary over institutional accounts. Return JSON only. No markdown."
          },
          {
            role: "user",
            content: `Find the 3-5 best posts on X right now about these interests: "${interests}"

RULES:
- Prefer citizen journalists, threads, and quote-tweet commentary over news orgs
- Each post MUST include the real URL with /status/NUMBERS. Use web_search to find actual posts.
- Include honesty scores

Return this exact JSON format:
{"stories":[{"headline":"one-line headline","handle":"@handle","url":"https://x.com/.../status/...","body":"2-3 sentence summary","honesty":"X/10","notes":"why this post is interesting"}]}`
          }
        ],
        tools: [{ type: "web_search" }],
        max_output_tokens: 4000,
        temperature: 0.3
      })
    });

    const data = await response.json();

    if (data.error) {
      return { statusCode: 500, headers, body: JSON.stringify({ error: "Grok API error: " + JSON.stringify(data.error) }) };
    }

    // Extract text from response
    let text = "";
    if (data.output) {
      for (const block of data.output) {
        if (block.type === "message") {
          for (const c of (block.content || [])) {
            if (c.type === "output_text") text += c.text;
          }
        }
      }
    }

    // Parse JSON from response
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      return { statusCode: 500, headers, body: JSON.stringify({ error: "No JSON in response", raw: text.slice(0, 500) }) };
    }

    let stories;
    try {
      stories = JSON.parse(jsonMatch[0]);
    } catch (e) {
      // Try to repair truncated JSON
      let fixed = jsonMatch[0];
      const quotes = (fixed.match(/(?<!\\)"/g) || []).length;
      if (quotes % 2 !== 0) fixed += '"';
      const openBraces = (fixed.match(/{/g) || []).length - (fixed.match(/}/g) || []).length;
      const openBrackets = (fixed.match(/\[/g) || []).length - (fixed.match(/]/g) || []).length;
      fixed += "]".repeat(Math.max(0, openBrackets)) + "}".repeat(Math.max(0, openBraces));
      try {
        stories = JSON.parse(fixed);
      } catch (e2) {
        return { statusCode: 500, headers, body: JSON.stringify({ error: "JSON parse failed", raw: text.slice(0, 500) }) };
      }
    }

    return { statusCode: 200, headers, body: JSON.stringify(stories) };

  } catch (e) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: "Fetch failed: " + e.message }) };
  }
};
