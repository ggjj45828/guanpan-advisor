# CONTINUATION.md — 观盘 AI 私人投资顾问（双端：iOS + NAS）

> 本文件依《完整开发、重构、测试与验收总要求》#114/#115 写入：若执行轮次必须结束，把完整状态写于此，下一轮从此续做。
> 写入时间：2026-10-24（GMT+8）｜仓库根：`guanpan_next/`｜当前 HEAD：见 `git log -1`（本轮追加：NAS 取消后台研究）
> 详细逐项矩阵见 `GuanpanNext/MASTER-ACCEPTANCE-MATRIX.md`（80✅/0🟡/2🟠/0❌）。

---

## 1. 验收口径（最高标准）

- 正文 **113 条** + 末尾 **#114/#115** 两条「轮次必须结束须写 CONTINUATION.md」补充条款 = 用户所称「115 条」。
- 工作红线（不可逾越）：
  1. 只有一个真实账户，无模拟/虚拟/孪生账户（A1）。
  2. AI 只指导、**绝不自动下单**（A2/A3，成交必须用户确认）。
  3. NAS = **纯数据仓库**（日K/分时/分红/新闻的采集与归档），**不做后台研究、不下判断、非第二顾问**；研究、因子与最终 AI 指导**全部在手机端**（A4/C4/A5/H5）。
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
5. **NAS↔手机 穿透流量平衡（详见 `GuanpanNext/NAS-MOBILE-SPLIT.md`）**：实时归手机直连（零隧道）、NAS 只归档、不推实时给手机。代码：①`worker.minute_loop` 去实时报价拉取（分时归档保留）；②日 K 上限 640→1000 + `put_daily` 合并不裁剪（累积 1000+ 天）；③`refreshQuotes` 直连优先（腾讯首源含 IOPV），NAS 仅兜底；④`refreshDaily` 亦直连优先、NAS 仅兜底/补超长历史。<br>**待 Mac/真机验证**：IOPV 不丢（`NextCore.swift:301`）、直连优先无编译错、穿透流量下降。
6. **NAS 取消后台研究（回应「研究就交给手机」）**：
   - `server/workers.py`：删除 `research_loop` + `research_factors`，`start_workers` 线程仅剩 `daily-archive` / `minute-archive` / `dividend-archive`（全部是**采集**，不是研究）。
   - `server/app.py` · `/v1/research/{code}`：`factors`/`ai` 恒 `null`（键保留以兼容旧客户端解码）、新增 `researchOwner: "mobile"`；历史 `factors-*`/`deepseek-*` 残留**不再回传**（否则手机读到与本机规则不一致的过期结论）。接口本身保留＝「手机来问才现算归档统计」的被动通道。
   - `server/research.py`：头注明「被动按需计算，不是后台研究员」；`put_research`/`get_research`/`get_research_stats` 保留（测试与按需缓存）。
   - 文案统一为「NAS 长期归档 / 数据归档」：`ThemeHome.swift` 两处、`GuanpanAdvisorApp.swift`（统一 AI 说明）、`DeepSeekMobile.swift`（系统提示）、`NextCandidatePlans.swift`（dataState + 上下文标签）、`NASService.swift`/`NextAppModel.swift`/`NextCore.swift` 错误与状态文案、`server/web/index.html`、`server/news.py`、`server/app.py` 注释。
   - 验证：`py_compile` 通过；`python -m unittest discover -s tests` **68 项全绿**。
7. **模型输出排版重写（回应「大模型生成的文字排版有点乱」）**：`ios/Sources/GuanpanAdvisorApp.swift` 的 `AIAnswerView` 重写——
   - 剥行内 Markdown（`**`/`__`/`` ` ``/`###`/`#`），此前 `**结论**` 会原样显示成符号；
   - 小节标题识别扩到 `【结论】`/`1. 结论`/`一、结论`/`## 结论`（`headingProbe` 去编号·括号·粗体后匹配）；
   - 有序列表 `1.`/`1、`/`1)` 编号成列表标（`1.400` 这类价格不会误判，小数点后须有空格）；
   - 表格行 `| a | b |` 转「a ｜ b」；一行用「；」串多条要点的按分号断行（保留标点）；
   - 每节浅底 + 左侧色条、风险/失效条件警示色、行距与节间距加大。
   - 纯渲染层，不动 prompt 与内容。
8. **闪退隐患修复（回应「闪退卡片/闪退按钮」）**：
   - 盘口卡片 `model.orderBooks[code]!` 强解包 → `if let` 绑定；
   - `GPSparkline` 遇 NaN/∞ 序列不画（非法坐标进 CoreGraphics 可能崩）；
   - 存储层 `applicationSupportDirectory.first!` → App Support → Documents → 临时目录三级兜底。
9. **NAS 网页 AI 入口彻底拆除 + 死文件清理**：`market.html` 删「跑 AI 分析/验证 AI」按钮、`runAI()`/`verifyAI()`/`aiHtml()`、DeepSeek Key 提示（点下去打的是恒 410 的退役端点），改为「NAS 归档数据 · 只读」；删除已 410 的 `server/web/classic.html`（1.6 MB 死页面，仍含影子模拟网格 UI）。

## 3. 当前状态汇总

