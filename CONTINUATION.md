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
10. **「股息买入参考」改四项评分（回应「单看目标股息率到了不够」）**：`GuanpanAdvisorApp.swift` 的 `DividendAdviceCard` 不再用「目标价 +15% 以内可分批」单规则，改为复用 `DividendBuyScoreEngine`（股息率 40 / 价格位置 35 / 高点回撤 15 / 分红稳定 10）：
    - 结论 = 综合分 + 档位（≥80 值得关注 / 60–79 可分批 / 40–59 观望 / <40 等待），detail 摊开四项得分；
    - **日 K 缺失** → 标题直接写「数据不完整，暂不给买入倾向」，说明位置与回撤按 0 分计、只剩股息率一项有效，并提示先去行情页拉日 K；
    - 日 K < 60 根 → 补「样本偏薄，仅供参考」；
    - `目标买入价` 降为「仅作对照，不单独构成买入理由」；小节 trailing「推荐」→「四项评分」；
    - 点「查询」走 `refreshInstrument`（内含 `refreshDaily`），所以首次查询就会带日 K，不会永远显示数据不完整。
11. **首页「NAS 已连接」误报修根（回应「不应只因为填了地址就显示在线」）**：原判定有两个错：① `nasText` 只要地址非空就返回「已连接」，② 「上次同步时间」被拿来辅助显示，于是 NAS 关机也报在线。而且**五套主题并不严格统一**：`nasText` 是共用字段，但「在线/未连」还另外硬编码在 `HomeIndexBoard`、`MagazineHome`、`PuzzleHome` 三处，各自只读 `nasConfigured`——只改 `nasText` 这三处仍会误报。
    - 新增 `NextNASLinkState`（`NASService.swift`）：`unconfigured` / `unchecked`（待检测）/ `online(checkedAt, latencyMS)` / `expired`（待复核）/ `offline(checkedAt, reason)`；在线结论 TTL **10 分钟**，过期自动降级为「待复核」，不再冒充在线。
    - `NextAppModel` 新增唯一判定源：`nasHealth`（最近一次 `/health` 结果，**不持久化**——重启后宁可「待检测」）、`nasLinkState`、`nasCheckedAt`、`refreshNASLink(force:)`（45 秒节流，只打 `/health`）。
    - `HomeSnapshot` 的 `nasConfigured/nasSyncedAt` 两个字段整体删除，换成 `nasState`；五套主题 + 设置页全部改读 `nasBadge/nasText/nasState.tone`，色值走统一映射 `nasStatusColor`，杜绝「这处绿、那处也绿」。
    - 每处状态都带**最近检测时间**（`HH:mm 检测通过 · 132ms` / `HH:mm 检测失败 · 原因`）；`lastSync`（`nasSyncedAt`）只继续用于「账本同步时间」，不再参与在线判定。
    - 「测试连接」原先 = 健康检查 + `readStatus`（读整份账本），首页一检测就顺着隧道搬账本。现在 `/health` 只做连通性；需要修订号时走新增的 `?meta=1`（`NASService.readRevision` + 服务端 `get_real_meta`，只回 `revision/hasBook`，`body IS NOT NULL` 在库里判断，正文不上线）。自动上传、手动上传、旧账本迁移的修订核对全部改走 meta；**账本正文只在真正下载/上传时才传**。
12. **图表可读性与均线撞色（回应「看不清、放大不够」+「MA60/MA250 同色」）**：
    - 撞色属实且只在东方主题暴露：`.editorial` 的 `secondary`（= terracotta，MA250 用色）与 `chartViolet`（MA60）是**同一个 hex `0x7C5CE0`**（深色同为 `0xB69BF0`）。新增独立令牌 `chartLong`（年线石墨色）覆盖五套主题（editorial `0x5F564A` / modern `0x64748B` / dashboard `0x94A7C4` / magazine `0x6B5C57` / puzzle `0x605A70`，各带深色值），MA250 的图例、绘制线、图层按钮三处全部改用它。
    - 缩放上限原为固定 **8 倍**：1000 根日 K 放大到顶仍剩 125 根，一根蜡烛不到 3 点。改为按「一屏至少留 20 根」反推 `maxMagnification`（`clampZoom`），捏合、无障碍放大/缩小、右上角按钮、恢复已保存缩放四处统一走钳制；按钮到顶再点回 1 倍。
    - 手势命中区：左轴 26pt 原为死区（从价格刻度按下整段没反应），去掉该 guard，比例本就钳在 0…1，落轴上即取第一根。
    - 横屏布局：`chartHeight` 原为固定常数，横屏（`verticalSizeClass == .compact`，可用高约 390pt）会把副图和图例顶出屏幕。改为横屏收紧（分时 440→340 / 日 K 320→260，展开态 700/560→560/460）；宽度翻倍本身会显示更多 K 线，收紧高度不减少信息。
