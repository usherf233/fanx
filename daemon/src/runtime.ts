import { mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  ModelRuntime,
  SessionManager,
  SettingsManager,
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices,
  type AgentSessionRuntime,
} from "@earendil-works/pi-coding-agent";
import type { AgentRecord } from "./types.ts";

/**
 * 关键隔离点：全部关掉默认发现，只把这个配置目录下的资源放进去。
 * 不关的话，~/.agents/skills、~/.pi/agent/skills、项目 .pi/ 都会混进来，
 * "不同 Agent 互不干扰"就无从谈起。
 */
export function scopedResourceOptions(configDir: string) {
  return {
    noSkills: true,
    additionalSkillPaths: [join(configDir, "skills")],
    noExtensions: true,
    additionalExtensionPaths: [join(configDir, "extensions")],
    noPromptTemplates: true,
    additionalPromptTemplatePaths: [join(configDir, "prompts")],
    noThemes: true,
    // 不设 noContextFiles：让 agentDir/AGENTS.md 作为该 Agent 的长期人格生效。
  };
}

type Services = Awaited<ReturnType<typeof createAgentSessionServices>>;

/** 按 Agent 记录创建一套独立 runtime：独立 agentDir、独立会话目录、独立 cwd。 */
export async function createAgentRuntime(agent: AgentRecord): Promise<AgentSessionRuntime> {
  const configDir = agent.configDir;
  const sessionsDir = join(configDir, "sessions");
  mkdirSync(sessionsDir, { recursive: true });

  // SDK 的 switchSession / newSession 会对同一个 factory 反复调用，默认实现
  // 每次都重跑 createAgentSessionServices —— 也就是重读模型凭据、重建
  // DefaultResourceLoader 并全量重扫 skills / extensions / prompts / AGENTS.md。
  // 这些是 cwd-bound 的只读重资源，跟"换一个会话文件"无关；按 cwd 缓存后，
  // 切会话只重建 AgentSession 本身。资源改动仍由 session.reload() 生效。
  const servicesByCwd = new Map<string, Promise<Services>>();

  return createAgentSessionRuntime(
    async (target) => {
      const cwd = resolve(target.cwd);
      let pending = servicesByCwd.get(cwd);
      if (!pending) {
        pending = (async (): Promise<Services> => {
          const modelRuntime = await ModelRuntime.create({
            authPath: join(configDir, "auth.json"),
            modelsPath: join(configDir, "models.json"),
            modelsStorePath: join(configDir, "models-store.json"),
            allowModelNetwork: false,
          });

          const settingsManager = SettingsManager.create(cwd, configDir, {
            projectTrusted: false,
          });

          return createAgentSessionServices({
            cwd,
            agentDir: configDir,
            settingsManager,
            modelRuntime,
            resourceLoaderOptions: scopedResourceOptions(configDir),
          });
        })().catch((error: unknown) => {
          // 失败不能把 rejected promise 留在缓存里，否则后续切换永远失败。
          servicesByCwd.delete(cwd);
          throw error;
        });
        servicesByCwd.set(cwd, pending);
      }
      const services = await pending;

      const result = await createAgentSessionFromServices({
        services,
        sessionManager: target.sessionManager,
        sessionStartEvent: target.sessionStartEvent,
      });

      return { ...result, services, diagnostics: services.diagnostics };
    },
    {
      cwd: agent.cwd,
      agentDir: configDir,
      sessionManager: SessionManager.create(agent.cwd, sessionsDir),
    },
  );
}

/** 读取该 Agent 当前实际生效的资源概览，用于界面展示"它到底加载了什么"。 */
export function describeEffectiveResources(runtime: AgentSessionRuntime) {
  const loader = runtime.services.resourceLoader;
  const skills = loader.getSkills();
  const prompts = loader.getPrompts();
  const extensions = loader.getExtensions();
  const agentsFiles = loader.getAgentsFiles().agentsFiles;

  return {
    skills: skills.skills.map((skill) => ({ name: skill.name, description: skill.description })),
    prompts: prompts.prompts.map((prompt) => ({ name: prompt.name, description: prompt.description })),
    extensions: extensions.extensions.map((extension) => ({
      path: extension.path,
      commands: [...extension.commands.keys()],
      tools: [...extension.tools.keys()],
    })),
    systemPromptSource: loader.getSystemPromptSource()?.path ?? null,
    agentsFiles: agentsFiles.map((file) => ({ path: file.path, chars: file.content.length })),
    diagnostics: [
      ...skills.diagnostics.map((item) => item.message),
      ...prompts.diagnostics.map((item) => item.message),
    ],
  };
}
