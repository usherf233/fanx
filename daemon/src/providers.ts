import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** pi models.json 支持的 API 类型（我们只暴露实际会用的这几种）。 */
export type ProviderApi =
  | "openai-completions"
  | "openai-responses"
  | "anthropic-messages"
  | "google-generative-ai";

export interface ModelEndpoint {
  /** provider id，写入 models.json 的键名，必须 ASCII */
  id: string;
  name: string;
  baseUrl: string;
  apiKey: string;
  api: ProviderApi;
}

export interface ProbedModel {
  id: string;
  name: string;
  reasoning: boolean;
  input: ("text" | "image")[];
  contextWindow: number;
  maxTokens: number;
  /** 是否支持工具调用，不支持的话当 Agent 用意义不大，界面上要标出来 */
  toolCall: boolean;
  cost: { input: number; output: number; cacheRead: number; cacheWrite: number };
  /** router 声明的推理档位，用于生成 thinkingLevelMap */
  reasoningLevels: string[];
}

const DEFAULT_CONTEXT = 128_000;
const DEFAULT_MAX_TOKENS = 16_384;

/** 用户可能把 baseUrl 写成带或不带 /v1 的形式，这里统一成 OpenAI 兼容前缀。 */
export function normalizeBaseUrl(raw: string): string {
  const trimmed = raw.trim().replace(/\/+$/, "");
  if (!trimmed) return "";
  return /\/v\d+(?:beta)?$/.test(trimmed) ? trimmed : `${trimmed}/v1`;
}

function pickNumber(...values: unknown[]): number | undefined {
  for (const value of values) {
    const numeric = typeof value === "string" ? Number(value) : value;
    if (typeof numeric === "number" && Number.isFinite(numeric) && numeric > 0) return numeric;
  }
  return undefined;
}

/** pricing 是"每 token 美元"，pi 要"每百万 token 美元"。部分网关把数字序列化成字符串。 */
function perMillion(value: unknown): number {
  const numeric = typeof value === "string" ? Number(value) : value;
  if (typeof numeric !== "number" || !Number.isFinite(numeric) || numeric <= 0) return 0;
  return Number((numeric * 1_000_000).toPrecision(6));
}

function toReasoningLevels(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const levels: string[] = [];
  for (const item of raw) {
    if (typeof item === "string") levels.push(item);
    else if (item && typeof item === "object") {
      const effort = (item as Record<string, unknown>).effort;
      if (typeof effort === "string") levels.push(effort);
    }
  }
  return levels;
}

function mapModel(raw: Record<string, unknown>): ProbedModel | null {
  const id = typeof raw.id === "string" ? raw.id : "";
  if (!id) return null;

  const supported = Array.isArray(raw.supported_parameters)
    ? raw.supported_parameters.filter((item): item is string => typeof item === "string")
    : [];
  const modalities = raw.modalities as Record<string, unknown> | undefined;
  const inputTypes = Array.isArray(modalities?.input)
    ? (modalities.input as unknown[]).filter((item): item is string => typeof item === "string")
    : [];
  const pricing = (raw.pricing ?? {}) as Record<string, unknown>;

  const contextWindow =
    pickNumber(raw.context_window, raw.context_length, raw.max_input_tokens) ?? DEFAULT_CONTEXT;
  const maxTokens =
    pickNumber(raw.max_output_tokens, raw.max_tokens, raw.max_completion_tokens) ??
    Math.min(DEFAULT_MAX_TOKENS, contextWindow);

  return {
    id,
    name:
      (typeof raw.display_name === "string" && raw.display_name) ||
      (typeof raw.name === "string" && raw.name) ||
      id,
    reasoning: raw.reasoning === true || supported.includes("reasoning"),
    input: inputTypes.includes("image") ? ["text", "image"] : ["text"],
    contextWindow,
    maxTokens,
    toolCall: supported.includes("tools") || raw.tool_call === true,
    cost: {
      input: perMillion(pricing.prompt),
      output: perMillion(pricing.completion),
      cacheRead: perMillion(pricing.input_cache_read),
      cacheWrite: 0,
    },
    reasoningLevels: toReasoningLevels(raw.reasoning_levels ?? raw.supported_reasoning_levels),
  };
}

/**
 * 探测一个 OpenAI 兼容端点上的模型列表。
 * 只发一次 GET /models；失败时把状态码和响应片段带出来，方便界面直接告诉用户哪一步错了。
 */
export async function probeEndpoint(
  endpoint: Pick<ModelEndpoint, "baseUrl" | "apiKey">,
): Promise<ProbedModel[]> {
  const baseUrl = normalizeBaseUrl(endpoint.baseUrl);
  if (!baseUrl) throw new Error("baseUrl 不能为空");

  let response: Response;
  try {
    response = await fetch(`${baseUrl}/models`, {
      headers: endpoint.apiKey ? { Authorization: `Bearer ${endpoint.apiKey}` } : {},
      signal: AbortSignal.timeout(15_000),
    });
  } catch (error) {
    throw new Error(`无法连接 ${baseUrl}：${error instanceof Error ? error.message : String(error)}`);
  }

  const text = await response.text();
  if (!response.ok) {
    throw new Error(`探测失败 HTTP ${response.status}：${text.slice(0, 200)}`);
  }

  let payload: unknown;
  try {
    payload = JSON.parse(text);
  } catch {
    throw new Error(`响应不是 JSON：${text.slice(0, 120)}`);
  }

  const list = Array.isArray(payload)
    ? payload
    : Array.isArray((payload as { data?: unknown }).data)
      ? ((payload as { data: unknown[] }).data)
      : Array.isArray((payload as { models?: unknown }).models)
        ? ((payload as { models: unknown[] }).models)
        : [];

  return list
    .map((item) => (item && typeof item === "object" ? mapModel(item as Record<string, unknown>) : null))
    .filter((item): item is ProbedModel => item !== null);
}