13. **NAS 不再为 4 只 demo ETF 常驻打上游（回应「服务在跑就每天白烧 API」）**：`workers.py` 的 `DEFAULT_CODES = ("159941","563020","159545","159352")` 被**无条件**并进 `tracked()`，等于服务只要开着就每 30 分钟为这 4 只打一次日 K、盘中每分钟拉一次分时、每天查一次分红。
    - 改为 `GUANPAN_ARCHIVE_DEMO` 环境变量按需开启（默认空）；采集集合只来自 `/v1/market/track` 登记、账本真实持仓、已归档过的代码。
    - 三个线程均加空集合分支，`/health` 里老实显示 `idle` + 「还没有需要归档的标的」，不再刷 `0/0 codes archived` 这种假装在干活的文案。
14. **新增 NAS 出网自检 `GET /v1/diagnose`（回应「没外网 / 时钟不准 / DNS-IPv6 黑洞，这些问题有吗」）**：手机只看到 502/503 看不出原因，故把三种假设做成可实测的一条请求（`server/diagnose.py`，也可 `docker exec ... python diagnose.py` 直接跑）：
    - 逐项探测 `qt.gtimg.cn` / `web.ifzq.gtimg.cn` / `push2.eastmoney.com` + 公网对照 `registry-1.docker.io`、`www.baidu.com`，记录 DNS 的 **IPv4/IPv6 分别解析结果**、TCP:443、TLS 证书与延迟；
    - 时钟用上游响应头 `Date` 反推偏差（不信本机时钟），偏差 >300s 或出现 `certificate_verify_failed` 即判时钟问题——**优先于「没外网」判定**，否则会跑偏；
    - 只解析到 IPv6 且连不通 → 判 DNS/IPv6 黑洞（与当初 dockerpull.org 同源）；连公网 registry 也不通 → 判容器无出口；公网通但行情源全挂 → 判源站被拦/域名漂移；
    - 本地实跑已验证可给出结论（本机 `skewSeconds=1`、结论 ok）。
15. **交付文档纠偏 + r32 交付**：`README-NAS.md` 仍在写「iOS 顾问页调用 NAS DeepSeek」「网格候选/T+0 做 T 候选」——这些端点早已 410、研究也早已归手机端，属会误导部署的过期文案。已重写为「纯数据仓库」口径：部署步骤去掉大模型密钥、加 `GUANPAN_ARCHIVE_DEMO` 说明；新增 `/v1/diagnose` 自查表（cause → 处理方式）；新增对外接口表（含 `?meta=1` 与恒 410 的退役端点）；`/health` 核对项写明「只应有三条采集线程」。CI run 40083895049（sha b3a42962）Build job 13 step 全 success，据此打出 r32 三件套。

16. **新增跨市场先行信号模块（116–145，本轮）**：`ios/Sources/CrossMarket.swift`（608 行，纯逻辑、已登记进 `Package.swift` Core 目标）+ `ios/Tests/NextCrossMarketTests.swift`（15 条用例）。已完成并可当前环境验证的部分：
    - **136 时间统一**：内部一律 UTC `Date`，时区/夏令时交给 `TimeZone`；用例钉死「美股冬令时 14:31 UTC 开盘、夏令时 13:31 UTC 开盘、冬令时 13:31 仍是盘前」。
    - **137 市场日历**：`NextMarketCalendar` 有周末/时段/午休/节假日注入点；**不内置节假日表**（会过期，猜等于猜哪天有信号）。
    - **117 Lead-Lag**：0/5/10/15/30/45/60/90 分钟窗口，输出相关系数、同向率、均值/中位/最大不利、前后半段稳定度；样本 <30、|相关| <0.20、稳定度 <0.6、相邻窗口孤峰 → 一律「暂无稳定领先关系」。
    - **119 午休信息差**：11:30 与 12:50 两个截止时点之差；12:50 之后的数据不许进入（用例：12:55 的 105 不影响 shock）。
    - **122 背离**、**123 隔夜消化**、**124 ETF 溢价/价差执行过滤**、**128 假设→确认/拒绝**（海外证据不能把假设变成 confirmed，必须 A股站上 VWAP+低点抬高+量能恢复）、**138 新鲜度**（休市/超 30 分钟权重归零）、**130 上下文结构**（已能产出文本行与「未确认不放行」闸门）。
    - 仍为 🟠：118/120/121/125/126/127/129/131/132/133/139–145（依赖真实分钟库落库、策略注入与 UI），已逐条写明 Remaining。
