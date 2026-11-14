import {
  cpSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  type Dirent,
  writeFileSync,
} from "node:fs";
import { basename, join } from "node:path";
import type {
  ResourceDetail,
  ResourceFileEntry,
  ResourceItem,
  ResourceSnapshot,
  ResourceType,
} from "./types.ts";
import { RESOURCE_DIRS } from "./scaffold.ts";

/** 资源层错误：带上 HTTP 状态，路由层不用再猜是 400 还是 409。 */
export class ResourceError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

/** Agent Skills 规范的名称规则：小写字母/数字/连字符，不允许首尾或连续连字符。 */
const SKILL_NAME_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

/** 单个资源最多统计这么多文件，避免误放进来的巨型目录拖死扫描。 */
const MAX_WALK_FILES = 4000;

/** 只解析 `---` 之间的顶层 key: value，够读 name/description 即可。 */
export function parseFrontmatter(text: string): Record<string, string> {
  if (!text.startsWith("---")) return {};
  const end = text.indexOf("\n---", 3);
  if (end === -1) return {};
  const block = text.slice(3, end);
  const result: Record<string, string> = {};
  for (const rawLine of block.split("\n")) {
    const match = /^([A-Za-z0-9_-]+)\s*:\s*(.*)$/.exec(rawLine.trim());
    if (!match) continue;
    const key = match[1];
    const value = match[2];
    if (!key || value === undefined) continue;
    result[key] = value.replace(/^["']|["']$/g, "").trim();
  }
  return result;
}

function readText(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function safeStat(path: string) {
  try {
    return statSync(path);
  } catch {
    return null;
  }
}

function walk(path: string): { bytes: number; files: number } {
  let bytes = 0;
  let files = 0;

  const visit = (target: string) => {
    if (files >= MAX_WALK_FILES) return;
    let entries: Dirent[];
    try {
      entries = readdirSync(target, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (files >= MAX_WALK_FILES) return;
      const full = join(target, entry.name);
      if (entry.isDirectory()) {
        visit(full);
      } else if (entry.isFile()) {
        files += 1;
        const info = safeStat(full);
        if (info) bytes += info.size;
      }
    }
  };

  visit(path);
  return { bytes, files };
}

/** 技能的问题清单：这些是 pi 真的会警告或直接不加载的情况，不是审美意见。 */
function skillIssues(declaredName: string | undefined, description: string): string[] {
  const issues: string[] = [];
  if (!declaredName) {
    issues.push("SKILL.md 缺少 name");
  } else if (declaredName.length > 64 || !SKILL_NAME_RE.test(declaredName)) {
    issues.push("name 不符合规范：只能小写字母/数字/连字符");
  }
  if (!description) {
    issues.push("缺少 description，pi 不会加载这个技能");
  } else if (description.length > 1024) {
    issues.push("description 超过 1024 字符");
  }
  return issues;
}

function scanSkills(baseDir: string, enabled: boolean): ResourceItem[] {
  if (!existsSync(baseDir)) return [];
  const items: ResourceItem[] = [];

  for (const entry of readdirSync(baseDir)) {
    const fullPath = join(baseDir, entry);
    const info = safeStat(fullPath);
    if (!info) continue;

    if (info.isDirectory()) {
      const skillFile = join(fullPath, "SKILL.md");
      if (!existsSync(skillFile)) continue;
      const meta = parseFrontmatter(readText(skillFile));
      const stats = walk(fullPath);
      const description = meta.description ?? "";
      items.push({
        name: entry,
        entry,
        description,
        declaredName: meta.name,
        path: fullPath,
        relPath: `${enabled ? "skills" : "skills.disabled"}/${entry}`,
        kind: "skill",
        enabled,
        bytes: stats.bytes,
        files: stats.files,
        modified: info.mtime.toISOString(),
        issues: skillIssues(meta.name, description),
      });
      continue;
    }

    // 根级散装 .md 也可能是技能，但必须带合法 frontmatter。
    if (entry.endsWith(".md")) {
      const meta = parseFrontmatter(readText(fullPath));
      if (!meta.description) continue;
      items.push({
        name: entry.replace(/\.md$/, ""),
        entry,
        description: meta.description,
        declaredName: meta.name,
        path: fullPath,
        relPath: `${enabled ? "skills" : "skills.disabled"}/${entry}`,
        kind: "skill",
        enabled,
        bytes: info.size,
        files: 1,
        modified: info.mtime.toISOString(),
        issues: skillIssues(meta.name, meta.description),
      });
    }
  }
  return items;
}

function scanFiles(
  baseDir: string,
  enabled: boolean,
  kind: ResourceType,
  extensions: string[],
): ResourceItem[] {
  if (!existsSync(baseDir)) return [];
  const items: ResourceItem[] = [];
  for (const entry of readdirSync(baseDir)) {
    if (!extensions.some((ext) => entry.endsWith(ext))) continue;
    const fullPath = join(baseDir, entry);
    const info = safeStat(fullPath);
    if (!info || !info.isFile()) continue;
    items.push({
      name: entry.replace(/\.[^.]+$/, ""),
      entry,
      description: entry,
      path: fullPath,
      relPath: `${enabled ? kind : `${kind}.disabled`}/${entry}`,
      kind: kind === "extensions" ? "extension" : "prompt",
      enabled,
      bytes: info.size,
      files: 1,
      modified: info.mtime.toISOString(),
      issues: [],
    });
  }
  return items;
}

function scanPrompts(baseDir: string, enabled: boolean): ResourceItem[] {
  return scanFiles(baseDir, enabled, "prompts", [".md"]).map((item) => {
    const meta = parseFrontmatter(readText(item.path));
    return {
      ...item,
      description: meta.description ?? "",
      declaredName: meta.name,
    };
  });
}

function sortItems(items: ResourceItem[]): ResourceItem[] {
  return items.sort((a, b) => {
    if (a.enabled !== b.enabled) return a.enabled ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
}

/** 扫描一个配置目录下的全部资源，含已禁用的。 */
export function scanResources(configDir: string): ResourceSnapshot {
  return {
    skills: sortItems([
      ...scanSkills(join(configDir, "skills"), true),
      ...scanSkills(join(configDir, "skills.disabled"), false),
    ]),
    extensions: sortItems([
      ...scanFiles(join(configDir, "extensions"), true, "extensions", [".ts", ".js", ".mts", ".mjs"]),
      ...scanFiles(join(configDir, "extensions.disabled"), false, "extensions", [
        ".ts",
        ".js",
        ".mts",
        ".mjs",
      ]),
    ]),
    prompts: sortItems([
      ...scanPrompts(join(configDir, "prompts"), true),
      ...scanPrompts(join(configDir, "prompts.disabled"), false),
    ]),
  };
}

function isResourceType(value: string): value is ResourceType {
  return (RESOURCE_DIRS as readonly string[]).includes(value);
}

function assertType(type: string): ResourceType {
  if (!isResourceType(type)) throw new ResourceError(400, `未知资源类型：${type}`);
  return type;
}

/** 名称里出现路径分隔符或 .. 一律拒绝：所有操作都限制在该 Agent 目录内。 */
function assertSafeSegment(value: string, label = "资源名"): void {
  if (!value || value === "." || value === ".." || /[/\\]/.test(value)) {
    throw new ResourceError(400, `非法的${label}`);
  }
}

/** 按显示名找到磁盘上的真实条目名（扩展/模板的 name 去掉了扩展名）。 */
function findItem(configDir: string, type: ResourceType, name: string): ResourceItem | undefined {
  const snapshot = scanResources(configDir);
  return snapshot[type].find((item) => item.name === name || item.entry === name);
}

/**
 * 启停一个资源：在 `<type>/` 与 `<type>.disabled/` 之间移动。
 * 文件级开关的好处是外部工具（pi CLI）看到的世界和本管理器一致。
 */
export function toggleResource(
  configDir: string,
  type: string,
  name: string,
  enabled: boolean,
): { path: string } {
  const kind = assertType(type);
  assertSafeSegment(name);

  // 显示名与磁盘名可能不同（extensions 的 name 没有 .ts），以扫描结果为准。
  const item = findItem(configDir, kind, name);
  if (!item) throw new ResourceError(404, `资源不存在：${name}`);
  if (item.enabled === enabled) return { path: item.path };

  const activeDir = join(configDir, kind);
  const disabledDir = join(configDir, `${kind}.disabled`);
  const from = join(enabled ? disabledDir : activeDir, item.entry);
  const to = join(enabled ? activeDir : disabledDir, item.entry);

  if (!existsSync(from)) throw new ResourceError(409, "资源状态已变更，请刷新后重试");
  if (existsSync(to)) throw new ResourceError(409, `目标位置已存在同名资源：${item.entry}`);

  renameSync(from, to);
  return { path: to };
}

/** 批量启停：逐条处理，单条失败不影响其它条目。 */
export function toggleMany(
  configDir: string,
  type: string,
  names: string[],
  enabled: boolean,
): { ok: string[]; failed: { name: string; error: string }[] } {
  const ok: string[] = [];
  const failed: { name: string; error: string }[] = [];
  for (const name of names) {
    try {
      toggleResource(configDir, type, name, enabled);
      ok.push(name);
    } catch (error) {
      failed.push({ name, error: error instanceof Error ? error.message : String(error) });
    }
  }
  return { ok, failed };
}

function listEntries(root: string, isFile: boolean): ResourceFileEntry[] {
  if (isFile) {
    const info = safeStat(root);
    return info ? [{ path: basename(root), bytes: info.size, dir: false }] : [];
  }

  const result: ResourceFileEntry[] = [];
  const visit = (dir: string, prefix: string) => {
    if (result.length >= 200) return;
    let entries: Dirent[];
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    entries.sort((a, b) => {
      if (a.isDirectory() !== b.isDirectory()) return a.isDirectory() ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    for (const entry of entries) {
      if (result.length >= 200) return;
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        result.push({ path: rel, bytes: 0, dir: true });
        visit(full, rel);
      } else if (entry.isFile()) {
        const info = safeStat(full);
        result.push({ path: rel, bytes: info?.size ?? 0, dir: false });
      }
    }
  };

  visit(root, "");
  return result;
}

/** 扩展注册了哪些工具/命令：静态扫一遍源码，运行中的精确结果另外由 effective 提供。 */
function scanRegistrations(source: string): { tools: string[]; commands: string[] } {
  const pick = (pattern: RegExp) => {
    const found = new Set<string>();
    for (const match of source.matchAll(pattern)) {
      if (match[1]) found.add(match[1]);
    }
    return [...found].slice(0, 24);
  };
  return {
    tools: pick(/registerTool\s*\(\s*["'`]([\w.-]+)["'`]/g),
    commands: pick(/registerCommand\s*\(\s*["'`]([\w.:-]+)["'`]/g),
  };
}

/** 单个资源的完整内容，用于右侧检视面板。 */
export function getResourceDetail(
  configDir: string,
  type: string,
  name: string,
): ResourceDetail {
  const kind = assertType(type);
  assertSafeSegment(name);

  const item = findItem(configDir, kind, name);
  if (!item) throw new ResourceError(404, `资源不存在：${name}`);

  const info = safeStat(item.path);
  const isDir = info?.isDirectory() ?? false;
  const entryFile = item.kind === "skill" && isDir ? join(item.path, "SKILL.md") : item.path;
  const raw = readText(entryFile);
  const content = raw.length > 200_000 ? `${raw.slice(0, 200_000)}\n\n…（已截断）` : raw;
  const frontmatter = item.kind === "extension" ? {} : parseFrontmatter(raw);

  const registration = item.kind === "extension" ? scanRegistrations(raw) : { tools: [], commands: [] };

  return {
    ...item,
    entryFile: isDir ? basename(entryFile) : basename(item.path),
    content,
    frontmatter,
    tools: registration.tools,
    commands: registration.commands,
    entries: listEntries(item.path, !isDir),
  };
}

const SKILL_TEMPLATE = (name: string, description: string) => `---
name: ${name}
description: ${description}
---

# ${name}

## 何时使用

（写清楚触发场景。description 决定模型是否加载这个技能，越具体越好。）

## 步骤

1. 
2. 

## 参考

- 把补充资料放进 references/，按需引用：见 [references/notes.md](references/notes.md)
`;

/** 新建技能骨架：只写 SKILL.md，其余目录由用户按需补。 */
export function createSkill(
  configDir: string,
  name: string,
  description: string,
): { path: string } {
  const trimmed = name.trim();
  if (trimmed.length > 64 || !SKILL_NAME_RE.test(trimmed)) {
    throw new ResourceError(400, "名称只能用小写字母、数字和连字符，不能首尾或连续连字符");
  }
  const desc = description.trim() || `TODO：说明 ${trimmed} 做什么、什么时候用。`;
  if (desc.length > 1024) throw new ResourceError(400, "description 不能超过 1024 字符");

  const target = join(configDir, "skills", trimmed);
  if (existsSync(target) || existsSync(join(configDir, "skills.disabled", trimmed))) {
    throw new ResourceError(409, `已存在同名技能：${trimmed}`);
  }

  mkdirSync(target, { recursive: true });
  mkdirSync(join(target, "references"), { recursive: true });
  mkdirSync(join(target, "scripts"), { recursive: true });
  writeFileSync(join(target, "SKILL.md"), SKILL_TEMPLATE(trimmed, desc), "utf8");
  return { path: target };
}

/** 从一个本地路径导入资源：目录（技能）或文件（扩展/模板/单文件技能）。 */
export function importResource(
  configDir: string,
  type: string,
  source: string,
  options: { name?: string; overwrite?: boolean } = {},
): { name: string; path: string } {
  const kind = assertType(type);
  const src = source.trim();
  if (!src) throw new ResourceError(400, "来源路径不能为空");
  if (!existsSync(src)) throw new ResourceError(400, `来源不存在：${src}`);

  const info = safeStat(src);
  if (!info) throw new ResourceError(400, `无法读取来源：${src}`);

  const isDir = info.isDirectory();
  const sourceBase = basename(src);
  const rawName = options.name?.trim() || sourceBase.replace(/\.[^.]+$/, "");

  if (kind === "skills") {
    if (isDir) {
      if (!existsSync(join(src, "SKILL.md"))) {
        throw new ResourceError(400, "技能目录里没有 SKILL.md");
      }
      assertSafeSegment(rawName, "技能名");
      const target = join(configDir, "skills", rawName);
      assertImportTarget(target, options.overwrite);
      cpSync(src, target, { recursive: true, force: true });
      return { name: rawName, path: target };
    }

    if (!src.endsWith(".md")) throw new ResourceError(400, "技能只能是目录（含 SKILL.md）或 .md 文件");
    const meta = parseFrontmatter(readText(src));
    if (!meta.description) throw new ResourceError(400, "这个 Markdown 没有 description，不是合法技能");
    assertSafeSegment(rawName, "技能名");
    const target = join(configDir, "skills", `${rawName}.md`);
    assertImportTarget(target, options.overwrite);
    cpSync(src, target, { force: true });
    return { name: rawName, path: target };
  }

  if (isDir) throw new ResourceError(400, "扩展与提示词模板只能导入单个文件");
  if (kind === "extensions" && !/\.(ts|js|mts|mjs)$/.test(sourceBase)) {
    throw new ResourceError(400, "扩展必须是 .ts / .js / .mts / .mjs 文件");
  }
  if (kind === "prompts" && !sourceBase.endsWith(".md")) {
    throw new ResourceError(400, "提示词模板必须是 .md 文件");
  }

  const fileName = options.name?.trim()
    ? `${options.name.trim().replace(/\.[^.]+$/, "")}${sourceBase.slice(sourceBase.lastIndexOf("."))}`
    : sourceBase;
  assertSafeSegment(fileName, "文件名");
  const target = join(configDir, kind, fileName);
  assertImportTarget(target, options.overwrite);
  cpSync(src, target, { force: true });
  return { name: fileName.replace(/\.[^.]+$/, ""), path: target };
}

function assertImportTarget(target: string, overwrite = false): void {
  if (!existsSync(target)) return;
  if (!overwrite) throw new ResourceError(409, `目标已存在：${basename(target)}（勾选覆盖才会替换）`);
  rmSync(target, { recursive: true, force: true });
}

/** 删除资源。删的是磁盘上的真东西，调用方必须先确认。 */
export function deleteResource(configDir: string, type: string, name: string): { removed: string } {
  const kind = assertType(type);
  assertSafeSegment(name);
  const item = findItem(configDir, kind, name);
  if (!item) throw new ResourceError(404, `资源不存在：${name}`);
  rmSync(item.path, { recursive: true, force: true });
  return { removed: item.entry };
}

/**
 * 把一个资源从某个 Agent 复制到另一个 Agent。
 * 只复制、不移动：源 Agent 的状态不受影响，目标已存在同名则拒绝。
 */
export function copyResourceBetween(
  sourceConfigDir: string,
  targetConfigDir: string,
  type: string,
  name: string,
): { path: string } {
  const kind = assertType(type);
  assertSafeSegment(name);

  const item = findItem(sourceConfigDir, kind, name);
  if (!item) throw new ResourceError(404, `源 Agent 没有这个资源：${name}`);

  const targetDir = join(targetConfigDir, kind);
  mkdirSync(targetDir, { recursive: true });
  const target = join(targetDir, item.entry);
  if (existsSync(target) || existsSync(join(targetConfigDir, `${kind}.disabled`, item.entry))) {
    throw new ResourceError(409, "目标 Agent 已有同名资源");
  }

  cpSync(item.path, target, { recursive: true, force: false });
  return { path: target };
}

/** 资源计数，列表页要显示。 */
export function countEnabled(snapshot: ResourceSnapshot): {
  skills: number;
  extensions: number;
  prompts: number;
} {
  return {
    skills: snapshot.skills.filter((item) => item.enabled).length,
    extensions: snapshot.extensions.filter((item) => item.enabled).length,
    prompts: snapshot.prompts.filter((item) => item.enabled).length,
  };
}