/** models.json 的值解析规则：`$` 开头的会被当环境变量，`!` 开头的会被当命令。 */
function escapeConfigValue(value: string): string {
  if (value.startsWith("$")) return `$${value}`;
  if (value.startsWith("!")) return `$!${value}`;
  return value;
}

/**
 * router 的推理档位 → pi 的 thinkingLevelMap。
 * 只声明 router 真正支持的档位，其余置 null 让 pi 直接隐藏，避免发出去被拒。
 */
function buildThinkingLevelMap(levels: string[]): Record<string, string | null> | undefined {
  if (levels.length === 0) return undefined;
  const supported = new Set(levels.map((level) => level.toLowerCase()));
  const map: Record<string, string | null> = {
    minimal: supported.has("minimal") ? "minimal" : null,
    low: supported.has("low") ? "low" : null,
    medium: supported.has("medium") ? "medium" : null,
    high: supported.has("high") ? "high" : null,
    xhigh: supported.has("xhigh") ? "xhigh" : null,
    max: supported.has("max") ? "max" : null,
  };
  return Object.values(map).some((value) => value !== null) ? map : undefined;
}

export function toModelEntry(model: ProbedModel): Record<string, unknown> {
  const entry: Record<string, unknown> = {
    id: model.id,
    name: model.name,
    reasoning: model.reasoning,
    input: model.input,
    contextWindow: model.contextWindow,
    maxTokens: model.maxTokens,
    cost: model.cost,
  };
  const thinkingLevelMap = buildThinkingLevelMap(model.reasoningLevels);
  if (thinkingLevelMap) entry.thinkingLevelMap = thinkingLevelMap;
  return entry;
}

export interface ModelsFile {
  providers: Record<string, Record<string, unknown>>;
}

/** 读取 Agent 的 models.json；损坏时返回空结构而不是抛错，避免整个界面打不开。 */
export function readModelsFile(configDir: string): ModelsFile {
  const path = join(configDir, "models.json");
  if (!existsSync(path)) return { providers: {} };
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<ModelsFile>;
    if (parsed && typeof parsed === "object" && parsed.providers && typeof parsed.providers === "object") {
      return { providers: parsed.providers };
    }
    return { providers: {} };
  } catch {
    return { providers: {} };
  }
}

/** 把端点写进 models.json：同名 provider 覆盖，其它 provider 保留。 */
export async function applyEndpointToAgent(
  configDir: string,
  endpoint: ModelEndpoint,
  models: ProbedModel[],
): Promise<void> {
  const file = readModelsFile(configDir);
  file.providers[endpoint.id] = {
    name: endpoint.name,
    baseUrl: normalizeBaseUrl(endpoint.baseUrl),
    api: endpoint.api,
    apiKey: escapeConfigValue(endpoint.apiKey),
    // 本地网关不一定接受 developer 角色，统一走 system 更稳。
    compat: { supportsDeveloperRole: false },
    models: models.map(toModelEntry),
  };
  await Bun.write(join(configDir, "models.json"), `${JSON.stringify(file, null, 2)}\n`);
}

/** 读取 settings.json，损坏时返回空对象，让写入逻辑可以从零重建。 */
export function readSettings(configDir: string): Record<string, unknown> {
  const path = join(configDir, "settings.json");
  if (!existsSync(path)) return {};
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : {};
  } catch {
    return {};
  }
}

/** 写回 settings.json 的启动默认模型：pi 启动会话时按 defaultProvider + defaultModel 解析。 */
export async function setDefaultModel(
  configDir: string,
  provider: string,
  model: string,
): Promise<void> {
  const settings = readSettings(configDir);
  settings.defaultProvider = provider;
  settings.defaultModel = model;
  await Bun.write(join(configDir, "settings.json"), `${JSON.stringify(settings, null, 2)}\n`);
}

/** 从 models.json 里列出已配置的 provider 与模型，用于界面展示。 */
export function listConfiguredModels(configDir: string) {
  const file = readModelsFile(configDir);
  return Object.entries(file.providers).map(([providerId, provider]) => {
    const models = Array.isArray(provider.models) ? provider.models : [];
    return {
      id: providerId,
      name: typeof provider.name === "string" ? provider.name : providerId,
      baseUrl: typeof provider.baseUrl === "string" ? provider.baseUrl : "",
      api: typeof provider.api === "string" ? provider.api : "openai-completions",
      models: models
        .map((item) => (item && typeof item === "object" ? (item as Record<string, unknown>) : null))
        .filter((item): item is Record<string, unknown> => item !== null)
        .map((item) => ({
          id: typeof item.id === "string" ? item.id : "",
          name: typeof item.name === "string" ? item.name : String(item.id ?? ""),
        }))
        .filter((item) => item.id.length > 0),
    };
  });
}
