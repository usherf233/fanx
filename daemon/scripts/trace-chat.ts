/**
 * 订阅 SSE 并触发一次对话，把事件流原样打出来，用于定位"消息发出去了但没回复"。
 * 跑法：bun run scripts/trace-chat.ts <agentId> [消息]
 */
const agentId = process.argv[2] ?? "coding";
const message = process.argv[3] ?? "只回复两个字：收到";
const base = process.env.BASE ?? "http://127.0.0.1:4399";

const events = await fetch(`${base}/api/agents/${agentId}/events`);
if (!events.body) throw new Error("无法订阅事件流");
const reader = events.body.getReader();
const decoder = new TextDecoder();
const deadline = Date.now() + 20_000;

void fetch(`${base}/api/agents/${agentId}/chat`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ message }),
});

while (Date.now() < deadline) {
  const { value, done } = await reader.read();
  if (done) break;
  const chunk = decoder.decode(value, { stream: true });
  for (const line of chunk.split("\n")) {
    if (!line.startsWith("data: ")) continue;
    const payload = JSON.parse(line.slice(6)) as Record<string, unknown>;
    const inner = payload.event as Record<string, unknown> | undefined;
    const kind = inner ? `${String(payload.type)}:${String(inner.type)}` : String(payload.type);
    const summary = JSON.stringify(inner ?? payload).slice(0, 240);
    console.log(kind, summary);
  }
  const state = JSON.parse("null") as null;
  void state;
}

console.log("--- 结束 ---");
process.exit(0);
