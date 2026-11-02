/**
 * AIMOL Unified Gateway
 * Endpoint: POST /v1/aimol/chat
 *
 * Cloudflare Worker Secrets:
 *   AIMOL_GATEWAY_TOKEN  (required)
 *   GEMINI_API_KEY       (required for Gemini)
 *   ANTHROPIC_API_KEY    (optional)
 *   GROQ_API_KEY         (optional)
 *   OPENROUTER_API_KEY   (optional)
 *
 * Optional Worker variables:
 *   GEMINI_MODEL, CLAUDE_MODEL, GROQ_MODEL, OPENROUTER_MODEL
 */

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Access-Control-Max-Age": "86400",
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" },
  });
}

function fail(message, type = "gateway_error") {
  return { error: { message: String(message), type } };
}

class ProviderError extends Error {
  constructor(message, status = 502) {
    super(message);
    this.status = status;
  }
}

function getBearer(request) {
  const h = request.headers.get("Authorization") || "";
  return h.startsWith("Bearer ") ? h.slice(7).trim() : "";
}

function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter(x => x?.type === "text").map(x => x.text || "").join("\n");
}

function dataUrl(value) {
  const m = /^data:([^;,]+);base64,([\s\S]+)$/.exec(value || "");
  return m ? { mimeType: m[1], data: m[2] } : null;
}

function geminiParts(content) {
  if (typeof content === "string") return [{ text: content }];
  const parts = [];
  for (const item of Array.isArray(content) ? content : []) {
    if (item?.type === "text") parts.push({ text: item.text || "" });
    if (item?.type === "image_url") {
      const u = typeof item.image_url === "string" ? item.image_url : item.image_url?.url;
      const image = dataUrl(u);
      if (image) parts.push({ inlineData: image });
    }
  }
  return parts.length ? parts : [{ text: "" }];
}

function geminiPayload(messages, body) {
  const system = [];
  const contents = [];
  for (const m of messages || []) {
    if (!m?.role) continue;
    if (m.role === "system" || m.role === "developer") {
      const t = textOf(m.content);
      if (t) system.push(t);
    } else {
      contents.push({
        role: m.role === "assistant" ? "model" : "user",
        parts: geminiParts(m.content),
      });
    }
  }
  const payload = {
    contents,
    generationConfig: {
      maxOutputTokens: Math.min(Number(body.max_tokens) || 4096, 8192),
      temperature: Number.isFinite(Number(body.temperature)) ? Number(body.temperature) : 0.4,
    },
  };
  if (system.length) payload.systemInstruction = { parts: [{ text: system.join("\n\n") }] };
  return payload;
}

async function callGemini(env, body) {
  if (!env.GEMINI_API_KEY) throw new ProviderError("Thiếu Secret GEMINI_API_KEY.", 501);
  const model = env.GEMINI_MODEL || "gemini-2.5-flash";
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`;
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY },
    body: JSON.stringify(geminiPayload(body.messages, body)),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new ProviderError(data?.error?.message || `Gemini HTTP ${response.status}`, response.status);
  const parts = data?.candidates?.[0]?.content?.parts || [];
  const text = parts.map(p => p.text || "").join("").trim();
  if (!text) throw new ProviderError("Gemini không trả nội dung văn bản.", 502);
  return { text, model, provider: "gemini" };
}

function anthropicMessages(messages) {
  const system = [];
  const result = [];
  for (const m of messages || []) {
    if (!m?.role) continue;
    if (m.role === "system" || m.role === "developer") {
      const t = textOf(m.content);
      if (t) system.push(t);
      continue;
    }
    const role = m.role === "assistant" ? "assistant" : "user";
    const blocks = [];
    if (typeof m.content === "string") blocks.push({ type: "text", text: m.content });
    else for (const item of Array.isArray(m.content) ? m.content : []) {
      if (item?.type === "text") blocks.push({ type: "text", text: item.text || "" });
      if (item?.type === "image_url") {
        const u = typeof item.image_url === "string" ? item.image_url : item.image_url?.url;
        const image = dataUrl(u);
        if (image) blocks.push({
          type: "image",
          source: { type: "base64", media_type: image.mimeType, data: image.data },
        });
      }
    }
    if (!blocks.length) blocks.push({ type: "text", text: "" });
    const last = result[result.length - 1];
    if (last?.role === role) last.content.push(...blocks);
    else result.push({ role, content: blocks });
  }
  return { system: system.join("\n\n"), messages: result };
}

async function callClaude(env, body) {
  if (!env.ANTHROPIC_API_KEY) throw new ProviderError("Chưa cấu hình Secret ANTHROPIC_API_KEY.", 501);
  const converted = anthropicMessages(body.messages);
  const payload = {
    model: env.CLAUDE_MODEL || "claude-3-5-haiku-latest",
    messages: converted.messages,
    max_tokens: Math.min(Number(body.max_tokens) || 4096, 8192),
    temperature: Number.isFinite(Number(body.temperature)) ? Number(body.temperature) : 0.4,
  };
  if (converted.system) payload.system = converted.system;
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(payload),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new ProviderError(data?.error?.message || `Claude HTTP ${response.status}`, response.status);
  const text = (data.content || []).filter(x => x.type === "text").map(x => x.text || "").join("\n").trim();
  if (!text) throw new ProviderError("Claude trả nội dung rỗng.", 502);
  return { text, model: payload.model, provider: "claude" };
}

async function callOpenAICompatible(env, provider, body) {
  const c = provider === "groq"
    ? { key: env.GROQ_API_KEY, model: env.GROQ_MODEL || "llama-3.3-70b-versatile", url: "https://api.groq.com/openai/v1/chat/completions" }
    : { key: env.OPENROUTER_API_KEY, model: env.OPENROUTER_MODEL || "openrouter/auto", url: "https://openrouter.ai/api/v1/chat/completions" };
  if (!c.key) throw new ProviderError(`Chưa cấu hình API key ${provider}.`, 501);
  const response = await fetch(c.url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${c.key}`,
      ...(provider === "openrouter" ? { "HTTP-Referer": "https://aimol.pages.dev", "X-Title": "AIMOL" } : {}),
    },
    body: JSON.stringify({
      model: c.model,
      messages: body.messages || [],
      max_tokens: Math.min(Number(body.max_tokens) || 4096, 8192),
      temperature: Number.isFinite(Number(body.temperature)) ? Number(body.temperature) : 0.4,
    }),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new ProviderError(data?.error?.message || `${provider} HTTP ${response.status}`, response.status);
  const text = data?.choices?.[0]?.message?.content;
  if (typeof text !== "string" || !text.trim()) throw new ProviderError(`${provider} trả nội dung rỗng.`, 502);
  return { text: text.trim(), model: data.model || c.model, provider };
}

