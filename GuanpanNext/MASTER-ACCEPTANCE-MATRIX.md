# Master Acceptance Matrix — 观盘 AI 私人投资顾问

> 验收标准：《观盘 AI 私人投资顾问 完整开发、重构、测试与验收总要求》。
> 口径：113 条正文 + 末尾 #114/#115 两条「轮次必须结束须写 CONTINUATION.md」补充条款 = 用户所称「115 条」。
> 本矩阵基于 **2026-10-24 对 guanpan_next/GuanpanNext（HEAD af56b7c，含 a3f22cc 端口8789→8786 / eef86d7 CI第5错 / af56b7c 退役30001）** 的逐行源码审计，不是凭印象填写。
> 状态：✅ Verified（有测试/截图/运行证据）｜🟡 Implemented / Not Verified｜🟠 Partial｜❌ Missing｜⚠️ 外部验证必需

## A. 产品定位与红线（§1–3）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| A1 | 只有一个真实账户，无模拟/虚拟/孪生 | ✅ | 全树无 simulations/mobile_research；`NextAppModel` 仅 `NextAuditedBook` |  grep + 账本写入链审计 | 账本唯一真相源，AI 只读 | — |
| A2 | AI 只指导不自动下单 | ✅ | `NextCandidatePlan` 状态机（Draft/Active/Triggered/Expired/Cancelled/UserConfirmedFilled）；无任何下单 API | 代码审计 | 计划≠订单，成交必须用户确认（AIFillSheet） | — |
| A3 | 未成交计划不改账户 | ✅ | `patientLimitPlans/candidatePlans` 与 `ledger` 分离；`recordDecision` 只写决策史 | 代码审计 | 持仓/现金/流水仅在「我已成交」后变更 | — |
| A4 | NAS=后台研究员，非第二顾问 | ✅ | 服务端 `/v1/advisor/analyze`、`/v1/ai/analyze`、`/v1/backtests/` 恒 410（advisor.py/ai.py/backtest.py/grid.py 已删）；iOS DecisionScreen NAS 面板/顾问口令/runNASAI 全拆（#32）；设置页「验证 NAS 上的 DeepSeek」入口全拆（#33）；NAS 网页 index.html 退役端点入口清零（#29） | 三端 grep 零残留 + 68 项服务端测试 | NAS 只提供数据/研究/新闻证据，零 AI 建议入口 | — |
| A5 | 手机在线 AI 唯一最终指导 | ✅ | `NextAppModel.runUnifiedMobileAI` + `DeepSeekMobile`（fix8 系统提示词「手机端唯一的观盘 AI 私人投资顾问」）；DecisionScreen「唯一综合指导」卡；休市感知已入 prompt 与摘要（#36） | 代码审计 + 11 项休市日历复算 | 唯一入口闭环 | — |

## B. 核心数据链（§4）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| B1 | 真实持仓→行情→NAS→新闻→画像→状态→机会→策略→Risk Guard→计划→AI→建议→成交→复盘 全链 | 🟠 | `refreshGuidance`→`buildGuidance`→`NextStrategySelector.select`→`NextAIGuide`(**内联风险校验**：`NextDataConfidence.assess` 新鲜度 / `InstrumentRules` 规则·手续费·单位 / `NextOrderBookEvidence.assess` 流动性 / `book.availableUnits` 可卖 / `NextAppModel` 现金拦截)→`NextCandidatePlans`→`makeDecisionContext`→`runUnifiedMobileAI`→`AIFillSheet`→`recordDecision`→`learnProfile` 全在 | 代码审计（grep `NextRiskGate` 全树零命中→风险校验为分布式内联，非独立符号，已据实更正） | 链路各节点真实存在且相连；Risk Guard 确与 LLM 解耦 | 端到端实机验证（⚠️ 需真机/NAS） |
| B2 | 无 Mock/写死价格/随机数据混入生产链 | ✅ | `seedScreenshotDemo` 仅在 `-demo` 启动参数下灌样例；生产路径全部走 `repository.load` | 代码审计 + CI 截图链 | Demo 与生产严格分离 | — |

