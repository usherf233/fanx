# 已知限制

1. **环境变量里的 API Key 对所有 Agent 共享**。pi 会读 `DEEPSEEK_API_KEY` 之类的环境变量，
   所以 `auth.json` 为空也能用。要给某个 Agent 独立凭据，写它自己的 `models.json`（界面「模型」页会做）。
2. **单进程多 runtime**。所有 Agent 跑在同一个 daemon 进程里，靠 `agentDir` 隔离。
   某个扩展崩溃可能波及整个 daemon，要进程级隔离得再拆 worker。
3. **没有认证**。服务只绑 `127.0.0.1` 并校验 Host / Origin，不适合暴露到网络。
4. **pi 调用失败不抛异常**：它照常结束这一轮，把原因写进 assistant 消息的
   `stopReason: "error"` 与 `errorMessage`（例如 `502 upstream connect failed (os error 10061)`）。
   后端现在原样透传这两项，界面把原始报错、provider/model、耗时摊在失败卡片里，并给一句
   可行动的诊断（端点拒绝连接 / 鉴权失败 / 超时 / 限流…），失败的那条消息可一键重试。
   只剩一种情况仍属推测：`stopReason` 正常但正文为空，界面会标明"模型返回了空内容"。

## 下一步

- [ ] daemon 拆分 worker，做进程级隔离
- [ ] 会话搜索与全文过滤
- [ ] 技能安装器：从 Git 仓库 / npm 直接拉取到指定 Agent
- [ ] macOS / Linux 平台回归