function providerOrder(body) {
  const allowed = ["gemini", "claude", "groq", "openrouter"];
  const requested = body?.aimol?.provider_priority;
  const preferred = body?.aimol?.preferred_provider;
  const order = [];
  if (allowed.includes(preferred)) order.push(preferred);
  for (const p of Array.isArray(requested) ? requested : []) {
    if (allowed.includes(p) && !order.includes(p)) order.push(p);
  }
  for (const p of allowed) if (!order.includes(p)) order.push(p);
  return order;
}

async function callProvider(env, provider, body) {
  if (provider === "gemini") return callGemini(env, body);
  if (provider === "claude") return callClaude(env, body);
  return callOpenAICompatible(env, provider, body);
}

function canFallback(error) {
  return [408, 429, 500, 501, 502, 503, 504].includes(Number(error.status));
}

async function chat(request, env) {
  if (!env.AIMOL_GATEWAY_TOKEN) return json(fail("Gateway chưa có Secret AIMOL_GATEWAY_TOKEN."), 500);
  if (getBearer(request) !== env.AIMOL_GATEWAY_TOKEN) return json(fail("Gateway token không hợp lệ.", "authentication_error"), 401);

  let body;
  try { body = await request.json(); }
  catch { return json(fail("Request body phải là JSON hợp lệ."), 400); }
  if (!Array.isArray(body.messages) || !body.messages.length) return json(fail("Thiếu mảng messages."), 400);

  const failures = [];
  for (const provider of providerOrder(body)) {
    try {
      const result = await callProvider(env, provider, body);
      return json({
        id: `aimol-${crypto.randomUUID()}`,
        object: "chat.completion",
        created: Math.floor(Date.now() / 1000),
        model: result.model,
        provider: result.provider,
        choices: [{
          index: 0,
          message: { role: "assistant", content: result.text },
          finish_reason: "stop",
        }],
      });
    } catch (error) {
      const status = Number(error.status) || 502;
      failures.push(`${provider} HTTP ${status}: ${error.message}`);
      if (!canFallback(error)) return json(fail(`${provider}: ${error.message}`, "provider_error"), status);
    }
  }
  return json(fail(`Tất cả nhà cung cấp đều thất bại. ${failures.join(" | ")}`, "all_providers_failed"), 503);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (request.method === "GET" && url.pathname === "/") {
      return json({
        service: "AIMOL Unified Gateway",
        status: "online",
        endpoint: "/v1/aimol/chat",
        providers: ["gemini", "claude", "groq", "openrouter"],
      });
    }
    if (request.method === "POST" && url.pathname === "/v1/aimol/chat") {
      try { return await chat(request, env); }
      catch (error) { return json(fail(error?.message || "Gateway internal error."), 500); }
    }
    return json(fail("Not found"), 404);
  },
};