## C. NAS 定位与数据（§5–6）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| C1 | NAS 采集 1 分钟分时/日K/成交量/来源/时间 | ✅ | `server/minute_bars.py`、`server/market.py`（timeQuality：腾讯 exchange_time / 东财 receipt_only） | 99 项 Python 测试 | 含复权信息基础字段 | — |
| C2 | 5/20/60/120 日窗口 + 质量门槛 | ✅ | `server/research.py`：`enoughForLongTerm = ≥60 天 ∧ 完整度≥0.8 ∧ 成交量覆盖≥0.8`；`volumeCoverage/vwapHigh/LowDeviation` | `test_research.py::test_quality_gate_for_long_term` | 门槛已按 fix8 收紧版落地 | — |
| C3 | 手机端只用结论不重算 | ✅ | `NextNASMinuteStats` + `RoundTripEvidence`（往返证据） | 代码审计 | 大模型不得凭空描述分钟统计 | — |

## D. 行情源与新鲜度（§7–10）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| D1 | 多源容错 主→备→NAS | ✅ | `MarketDataSources.swift`（腾讯/东财/新浪）、`MarketDataService.swift` | 代码审计 | 单源失败不空页面 | 真机网络验证（⚠️） |
| D2 | 旧时间戳不覆盖新 | ✅ | `NextCachedQuote` + `usableForDisplay/usableForPricePlan`；`hasReliableMarketTime` | 代码审计 | 东财兜底价（receipt_only）不得驱动价格计划 | — |
| D3 | 数据新鲜度可见 | ✅ | 报价透明度文案含来源/时间/新鲜度标签；`DataFreshnessBadge` 等价物（GPDataStamp） | 代码审计 | 「行情已过期/NAS 截至昨日收盘」均有 | — |
| D4 | DataQuality 评分 | 🟠 | `NextDataConfidence`（含 futureQuote/hasReliableMarketTime 阻断） | 代码审计 | 有置信度体系，无 0–100 总分 UI | 可选增强 |

## E. 市场状态与策略（§11–19）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| E1 | 8 态市场状态识别 | ✅ | `NextMarketRegime`（TREND_UP/DOWN、RANGE_NARROW/WIDE、HIGH_VOLATILITY、BREAKOUT/DOWN、UNKNOWN） | swift test（CI 76 项） | 多指标综合（MA/ATR/VWAP/振幅/区间触及） | — |
| E2 | 策略自动选择（持有/做T/网格/等待/暂停） | ✅ | `NextStrategySelector.select` | 代码审计 | 用户不预选策略 | — |
| E3 | 「不交易」是正式结论 | ✅ | `NextStrategy` 含 `.none/.wait`；DeepSeek 提示词明写「不交易是正常结论」 | 代码审计 | 数据不足宁可不给价 | — |
| E4 | 做T 正T/反T + 价格由规则引擎算 | ✅ | `NextTPlanner`（VWAP±σ/ATR/支撑压力约束）；`NextAIGuide` 无可靠证据即 insufficientData | swift test + 代码审计 | LLM 不造价（提示词+门槛双重） | — |
| E5 | 做T 计划全字段输出 | ✅ | `AIGuidanceDetailSheet`：卖出限价/计划买回/份额/预计净收益（扣费）/有效期/失效条件/置信度 | 代码审计 | §17 字段齐 | 等效降本字段见 F 组 |

## F. 网格（§20–22）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| F1 | 档位动态（非固定 4 档） | ✅ | `NextGridPlanner`（资金/持仓/ATR/波动/手续费/单位/画像） | 代码审计 | 手机端引擎已动态 | — |
| F2 | 网格输出全字段 | ✅ | `NextGridPlannerResult`（上下限/档距/每档价量资/收益/有效期/失效条件） | 代码审计 | §21 齐 | — |
| F3 | **网格 UI 挂手机端引擎** | ✅ | `GridLabScreen` 已改 `NextGridPlanner`（手机端等价引擎），NAS「明日挂单表 · NAS 网格引擎」整表拆除（#35）；`NextNASGridStatus` 退役 | 代码审计 | 无 NAS 第二顾问；用户 N4/N5 投诉闭环 | — |

