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
| A4 | NAS＝纯数据仓库，非第二顾问 | ✅ | 服务端 `/v1/advisor/analyze`、`/v1/ai/analyze`、`/v1/backtests/` 恒 410（advisor.py/ai.py/backtest.py/grid.py 已删）；iOS DecisionScreen NAS 面板/顾问口令/runNASAI 全拆（#32）；设置页「验证 NAS 上的 DeepSeek」入口全拆（#33）；NAS 网页 index.html 退役端点入口清零（#29）；2026-10-24 再删后台 `research_loop`，并拆掉 market.html 残留的「跑 AI 分析/验证 AI」按钮与 DeepSeek Key 提示（此前只清了 index.html） | 三端 grep 零残留 + 68 项服务端测试实跑全绿 | NAS 只提供数据归档（日K/分时/分红/新闻），不研究、不下判断、零 AI 建议入口 | — |
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
| C2 | 5/20/60/120 日窗口 + 质量门槛 | ✅ | `server/research.py`：`enoughForLongTerm = ≥60 天 ∧ 完整度≥0.8 ∧ 成交量覆盖≥0.8`；`volumeCoverage/vwapHigh/LowDeviation` | `test_research.py::test_quality_gate_for_long_term` | 门槛已按 fix8 收紧版落地；模块为**被动按需计算**，非后台研究 | — |
| C3 | 手机端只用结论不重算 | ✅ | `NextNASMinuteStats` + `RoundTripEvidence`（往返证据） | 代码审计 | 分时窗口统计由 NAS 用归档现算（数据只在 NAS），手机不重算；策略/因子/AI 判断则全在手机 | — |
| C4 | NAS＝纯数据仓库，不做后台研究（2026-10-24 用户定调） | ✅ | `server/workers.py` 删除 `research_loop`/`research_factors`，线程仅剩 daily/minute/dividend；`/v1/research/{code}` 的 `factors`/`ai` 恒 `null` 并返回 `researchOwner: "mobile"` | 68 项服务端测试实跑全绿 + grep 零残留 | 研究、因子、判断、最终 AI 全在手机；手机需要历史数据时才向 NAS 要，属正常同步、与隧道无关 | — |

## D. 行情源与新鲜度（§7–10）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| D1 | 多源容错 主→备→NAS | ✅ | `MarketDataSources.swift`（腾讯/东财/新浪）、`MarketDataService.swift` | 代码审计 | 单源失败不空页面 | 真机网络验证（⚠️） |
| D2 | 旧时间戳不覆盖新 | ✅ | `NextCachedQuote` + `usableForDisplay/usableForPricePlan`；`hasReliableMarketTime` | 代码审计 | 东财兜底价（receipt_only）不得驱动价格计划 | — |
| D3 | 数据新鲜度可见 | ✅ | 报价透明度文案含来源/时间/新鲜度标签；`DataFreshnessBadge` 等价物（GPDataStamp） | 代码审计 | 「行情已过期/NAS 截至昨日收盘」均有 | — |
| D4 | DataQuality 评分（0–100 总分 UI） | ✅ | `NextDataConfidence.score0to100`（NextAIGuide.swift:32，纯计算：等级基分 82/60/38 + 新鲜度 ±8/−20 + 样本覆盖 ±6，blocked=0）＋ `GPDataQualityScore` 环形视图（GPDataQualityScore.swift，绿/橙/红分档）已注入 AIGuidanceViews.swift:128 的 AI 指导列表 | **CI run 40081537292（HEAD ed934e8）：Core logic tests（swift test）success + Build unsigned device app success + UI 测试 success + 主题截图 success** | 0–100 总分 UI 已实现、编译通过、测试通过；出价仍走 canPriceTPlan/canPriceGridPlan 硬门槛，score 低不编挂单价 | 圆环观感需人眼看截图（CI 已产出工件，下载需认证） |

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
| J5 | 首页 8 模块齐全 | ✅ | #40 补齐：现代/杂志新闻入口、杂志 NAS 状态入口、拼图指数板（HomeIndexBoard）、仪表盘 tabHeader 接真实导航（市场/持仓/AI 指导/新闻）、编辑室新闻 chip 独立、拼图 NAS 砖文案修正为「数据归档 · 不构成第二建议」 | 逐主题代码审计（news 入口 6 处） | §12 齐 | — |
| J6 | 主题统一性（非首页页不跳戏） | ✅ | #37：硬编码渐变（0x1B3E8F 等 16 处 Color(hex:)）清零，持仓/网格 hero 卡改 `p.heroGradient/heroInk/heroMutedInk/heroSurface`，五主题自动换色 | grep 零残留 | 用户 N7 投诉闭环 | — |
| J7 | DesignTokens 组件族（AIRecommendationCard/TradePlanCard/IndexCard…） | 🟠 | 组件以 GP* 前缀实现（GPCard/DataPanel/GPStatTile/CandidatePlanRow…），命名不齐但功能在 | 代码审计 | §70 部分 | 可选：重命名归拢 |
| J8 | 深色模式/横屏/Dynamic Type | ✅ | `effectiveScheme` + 横屏图表 + `.dynamicTypeSize` | CI 截图（含小屏 7/8） | §73–§75 基本齐 | 极端数字截断需真机复核（⚠️） |

