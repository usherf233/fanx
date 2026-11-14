/**
 * 隔离验证：两个 Agent 各自建配置目录、各自放技能，确认互相看不到对方的资源。
 * 跑法：bun run scripts/poc-isolation.ts
 */
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentRuntime, describeEffectiveResources } from "../src/runtime.ts";
import { scaffoldAgentDir } from "../src/scaffold.ts";
import type { AgentRecord } from "../src/types.ts";

const root = mkdtempSync(join(tmpdir(), "pi-manager-poc-"));

function makeAgent(id: string, skillName: string, prompt: string): AgentRecord {
  const configDir = join(root, id, "config");
  const cwd = join(root, id, "work");
  mkdirSync(cwd, { recursive: true });
  scaffoldAgentDir({ configDir, name: id, systemPrompt: prompt });

  const skillDir = join(configDir, "skills", skillName);
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(
    join(skillDir, "SKILL.md"),
    `---\nname: ${skillName}\ndescription: ${id} 专属技能，用于验证隔离\n---\n\n# ${skillName}\n`,
    "utf8",
  );

  writeFileSync(
    join(configDir, "prompts", `${id}-template.md`),
    `---\nname: ${id}-template\ndescription: ${id} 专属提示词\n---\n\n模板正文\n`,
    "utf8",
  );

  const now = new Date().toISOString();
  return { id, name: id, description: "", configDir, cwd, createdAt: now, updatedAt: now };
}

const coding = makeAgent("coding", "code-review", "# 编码 Agent\n\n只做代码相关的事。");
const office = makeAgent("office", "slide-maker", "# 办公 Agent\n\n只做文档与演示。");

const codingRuntime = await createAgentRuntime(coding);
const officeRuntime = await createAgentRuntime(office);

const codingView = describeEffectiveResources(codingRuntime);
const officeView = describeEffectiveResources(officeRuntime);

console.log("=== coding ===");
console.log(JSON.stringify(codingView, null, 2));
console.log("=== office ===");
console.log(JSON.stringify(officeView, null, 2));

const codingSkillNames = codingView.skills.map((skill) => skill.name);
const officeSkillNames = officeView.skills.map((skill) => skill.name);

const checks: Array<[string, boolean]> = [
  ["coding 只加载自己的技能", codingSkillNames.length === 1 && codingSkillNames[0] === "code-review"],
  ["office 只加载自己的技能", officeSkillNames.length === 1 && officeSkillNames[0] === "slide-maker"],
  ["两侧技能无交集", !codingSkillNames.some((name) => officeSkillNames.includes(name))],
  ["coding 提示词独立", codingView.prompts.length === 1 && codingView.prompts[0]?.name === "coding-template"],
  ["office 提示词独立", officeView.prompts.length === 1 && officeView.prompts[0]?.name === "office-template"],
  ["AGENTS.md 被作为上下文加载", codingView.agentsFiles.some((file) => file.path.endsWith("AGENTS.md"))],
];

let failed = 0;
for (const [label, ok] of checks) {
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}`);
  if (!ok) failed += 1;
}

await codingRuntime.dispose();
await officeRuntime.dispose();

console.log(failed === 0 ? "\n全部通过：隔离成立" : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