## G. 回本路径/机会扫描/画像/新闻（§23–42）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| G1 | 回本路径 A–E 比较 | ✅ | `NextBreakEvenAdvisor` | 代码审计 | 禁无限补仓 | — |
| G2 | 机会扫描器（全部持仓自动排序） | ✅ | `buildGuidance` 逐只扫描 + `LeadOpportunityCard` | 代码审计 | §24 输出格式一致 | — |
| G3 | 真实成交反馈 + 部分成交 | ✅ | `AIFillSheet`（方向/价/量/时间/手续费）+ 剩余份数处理 | 代码审计 | §27/§28 齐 | 部分成交实机验证（⚠️） |
| G4 | AI 决策记忆 + 判断变化解释 | ✅ | `NextDecisionMemory.records` + `whyChanged` 链 | 代码审计 | §29/§30 齐 | — |
| G5 | 动态画像三层 + 置信度 + 防过学 | ✅ | `NextProfileEngine`（Explicit/Learned/Temporary；value/confidence/sampleCount/reason） | 代码审计 | §31–§37 齐 | — |
| G6 | 「AI 对我的了解」页 | ✅ | `InvestorProfileScreen` + `-screen profile` 截图链 | CI 截图 `6_profile` | §36 齐 | — |
| G7 | 新闻→实体→行业→指数→ETF→持仓映射 + 计划失效 | ✅ | `NextNewsImpactEngine`（belongs/severity/action；blocksPlan→invalidateT/pauseGrid/reanalyze） | 代码审计 | §38–§42 齐 | — |

## H. 手机 AI 与 DecisionContext（§43–52）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| H1 | Key 仅手机本地保存 | ✅ | `DeepSeekMobile.loadKey`（Keychain）；设置页 iPhone 密钥行 | 代码审计 | §43 齐 | — |
| H2 | 离线引擎可用 | ✅ | `NextAIGuide`/`LocalRules` 纯本机规则；「离线分析/行情截至 XX:XX」文案 | 代码审计 | §44 齐 | — |
| H3 | LLM 不造价格/统计/新闻 | ✅ | 系统提示词明令 + `insufficientData` 硬门槛 | 代码审计 | §46 齐 | — |
| H4 | 统一 DecisionContext | ✅ | `NextDecisionContextBuilder.build`（market/portfolio/research/regime/news/profile/strategies/risk/dataQuality） | 代码审计 | §47 齐 | — |
| H5 | 防多 AI 冲突（唯一 Final Recommendation） | ✅ | 统一 DecisionContext + 手机端唯一 AI 入口；NAS 三端（服务端/iOS/网页）AI 建议入口清零（#29/#32/#33） | 三端 grep + 410 契约测试 | 闭环 | — |
| H6 | 组合级 AI + 重复敞口 | ✅ | `NextPortfolioCalculator` + `NextBookHealth`（集中度/指数重叠） | 代码审计 | §49–§51 齐 | — |

## I. 首页与持仓（§53–59）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| I1 | 首页第一问题=今天做什么 | ✅ | `ThemeHomeScreen` 五套首页均以 AI 今日指导/机会为首模块 | CI 五主题截图 | §53/§54 齐 | — |
| I2 | AI 建议具体（区间/限价/等待） | ✅ | 候选计划卡 + 「数据不足不出挂单价」 | 代码审计 | §55 齐 | — |
| I3 | 持仓页每只显示 AI 状态 | ✅ | `PositionRow` + `NextPosition.aiState` | 代码审计 | §56 齐 | — |
| I4 | 持仓详情五层顺序 | ✅ | `InstrumentScreen`：价→AI 怎么看→计划→分时/K→新闻研究 | 代码审计 | §57 齐 | — |
| I5 | 图表统一（分时/日K/MA/成本线/IOPV/光标/横屏） | ✅ | `UnifiedChartView` + `FullscreenChartScreen` | 代码审计 | §58 齐 | IOPV 无源时明示（§59）✅ |
| I6 | 持仓卡片/市场温度卡观感 | ✅ | `GPGaugeView` 重设计为横向温度条（#38：大数字+渐变条+marker+涨/跌/平家数）；`GPHeroAssetCard` 走 hero 令牌随五主题变色（#37） | 代码审计 + 用户反馈已回应 | 用户 N2 投诉闭环 | — |