## K. 底部导航/AI 聊天/通知/离线（§76–85）

| # | 需求 | 状态 | 代码位置 | 验证方法 | 结果 | 剩余 |
|---|---|---|---|---|---|---|
| K1 | 底部导航 4–5 项、无孪生 Tab | ✅ | 「首页」已移到第一位（#34）；入口去重后无孪生 tab | 代码审计 | 用户 N1 投诉闭环 | — |
| K2 | AI 聊天（直接问，自动带上下文） | ✅ | DecisionScreen 对话入口 + `makeDecisionContext` 注入 | 代码审计 | §77 齐 | — |
| K3 | AI 回答结构化卡片 | ✅ | `AIAnswerView`（结论/证据/风险/等待/失效/跟踪拆块）；2026-10-24 重写排版层：剥 Markdown 记号（`**`/`#`/`` ` ``）、识别 `【结论】`·`1. 结论` 等标题变体、有序列表编号对齐、表格行转「a ｜ b」、一行多要点按「；」断行、每节浅底 + 左侧色条 | 代码审计 | §78 齐；「排版乱」反馈已处理（待 Mac 截图复核） | — |
| K4 | NAS 状态简洁 + 异常进通知中心 | ✅ | 首页 NAS 状态文本 + `AlertCenterScreen` + LocalNotificationService | 代码审计 | §79/§80 齐 | — |
| K5 | 通知 8 类 + 画像过滤 | ✅ | priceRules/AI 计划触发/新闻影响/NAS 异常 | 代码审计 | §81 齐 | 真机推送验证（⚠️） |
| K6 | 离线可用 + 旧数据显时间 | ✅ | 缓存报价/图表/NAS 归档快照 + 时间戳文案 | 代码审计 | §82 齐 | — |
| K7 | 三类数据同步分离 | ✅ | 账本（autoUploadBookIfNeeded）/行情（轮询）/NAS 归档数据（refreshNASResearch）分通道 | 代码审计 | §83 齐 | — |
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

- ✅ Verified：80 项（M3 构建、M6 五主题截图经 CI 确认绿；新增 C4「NAS＝纯数据仓库」；**D4 于本轮由 🟡 翻 ✅**——CI run 40081537292 的 `Core logic tests`/`Build unsigned device app`/`UI 测试`/`精选截图`四步全 success）｜🟡 Implemented/Not Verified：0 项｜🟠 Partial：2 项（B1 端到端实机链、J7 组件命名归拢）｜❌ Missing：0 项
- ⚠️ 外部验证必需：真机推送（K5）/ 实机网络多源（D1）/ 部分成交（G3）/ NAS 真实部署 / 极端字号截断（J8）/ 端到端链（B1）
- **主题严格审计（本轮，回应「其他主题也要严格做」）**：J1–J8 五套主题（编辑室/现代/仪表盘/杂志/拼图）经源码钉死——`AppThemeCore.swift` 单一真相源（5 `AppTheme` + `ThemeManager.resolve` + `forcesDark` + 场景→主题映射），`ThemeHome.swift` 五套互异首页结构体（EditorialHome:900 / ModernHome:1026 / DashboardHome:1150 / MagazineHome:1312 / PuzzleHome:1432），J6 硬编码渐变清零。五主题对照视觉见仓库外 `guanpan-themes-5-comparison.svg`。
- **诚实自纠（§105/§108）**：原矩阵 L1/B1 将风险校验写作独立符号 `NextRiskGate`；本轮 grep 全树零命中，证实其为分布式内联校验（新鲜度 `NextDataConfidence.assess` / 规则·手续费·单位 `InstrumentRules` / 流动性 `NextOrderBookEvidence.assess` / 可卖 `book.availableUnits` / 现金 `NextAppModel` 拦截），LLM 仅接收已校验结论。已据实更正，杜绝过度宣称。
- **D4 落地（本轮）**：`NextDataConfidence.score0to100`（NextAIGuide.swift:32，纯计算：等级基分 82/60/38 + 新鲜度 ±8/−20 + 样本覆盖 ±6，blocked=0）＋ `GPDataQualityScore` 环形视图（新文件 GPDataQualityScore.swift，绿/橙/红分档）已注入 AIGuidanceViews.swift:128 的 AI 指导列表。出价仍走 canPriceTPlan/canPriceGridPlan 硬门槛，分数低不编挂单价。状态 🟡（已写码、Windows 无 Mac 未跑 swift build 验证）。
- **旧文件全盘清理（本轮，回应「明日挂单表这类旧文件」）**：grep 全树确认「明日挂单表」仅存于文档与一处**过期 UITest**——`ios/UITests/NativeNavigationTests.swift` 的 `testGridPlanControlsAreVisibleInLaboratory`（断言已下线的「网格实验室/明日挂单表/虚拟账户」）及 `tabs` 数组残留的 `tab.laboratory`。已删除该方法 + 移除 `tab.laboratory` 项（底栏确为 5 入口：首页/行情/持仓/收息/我的）；并删除过时 `previews/观盘Next-五页界面预览.svg`。经核查 `BackupDocument.swift`（账本导出）、`NASService.downloadAndStageLegacyBook`/`legacyWebBaseURL`（旧网页账本迁移导入）、`NextTab.overview/laboratory` 枚举（仅为解码旧存档保留）均为**在用合法功能，非死代码，保留**。矩阵原 N4/N5/F3 的 ✅ 经此清理才真正闭环（此前遗漏了 UITest 残留）。
- **NAS↔手机 穿透流量平衡**：原则＝**实时归手机直连（零隧道）、NAS 只归档（不推手机）**，隧道仅用于账本上行 + 手机按需取 NAS 独有数据。落地：①`minute_loop` 不再每分钟额外拉实时报价（**分时归档保留——用户明确重要**）；②日 K 拉取上限 640→1000，配合 `put_daily` 按日期合并、从不裁剪 → NAS 累积保存 1000+ 天日 K；③`refreshQuotes` 改为**手机直连优先**（腾讯首源自带 IOPV，`NextCore.swift:301` 第 78 字段），NAS 仅直连全失败时兜底，IOPV 不经隧道。④`refreshDaily` 亦改为直连优先、NAS 仅兜底/补超长历史（日 K 图表不再经隧道下行）。详见 `GuanpanNext/NAS-MOBILE-SPLIT.md`。待 Mac/真机验证 IOPV 不丢与穿透流量下降。
- **NAS 取消后台研究（本轮，回应「研究就交给手机」）**：删除 `server/workers.py` 的 `research_loop` 与 `research_factors`，后台线程仅剩 `daily-archive` / `minute-archive` / `dividend-archive` 三个**采集**线程；`/v1/research/{code}` 的 `factors`/`ai` 改为恒 `null`（键保留以兼容旧客户端解码）并新增 `researchOwner: "mobile"`，历史 `factors-*`/`deepseek-*` 残留不再回传，避免手机读到与本机规则不一致的过期结论；`research.py` 头注明「被动按需计算」而非后台研究员。文案同步改为「NAS 长期归档 / 数据归档」（ThemeHome 两处、GuanpanAdvisorApp、DeepSeekMobile 系统提示、NextCandidatePlans 上下文与 dataState、NASService/NextAppModel/NextCore 错误文案、server/web/index.html、news.py、app.py 注释）。`put_research`/`get_research`/`get_research_stats` 保留（测试与按需缓存用）。68 项服务端测试实跑全绿。
- **模型输出排版重写（本轮，回应「大模型生成的文字排版有点乱」）**：`AIAnswerView` 重写解析与渲染——①剥除行内 Markdown（`**`/`__`/`` ` ``/`###`/`#`），此前 `**结论**` 会原样显示成符号；②标题识别扩到 `【结论】`、`1. 结论`、`一、结论`、`## 结论`（`headingProbe` 去编号/括号/粗体后再匹配）；③有序列表 `1.`/`1、`/`1)` 编号右对齐成列表标；④表格行 `| a | b |` 转「a ｜ b」；⑤一行用「；」串多条要点的按分号断行（保留标点）；⑥每节浅底 + 左侧色条、风险/失效条件用警示色、行距与节间距加大。价格如 `1.400` 不会被误判成编号（小数点后须有空格）。纯渲染层改动，不动 prompt 与内容。
- **闪退隐患修复（本轮）**：①`GuanpanAdvisorApp.swift` 盘口卡片 `model.orderBooks[code]!` 强解包 → 改为 `if let` 绑定（刷新瞬间字典被清空会直接把卡片点崩）；②`GPAssetCards.GPSparkline` 对含 NaN/∞ 的序列直接不画（非法坐标进 CoreGraphics 可能崩）；③`NextAppModel` 存储层 `applicationSupportDirectory.first!` → 三级兜底（App Support → Documents → 临时目录），容器异常时不再启动即闪退。
- **NAS 网页 AI 入口彻底拆除（本轮）**：`market.html` 删「跑 AI 分析」「验证 AI」按钮、`runAI()`/`verifyAI()`/`aiHtml()` 及 DeepSeek Key 提示（这些按钮点下去打的是恒 410 的退役端点）。页面改为「NAS 归档数据 · 只读」，只渲染分钟归档统计。
- **NAS 侧实测（2026-10-24，本地真跑而非纸面断言）**：起本地服务后实测——①`/health` 的 `workers` 仅 3 条：`daily-archive ok` / `dividend-archive ok`（已从 `dividend-research` 改名，分红是采集器不是研究）/ `minute-archive idle`，**无 `factor-research`**；②`/v1/research/159941` 返回 `{factors: null, ai: null, minuteStats: {...}, researchOwner: "mobile"}`；③四个退役端点 `POST /v1/ai/analyze`、`/v1/advisor/analyze`、`/v1/backtests/runs/x`、`/v1/simulations/x` 全 `410`；④`domain.py` 启动清理 `factor-research`/`dividend-research` 旧心跳，避免改名后 `/health` 永久 stale；⑤`python -m unittest discover -s tests` 68 项全绿。
- **「股息买入参考」改四项评分（本轮，回应「单看目标股息率到了不够」）**：该卡此前用「目标价 +15% 以内可分批」的单一规则给结论——只看股息率，价格位置/回撤完全不参与，容易被读成"可以买"。现改为复用收息页「自选打分」的同一引擎 `DividendBuyScoreEngine`：股息率 40 / 价格位置 35 / 高点回撤 15 / 分红稳定 10，卡片逐项摊开（`① 股息率 40 分`…`④ 分红稳定 10 分`）+ 综合分与档位；**日 K 缺失时明确说「数据不完整，暂不给买入倾向」**（位置与回撤按 0 分计并列出缺项），不再用低分/缺项冒充判断；日 K 少于 60 根时补一句「样本偏薄，仅供参考」。`目标买入价` 降级为「仅作对照，不单独构成买入理由」；小节 trailing 由「推荐」改为「四项评分」。口径单一来源，避免两套算法打架。
- 用户 8 项反馈（N1–N8）全部闭环；A4/H5「NAS 非第二顾问、手机唯一最终 AI」三端（服务端/iOS/网页）清零。
- 端口与旧服务（本轮）：`8789→8786` 全树替换（a3f22cc）、CI 第 5 处编译错修正（eef86d7）、旧 30001 服务退役并全树统一 8786（af56b7c）。
- **首页「NAS 在线」改为真实健康检查（本轮，回应「不应只因为填了地址就显示在线」）**：原判定错在两处——`nasText` 只要地址非空就回「已连接」，「上次同步时间」又被拿来辅助显示，NAS 关机照样报在线。更要紧的是**五套主题并不严格统一**：`nasText` 是共用字段，但「在线/未连」还硬编码在 `HomeIndexBoard`、`MagazineHome`、`PuzzleHome` 三处，各自只读 `nasConfigured`，只改 `nasText` 这三处仍会误报。现新增 `NextNASLinkState`（未配置/待检测/在线/待复核/离线）与唯一判定源 `NextAppModel.nasHealth`（最近一次 `/health` 结果，不持久化：重启后宁可「待检测」），在线结论 **10 分钟 TTL**，过期降级「待复核」；每处状态都带最近检测时间。`HomeSnapshot` 删除 `nasConfigured/nasSyncedAt`，五套主题与设置页统一读 `nasState`，色值走同一映射。`nasSyncedAt` 只保留「账本同步时间」语义，不再参与在线判定。
- **连通性检查不再搬账本（本轮）**：「测试连接」原先 = `/health` + `readStatus`（读整份账本），首页一检测就把账本顺隧道传一遍。现 `/health` 只做连通性；需要修订号时走 `?meta=1`（服务端 `get_real_meta`：`SELECT revision, (body IS NOT NULL)`，正文不上线）。自动上传、手动上传、旧账本迁移的修订核对全部改走 meta，**账本正文只在真正下载/上传时才传**；首页自动检测 45 秒节流。
- **图表：MA250 独立配色 + 缩放上限 + 手势命中区 + 横屏（本轮，回应「看不清、放大不够」）**：东方主题里 `secondary`（MA250 用色）与 `chartViolet`（MA60）是同一 hex `0x7C5CE0`，两条线完全同色——新增令牌 `chartLong` 覆盖五套主题并替换图例/绘制线/图层按钮三处。缩放上限由固定 8 倍改为按「一屏至少留 20 根」反推（`clampZoom`），捏合/无障碍放大缩小/按钮/恢复保存值四处统一钳制；左轴 26pt 死区取消，从价格刻度按下也能拖出十字线；`chartHeight` 按 `verticalSizeClass` 适配横屏，避免副图与图例被顶出屏幕。
- **NAS 不再为 4 只 demo ETF 常驻打上游（本轮）**：`DEFAULT_CODES` 原被无条件并进 `tracked()`，服务开着就每 30 分钟为 4 只 demo ETF 打一次日 K、盘中每分钟拉分时、每天查分红，全是白烧的请求。改为 `GUANPAN_ARCHIVE_DEMO` 按需开启（默认空），采集集合只来自 track 登记、真实持仓、已归档代码；空集合时三个线程显示 `idle` +「还没有需要归档的标的」。
- **新增 `GET /v1/diagnose` 出网自检（本轮）**：把「没外网 / 时钟不准 / DNS-IPv6 黑洞」三种假设变成一次可实测的请求——逐项探测三个行情域名 + 公网对照（registry/baidu），记录 IPv4/IPv6 分别解析、TCP:443、TLS 证书、延迟；时钟用上游响应头 `Date` 反推偏差（>300s 或 `certificate_verify_failed` 即判时钟问题，且**优先于「没外网」判定**，否则会跑偏）。本地实跑已验证（skew 1s、结论 ok）。

