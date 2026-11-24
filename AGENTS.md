# AGENTS.md — 微信桥（WeChat Menu Bridge）项目研发规范与记忆

本文件为所有参与本仓库开发、测试与发布的协作者和 AI 智能体的长期规范，务必严格遵守。

## 1. 仓库与分支模型
- **唯一代码主干在 GitHub**：`https://github.com/kts-kris/wechat-menu-bridge` 的 `main` 分支是唯一权威主干。
- **严禁直接在 `main` 上提交开发代码**：所有功能开发、缺陷修复与文档调整都必须在本地创建独立开发/测试分支（如 `dev/<topic>`、`fix/issue-<n>`）。
- **合并流程**：
  1. 本地分支开发并补齐对应单测/回归测试；
  2. 本地跑通全量验证（`scripts/selftest.sh`）；
  3. 完成本机 UAT 真机验收（需要真实微信消息验证的场景，经授权后可使用「马首是瞻」测试群验证）；
  4. 确认无任何本地私有文件、密钥或硬编码调试路径后，推送分支并在 GitHub 合并回 `main`（推荐 PR 或经审查的 fast-forward / squash merge）。

## 2. Issue 闭环规范
- 所有遗留问题、缺陷与规划需求统一沉淀到 [GitHub Issues](https://github.com/kts-kris/wechat-menu-bridge/issues)，并使用对应标签（`bug/ui`、`bug/updater`、`bug/llm`、`bug/mcp`、`area/qa`、`v2.1.x`、`v2.2.0`、`v2.3.0`）。
- 提交信息或 PR 描述中使用 `Fixes #<编号>` 关联对应 Issue。
- **完成并验证通过后必须关闭对应 Issue**，并在关闭评论中附上验证方式与结果（单测通过数、UAT 结论、合入提交哈希）。

## 3. 版本打包与发布规则（并非每个 Issue 关闭都打包）
日常开发合入 `main` 与正式打版发布解耦，按以下规则触发打包：
- **不需要发版打包**：纯文档更新（如 `README.md`、`AGENTS.md`）、Issue 模板/脚本维护、内部重构、测试补充、或尚未达到发布窗口的零散小改进——完成 UAT 并合入 `main`、关闭对应 Issue 即可。
- **触发打版发布**（同步递增 `App/Info.plist` 版本号与构建号 → `bash scripts/selftest.sh` → `bash scripts/release-feed.sh` 生成 Ed25519 签名 `appcast.json`/`appcast.xml` → 打 Git Tag 并发布 GitHub Release）：
  1. 修复影响日常使用的关键缺陷（Patch 版本，如 `v2.1.1`）；
  2. 达成阶段性功能里程碑（Minor 版本，如 `v2.2.0`）；
  3. 项目负责人明确指令发布新版本。

## 4. 不可妥协的安全底线
1. **绝不自动重发 `send-unknown`**：微信发信返回未知状态时永久锁定该会话，必须人工在微信核对后手动解除。
2. **绝不违背 `peer-stopped` 退订锁**：对方叫停后跨重启持久化锁定，绝不绕过。
3. **历史补扫绝不触发发信**：`origin === 'backfill'` 的事件仅用于上下文、只读插件与记忆整理。
4. **绝不削弱 `Engine/test/faults.test.ts`**：保持核心故障对抗测试完整有效。
5. **凭据隔离**：API Key 与令牌仅存本机 `0600` 私有文件（`secrets.json`）或隔离测试钥匙串，绝不写入 `settings.json`、`engine.log`、诊断报告或任何 Git 跟踪文件。