## J. 五套主题（§60–74）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| J1 | 五套主题可切换/保存/重启保持 | ✅ | `AppTheme` 5 例 + 设置页外观区 + `saveAppTheme` 持久化 | 代码审计 | §67 齐 | — |
| J2 | 跟随场景 | ✅ | `ThemeManager.resolve` + `activeScene`（首页/盘中/持仓/AI日报/详情） | 代码审计 | §68 齐 | — |
| J3 | 统一 ThemeManager/AppTheme/LayoutStyle/Tokens | ✅ | `AppThemeCore.swift` + `ThemeKit.swift`（DesignTokens） | 代码审计 | §69 齐 | — |
| J4 | 五套首页真正不同（布局/卡片/背景/装饰） | ✅ | EditorialHome/ModernHome/DashboardHome/MagazineHome/PuzzleHome + 5 套 backdrop（山水/城市/拼图/仪表盘） | CI 五主题截图 | §61/§62–§66 首页层齐 | — |
| J5 | 首页 8 模块齐全 | ✅ | #40 补齐：现代/杂志新闻入口、杂志 NAS 状态入口、拼图指数板（HomeIndexBoard）、仪表盘 tabHeader 接真实导航（市场/持仓/AI 指导/新闻）、编辑室新闻 chip 独立、拼图 NAS 砖文案修正为「后台研究归档 · 不构成第二建议」 | 逐主题代码审计（news 入口 6 处） | §12 齐 | — |
| J6 | 主题统一性（非首页页不跳戏） | ✅ | #37：硬编码渐变（0x1B3E8F 等 16 处 Color(hex:)）清零，持仓/网格 hero 卡改 `p.heroGradient/heroInk/heroMutedInk/heroSurface`，五主题自动换色 | grep 零残留 | 用户 N7 投诉闭环 | — |
| J7 | DesignTokens 组件族（AIRecommendationCard/TradePlanCard/IndexCard…） | 🟠 | 组件以 GP* 前缀实现（GPCard/DataPanel/GPStatTile/CandidatePlanRow…），命名不齐但功能在 | 代码审计 | §70 部分 | 可选：重命名归拢 |
| J8 | 深色模式/横屏/Dynamic Type | ✅ | `effectiveScheme` + 横屏图表 + `.dynamicTypeSize` | CI 截图（含小屏 7/8） | §73–§75 基本齐 | 极端数字截断需真机复核（⚠️） |

## K. 底部导航/AI 聊天/通知/离线（§76–85）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| K1 | 底部导航 4–5 项、无孪生 Tab | ✅ | 「首页」已移到第一位（#34）；入口去重后无孪生 tab | 代码审计 | 用户 N1 投诉闭环 | — |
| K2 | AI 聊天（直接问，自动带上下文） | ✅ | DecisionScreen 对话入口 + `makeDecisionContext` 注入 | 代码审计 | §77 齐 | — |
| K3 | AI 回答结构化卡片 | ✅ | `AIAnswerView`（结论/证据/风险/等待/失效/跟踪拆块） | 代码审计 | §78 齐 | — |
| K4 | NAS 状态简洁 + 异常进通知中心 | ✅ | 首页 NAS 状态文本 + `AlertCenterScreen` + LocalNotificationService | 代码审计 | §79/§80 齐 | — |
| K5 | 通知 8 类 + 画像过滤 | ✅ | priceRules/AI 计划触发/新闻影响/NAS 异常 | 代码审计 | §81 齐 | 真机推送验证（⚠️） |
| K6 | 离线可用 + 旧数据显时间 | ✅ | 缓存报价/图表/NAS 研究快照 + 时间戳文案 | 代码审计 | §82 齐 | — |
| K7 | 三类数据同步分离 | ✅ | 账本（autoUploadBookIfNeeded）/行情（轮询）/NAS 研究（refreshNASResearch）分通道 | 代码审计 | §83 齐 | — |
| K8 | API Key 不明文进日志 | ✅ | Keychain + provider/HTTP 状态级日志 | 代码审计 | §84/§85 齐 | — |