- **CI 编译通过 → r32 交付（本轮，run 40083895049 / sha b3a42962）**：Build job 13 个 step 全 success（`Core logic tests`、`Build unsigned device app`、`Package unsigned IPA`、`UI navigation and gesture tests`、`Upload IPA`），据此确认本轮 NAS 状态机、`?meta=1`、`chartLong`、缩放钳制、横屏适配、`diagnose.py` 均**编译并通过测试**。IPA 实测：`com.guanpan.advisor.ios` 3.6.0 (build 25)、`MinimumOSVersion 17.0`、Mach-O 12,695,984 B、可执行位 0755、6,113,810 B、`sha256 6caca088…94d3`。同时纠偏 `README-NAS.md`（旧文案仍在写 NAS 调 DeepSeek/网格候选，端点早已 410），重写为纯数据仓库口径 + `/v1/diagnose` 自查表 + 接口表。旧 r31/r29 产物与旧 workflow run 已清理，只留最新。

- **下一步**：D4 已由 CI（`Core logic tests` + `Theme screenshots`）翻 ✅，仅剩圆环观感需人眼看图；J7 组件命名归拢（低风险，随时可做）；B1 等 ⚠️ 项需真机/NAS 实环境；详细续做状态见仓库根 `CONTINUATION.md`。

