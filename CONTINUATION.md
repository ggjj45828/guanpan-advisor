# CONTINUATION.md — 观盘 AI 私人投资顾问（双端：iOS + NAS）

> 本文件依《完整开发、重构、测试与验收总要求》#114/#115 写入：若执行轮次必须结束，把完整状态写于此，下一轮从此续做。
> 写入时间：2026-10-24（GMT+8）｜仓库根：`guanpan_next/`｜当前 HEAD：`af56b7c`
> 详细逐项矩阵见 `GuanpanNext/MASTER-ACCEPTANCE-MATRIX.md`（HEAD af56b7c，78✅/0🟡/3🟠/0❌）。

---

## 1. 验收口径（最高标准）

- 正文 **113 条** + 末尾 **#114/#115** 两条「轮次必须结束须写 CONTINUATION.md」补充条款 = 用户所称「115 条」。
- 工作红线（不可逾越）：
  1. 只有一个真实账户，无模拟/虚拟/孪生账户（A1）。
  2. AI 只指导、**绝不自动下单**（A2/A3，成交必须用户确认）。
  3. NAS = 后台研究员，**非第二顾问**；手机在线 AI 是**唯一最终指导**（A4/A5/H5）。
  4. 数据不足**不出伪精确价格**（E3/H3，LLM 不造价格/统计/新闻）。

## 2. 本轮已完成的审计与修正（2026-10-24）

1. **矩阵诚实自纠（§105/§108）**：原 L1/B1 把风险校验写成独立符号 `NextRiskGate`。本轮 `grep NextRiskGate` 全树**零命中**——证实风险校验是**分布式内联**（新鲜度 `NextDataConfidence.assess` / 规则·手续费·单位 `InstrumentRules` / 流动性 `NextOrderBookEvidence.assess` / 可卖 `book.availableUnits` / 现金 `NextAppModel` 拦截），LLM 仅接收已校验结论，§86 解耦成立。已据实更正，杜绝过度宣称。
2. **主题严格审计（回应「其他主题也要严格做」）**：J1–J8 五套主题经源码钉死——
   - `AppThemeCore.swift`：单一真相源（5 `AppTheme` + `ThemeManager.resolve` + `forcesDark` + 场景→主题映射 `ThemeScene.recommendedTheme`）。
   - `ThemeHome.swift`：五套互异首页结构体 `EditorialHome:900` / `ModernHome:1026` / `DashboardHome:1150` / `MagazineHome:1312` / `PuzzleHome:1432`，按主题分发（123–127 行）。
   - J6 硬编码渐变（`Color(hex:)` 16 处）已清零，hero 令牌化。
   - 五主题对照视觉：`/c/Users/Administrator/WorkBuddy/2026-10-15-21-10-40/guanpan-themes-5-comparison.svg`（配色取自 `previewHexes`，骨架取自 ThemeHome 五结构体）。
3. **CI 绿确认**：`grwzxq` 监控 eef86d7/af56b7c 推送后连续 18 次轮询 `ci-logs-build` **无新 failure 目录**，且 `ci-logs-sim` 分支未生成＝screenshots job 通过。M3（构建）/ M6（五主题截图）自 🟡 翻 ✅。
4. **矩阵回写三提交**：a3f22cc（端口 8789→8786 全树）、eef86d7（CI 第 5 处编译错 scan() 实参顺序）、af56b7c（退役旧 30001 服务）。

## 3. 当前状态汇总

| 状态 | 数量 | 项 |
|---|---|---|
| ✅ Verified | 78 | 含 M3/M6 本轮翻绿 |
| 🟡 Implemented/Not Verified | 0 | — |
| 🟠 Partial | 3 | B1（端到端实机链）、D4（DataQuality 0–100 总分 UI）、J7（组件命名归拢） |
| ❌ Missing | 0 | — |
| ⚠️ 外部验证必需 | 6 | K5 真机推送 / D1 实机多源 / G3 部分成交 / NAS 真实部署 / J8 极端字号 / B1 端到端链 |

