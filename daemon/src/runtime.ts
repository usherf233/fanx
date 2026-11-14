import { mkdirSync } from "node:fs";
import { join } from "node:path";
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

/** 按 Agent 记录创建一套独立 runtime：独立 agentDir、独立会话目录、独立 cwd。 */
export async function createAgentRuntime(agent: AgentRecord): Promise<AgentSessionRuntime> {
  const configDir = agent.configDir;
  const sessionsDir = join(configDir, "sessions");
  mkdirSync(sessionsDir, { recursive: true });

  return createAgentSessionRuntime(
    async (target) => {
      const modelRuntime = await ModelRuntime.create({
        authPath: join(configDir, "auth.json"),
        modelsPath: join(configDir, "models.json"),
        modelsStorePath: join(configDir, "models-store.json"),
        allowModelNetwork: false,
      });

      const settingsManager = SettingsManager.create(target.cwd, configDir, {
        projectTrusted: false,
      });

      const services = await createAgentSessionServices({
        cwd: target.cwd,
        agentDir: configDir,
        settingsManager,
        modelRuntime,
        resourceLoaderOptions: scopedResourceOptions(configDir),
      });

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
