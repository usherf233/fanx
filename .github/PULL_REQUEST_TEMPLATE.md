## 改了什么

<!-- 一句话说清这个 PR 的目标。 -->

## 为什么

<!-- 关联的 issue：Closes #123 -->

## 自查

- [ ] `cd daemon && bun run typecheck` 通过
- [ ] `flutter analyze` 无新增告警
- [ ] `HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= flutter test` 通过
- [ ] 涉及对话区渲染的改动，已确认流式期间不重建历史消息（见 docs/design-notes.md）
- [ ] 没有提交 `auth.json`、`.devhome/` 或任何本地凭据

## 截图 / 录屏

<!-- 界面改动请附上前后对比。 -->
