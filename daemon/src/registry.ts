import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { AgentRecord, RegistryFile } from "./types.ts";

/** 管理器自身的家目录，可用 PI_MANAGER_HOME 覆盖，便于测试与多套配置。 */
export const MANAGER_HOME = process.env.PI_MANAGER_HOME ?? join(homedir(), ".pi-manager");
export const REGISTRY_PATH = join(MANAGER_HOME, "registry.json");
export const AGENTS_ROOT = join(MANAGER_HOME, "agents");

function ensureHome(): void {
  mkdirSync(AGENTS_ROOT, { recursive: true });
}

function emptyRegistry(): RegistryFile {
  return { version: 1, agents: [] };
}

export function readRegistry(): RegistryFile {
  ensureHome();
  if (!existsSync(REGISTRY_PATH)) return emptyRegistry();
  try {
    const raw = JSON.parse(readFileSync(REGISTRY_PATH, "utf8")) as Partial<RegistryFile>;
    if (!Array.isArray(raw.agents)) return emptyRegistry();
    return { version: 1, agents: raw.agents.filter(isAgentRecord) };
  } catch {
    // 注册表损坏时不静默清空：留一份备份再重建，避免用户配置被无声抹掉。
    const backup = `${REGISTRY_PATH}.corrupt-${Date.now()}`;
    try {
      renameSync(REGISTRY_PATH, backup);
    } catch {
      /* 备份失败也不阻塞启动 */
    }
    return emptyRegistry();
  }
}

function isAgentRecord(value: unknown): value is AgentRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.id === "string" &&
    typeof record.name === "string" &&
    typeof record.configDir === "string" &&
    typeof record.cwd === "string"
  );
}

export function writeRegistry(registry: RegistryFile): void {
  ensureHome();
  const temp = `${REGISTRY_PATH}.tmp`;
  writeFileSync(temp, `${JSON.stringify(registry, null, 2)}\n`, "utf8");
  renameSync(temp, REGISTRY_PATH);
}

export function listAgents(): AgentRecord[] {
  return readRegistry().agents;
}

export function getAgent(id: string): AgentRecord | undefined {
  return readRegistry().agents.find((agent) => agent.id === id);
}

/**
 * 由名称推导 id：只保留 a-z0-9，其余折成连字符。
 * 刻意不支持中文——id 会同时用作目录名和 URL 路径，ASCII 能省掉一整类编码问题。
 * 中文名称请通过 name 字段表达，创建时也可以直接指定 id。
 */
export function slugify(name: string): string {
  return name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48);
}

export function isValidAgentId(id: string): boolean {
  return /^[a-z0-9][a-z0-9-]{0,47}$/.test(id);
}

export function uniqueAgentId(name: string): string {
  const base = slugify(name) || "agent";
  const taken = new Set(listAgents().map((agent) => agent.id));
  if (!taken.has(base)) return base;
  for (let index = 2; index < 1000; index += 1) {
    const candidate = `${base}-${index}`;
    if (!taken.has(candidate)) return candidate;
  }
  return `${base}-${Date.now().toString(36)}`;
}

export function addAgent(record: AgentRecord): AgentRecord {
  const registry = readRegistry();
  registry.agents.push(record);
  writeRegistry(registry);
  return record;
}

export function updateAgent(id: string, patch: Partial<AgentRecord>): AgentRecord | undefined {
  const registry = readRegistry();
  const index = registry.agents.findIndex((agent) => agent.id === id);
  if (index === -1) return undefined;
  const current = registry.agents[index]!;
  const next: AgentRecord = { ...current, ...patch, id: current.id, updatedAt: new Date().toISOString() };
  registry.agents[index] = next;
  writeRegistry(registry);
  return next;
}

export function removeAgent(id: string): AgentRecord | undefined {
  const registry = readRegistry();
  const index = registry.agents.findIndex((agent) => agent.id === id);
  if (index === -1) return undefined;
  const [removed] = registry.agents.splice(index, 1);
  writeRegistry(registry);
  return removed;
}