## 新增模块 116–145：跨市场先行信号与盘中假设验证（2026-10-24 追加）

> 判据同前：**代码 + 数据链 + 测试 + 异常处理** 四件齐才允许离开 🟠。本表只记录本轮真实状态，
> 不因为「新建了 CrossMarket.swift」而把整块标成已完成。

| # | 需求 | Status | Implementation | Test | Remaining |
|---|---|---|---|---|---|
| 116 | 跨市场引擎骨架 | ✅ | `CrossMarket.swift`（枚举/时段/对齐/结论结构）+ **数据底座已通**：`server/crossmarket.py` 每分钟采日经/KOSPI/恒生科技/纳指快照入库（`cross_market_samples`），`/v1/cross/series`、`/v1/cross/availability` 出数；手机 `CrossMarketFeed.swift` 解析 + `NextReplayAssembler` 装配逐日回放素材 | `NextCrossMarketTests` 时区/时段 15 项；`tests/test_crossmarket.py` 17 项（解析/丢弃过期源/按市场时区切日/库读写/2 个 HTTP 端点）；`NextCrossMarketFeedTests` 归档解析 4 项 | — |
| 117 | Lead-Lag 统计（多窗口、胜率、中位、最大不利、稳定度） | 🟡 | `NextLeadLagEngine`：0/5/10/15/30/45/60/90 分钟窗口，相关系数+同向率+中位+最大不利+前后半段稳定度；**真实数据入口已就绪**（`NextReplayAssembler` 产出「前收取上一交易日、海外点只取 A股 收盘前」的逐日素材） | 构造真实滞后关系→识别；无关序列→拒绝；样本不足→拒绝；装配器 3 项（前收、未来数据排除、缺前收跳过） | 真要出统计还得等归档攒够 30 个交易日；当前 `/v1/cross/availability` 会如实报「不足 30 天 → 暂无稳定领先关系」 |
| 118 | 每只持仓的外部指标篮子 | 🟠 | 结构未落地 | — | 按标的维护 lead profile，权重来源于 117 的统计 |
| 119 | A股午休信息差 | ✅ | `NextLunchBreakEngine`：11:30 快照与 12:50 快照的差；12:50 之后数据禁止进入。**采样已自动落库**：cross-market 线程 08:00–16:10 北京时间每分钟一采，11:30 与 12:50 两个检查点必然覆盖 | 只用检查点前数据、shock=+0.7、晚于 12:50 的点不参与；服务端「源时间过期即丢弃」用例保证收盘后不会伪造横盘 | — |
| 120 | 午后反应统计（13:00→13:05/15/30/14:00/收盘） | 🟡 | `NextAfternoonReactionEngine`：5 个检查点，逐点算上涨比例/中位/均值/最大不利；<20 天或偏离 50% 不足 10 个百分点一律判「暂无稳定规律」 | `NextCrossMarketFeedTests`：5 天样本→暂无规律；25 天一致上涨→识别；24 天涨跌各半→明确判为「与随机无异」 | 接真实会话批次（需 ≥20 天午后分时）并接到界面 |

