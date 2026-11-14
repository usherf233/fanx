// 本机回环一律不经 HTTP_PROXY：沙箱/系统代理会把 localhost 请求拦成 404，
// 或把 SSE 流缓冲掉——模型的 token 增量就全没了。
{
  const loopback = ["127.0.0.1", "localhost", "::1", "[::1]"];
  const existing = (process.env.NO_PROXY ?? process.env.no_proxy ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  for (const host of loopback) {
    if (!existing.includes(host)) existing.push(host);
  }
  const merged = existing.join(",");
  process.env.NO_PROXY = merged;
  process.env.no_proxy = merged;
}

import { startServer } from "./src/server.ts";
import { AGENTS_ROOT, MANAGER_HOME } from "./src/registry.ts";

const port = Number(process.env.PORT ?? 4317);
const running = await startServer({ port });

console.log(`[pi-agent-manager] listening on http://127.0.0.1:${running.port}`);
console.log(`[pi-agent-manager] manager home: ${MANAGER_HOME}`);
console.log(`[pi-agent-manager] agents root:  ${AGENTS_ROOT}`);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void running.close().finally(() => process.exit(0));
  });
}