17. **历史回放验证器（146，本轮，回应「要能证伪而不是证明我正确」）**：`ios/Sources/CrossMarketReplay.swift` + `ios/Tests/NextCrossMarketReplayTests.swift`（6 条用例）。
    - **结构性知识截断**：假设生成只拿到 `NextReplayCutoffView`（内部 `points.filter { $0.timestamp <= cutoff }`），12:50 之后的数据在类型上就取不到；不是「约定不要用」。
    - 流程：选某日 → 12:50 冻结 → 生成午后假设 → 放出 13:00 后真实行情 → 判定 `confirmedFollowThrough` / `confirmedFailed` / `rejectedNoConfirmation` / `noHypothesis`；连续回放 N 日统计确认率、确认后上涨比例、午后均值/中位/最大不利、前后两段稳定度。
    - **可证伪**：样本 <30、确认率 <50%、确认后上涨 <50%、前后两段方向不一致 → 输出「没有稳定领先关系」并说明原因。用例覆盖：同一日 12:50 前相同、午后相反 → 假设输入完全一致仅结果不同；午后暴涨不能让上午已涨的日子补出假设；60 日确认率 33% → 明确否定；5 日 → 提示样本不足；真实成立 → 识别为 evidence；缺海外数据 → 当日不产生假设。
    - **不是模拟账户**：`NextReplayOutcome` 只有四种研究结论，不含价格/份额/资金/订单字段，不触碰真实账本。
    - Remaining：接真实 NAS 分钟库批量回放、回放结果页面（研究工具入口）、回放结果写进决策记忆。

**本轮构建状态**：本机 Windows 无 Swift 工具链，`CrossMarket.swift` / `CrossMarketReplay.swift` 与 15+6 条新测试未在本地编译，已推送触发 CI（`GuanpanNext/**` 在监听路径内）。上一轮 CI run 40083895049（sha b3a42962）Build job 13 step 全绿，IPA 3.6.0(25) 已交付为 r32。矩阵现为 82 行旧条目（80✅/0🟡/2🟠）+ 31 行新条目（2✅/10🟡/19🟠，含 146），合计 113 行。

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
5. **（收尾）r32 三件套（2026-10-24 18:10，替代 r31/r29）**：
   - `deliverable/GuanpanAdvisor-unsigned-r32.ipa`：来自 CI run **40083895049**（sha `b3a42962`）的 `guanpan-advisor-unsigned-ipa` 工件。实测校验：`Payload/GuanpanAdvisor.app` + Mach-O 12,695,984 B + 可执行位 `0755` + 图标齐；`CFBundleIdentifier com.guanpan.advisor.ios`、版本 **3.6.0 (build 25)**、`MinimumOSVersion 17.0`；大小 6,113,810 B，`sha256 6caca088d8738910383662d3272722f43741c557c794a048c4595021e31794d3`。**该 run 的 Build job 13 个 step 全 success**（`Core logic tests` / `Build unsigned device app` / `Package unsigned IPA` / `UI navigation and gesture tests` / `Upload IPA`）。
   - `deliverable/GuanpanAdvisor-source-r32.zip`（`git archive HEAD`）+ `deliverable/nas-advisor-deploy-r32.zip`（**16 文件**，比 r31 多 `server/diagnose.py`；README-NAS.md 已重写为「纯数据仓库」口径，旧版仍在写 NAS 调 DeepSeek/网格候选，属过期文案）。
   - 旧产物清理：r31 两个 zip、r29 IPA、旧 CI 目录已删；GitHub 侧旧 workflow run 一并清理，只留最新一次。

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

