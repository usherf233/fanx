import { cpSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** 可被"启用/禁用"的资源目录，禁用态落到同名 `.disabled` 目录。 */
export const RESOURCE_DIRS = ["skills", "extensions", "prompts"] as const;

/** pi 会读取的运行期目录，缺一个都会在首次启动时产生噪音。 */
const RUNTIME_DIRS = ["sessions", "uploads", "bin"] as const;

/** 未指定工作目录时，Agent 在这个子目录里活动，避免把自己的配置目录当成项目。 */
export const DEFAULT_WORKSPACE = "workspace";

export const DEFAULT_SETTINGS = {
  compaction: { enabled: true, reserveTokens: 16384, keepRecentTokens: 20000 },
  retry: { enabled: true, maxRetries: 2 },
};

export const DEFAULT_SYSTEM_PROMPT = `# 角色

你是一个专注、务实的助手。回答直接给结论，必要时再补充依据。

## 约定

- 先确认事实，再下判断，不确定就说不确定。
- 涉及文件操作时，先读再改，不做超出要求的改动。
`;

export interface ScaffoldOptions {
  configDir: string;
  name: string;
  systemPrompt?: string;
  /** 复制该 Agent 的配置目录作为起点（不复制会话与凭据） */
  cloneFrom?: string;
}

/**
 * 初始化一个 Agent 的配置目录。
 * 已存在的文件不覆盖——重复调用是安全的，可用来补齐缺失目录。
 */
export function scaffoldAgentDir(options: ScaffoldOptions): void {
  const { configDir, cloneFrom } = options;
  mkdirSync(configDir, { recursive: true });

  for (const dir of [...RESOURCE_DIRS, ...RUNTIME_DIRS]) {
    mkdirSync(join(configDir, dir), { recursive: true });
  }
  for (const dir of RESOURCE_DIRS) {
    mkdirSync(join(configDir, `${dir}.disabled`), { recursive: true });
  }
  mkdirSync(join(configDir, DEFAULT_WORKSPACE), { recursive: true });

  if (cloneFrom && existsSync(cloneFrom)) {
    for (const dir of RESOURCE_DIRS) {
      cpSync(join(cloneFrom, dir), join(configDir, dir), { recursive: true, force: true });
      const disabledSource = join(cloneFrom, `${dir}.disabled`);
      if (existsSync(disabledSource)) {
        cpSync(disabledSource, join(configDir, `${dir}.disabled`), { recursive: true, force: true });
      }
    }
    cpSync(join(cloneFrom, "settings.json"), join(configDir, "settings.json"), { force: true });
    cpSync(join(cloneFrom, "models.json"), join(configDir, "models.json"), { force: true });
  }

  writeIfAbsent(join(configDir, "auth.json"), "{}\n");
  writeIfAbsent(join(configDir, "models.json"), `${JSON.stringify({ providers: {} }, null, 2)}\n`);
  writeIfAbsent(join(configDir, "models-store.json"), "{}\n");
  writeIfAbsent(join(configDir, "settings.json"), `${JSON.stringify(DEFAULT_SETTINGS, null, 2)}\n`);

  // AGENTS.md 是 pi 的全局上下文文件：人格与长期约定写这里。
  const prompt = options.systemPrompt?.trim();
  if (prompt) {
    writeFileSync(join(configDir, "AGENTS.md"), `${prompt}\n`, "utf8");
  } else {
    writeIfAbsent(join(configDir, "AGENTS.md"), DEFAULT_SYSTEM_PROMPT);
  }
}

function writeIfAbsent(path: string, content: string): void {
  if (existsSync(path)) return;
  writeFileSync(path, content, "utf8");
}
