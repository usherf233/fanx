/** 一个被管理的 Agent 实例。一条记录对应一个完全独立的配置目录。 */
export interface AgentRecord {
  /** 稳定标识，同时用作目录名与 API 路径参数 */
  id: string;
  name: string;
  description: string;
  /** pi 的 agentDir：auth/models/settings/skills/extensions/prompts/sessions 全在这里 */
  configDir: string;
  /** 该 Agent 的工作目录，决定项目上下文、文件工具的作用范围 */
  cwd: string;
  createdAt: string;
  updatedAt: string;
}

export interface AgentSummary extends AgentRecord {
  running: boolean;
  skills: number;
  extensions: number;
  prompts: number;
}

export interface RegistryFile {
  version: 1;
  agents: AgentRecord[];
}

export type ResourceType = "skills" | "extensions" | "prompts";

/** 资源条目：技能是一目录，扩展是单文件，提示词是单 md。 */
export interface ResourceItem {
  /** 展示名：技能=目录名，扩展/模板=去掉扩展名的文件名 */
  name: string;
  /** 磁盘上的真实名字（含扩展名），启停/删除都以它为准 */
  entry: string;
  description: string;
  /** 绝对路径 */
  path: string;
  /** 相对配置目录的路径，例如 skills/pdf-tools */
  relPath: string;
  kind: "skill" | "extension" | "prompt";
  enabled: boolean;
  /** 仅技能有：SKILL.md 里声明的 name 可能与目录名不同 */
  declaredName?: string;
  bytes: number;
  files: number;
  /** ISO 时间 */
  modified: string;
  /** 会导致 pi 警告或直接不加载的问题 */
  issues: string[];
}

/** 检视面板要的文件树条目。 */
export interface ResourceFileEntry {
  path: string;
  bytes: number;
  dir: boolean;
}

/** 单个资源的完整内容。 */
export interface ResourceDetail extends ResourceItem {
  /** 入口文件名：技能是 SKILL.md，其余是自身 */
  entryFile: string;
  content: string;
  frontmatter: Record<string, string>;
  /** 仅扩展：静态扫到的 registerTool / registerCommand */
  tools: string[];
  commands: string[];
  entries: ResourceFileEntry[];
}

export interface ResourceSnapshot {
  skills: ResourceItem[];
  extensions: ResourceItem[];
  prompts: ResourceItem[];
}

export interface CreateAgentInput {
  name: string;
  description?: string;
  /** 不传则落在 ~/.pi-manager/agents/<id> */
  configDir?: string;
  /** 不传则等于 configDir */
  cwd?: string;
  systemPrompt?: string;
  /** 从已有 Agent 复制资源与设置 */
  cloneFrom?: string;
}