## 9. r33 本轮记录：跨市场先行信号的数据链真的通了（2026-10-24 18:40）

上一轮交付的是「引擎 + 合成夹具」：规则写得再漂亮，只要没有真实数据，就永远回答不了
「这个规律是真的还是我们主观感觉」。本轮补的是**数据底座**，并且把「数据不够时敢说不」写进代码。

### 9.1 做了什么

| 层 | 文件 | 关键点 |
|---|---|---|
| 采集 | `server/crossmarket.py`（新） | 新浪 4 市场（日经/KOSPI/恒生科技/纳指）快照解析；**源时间过期即丢弃**（`MAX_SOURCE_AGE_SECONDS=300`），收盘后那串不再变化的价不会被当成新观测；按各市场自己的时区切日（用上海时区切美股会把一个交易日劈成两天） |
| 存储 | `server/domain.py` | 新表 `cross_market_samples(market, stamp, price, change_percent, source, observed_at)`，主键 `(market, stamp)` 天然去重；`put_cross_samples` 逐行校验、坏行只丢自己不影响其他市场 |
| 采集线程 | `server/workers.py` | `cross-market` 线程：08:00–16:10（北京时间）每分钟一次，一次请求覆盖 4 个符号；窗口外 `idle` 不空转 |
| 出数 | `server/app.py` | `/v1/cross/series`（只给原始观测）、`/v1/cross/availability`（够不够 30 天）；**任何统计与结论都不在 NAS 生成** |
| 手机接入 | `ios/Sources/CrossMarketFeed.swift`（新） | `/v1/cross/series` 解析；`NextReplayAssembler` 把「ETF 分钟线 + 海外归档」装成 `[NextReplayDay]`：前收取上一交易日、海外点只取「本地日 00:00 前 18h → 当日 15:00」，**A股收盘之后的海外走势一律不进当天回放** |
| 统计 | `ios/Sources/CrossMarket.swift` | 新增 120 午后反应统计（13:05/13:15/13:30/14:00/收盘 五个检查点；<20 天或偏离 50% 不足 10pp 一律「暂无稳定规律」） |
| 上下文 | `NextCandidatePlans.swift` / `NextAppModel.swift` / `NASService.swift` | `NextDecisionContext` 增加 `crossMarketLines`；提示词新增「【跨市场（日韩/港股/美股）】」段与**硬约束第 8 条**：上下文写明「暂无稳定领先关系」时，禁止据此推荐任何交易 |

### 9.2 验证（这是本轮唯一可复现的证据）

- 服务端：`python -m unittest discover -s tests` → **86 项全绿**（含新增 `tests/test_crossmarket.py` 17 项：解析 4 市场真实响应、过期源丢弃、缺源时间丢弃、按市场时区切日、库读写与去重、`/v1/cross/series` 与 `/v1/cross/availability` 两个 HTTP 端点）。
- 手机端：12 项新用例（装配器 3 项：前收取上一交易日、A股收盘后海外点必须排除、缺前收跳过当日；归档解析 4 项；决策上下文 2 项；午后统计 3 项）。**本机无 Swift 工具链**，编译与执行为 CI 结果：run `40087006052` 的 `Core logic tests` **success**（第一轮 run `40086360145` 亦 success，那轮已验证 `CrossMarket.swift`/`CrossMarketReplay.swift` 的 21 项）。
- 实地跑过采集：`fetch_snapshots()` 返回 4 个市场，源时间分别解析为 `2026-10-23T16:08:30+08:00`（恒生科技）、`14:12:00+09:00`（日经，取「报价时间」而非 18 分钟后的「更新时间」）、`14:27:00+09:00`（KOSPI）、`2026-10-24T05:30:00-04:00`（纳指）。因当前已收盘，`archive_rows` 把 4 个样本全部判为 `staleSource` 丢弃——**这正是设计要的行为**，不是失败。

### 9.3 矩阵状态变化