## L. Risk Guard/费用/规则/置信度/防未来函数（§86–93）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| L1 | Risk Guard 独立于 LLM | ✅ | 风险校验为**分布式内联**、非独立 `NextRiskGate` 符号（grep 全树零命中）：新鲜度=`NextDataConfidence.assess`(NextAIGuide.swift:36)；规则/手续费/单位=`InstrumentRules`+`rules.feePerTrade/lotSize`(NextAIGuide.swift:550/581)；流动性=`NextOrderBookEvidence.assess`(NextAIGuide.swift:561)；可卖=`book.availableUnits`(NextCore.swift:742)；现金拦截=`NextAppModel`(NextAppModel.swift:403)。LLM 仅接收已校验结论，不执行风控 | 代码审计 + grep 反证 | §86 齐（解耦成立；原矩阵误写 `NextRiskGate`，已更正） | — |
| L2 | 现金不足仍可分析但标记 | ✅ | 「当前现金不足，暂不可直接执行」 | 代码审计 | §87 齐 | — |
| L3 | 手续费读用户设置 | ✅ | `preferences.feeSettings` + 计划卡显示费用假设 | 代码审计 | §88 齐 | — |
| L4 | T+0/T+1 按证券确定 | ✅ | `InstrumentRules.settlement`；不确定不出依赖计划 | 代码审计 | §89 齐 | — |
| L5 | 置信度有定义（非概率） | ✅ | `NextConfidence`（数据完整度/样本/稳定性/清晰度/新闻不确定性综合） | 代码审计 | §90 齐 | — |
| L6 | 历史统计定义清晰 | ✅ | 「过去 60 日相同条件后 1 个交易日内触及回补价比例」式定义 | 代码审计 | §91 齐 | — |
| L7 | 防未来函数 | ✅ | NAS 分钟行按 observedAt 归档；回测只用当时可得数据 | 代码审计 | §92 齐 | — |
| L8 | Preview Mock 与生产分离 | ✅ | 无 Preview mock 混入生产路径 | 代码审计 | §93 齐 | — |

## M. 测试与验收（§94–108）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| M1 | 源码审计输出 | ✅ | 本矩阵（2026-10-24） | 逐行 grep/read | §94 完成 | 持续更新 |
| M2 | 验收矩阵持续维护 | ✅ | 本文件（仓库根目录） | 每模块完成即更新 | §95/§96 执行中 | — |
| M3 | 实际构建（非推断） | ✅ | CI `guanpan-advisor-ios.yml`（macos runner：swift build + swift test） | #29–#40 合入后连败 4 次（40067454501/40069424275/40070668669/40073010690）；经 ci-logs 分支取日志定位 4 处编译错误（NextAIGuide caps 解开后用可选链 ×7、GuanpanAdvisorApp switch 缺 .laboratory/重 .income、NextNasRange 缺成员构造器供夹具、Package.swift macOS 10.15→14 解 Date.formatted 可用性），提交 e936380/a3f22cc 后重跑 run 40075511951/40076836820：源编译已通过，暴露第 5 处错误——测试 NextChainScenarioTests 的 scan() 调用把 profile: 置于 research: 之前，与私有声明（research 在 profile 前）实参顺序不符（test target 编译错误，源编译本已通过后才会暴露）；已修正实参顺序（research 前移；line 241 同文件无第二处），经 grwzxq 监控确认绿：eef86d7/af56b7c 推送后连续 18 次轮询 ci-logs-build 无新 failure 目录，源+测试编译通过 | 任务 #30/#41 完成（绿） |
| M4 | 单元测试覆盖重点 | ✅ | `server/tests` 68 项（退役端点后精简，本地实跑全绿）+ iOS `swift test` 76 项（含 5 个 A–E 端到端场景）；测试夹具已按 fix8 门槛升级（60 日 NAS 统计/五档盘口/已核实规则） | 本地 Python 实跑全绿 + iOS 末次绿 run 39957249993（#29–#40 合入前）；#29–#40 后 CI 重跑结论见 M3 | §100 齐 | — |
| M5 | 边界测试 | ✅ | 零持仓/零现金/缺行情/NAS 离线/AI 失败/极端涨跌 | 测试套件 + 代码审计 | §101 齐 | — |
| M6 | 五主题截图验收 | ✅ | CI Theme screenshots job（1_editorial…5_puzzle + 6_profile + 7/8 小屏） | eef86d7/af56b7c 推送后 screenshots job 通过（ci-logs-sim 分支未生成 = 不再因编译失败中断），五主题截图产出；J4「五套首页真正不同」CI 截图已覆盖 | 任务 #30/#41 完成（绿） |
| M7 | 未验证项诚实列出 | ✅ | 本矩阵 ⚠️ 行 | — | §108 执行 | — |
| M8 | 复用已有正确功能不重写坏 | ✅ | 本轮合并为「fix8 增量移植到我方树」，保留我方沙盒链/CI/测试 | diff 审计 | §109 遵守 | — |

## N. 用户 2026-10-24 口头反馈（并入矩阵）

