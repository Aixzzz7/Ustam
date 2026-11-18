// =====================================================================
// Supabase Edge Function: ai-advisor  (Deno runtime)
//
// Optional LLM layer for Ustam. The API key never reaches the browser.
//
// Deploy:
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//   supabase functions deploy ai-advisor
// Then set VITE_AI_LLM_ENABLED=true in the web app's .env
//
// Actions:
//   { action: "match",   text, services:[{id,group,name}] } -> { serviceIds: string[] }
//   { action: "explain", strategy, candidates:[...] }      -> { text: string }
// =====================================================================

const API_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';
const MODEL = Deno.env.get('AI_MODEL') ?? 'claude-sonnet-5-5';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

/** Sends one prompt to the Anthropic Messages API and returns the text reply. */
async function ask(system: string, user: string, maxTokens = 300): Promise<string> {
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'x-api-key': API_KEY, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({ model: MODEL, max_tokens: maxTokens, system, messages: [{ role: 'user', content: user }] }),
  });
  if (!res.ok) throw new Error(`LLM error ${res.status}`);
  const data = await res.json();
  return data.content?.[0]?.text ?? '';
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  try {
    if (!API_KEY) return json({ error: 'ANTHROPIC_API_KEY not set' }, 500);
    const body = await req.json();

    // ---- 1. understand the client's free-text problem -------------------
    if (body.action === 'match') {
      const system =
        'You map a home-repair problem (English, Russian or Uzbek) to service ids from a catalog. ' +
        'Reply with ONLY a JSON array of up to 3 ids, most relevant first. Reply [] if nothing fits.';
      const user = `Problem: ${body.text}\nCatalog:\n${JSON.stringify(body.services)}`;
      const raw = await ask(system, user, 150);
      const match = raw.match(/\[[\s\S]*\]/);
      return json({ serviceIds: match ? JSON.parse(match[0]) : [] });
    }

    // ---- 2. explain the ranking -----------------------------------------
    if (body.action === 'explain') {
      const system =
        'You are the AI advisor of a home-services marketplace in Tashkent. In 2-3 short sentences, ' +
        'recommend the master with the best balance of high rating and low price, mention the price vs market ' +
        'and one alternative. Use only the data given. Prices are in Uzbek sum. No markdown.';
      const user = `Sort strategy chosen by user: ${body.strategy}\nCandidates: ${JSON.stringify(body.candidates)}`;
      return json({ text: (await ask(system, user)).trim() });
    }

    return json({ error: 'unknown action' }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