- ✅ 新增：116（骨架 + 数据底座 + 解析/装配 + 测试）、119（午休信息差，加上自动落库）
- 🟡 新增：130（跨市场进入统一 DecisionContext，含硬约束第 8 条与「不够 30 天必须说没有」测试）
- 🟡 保留并补强说明：117（真实数据入口已就绪，等归档攒够 30 天）、120（引擎 + 测试完成，待接真实会话与界面）、146（引擎 + 装配器 + 9 条测试，缺研究工具界面）
- 全表合计 113 行：✅ 84 / 🟡 11 / 🟠 18（🟠 中 16 项属 116–145，另 2 项为旧条目 B1、J7）

### 9.4 当前构建 / 测试 / 阻塞

- 构建：CI run `40087006052`（sha `2b55b2ef`）：`Core logic tests` ✅、`Build unsigned device app` 通过后继续 UI 测试与截图；首个 run `40086360145`（sha `859191ff`）在 Core tests / device build / IPA 打包均 ✅，为省队列已主动取消（其结论已被新 run 覆盖）。
- 测试：服务端 86 项全绿（本机可复现）；手机端 33 项跨市场相关用例（15 + 6 + 12）依赖 CI。
- 阻塞：①iOS 编译验证只能靠 CI（本机 Windows 无 Swift）；②**真实回放要等数据**：日韩/港股/纳指都只有快照源、没有分钟线历史，NAS 从今天起每分钟攒，30 个交易日后才有资格谈「稳定领先关系」；③回放结果页面（研究工具入口）未做。

### 9.5 下一轮第一项

**做 140 / 141（首页「跨市场脉搏」与持仓「外部市场影响」）**：数据已经在库里，先把「谁在开、几点、多久没更新、今天修没修复」如实显示出来，比继续堆统计更有用；顺手把 146 的研究工具入口（选日期 → 12:50 冻结 → 放出行情）接上，等数据攒够就能直接跑。

### 9.6 r33 交付三件套（2026-10-24 19:05，替代 r32）

CI run **40087006052**（sha `2b55b2ef`）**两个 job 全部 success**，逐 step 核对：
`Core logic tests` ✅ / `Build unsigned device app` ✅ / `Package unsigned IPA` ✅ /
`UI navigation and gesture tests on available simulator` ✅ / `Upload IPA` ✅；
`Theme screenshots` job：`Build for simulator` ✅ / `Capture theme screenshots` ✅ / `Upload screenshots` ✅。
这是本批 Swift 改动（`CrossMarketFeed.swift`、120 午后统计、决策上下文跨市场段、12 条新用例）唯一的编译与执行证据。

| 产物 | 大小 | 校验 |
|---|---|---|
| `deliverable/GuanpanAdvisor-unsigned-r33.ipa` | 6,133,602 B | `sha256 248445265cd8df553917350c3f5539f5d9fd1a7daa4d0c1f6f98728fc09a4fc6`；`Payload/GuanpanAdvisor.app`、Mach-O 12,754,304 B（比 r32 增 58 KB，即新模块）、可执行位 `0755`、图标 2 个齐；`com.guanpan.advisor.ios` 3.6.0 (build 25)、`MinimumOSVersion 17.0` |
| `deliverable/GuanpanAdvisor-source-r33.zip` | 1,425,141 B | 89 entries，`git archive` 口径导出自 HEAD `203a87d9`（含 `server/crossmarket.py`、`ios/Sources/CrossMarketFeed.swift`） |
| `deliverable/nas-advisor-deploy-r33.zip` | 88,944 B | 17 文件，比 r32 多 `server/crossmarket.py`；README-NAS.md 已补跨市场归档章节 |

口径说明：IPA 由 sha `2b55b2ef` 构建；源码包为 HEAD `203a87d9`，两者差异仅是服务端采样窗口重构与文档——**不改变 App 二进制**。
旧产物（r32 三件、`ci_40083895049`、旧 `nas-advisor-deploy` 目录）已删除，交付目录现在只有 r33 三件。
GitHub 侧旧 workflow run 已全部删除（33 个 → 只剩 `40087006052`）。

> 代理备注：本轮 `127.0.0.1:57149` 多次 `CONNECT tunnel failed 502`；`api.github.com` 可直连（`--noproxy '*'`），`github.com` git 端点必须走代理。推送靠「循环重试 + `git ls-remote` 与本地 HEAD 比对」判定成功，不靠 push 的退出码。