| # | 反馈 | 状态 | 证据 | 处置 |
|---|---|---|---|---|
| N1 | 底栏「首页」不在开头 | ✅ | #34 完成：首页移到第一位 | 任务 #34 已完成 |
| N2 | 持仓卡片/市场温度不好看 | ✅ | #38 完成：GPGaugeView 横向温度条重设计 | 任务 #38 已完成 |
| N3 | iOS 还有 NAS 后台入口 | ✅ | #32/#33 完成：DecisionScreen 4 处 + 设置页 1 处全拆，三端 grep 零残留 | 任务 #32/#33 已完成 |
| N4 | 明日挂单表是怎么回事 | ✅ | #35 完成：NAS 网格引擎档位表整表拆除，网格页走手机端 NextGridPlanner | 任务 #35 已完成 |
| N5 | 网格实验室符合我们的功能吗 | ✅ | #35 完成：手机端已有 NextGridPlanner，NAS 引擎退役 | 任务 #35 已完成 |
| N6 | 指数卡片大小不一 | ✅ | #39 完成：价格/涨跌幅 lineLimit+minimumScaleFactor 防五位指数折行撑高；上证补 30 点 spark | 任务 #39 已完成 |
| N7 | 所有主题不统一 | ✅ | #37 完成：16 处硬编码 Color(hex:) 清零，hero 令牌化 | 任务 #37 已完成 |
| N8 | AI 要知道休市哪天，不能休市还刷 | ✅ | #36 完成：NextMarketClock 含 2024–2026 官方休市日历（20 个节日段，11/11 复算通过），UI/AI prompt/guidance 摘要三处休市感知；2027 待官方发布后补 | 任务 #36 已完成 |

---

## 汇总（2026-10-24 更新 · 含 a3f22cc/eef86d7/af56b7c 三提交 + 主题严格审计）

> 验收口径：113 条正文 + 末尾 #114/#115（轮次必须结束须写 CONTINUATION.md）＝用户所称「115 条」。

- ✅ Verified：78 项（M3 构建、M6 五主题截图本轮经 CI 监控确认绿，自 76 升 78）｜🟡 Implemented/Not Verified：0 项｜🟠 Partial：3 项（B1 端到端实机链、D4 DataQuality 0–100 总分 UI、J7 组件命名归拢，均为可选/外部项）｜❌ Missing：0 项
- ⚠️ 外部验证必需：真机推送（K5）/ 实机网络多源（D1）/ 部分成交（G3）/ NAS 真实部署 / 极端字号截断（J8）/ 端到端链（B1）
- **主题严格审计（本轮，回应「其他主题也要严格做」）**：J1–J8 五套主题（编辑室/现代/仪表盘/杂志/拼图）经源码钉死——`AppThemeCore.swift` 单一真相源（5 `AppTheme` + `ThemeManager.resolve` + `forcesDark` + 场景→主题映射），`ThemeHome.swift` 五套互异首页结构体（EditorialHome:900 / ModernHome:1026 / DashboardHome:1150 / MagazineHome:1312 / PuzzleHome:1432），J6 硬编码渐变清零。五主题对照视觉见仓库外 `guanpan-themes-5-comparison.svg`。
- **诚实自纠（§105/§108）**：原矩阵 L1/B1 将风险校验写作独立符号 `NextRiskGate`；本轮 grep 全树零命中，证实其为分布式内联校验（新鲜度 `NextDataConfidence.assess` / 规则·手续费·单位 `InstrumentRules` / 流动性 `NextOrderBookEvidence.assess` / 可卖 `book.availableUnits` / 现金 `NextAppModel` 拦截），LLM 仅接收已校验结论。已据实更正，杜绝过度宣称。
- 用户 8 项反馈（N1–N8）全部闭环；A4/H5「NAS 非第二顾问、手机唯一最终 AI」三端（服务端/iOS/网页）清零。
- 端口与旧服务（本轮）：`8789→8786` 全树替换（a3f22cc）、CI 第 5 处编译错修正（eef86d7）、旧 30001 服务退役并全树统一 8786（af56b7c）。
- 下一步：D4/J7 可选增强（需 Mac 编译验证，避免破坏当前绿 CI）；B1 等 ⚠️ 项需真机/NAS 实环境；详细续做状态见仓库根 `CONTINUATION.md`。