| 状态 | 数量 | 项 |
|---|---|---|
| ✅ Verified | 79 | 含 M3/M6 本轮翻绿 + 新增 C4（NAS＝纯数据仓库、无后台研究） |
| 🟡 Implemented/Not Verified | 0 | —（D4 已于 CI run 40081537292 编译+测试通过后翻 ✅） |
| 🟠 Partial | 2 | B1（端到端实机链）、J7（组件命名归拢） |
| ❌ Missing | 0 | — |
| ⚠️ 外部验证必需 | 6 | K5 真机推送 / D1 实机多源 / G3 部分成交 / NAS 真实部署 / J8 极端字号 / B1 端到端链 |

## 4. Partial / Missing 明细与处置

- **B1（端到端实机链）🟠**：源码链路各节点真实存在且相连（已逐节点核对，见矩阵 B1 行）。剩余仅是「真机/NAS 实跑验证」——**环境约束，无法在本轮完成**，留 ⚠️。
- **D4（DataQuality 0–100 总分 UI）✅ 已翻绿（2026-10-24 17:35）**：`NextDataConfidence.score0to100`（NextAIGuide.swift:32，纯计算：等级基分 82/60/38 + 新鲜度 ±8/−20 + 样本覆盖 ±6，blocked=0）＋ `GPDataQualityScore` 环形视图（GPDataQualityScore.swift，绿/橙/红分档）注入 AIGuidanceViews.swift:128。**编译验证已拿到**：CI run `40081537292`（HEAD `ed934e8`）四步全 success——`Core logic tests`（swift test）、`Build unsigned device app`、`UI navigation and gesture tests`、`Capture theme screenshots`。换言之本轮重写的 `AIAnswerView` 与三处闪退修复也一并编译/测试通过。剩余只是圆环的观感需人眼看截图（工件在 Actions，下载需认证）。
- **J7（组件命名归拢）🟠**：组件以 `GP*` 前缀实现（`GPCard`/`GPStatTile`/`CandidatePlanRow`…），功能齐但命名未完全统一。可选整理，风险同上。

## 5. 环境约束（决定「本轮回什么、留什么」）

- 当前环境 **Windows + 无 Mac**：无法 `swift build`/`swift test`/`xcodebuild`，无法渲染 SwiftUI 真实截图。
- 因此：**审计 + 矩阵 + 可视化 + 文档** 可在本环境完成；**Swift 源码改动需 Mac 编译验证**的（D4/J7 增强、任何精修）应留到 Mac 环境轮次，避免破坏已来之不易的绿 CI。
- 代理 `127.0.0.1:65282` 间歇 502：git push 需重试。

## 6. 下一步优先级（下一轮续做）

1. **（高→已实现待验）D4 0–100 总分 UI**：代码已写（NextAIGuide.swift:32 + GPDataQualityScore.swift + AIGuidanceViews.swift:128 注入）。下一轮在 Mac 跑 `swift test` + 截图确认翻 ✅。
1. **（中）旧文件全盘清理（本轮已完成）**：删除 `ios/UITests/NativeNavigationTests.swift` 的 `testGridPlanControlsAreVisibleInLaboratory`（断言已下线的「网格实验室/明日挂单表/虚拟账户」）+ `tabs` 数组残留的 `tab.laboratory`；删除过时 `previews/观盘Next-五页界面预览.svg`。保留项（非死代码，已核实）：`BackupDocument.swift` 账本导出、`NASService.downloadAndStageLegacyBook`/`legacyWebBaseURL` 旧网页账本迁移导入、`NextTab.overview/laboratory` 枚举（解码旧存档用）。
2. **（高）B1 端到端实机链**：需真机 + NAS 真实部署后跑一遍全链（持仓→行情→NAS→新闻→画像→策略→风控→计划→AI→成交→复盘）。
3. **（中）J7 组件命名归拢**：低风险整理，随 D4 一并做。
4. **（中）⚠️ 外部项**：K5 真机推送 / D1 多源 / G3 部分成交 / NAS 部署 / J8 极端字号 —— 需真机或部署环境。
5. **（收尾）r31 三件套已重打（2026-10-24 17:30）**：`deliverable/GuanpanAdvisor-source-r31.zip`（`git archive HEAD`，含 23 处入口去重后的源码）+ `deliverable/nas-advisor-deploy-r31.zip`（15 文件，已核验：`researchOwner` 在、`research_loop` 不在、`classic.html` 不在）；旧 r29/r30 四个 zip 已删，只留 r31（IPA 仍是 CI r29 产物，等新一轮 CI 出了再替换）。

## 7. 已提交改动（本轮相关）

| Commit | 内容 |
|---|---|
| fe77acc | 首页入口去重：删同屏重复的「AI 指导」chip 与「今日市场观察·更多」；审计清单改诚实版 |
| ee2470e | 新增首页重导向入口审计清单（`REDIRECT-CARDS-AUDIT.md`） |
| ed934e8 | NAS 取消后台研究（删 research_loop）+ 模型输出排版重写 + 拆 market.html AI 入口 + 删 classic.html + 3 处闪退隐患 |
| d415071 | 日 K 图表改直连优先（NAS 仅兜底/补超长历史） |
| a5769e4 | NAS↔手机穿透流量平衡（NAS 不再额外拉实时报价，分时归档保留；日 K 累积 1000 天；手机直连优先） |
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
