/**
 * AI usage log + cost (admin panel → AI usage). Every OpenAI call made by routes/ai.js is recorded with its feature,
 * model, token counts, latency, outcome and an estimated cost.
 *
 * Prices are USD per 1M tokens from OpenAI's public price list (input / output). OpenAI bills images as input tokens,
 * so photo scans are covered by prompt_tokens. Override or add models without a code change:
 *   AI_PRICES_JSON='{"gpt-4o-mini":{"in":0.15,"out":0.6}}'   USD_INR=84
 * The cost is an ESTIMATE from the token counts OpenAI returns — the OpenAI dashboard bill is the source of truth.
 *
 * Privacy: only a short, redacted preview of the member's text is stored (phones, emails, long numbers masked);
 * images are never stored. Set AI_LOG_PREVIEWS=off to store no text at all.
 */
import { AsyncLocalStorage } from 'node:async_hooks';
import { query } from '../db/index.js';

const DEFAULT_PRICES = {
  'gpt-4o-mini': { in: 0.15, out: 0.6 },
  'gpt-4o': { in: 2.5, out: 10 },
  'gpt-4.1': { in: 2, out: 8 },
  'gpt-4.1-mini': { in: 0.4, out: 1.6 },
  'gpt-4.1-nano': { in: 0.1, out: 0.4 },
  'gpt-5': { in: 1.25, out: 10 },
  'gpt-5-mini': { in: 0.25, out: 2 },
  'gpt-5-nano': { in: 0.05, out: 0.4 },
};

function loadPrices() {
  try {
    return { ...DEFAULT_PRICES, ...(process.env.AI_PRICES_JSON ? JSON.parse(process.env.AI_PRICES_JSON) : {}) };
  } catch {
    return DEFAULT_PRICES;
  }
}
export const AI_PRICES = loadPrices();
export const USD_INR = Number(process.env.USD_INR) > 0 ? Number(process.env.USD_INR) : 84;

/** Price entry for a model id; dated snapshots ("gpt-4o-mini-2024-07-18") fall back to their family. */
export function priceFor(model = '') {
  if (AI_PRICES[model]) return AI_PRICES[model];
  const family = Object.keys(AI_PRICES)
    .sort((a, b) => b.length - a.length)
    .find((k) => model.startsWith(k));
  return family ? AI_PRICES[family] : null;
}

/** Estimated cost in USD for a call. Unknown model → null (shown as "price unknown"). */
export function costUsd(model, promptTokens = 0, completionTokens = 0) {
  const p = priceFor(model);
  if (!p) return null;
  return (promptTokens * p.in + completionTokens * p.out) / 1_000_000;
}

const PREVIEWS = (process.env.AI_LOG_PREVIEWS ?? 'on') !== 'off';

/** Short, redacted text preview: masks emails, phone numbers and other long digit runs. */
export function preview(text, max = 240) {
  if (!PREVIEWS || text == null) return null;
  const s = String(text)
    .replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, '[email]')
    .replace(/\+?\d[\d\s-]{8,}\d/g, '[number]')
    .replace(/\s+/g, ' ')
    .trim();
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
}

/** Request context (member + feature) so nested helpers (e.g. the topic guard) are attributed correctly. */
export const aiContext = new AsyncLocalStorage();

/**
 * Records one call. Never throws and never delays the member's response.
 * entry: { userId, feature, model, usage:{prompt_tokens, completion_tokens, total_tokens}, latencyMs, status,
 *          httpStatus, error, input, output, hasImage }
 */
export function logAiUsage(entry) {
  const ctx = aiContext.getStore() ?? {};
  const u = entry.usage ?? {};
  const pt = Number(u.prompt_tokens) || 0;
  const ct = Number(u.completion_tokens) || 0;
  const usd = costUsd(entry.model, pt, ct);
  query(
    `INSERT INTO ai_usage_logs (user_id, feature, model, prompt_tokens, completion_tokens, total_tokens, cost_usd, cost_inr,
       latency_ms, status, http_status, error, input_preview, output_preview, has_image)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)`,
    [
      entry.userId ?? ctx.userId ?? null,
      entry.feature ?? ctx.feature ?? 'other',
      entry.model ?? 'unknown',
      pt,
      ct,
      Number(u.total_tokens) || pt + ct,
      usd,
      usd == null ? null : usd * USD_INR,
      entry.latencyMs ?? null,
      entry.status ?? 'ok',
      entry.httpStatus ?? null,
      entry.error ? String(entry.error).slice(0, 300) : null,
      preview(entry.input),
      preview(entry.output, 400),
      Boolean(entry.hasImage),
    ],
  ).catch((e) => console.error('[ai-usage] log failed:', e.message));
}