## 4. Partial / Missing 明细与处置

- **B1（端到端实机链）🟠**：源码链路各节点真实存在且相连（已逐节点核对，见矩阵 B1 行）。剩余仅是「真机/NAS 实跑验证」——**环境约束，无法在本轮完成**，留 ⚠️。
- **D4（DataQuality 0–100 总分 UI）🟠**：`NextDataConfidence`（`NextAIGuide.swift:7`）有 `.assess()` + `.Level` 置信度体系，但无 0–100 聚合总分 UI。属可选增强。
  - *建议实现*：在 `AIGuidanceViews.swift` 或首页加一个 `NextDataConfidence`→0–100 分数的 `GPScoreRing`/条；分数可由 `quoteAgeSeconds`/`quoteSource`/`dailyBarCount`/`minuteSampleCount` 加权。需 Mac 编译验证，**不可在 Windows 环境盲目改 Swift 以免破坏当前绿 CI**。
- **J7（组件命名归拢）🟠**：组件以 `GP*` 前缀实现（`GPCard`/`GPStatTile`/`CandidatePlanRow`…），功能齐但命名未完全统一。可选整理，风险同上。

## 5. 环境约束（决定「本轮回什么、留什么」）

- 当前环境 **Windows + 无 Mac**：无法 `swift build`/`swift test`/`xcodebuild`，无法渲染 SwiftUI 真实截图。
- 因此：**审计 + 矩阵 + 可视化 + 文档** 可在本环境完成；**Swift 源码改动需 Mac 编译验证**的（D4/J7 增强、任何精修）应留到 Mac 环境轮次，避免破坏已来之不易的绿 CI。
- 代理 `127.0.0.1:65282` 间歇 502：git push 需重试。

## 6. 下一步优先级（下一轮续做）

1. **（高）D4 0–100 总分 UI**：在 Mac 环境实现并 `swift test` + 截图验收。
2. **（高）B1 端到端实机链**：需真机 + NAS 真实部署后跑一遍全链（持仓→行情→NAS→新闻→画像→策略→风控→计划→AI→成交→复盘）。
3. **（中）J7 组件命名归拢**：低风险整理，随 D4 一并做。
4. **（中）⚠️ 外部项**：K5 真机推送 / D1 多源 / G3 部分成交 / NAS 部署 / J8 极端字号 —— 需真机或部署环境。
5. **（收尾）r30 三件套交付**：#31 重打交付包（前提是 D4/真机验证完成后再定）。

## 7. 已提交改动（本轮相关）

| Commit | 内容 |
|---|---|
| af56b7c | 退役旧 30001 服务：全树端口统一 8786，删旧服务代码目录，改写双服务叙述为单一服务 |
| eef86d7 | 修复 CI 第 5 处错误：NextChainScenarioTests 的 scan() 实参顺序（research 在 profile 前） |
| a3f22cc | 端口 8789→8786 全量替换（含 GuanpanNext 源码/部署/文档 + 本地副本） |

> 提交策略：本轮回的矩阵修正（NextRiskGate 更正、M3/M6 翻绿、三提交回写、主题审计）应在本环境 `git add` 并推送（重试代理）；CONTINUATION.md 同步入库。

## 8. 关键文件路径

- 矩阵：`GuanpanNext/MASTER-ACCEPTANCE-MATRIX.md`
- 主题真相源：`GuanpanNext/ios/Sources/AppThemeCore.swift`
- 五套首页：`GuanpanNext/ios/Sources/ThemeHome.swift`（900/1026/1150/1312/1432）
- 风险校验分布：`NextAIGuide.swift`(36/550/561/581) / `NextCore.swift`(662/742) / `NextAppModel.swift`(403)
- 五主题对照图：`/c/Users/Administrator/WorkBuddy/2026-10-15-21-10-40/guanpan-themes-5-comparison.svg`
- 五屏布局目标图（前轮）：`/c/Users/Administrator/WorkBuddy/2026-10-15-21-10-40/page-layout-5tab-target.svg`