| 121 | 条件化领先（市场状态分组） | 🟠 | 未实现 | — | 需 117 统计 + 状态标签 |
| 122 | 跨市场背离检测 | 🟡 | `NextDivergenceDetector`：需「海外明显动且本地未动」双门槛 | 2% vs 0.1% → 补涨观察；0.25% → 不算背离 | 接入实时与持仓映射 |
| 123 | 隔夜信息消化 | 🟡 | `NextAbsorptionEngine`：已计价比例 + 结论话术 | 隔夜 -2% / 低开 -2.3% → 已计价 | 接真实隔夜美股与开盘价 |
| 124 | ETF 溢折价执行过滤 | 🟡 | `NextETFExecution`：溢价/价差双阈值，超限禁止追价 | 溢价 2% 拦截、价差 1% 拦截、正常放行 | 与盘口/成交量联动 |
| 125 | 汇率上下文 | 🟠 | 未实现 | — | USD/CNH、USD/JPY 接入 |
| 126 | 开盘信息消化 9:30–10:00 | 🟠 | 未实现 | — | 依赖开盘分钟数据 |
| 127 | 尾盘→次日观察计划 | 🟠 | 未实现 | — | 14:30 后重组上下文 |
| 128 | 假设→确认→执行 | 🟡 | `NextCrossHypothesis` + `NextHypothesisJudge`：海外证据不能直接转 confirmed，必须 A股站上 VWAP/低点抬高/量能恢复 | 未确认→rejected 且 allowsPlan=false；确认→confirmed | 接实时循环与决策记忆 |
| 129 | 信号进入做T/网格 | 🟠 | 未接入（计划生成仍走原链路） | — | 在 scan 前注入 crossMarket 结论并影响策略；前置条件 117 还没在真实 30 日数据上出结论 |
| 130 | 跨市场进入统一 DecisionContext | 🟡 | `NextDecisionContext` 新增 `crossMarketLines` + 提示词新增「【跨市场（日韩/港股/美股）】」段与硬约束第 8 条（无稳定领先关系时禁止据此推荐）；`makeDecisionContext` 从 `refreshCrossMarket()` 的 NAS 归档生成说明行；`NextNASService.readCrossMarketSeries` 走 `/v1/cross/series` | `NextCrossMarketFeedTests`：日韩不足 30 天必须输出「暂无稳定领先关系 + 不得据此产生午后假设」；两端都够 30 天时不再出现该禁止语 | 实时信号对象（`NextCrossHypothesis`/背离/执行过滤）还没进上下文——那属于 128/129 的实时循环 |
| 131 | 每只 ETF 的领先来源排名 | 🟠 | 未实现 | — | 由 117 的窗口统计聚合排序 |
| 132 | 时间段画像 | 🟠 | 未实现 | — | 按时段切分 117 |
| 133 | 滚动有效性（20/60/120 日） | 🟠 | 未实现 | — | 分段统计 + 失效降权 |
| 134 | 防伪相关 | 🟡 | 门槛：样本≥30、|相关|≥0.20、稳定度≥0.6、相邻窗口不得孤峰 | 无关序列必须输出「暂无稳定领先关系」 | 多重比较校正可继续加强 |
| 135 | 禁止未来数据 | ✅ | `NextCrossMarketAlignment`：领先 t 只能配 t 之后的跟随观测；午休用 12:50 截止 | 12:55 的数据不影响 shock | — |
| 136 | 跨市场时间统一 | ✅ | 内部 UTC、时区交给 `TimeZone`，展示用北京时间 | 冬令时 14:31 UTC / 夏令时 13:31 UTC 开盘判定 | — |
| 137 | 市场日历 | 🟡 | `NextMarketCalendar`：周末/时段/午休/节假日注入点 | 节假日注入后返回 holiday | 节假日表需按交易所公告注入（不内置过期表） |
| 138 | 数据新鲜度 | 🟡 | `NextCrossMarketFreshness`：来源/时间/年龄/市场状态，过期或休市权重归零 | 45 分钟 → usable=false、weight=0；休市 → 提示 | 接真实数据源时间戳 |
| 139 | AI 最终表达 | 🟠 | 文案片段已在各结构 note 中 | — | 接入手机 AI 输出层 |
| 140 | 首页「跨市场脉搏」 | 🟠 | 未实现 | — | UI |
| 141 | 持仓详情「外部市场影响」 | 🟠 | 未实现 | — | UI + 星标来源 |
| 142 | 与画像结合（打扰门槛） | 🟠 | 未实现 | — | 依赖 131 |
| 143 | 与决策记忆结合 | 🟠 | 未实现 | — | 记录假设→确认→执行→结果 |
| 144 | 信号结果复盘 | 🟠 | 未实现 | — | 正确取消也要记成功 |
| 145 | 完整推理链 | 🟠 | 各环节零件已分散具备 | — | 需在 scan/DecisionContext 串起来 |
| 146 | 历史回放验证器（研究工具，非模拟账户） | 🟡 | `CrossMarketReplay.swift`：选某日 → 12:50 知识截断（`NextReplayCutoffView` 在类型上就拿不到之后的数据）→ 生成午后假设 → 放出 13:00 后真实行情 → 判定 confirmed / failed / rejected；可连续回放 N 日并统计确认率、确认后上涨比例、午后均值/中位/最大不利、前后两段稳定度；样本 <30 或确认率 <50% 或确认后上涨 <50% 一律输出「没有稳定领先关系」。**数据入口已接**：`NextReplayAssembler` 把「A股 ETF 分钟线 + NAS 海外归档」装成逐日素材 | `NextCrossMarketReplayTests` 6 项：①同一日 12:50 前相同、午后相反 → 假设输入完全一致、仅结果不同；②午后暴涨不能让「上午已涨」的日子补出假设；③60 日确认率 33% → 明确否定；④5 日样本 → 提示少于 30；⑤真实成立 → 识别为 evidence；⑥无海外数据 → 当日不产生假设。另有装配器 3 项：前收取上一交易日、A股收盘后的海外点禁止进入、缺前收则跳过当日 | 回放结果页面（研究工具入口）尚未做；真实回放要等归档攒够 30 个交易日 |

**本轮小结（r33）**：116–145 共 30 项，✅ 4 项（116/119/135/136）、🟡 11 项、🟠 16 项；另加 146 历史回放验证器（🟡：引擎 + 装配器 + 9 条测试已完成，缺研究工具界面与 30 日真实样本）。全表合计 113 行：✅ 84 / 🟡 11 / 🟠 18（🟠 里 16 项属 116–145，另 2 项是旧条目 B1、J7）。
本轮关键变化不是"又写了几个类"，而是**数据链真的通了**：NAS 每分钟把日经/KOSPI/恒生科技/纳指快照落库并做「源时间过期即丢弃」，手机端能把这批数据和 ETF 分钟线装成逐日回放素材，回放器与午后统计都能直接吃真实数据。同时，数据不够 30 天时，决策上下文里会明确写出「暂无稳定领先关系，不得据此产生午后假设」——不是靠自觉，是写死在 `decisionContextNotes()` 与提示词硬约束第 8 条里。
下一步按依赖顺序：140/141（跨市场脉搏与持仓外部影响，把已有数据先展示出来）→ 117 在真实 30 日数据上出第一条结论 → 129 注入策略 → 146 研究工具界面。
