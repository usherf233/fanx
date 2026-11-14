import { existsSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import type { AgentSessionRuntime } from "@earendil-works/pi-coding-agent";
import { createAgentRuntime, describeEffectiveResources } from "./runtime.ts";
import {
  AGENTS_ROOT,
  addAgent,
  getAgent,
  isValidAgentId,
  listAgents,
  removeAgent,
  uniqueAgentId,
  updateAgent,
} from "./registry.ts";
import { scaffoldAgentDir, DEFAULT_WORKSPACE } from "./scaffold.ts";
import {
  ResourceError,
  copyResourceBetween,
  countEnabled,
  createSkill,
  deleteResource,
  getResourceDetail,
  importResource,
  scanResources,
  toggleMany,
  toggleResource,
} from "./resources.ts";
import {
  applyEndpointToAgent,
  listConfiguredModels,
  probeEndpoint,
  readSettings,
  setDefaultModel,
  type ProviderApi,
} from "./providers.ts";
import type { AgentRecord, ResourceItem, ResourceSnapshot } from "./types.ts";

class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

interface Managed {
  runtime: AgentSessionRuntime;
  unsubscribe: () => void;
  lastError?: string;
}

export interface ServerOptions {
  port?: number;
  hostname?: string;
}

type SseSend = (payload: unknown) => void;

/** 跨 Agent 总览的一行：同一份资源在各 Agent 里的启用情况。 */
interface LibraryRow {
  key: string;
  kind: string;
  name: string;
  description: string;
  bytes: number;
  files: number;
  issues: string[];
  agents: {
    agentId: string;
    agentName: string;
    enabled: boolean;
    loaded: boolean | null;
    entry: string;
  }[];
}

type SessionRow = {
  id: string;
  name: string;
  firstMessage: unknown;
  modified: unknown;
  messageCount: unknown;
};

/**
 * 会话目录的轻量签名：只看文件名、大小与 mtime，不读文件内容。
 * SDK 的 SessionManager.list 会把每个 JSONL 从头到尾读一遍来拼标题和摘要，
 * 会话一多就是 N 份完整历史；用这个签名可以在目录没变时复用上次结果。
 */
function sessionsSignature(dir: string): string {
  if (!existsSync(dir)) return "missing";
  const parts: string[] = [];
  for (const name of readdirSync(dir)) {
    if (!name.endsWith(".jsonl")) continue;
    try {
      const stat = statSync(join(dir, name));
      parts.push(`${name}:${stat.size}:${stat.mtimeMs}`);
    } catch {
      // 扫描瞬间被删掉的文件跳过即可，下次签名自然会变。
    }
  }
  parts.sort();
  return parts.join("|");
}

export async function startServer(options: ServerOptions = {}) {
  const managed = new Map<string, Managed>();
  const listeners = new Map<string, Set<SseSend>>();
  const busy = new Set<string>();
  const lastStateJson = new Map<string, string>();
  const sessionListCache = new Map<string, { signature: string; rows: SessionRow[] }>();
  // 只读预览缓存：key 是 JSONL 路径，签名用 size+mtime，内容没变就不重读盘。
  const sessionPreviewCache = new Map<string, { signature: string; messages: unknown[] }>();

  function broadcast(agentId: string, payload: unknown): void {
    const set = listeners.get(agentId);
    if (!set) return;
    // 每个事件都带上产生它的会话号。前端订阅 SSE 时会带 ?session=，
    // 这样预览历史会话时不会把另一个会话的 token / state 串到画面上。
    const event: Record<string, unknown> = {
      ...(payload as Record<string, unknown>),
      sessionId: managed.get(agentId)?.runtime.session.sessionId ?? null,
    };
    // 一轮对话里 message_end / agent_end / finally 会连推数份 state，每份都
    // 带全量消息历史。内容完全相同的那几份直接丢掉，避免前端反复全量解析。
    // 新 SSE 连接用 rawSend() 直发，不走这里，不会因去重漏掉初始快照。
    if (event.type === "state") {
      const encoded = JSON.stringify(event);
      if (encoded === lastStateJson.get(agentId)) return;
      lastStateJson.set(agentId, encoded);
    }
    for (const send of set) send(event);
  }

  function agentState(agent: AgentRecord) {
    const entry = managed.get(agent.id);
    if (!entry) {
      return { running: false as const, busy: false, messages: [], sessionId: null };
    }
    const session = entry.runtime.session;
    const model = session.model;
    return {
      running: true as const,
      busy: busy.has(agent.id) || session.isStreaming,
      sessionId: session.sessionId,
      sessionName: session.sessionName ?? "",
      model:
        model && model.id !== "unknown"
          ? { provider: model.provider, id: model.id, name: model.name }
          : null,
      thinkingLevel: session.thinkingLevel,
      messages: session.messages,
      diagnostics: entry.runtime.diagnostics,
      lastError: entry.lastError ?? null,
    };
  }

  function bindSession(agentId: string, entry: Managed): void {
    entry.unsubscribe();
    entry.unsubscribe = entry.runtime.session.subscribe((event) => {
      // 流式增量单独走一条轻量事件：原始 message_update 带着整条 partial
      // 消息，逐个 token 广播会把 SSE 撑爆。
      if (event.type === "message_update") {
        const delta = event.assistantMessageEvent;
        if (delta.type === "text_delta") {
          broadcast(agentId, { type: "delta", text: delta.delta });
        } else if (delta.type === "thinking_start") {
          broadcast(agentId, { type: "thinking" });
        } else if (delta.type === "text_start") {
          broadcast(agentId, { type: "text_start" });
        }
        return;
      }

      // SDK 原始事件（agent_end 的全量 messages、工具入参/结果等）前端并不
      // 消费，以前无过滤透传只是白白撑大 SSE 流、多一次 jsonDecode。
      // 只保留下面这条精简的 state 广播。
      if (event.type === "message_end" || event.type === "agent_end") {
        const agent = getAgent(agentId);
        if (agent) broadcast(agentId, { type: "state", state: agentState(agent) });
      }
    });
  }

  async function ensureRuntime(agent: AgentRecord): Promise<Managed> {
    const existing = managed.get(agent.id);
    if (existing) return existing;

    const runtime = await createAgentRuntime(agent);
    const entry: Managed = { runtime, unsubscribe: () => {} };
    bindSession(agent.id, entry);
    entry.runtime.setRebindSession(async () => {
      bindSession(agent.id, entry);
    });
    managed.set(agent.id, entry);
    return entry;
  }

  async function disposeRuntime(agentId: string): Promise<void> {
    const entry = managed.get(agentId);
    if (!entry) return;
    entry.unsubscribe();
    managed.delete(agentId);
    try {
      await entry.runtime.dispose();
    } catch {
      /* 关闭失败不应阻塞删除 */
    }
  }

  function summary(agent: AgentRecord) {
    const snapshot = scanResources(agent.configDir);
    const counts = countEnabled(snapshot);
    return {
      ...agent,
      running: managed.has(agent.id),
      skills: counts.skills,
      extensions: counts.extensions,
      prompts: counts.prompts,
    };
  }

  function requireAgent(id: string): AgentRecord {
    const agent = getAgent(id);
    if (!agent) throw new HttpError(404, "Agent 不存在");
    return agent;
  }

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
    });

  async function readJson(req: Request): Promise<Record<string, unknown>> {
    const text = await req.text();
    if (!text.trim()) return {};
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new HttpError(400, "请求体不是合法 JSON");
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new HttpError(400, "请求体必须是 JSON 对象");
    }
    return parsed as Record<string, unknown>;
  }

  function str(input: Record<string, unknown>, key: string): string | undefined {
    const value = input[key];
    if (value === undefined || value === null) return undefined;
    if (typeof value !== "string") throw new HttpError(400, `字段 ${key} 必须是字符串`);
    return value;
  }

  function bool(input: Record<string, unknown>, key: string): boolean | undefined {
    const value = input[key];
    if (value === undefined || value === null) return undefined;
    if (typeof value !== "boolean") throw new HttpError(400, `字段 ${key} 必须是布尔值`);
    return value;
  }

  /** 凭据只回传"是否已配置"，密钥永远不出后端。 */
  function authSummary(configDir: string) {
    const path = join(configDir, "auth.json");
    if (!existsSync(path)) return { providers: [] as string[], configured: false };
    try {
      const parsed = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
      const providers = Object.keys(parsed).filter((key) => {
        const value = parsed[key];
        if (typeof value === "string") return value.length > 0;
        return Boolean(value);
      });
      return { providers, configured: providers.length > 0 };
    } catch {
      return { providers: [] as string[], configured: false };
    }
  }

  function readTextFile(path: string): string {
    try {
      return readFileSync(path, "utf8");
    } catch {
      return "";
    }
  }

  function readJsonFile(path: string): unknown {
    try {
      return JSON.parse(readFileSync(path, "utf8"));
    } catch {
      return null;
    }
  }

  async function handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const parts = url.pathname.split("/").filter(Boolean);

    if (parts[0] !== "api") throw new HttpError(404, "Not found");

    if (parts[1] === "health" && req.method === "GET") {
      return json({ ok: true, service: "pi-agent-manager", managerHome: AGENTS_ROOT });
    }

    // /api/library —— 跨 Agent 的能力总账：同一份资源装给了谁、谁还停着
    if (parts[1] === "library") {
      if (parts.length === 2 && req.method === "GET") {
        const records = listAgents();
        const rows = new Map<string, LibraryRow>();

        for (const record of records) {
          const snapshot = scanResources(record.configDir);
          const entry = managed.get(record.id);
          const effective = entry ? describeEffectiveResources(entry.runtime) : null;
          const loadedSets = effective
            ? {
                skills: new Set(effective.skills.map((item) => item.name)),
                prompts: new Set(effective.prompts.map((item) => item.name)),
                extensions: new Set(effective.extensions.map((item) => basename(item.path))),
              }
            : null;

          for (const kind of ["skills", "extensions", "prompts"] as const) {
            const loadedSet = loadedSets
              ? kind === "skills"
                ? loadedSets.skills
                : kind === "prompts"
                  ? loadedSets.prompts
                  : loadedSets.extensions
              : null;

            for (const item of snapshot[kind]) {
              const key = `${item.kind}:${item.name}`;
              const row: LibraryRow =
                rows.get(key) ?? {
                  key,
                  kind: item.kind,
                  name: item.name,
                  description: item.description,
                  bytes: 0,
                  files: 0,
                  issues: [],
                  agents: [],
                };
              if (!row.description && item.description) row.description = item.description;
              row.bytes = Math.max(row.bytes, item.bytes);
              row.files = Math.max(row.files, item.files);
              row.issues = [...new Set([...row.issues, ...item.issues])];
              row.agents.push({
                agentId: record.id,
                agentName: record.name,
                enabled: item.enabled,
                loaded: loadedSet
                  ? item.enabled && loadedSet.has(kind === "extensions" ? item.entry : item.name)
                  : null,
                entry: item.entry,
              });
              rows.set(key, row);
            }
          }
        }

        const order = ["skill", "extension", "prompt"];
        const items = [...rows.values()].sort(
          (a, b) => order.indexOf(a.kind) - order.indexOf(b.kind) || a.name.localeCompare(b.name),
        );

        return json({
          agents: records.map(summary),
          items,
          stats: {
            items: items.length,
            relations: items.reduce((sum, row) => sum + row.agents.length, 0),
            enabled: items.reduce(
              (sum, row) => sum + row.agents.filter((agent) => agent.enabled).length,
              0,
            ),
            issues: items.filter((row) => row.issues.length > 0).length,
          },
        });
      }

      // 把某个 Agent 的资源复制给另一个 Agent（只复制，不动源）。
      if (parts.length === 3 && parts[2] === "copy" && req.method === "POST") {
        const input = await readJson(req);
        const sourceAgentId = str(input, "sourceAgentId");
        const targetAgentId = str(input, "targetAgentId");
        const type = str(input, "type");
        const name = str(input, "name");
        if (!sourceAgentId || !targetAgentId || !type || !name) {
          throw new HttpError(400, "需要 sourceAgentId / targetAgentId / type / name");
        }
        const sourceAgent = requireAgent(sourceAgentId);
        const targetAgent = requireAgent(targetAgentId);

        let result: { path: string };
        try {
          result = copyResourceBetween(sourceAgent.configDir, targetAgent.configDir, type, name);
        } catch (error) {
          if (error instanceof ResourceError) throw new HttpError(error.status, error.message);
          throw error;
        }

        const target = managed.get(targetAgentId);
        if (target) {
          try {
            await target.runtime.session.reload();
          } catch {
            /* 重载失败不影响复制本身 */
          }
        }
        return json({ ok: true, path: result.path });
      }

      throw new HttpError(404, "Not found");
    }

    if (parts[1] !== "agents") throw new HttpError(404, "Not found");

    // /api/agents
    if (parts.length === 2) {
      if (req.method === "GET") return json({ agents: listAgents().map(summary) });

      if (req.method === "POST") {
        const input = await readJson(req);
        const name = str(input, "name")?.trim();
        if (!name) throw new HttpError(400, "name 不能为空");

        const requestedId = str(input, "id")?.trim();
        if (requestedId && !isValidAgentId(requestedId)) {
          throw new HttpError(400, "id 只能包含小写字母、数字和连字符，且不能以连字符开头");
        }
        const id = requestedId ?? uniqueAgentId(name);
        if (getAgent(id)) throw new HttpError(409, `Agent id 已存在：${id}`);

        const configDir = str(input, "configDir")?.trim() || join(AGENTS_ROOT, id);
        const cwd = str(input, "cwd")?.trim() || join(configDir, DEFAULT_WORKSPACE);
        if (existsSync(configDir)) throw new HttpError(409, `配置目录已存在：${configDir}`);

        const cloneFromId = str(input, "cloneFrom");
        const cloneFrom = cloneFromId ? getAgent(cloneFromId)?.configDir : undefined;

        scaffoldAgentDir({
          configDir,
          name,
          systemPrompt: str(input, "systemPrompt"),
          cloneFrom,
        });

        const now = new Date().toISOString();
        const record: AgentRecord = {
          id,
          name,
          description: str(input, "description") ?? "",
          configDir,
          cwd,
          createdAt: now,
          updatedAt: now,
        };
        addAgent(record);
        return json({ agent: summary(record) }, 201);
      }
      throw new HttpError(405, "Method not allowed");
    }

    const agentId = parts[2]!;
    const agent = requireAgent(agentId);

    // /api/agents/:id
    if (parts.length === 3) {
      if (req.method === "GET") return json({ agent: summary(agent), state: agentState(agent) });

      if (req.method === "PATCH") {
        const input = await readJson(req);
        const patch: Partial<AgentRecord> = {};
        const name = str(input, "name")?.trim();
        if (name) patch.name = name;
        const description = str(input, "description");
        if (description !== undefined) patch.description = description;
        const cwd = str(input, "cwd")?.trim();
        if (cwd) {
          if (!existsSync(cwd)) throw new HttpError(400, `工作目录不存在：${cwd}`);
          patch.cwd = cwd;
        }
        const updated = updateAgent(agentId, patch);
        if (!updated) throw new HttpError(404, "Agent 不存在");
        // cwd 变了，运行中的 runtime 必须重建。
        if (patch.cwd) await disposeRuntime(agentId);
        return json({ agent: summary(updated) });
      }

      if (req.method === "DELETE") {
        const deleteDir = url.searchParams.get("deleteDir") === "true";
        await disposeRuntime(agentId);
        const removed = removeAgent(agentId);
        if (!removed) throw new HttpError(404, "Agent 不存在");
        if (deleteDir && existsSync(removed.configDir)) {
          rmSync(removed.configDir, { recursive: true, force: true });
        }
        return json({ removed: removed.id, deletedDir: deleteDir });
      }
      throw new HttpError(405, "Method not allowed");
    }

    // /api/agents/:id/config
    if (parts[3] === "config") {
      if (req.method === "GET") {
        return json({
          systemPrompt: readTextFile(join(agent.configDir, "AGENTS.md")),
          settings: readJsonFile(join(agent.configDir, "settings.json")),
          models: readJsonFile(join(agent.configDir, "models.json")),
          auth: authSummary(agent.configDir),
          paths: {
            configDir: agent.configDir,
            cwd: agent.cwd,
            skills: join(agent.configDir, "skills"),
            extensions: join(agent.configDir, "extensions"),
            prompts: join(agent.configDir, "prompts"),
            sessions: join(agent.configDir, "sessions"),
          },
        });
      }
      if (req.method === "PUT") {
        const input = await readJson(req);
        const systemPrompt = str(input, "systemPrompt");
        if (systemPrompt !== undefined) {
          await Bun.write(join(agent.configDir, "AGENTS.md"), `${systemPrompt}\n`);
        }
        return json({ ok: true });
      }
      throw new HttpError(405, "Method not allowed");
    }

    // /api/agents/:id/resources
    if (parts[3] === "resources") {
      // 资源改动后让运行中的会话重新读取磁盘，否则界面说"已启用"、模型却还看不到。
      const reloadRuntime = async () => {
        const entry = managed.get(agentId);
        if (!entry) return;
        try {
          await entry.runtime.session.reload();
        } catch {
          /* 重载失败不影响文件操作本身 */
        }
      };

      const withEffective = (snapshot: ResourceSnapshot) => {
        const entry = managed.get(agentId);
        const effective = entry ? describeEffectiveResources(entry.runtime) : null;
        // 磁盘上有、pi 却没加载的条目要能在界面上被标出来。
        // 没有运行时会话时不写 loaded 字段：界面显示「未知」比谎报「未加载」诚实。
        const loadedSkills = new Set((effective?.skills ?? []).map((item) => item.name));
        const loadedPrompts = new Set((effective?.prompts ?? []).map((item) => item.name));
        const loadedExtensions = new Set(
          (effective?.extensions ?? []).map((item) => basename(item.path)),
        );
        const mark = (items: ResourceItem[], loaded: Set<string>, by: (item: ResourceItem) => string) =>
          items.map((item) =>
            effective ? { ...item, loaded: item.enabled && loaded.has(by(item)) } : { ...item },
          );
        return {
          ...snapshot,
          skills: mark(snapshot.skills, loadedSkills, (item) => item.name),
          prompts: mark(snapshot.prompts, loadedPrompts, (item) => item.name),
          extensions: mark(snapshot.extensions, loadedExtensions, (item) => item.entry),
          effective,
        };
      };

      const guard = <T>(run: () => T): T => {
        try {
          return run();
        } catch (error) {
          if (error instanceof ResourceError) throw new HttpError(error.status, error.message);
          throw error;
        }
      };

      if (parts.length === 4 && req.method === "GET") {
        return json(withEffective(scanResources(agent.configDir)));
      }

      // 单个资源的完整内容，供右侧检视面板使用。
      if (parts.length === 5 && parts[4] === "item" && req.method === "GET") {
        const type = url.searchParams.get("type") ?? "";
        const name = url.searchParams.get("name") ?? "";
        const detail = guard(() => getResourceDetail(agent.configDir, type, name));
        return json({ item: detail });
      }

      if (parts.length === 5 && parts[4] === "toggle" && req.method === "POST") {
        const input = await readJson(req);
        const type = str(input, "type");
        const name = str(input, "name");
        const enabled = bool(input, "enabled");
        if (!type || !name || enabled === undefined) {
          throw new HttpError(400, "需要 type / name / enabled");
        }
        const result = guard(() => toggleResource(agent.configDir, type, name, enabled));
        await reloadRuntime();
        return json({
          ok: true,
          path: result.path,
          resources: withEffective(scanResources(agent.configDir)),
        });
      }

      // 批量启停：按当前过滤结果一次性操作。
      if (parts.length === 5 && parts[4] === "batch" && req.method === "POST") {
        const input = await readJson(req);
        const type = str(input, "type");
        const enabled = bool(input, "enabled");
        const names = Array.isArray(input.names)
          ? input.names.filter((item): item is string => typeof item === "string")
          : [];
        if (!type || enabled === undefined || names.length === 0) {
          throw new HttpError(400, "需要 type / names / enabled");
        }
        const result = guard(() => toggleMany(agent.configDir, type, names, enabled));
        await reloadRuntime();
        return json({
          ...result,
          resources: withEffective(scanResources(agent.configDir)),
        });
      }

      // 从本地路径导入：目录→技能，单文件→扩展/模板/单文件技能。
      if (parts.length === 5 && parts[4] === "import" && req.method === "POST") {
        const input = await readJson(req);
        const type = str(input, "type");
        const source = str(input, "source");
        if (!type || !source) throw new HttpError(400, "需要 type / source");
        const result = guard(() =>
          importResource(agent.configDir, type, source, {
            name: str(input, "name"),
            overwrite: bool(input, "overwrite") ?? false,
          }),
        );
        await reloadRuntime();
        return json({ ok: true, ...result, resources: withEffective(scanResources(agent.configDir)) });
      }

      // 新建技能骨架。
      if (parts.length === 5 && parts[4] === "create" && req.method === "POST") {
        const input = await readJson(req);
        const type = str(input, "type") ?? "skills";
        if (type !== "skills") throw new HttpError(400, "目前只支持新建技能");
        const name = str(input, "name") ?? "";
        const result = guard(() => createSkill(agent.configDir, name, str(input, "description") ?? ""));
        await reloadRuntime();
        return json({ ok: true, ...result, resources: withEffective(scanResources(agent.configDir)) });
      }

      if (parts.length === 5 && parts[4] === "item" && req.method === "DELETE") {
        const type = url.searchParams.get("type") ?? "";
        const name = url.searchParams.get("name") ?? "";
        const result = guard(() => deleteResource(agent.configDir, type, name));
        await reloadRuntime();
        return json({ ok: true, ...result, resources: withEffective(scanResources(agent.configDir)) });
      }

      throw new HttpError(404, "Not found");
    }

    // /api/agents/:id/models —— 该 Agent 的模型端点与模型清单
    if (parts[3] === "models") {
      if (parts.length === 4 && req.method === "GET") {
        const settings = readSettings(agent.configDir);
        return json({
          providers: listConfiguredModels(agent.configDir),
          defaultProvider:
            typeof settings.defaultProvider === "string" ? settings.defaultProvider : null,
          defaultModel: typeof settings.defaultModel === "string" ? settings.defaultModel : null,
          active: agentState(agent).model ?? null,
        });
      }

      // 只探测、不落盘：让界面在保存前先看清楚这个端点上到底有什么。
      if (parts.length === 5 && parts[4] === "probe" && req.method === "POST") {
        const input = await readJson(req);
        const baseUrl = str(input, "baseUrl")?.trim();
        if (!baseUrl) throw new HttpError(400, "baseUrl 不能为空");
        const models = await probeEndpoint({ baseUrl, apiKey: str(input, "apiKey") ?? "" });
        return json({ models });
      }

      // 写入端点与模型，并设定默认模型；已启动的 runtime 必须重建才会读到新配置。
      if (parts.length === 4 && req.method === "PUT") {
        const input = await readJson(req);
        const providerId = str(input, "providerId")?.trim();
        const baseUrl = str(input, "baseUrl")?.trim();
        if (!providerId || !/^[a-z0-9][a-z0-9-]{0,47}$/.test(providerId)) {
          throw new HttpError(400, "providerId 只能包含小写字母、数字和连字符");
        }
        if (!baseUrl) throw new HttpError(400, "baseUrl 不能为空");

        const api = (str(input, "api") ?? "openai-completions") as ProviderApi;
        const picked = Array.isArray(input.models)
          ? input.models.filter((item): item is string => typeof item === "string")
          : [];

        const probed = await probeEndpoint({ baseUrl, apiKey: str(input, "apiKey") ?? "" });
        const selected =
          picked.length > 0 ? probed.filter((model) => picked.includes(model.id)) : probed;
        if (selected.length === 0) {
          throw new HttpError(400, "没有匹配到任何模型，请先探测端点确认模型 id");
        }

        await applyEndpointToAgent(
          agent.configDir,
          {
            id: providerId,
            name: str(input, "name")?.trim() || providerId,
            baseUrl,
            apiKey: str(input, "apiKey") ?? "",
            api,
          },
          selected,
        );

        const wantedModel = str(input, "model")?.trim();
        const fallback =
          selected.find((model) => model.id === wantedModel) ??
          selected.find((model) => model.toolCall) ??
          selected[0]!;
        await setDefaultModel(agent.configDir, providerId, wantedModel || fallback.id);

        // 配置变了，运行中的会话仍持有旧 ModelRuntime，必须丢弃重建。
        await disposeRuntime(agentId);

        return json({
          ok: true,
          providers: listConfiguredModels(agent.configDir),
          defaultProvider: providerId,
          defaultModel: wantedModel || fallback.id,
        });
      }
      throw new HttpError(405, "Method not allowed");
    }

    // /api/agents/:id/model —— 切换当前生效的默认模型
    if (parts[3] === "model" && req.method === "PUT") {
      const input = await readJson(req);
      const provider = str(input, "provider")?.trim();
      const modelId = str(input, "model")?.trim();
      if (!provider || !modelId) throw new HttpError(400, "需要 provider 与 model");

      const configured = listConfiguredModels(agent.configDir).find((item) => item.id === provider);
      if (!configured) throw new HttpError(400, `未配置的 provider：${provider}`);
      if (!configured.models.some((item) => item.id === modelId)) {
        throw new HttpError(400, `该 provider 下没有模型：${modelId}`);
      }

      await setDefaultModel(agent.configDir, provider, modelId);

      const entry = managed.get(agentId);
      if (entry) {
        const target = entry.runtime.services.modelRuntime.getModel(provider, modelId);
        if (target) await entry.runtime.session.setModel(target);
      }
      return json({ ok: true, defaultProvider: provider, defaultModel: modelId });
    }

    // /api/agents/:id/sessions —— 会话列表与生命周期
    if (parts[3] === "sessions") {
      const { SessionManager } = await import("@earendil-works/pi-coding-agent");
      const sessionsDir = join(agent.configDir, "sessions");
      const activeId = managed.get(agentId)?.runtime.session.sessionId;

      if (parts.length === 4 && req.method === "GET") {
        const signature = sessionsSignature(sessionsDir);
        const cached = sessionListCache.get(agentId);
        let rows: SessionRow[];
        if (cached && cached.signature === signature) {
          rows = cached.rows;
        } else {
          const list = await SessionManager.list(agent.cwd, sessionsDir);
          rows = list.map((item) => ({
            id: item.id,
            name: item.name ?? "",
            firstMessage: item.firstMessage,
            modified: item.modified,
            messageCount: item.messageCount,
          }));
          sessionListCache.set(agentId, { signature, rows });
        }
        // active 是运行时状态，不随文件内容变化，每次按当前会话重算。
        return json({
          sessions: rows.map((row) => ({ ...row, active: row.id === activeId })),
        });
      }

      // 新建会话：不删旧会话，只是把 runtime 切到一个新的空会话。
      if (parts.length === 4 && req.method === "POST") {
        const entry = await ensureRuntime(agent);
        if (busy.has(agentId) || entry.runtime.session.isStreaming) {
          throw new HttpError(409, "该 Agent 正在回复，先停止再新建会话");
        }
        const result = await entry.runtime.newSession();
        if (result.cancelled) throw new HttpError(409, "新建会话被取消");
        // 全量 state 只组一次：broadcast 要序列化一遍，HTTP 响应又是一遍。
        const state = agentState(agent);
        broadcast(agentId, { type: "state", state });
        return json({ ok: true, state });
      }

      // 只读预览：直接读目标 JSONL 的历史，不切换 runtime、不重建 AgentSession。
      // 「点开看看」与「在这个会话里继续聊」是两件事，前者不该付切换的代价。
      if (parts.length === 6 && parts[5] === "state" && req.method === "GET") {
        const sessionId = parts[4]!;
        const path = SessionManager.findById(agent.cwd, sessionId, sessionsDir);
        if (!path || !existsSync(path)) throw new HttpError(404, "会话不存在");

        let signature: string;
        try {
          const stat = statSync(path);
          signature = `${stat.size}:${stat.mtimeMs}`;
        } catch {
          throw new HttpError(404, "会话不存在");
        }
        const cached = sessionPreviewCache.get(path);
        let messages: unknown[];
        if (cached && cached.signature === signature) {
          messages = cached.messages;
        } else {
          const manager = SessionManager.open(path, sessionsDir, agent.cwd);
          messages = manager.buildSessionContext().messages as unknown[];
          sessionPreviewCache.set(path, { signature, messages });
          while (sessionPreviewCache.size > 24) {
            const oldest = sessionPreviewCache.keys().next().value;
            if (oldest === undefined) break;
            sessionPreviewCache.delete(oldest);
          }
        }

        const runtime = managed.get(agentId)?.runtime.session;
        const model = runtime?.model;
        return json({
          running: runtime != null,
          busy: busy.has(agentId) || (runtime?.isStreaming ?? false),
          sessionId,
          sessionName: "",
          model:
            model && model.id !== "unknown"
              ? { provider: model.provider, id: model.id, name: model.name }
              : null,
          messages,
          lastError: null,
          // 前端据此显示「预览中」提示；发送第一条新消息时才会真正激活。
          readOnly: sessionId !== runtime?.sessionId,
        });
      }

      // 切到历史会话：只有用户真的要在这个会话里发消息时才调用。
      if (parts.length === 6 && parts[5] === "activate" && req.method === "POST") {
        const sessionId = parts[4]!;
        const entry = await ensureRuntime(agent);
        if (busy.has(agentId) || entry.runtime.session.isStreaming) {
          throw new HttpError(409, "该 Agent 正在回复，先停止再切换会话");
        }
        if (entry.runtime.session.sessionId === sessionId) {
          return json({ ok: true, state: agentState(agent) });
        }
        const path = SessionManager.findById(agent.cwd, sessionId, sessionsDir);
        if (!path || !existsSync(path)) throw new HttpError(404, "会话不存在");
        const result = await entry.runtime.switchSession(path);
        if (result.cancelled) throw new HttpError(409, "切换会话被取消");
        // 全量 state 只组一次：broadcast 要序列化一遍，HTTP 响应又是一遍。
        const state = agentState(agent);
        broadcast(agentId, { type: "state", state });
        return json({ ok: true, state });
      }

      // 删除会话：直接删 JSONL 文件。删的是当前会话时，顺手新建一个空会话顶上。
      if (parts.length === 5 && req.method === "DELETE") {
        const sessionId = parts[4]!;
        const path = SessionManager.findById(agent.cwd, sessionId, sessionsDir);
        if (!path || !existsSync(path)) throw new HttpError(404, "会话不存在");

        const entry = managed.get(agentId);
        const isActive = entry?.runtime.session.sessionId === sessionId;
        if (isActive && (busy.has(agentId) || entry!.runtime.session.isStreaming)) {
          throw new HttpError(409, "该 Agent 正在回复，先停止再删除会话");
        }

        rmSync(path, { force: true });
        if (isActive && entry) {
          await entry.runtime.newSession();
          broadcast(agentId, { type: "state", state: agentState(agent) });
        }
        return json({ ok: true, removed: sessionId, active: isActive });
      }

      throw new HttpError(405, "Method not allowed");
    }

    // /api/agents/:id/state
    if (parts[3] === "state" && req.method === "GET") {
      return json(agentState(agent));
    }

    // /api/agents/:id/chat
    if (parts[3] === "chat" && req.method === "POST") {
      const input = await readJson(req);
      const message = str(input, "message")?.trim();
      if (!message) throw new HttpError(400, "message 不能为空");

      const entry = await ensureRuntime(agent);
      if (busy.has(agentId) || entry.runtime.session.isStreaming) {
        throw new HttpError(409, "该 Agent 正忙");
      }
      busy.add(agentId);
      broadcast(agentId, { type: "state", state: agentState(agent) });

      void (async () => {
        try {
          entry.lastError = undefined;
          const before = entry.runtime.session.messages.length;
          await entry.runtime.session.prompt(message);

          // pi 调用模型失败时不会抛错，而是正常结束并产出一条 content 为空的
          // assistant 消息，真实原因写在 stopReason=error + errorMessage 里。
          // 这里优先用它，别再把"请求失败"说成"空回复"。
          const produced = entry.runtime.session.messages.slice(before);
          const replies = produced.filter((item) => item.role === "assistant");
          const loose = replies as unknown as {
            provider?: string;
            model?: string;
            errorMessage?: string;
          }[];
          const failure = [...loose]
            .reverse()
            .find((item) => typeof item.errorMessage === "string" && item.errorMessage.trim());

          if (failure) {
            const endpoint = [failure.provider, failure.model].filter(Boolean).join("/");
            const raw = failure.errorMessage!.trim();
            entry.lastError = endpoint ? `${endpoint} 调用失败：${raw}` : raw;
            console.error(`[chat] ${agentId}: ${entry.lastError}`);
          } else {
            const hasContent = replies.some(
              (item) => Array.isArray(item.content) && item.content.length > 0,
            );
            if (replies.length > 0 && !hasContent) {
              entry.lastError = "模型返回了空内容（没有 text 块），检查该 Agent 的模型配置。";
              console.error(`[chat] ${agentId}: 空回复`);
            }
          }
        } catch (error) {
          const messageText = error instanceof Error ? error.message : String(error);
          entry.lastError = messageText;
          // 没有 SSE 订阅者时错误会无声消失，至少留在服务端日志里。
          console.error(`[chat] ${agentId}: ${messageText}`);
          broadcast(agentId, { type: "error", message: messageText });
        } finally {
          busy.delete(agentId);
          broadcast(agentId, { type: "state", state: agentState(agent) });
        }
      })();

      return json({ accepted: true }, 202);
    }

    // /api/agents/:id/action
    if (parts[3] === "action" && req.method === "POST") {
      const input = await readJson(req);
      const action = str(input, "action");
      const entry = await ensureRuntime(agent);

      switch (action) {
        case "abort":
          busy.delete(agentId);
          await entry.runtime.session.abort();
          return json({ ok: true });
        case "new":
          await entry.runtime.newSession();
          return json({ ok: true, state: agentState(agent) });
        case "reload":
          await entry.runtime.session.reload();
          return json({ ok: true });
        default:
          throw new HttpError(400, `不支持的操作：${action ?? "(空)"}`);
      }
    }

    // /api/agents/:id/events
    if (parts[3] === "events" && req.method === "GET") {
      // 乐观切换时前端已经画了目标会话的缓存，后端此刻还在旧会话上。
      // 带上期望会话号就不会再推一份旧会话的全量历史过去。
      const expectedSession = new URL(req.url).searchParams.get("session");
      let cleanup = () => {};
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          const encoder = new TextEncoder();
          let ended = false;
          let heartbeat: ReturnType<typeof setInterval>;

          const rawSend: SseSend = (payload) => {
            if (ended) return;
            try {
              controller.enqueue(encoder.encode(`data: ${JSON.stringify(payload)}\n\n`));
            } catch {
              cleanup();
            }
          };

          // 广播入口严格按订阅时期望的会话过滤：用户只是「点开看历史」时，
          // 后端仍在别的会话上跑，delta / state 一条都不该送到这个视图。
          // 真正激活该会话后 sessionId 变成期望值，同一条连接会自然开始收事件。
          const send: SseSend = (payload) => {
            if (
              expectedSession &&
              (payload as { sessionId?: unknown }).sessionId !== expectedSession
            ) {
              return;
            }
            rawSend(payload);
          };

          cleanup = () => {
            if (ended) return;
            ended = true;
            clearInterval(heartbeat);
            listeners.get(agentId)?.delete(send);
            req.signal.removeEventListener("abort", cleanup);
            try {
              controller.close();
            } catch {
              /* 已关闭 */
            }
          };

          const set = listeners.get(agentId) ?? new Set<SseSend>();
          set.add(send);
          listeners.set(agentId, set);
          req.signal.addEventListener("abort", cleanup, { once: true });
          heartbeat = setInterval(() => rawSend({ type: "heartbeat" }), 15_000);

          // 初始快照直发：预览的是历史会话时不推旧会话的全量消息历史。
          const snapshot = agentState(agent);
          if (!expectedSession || expectedSession === snapshot.sessionId) {
            rawSend({ type: "state", state: snapshot });
          }
        },
        cancel() {
          cleanup();
        },
      });

      return new Response(stream, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-store",
          Connection: "keep-alive",
        },
      });
    }

    throw new HttpError(404, "Not found");
  }

  const port = options.port ?? Number(process.env.PORT ?? 4317);
  const hostname = options.hostname ?? "127.0.0.1";

  const server = Bun.serve({
    hostname,
    port,
    idleTimeout: 0,
    async fetch(req) {
      // 只接受本机访问，且只放行本机来源的浏览器调试请求。
      const url = new URL(req.url);
      if (!["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)) {
        return json({ error: "Host not allowed" }, 403);
      }

      const origin = req.headers.get("origin");
      const originAllowed = origin !== null && /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(origin);
      const corsHeaders: Record<string, string> = originAllowed
        ? {
            "Access-Control-Allow-Origin": origin,
            "Access-Control-Allow-Methods": "GET,POST,PATCH,PUT,DELETE,OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
          }
        : {};

      if (req.method === "OPTIONS" && originAllowed) {
        return new Response(null, { status: 204, headers: corsHeaders });
      }

      try {
        const response = await handle(req);
        for (const [key, value] of Object.entries(corsHeaders)) response.headers.set(key, value);
        return response;
      } catch (error) {
        const status = error instanceof HttpError ? error.status : 500;
        const message = error instanceof Error ? error.message : String(error);
        const body = json({ error: message }, status);
        for (const [key, value] of Object.entries(corsHeaders)) body.headers.set(key, value);
        return body;
      }
    },
  });

  return {
    server,
    port,
    async close() {
      for (const id of [...managed.keys()]) await disposeRuntime(id);
      server.stop(true);
    },
  };
}
