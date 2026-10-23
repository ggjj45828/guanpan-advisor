# 观盘顾问（Guanpan Pro Next）功能验收矩阵 — 重建版

> 重建日期：2026-10-23｜基于 `b46fda7`（远端 `5f9e75648d`）。
> 旧版（68 项测试 / A–H 数字孪生）已废弃：数字孪生接口已下线，模拟账户已停用，测试基数已变为 **NAS 100 项** + iOS 3 套测试文件。
> 本表只认**可复核证据**，不认"源码存在 / 文件存在 / 算法文件存在"。

## 状态定义（五档）

| 标记 | 含义 | 判定门槛 |
|---|---|---|
| ✅ 本环境实测 | 在当前沙箱实际跑通并产出真实数据 | 实跑脚本 / 实跑服务 / 实跑测试通过 |
| 🟡 已实现待验证 | 代码逻辑完整、接线上，但当前环境无法编译或无法截图/无法真机 | 代码审阅 + 远端 CI 状态 |
| 🟠 已知缺口 | 功能有但依赖缺失数据/接口，或仅部分接通 | 明确列出缺口与修复路径 |
| ❌ 未实现 | 尚未编码 | — |
| ⚠️ 外部依赖 | 功能本身完成，但依赖外部密钥/网络/真机 | 注明依赖项 |

## A. 九项核心功能

| # | 核心功能 | 实现位置 | 状态 | 证据 |
|---|---|---|---|---|
| ① | 单一真实账户（无模拟账户） | `NextCore.swift` NextPosition/NextBook；`grid.py` 纯档位计划 | ✅ | 模拟账户相关代码已下线；`test_grid_plan_only.py` 验证网格不再产生虚拟资金/盈亏 |
| ② | NAS 长期分时统计 | `server/research.py:minute_stats`；`NextAppModel.swift:refreshNASResearch` | ✅ | 本环境实跑：`fetch_minute("600519")` 取 267 条真实分钟 → `minute_stats` 算出 收盘-VWAP 0.276% / 振幅中位 2.303% / 往返中位 13 / 支撑 1311.84 / 压力 1342.40（2026-10-23 真实数据）；NAS 测试 `test_research.py` 覆盖 |
| ③ | 市场状态识别 | `NextAIGuide.swift:157 NextMarketStateEngine.classify` | 🟡 | 引擎真实计算：基于 return20 / priceVsMA20 / 当日涨跌 / RSI·MA 结构·量比，含"日 K<20 根拒判"门槛；分 anomalous/trendingUp/trendingDown/narrowRange/wideRange。**iOS 未编译验证** |
| ④ | 做 T 指导 | `NextAIGuide.swift NextTradeTPlanner`；`NextCandidatePlans.swift` | 🟡 | 计划经 `NextPlanCaps.maxTUnits` 硬压份额（写入 evidence）；未编译验证 |
| ⑤ | 智能网格（plan-only） | `server/grid.py`；`ios/NextAIGuide.swift NextGridPlanner` | ✅ | `test_grid_plan_only.py` 验证：`grid.tick()` 只记 touch，不改现金/持仓/收益；档数/资金被 `NextPlanCaps.maxGridTiers/maxGridCash` 硬封顶（写入 reasons） |
| ⑥ | 动态投资者画像 + 硬约束 | `ios/InvestorProfile.swift`；`NextAIGuide.swift NextPlanCaps.make` | 🟡 | `NextPlanCaps` 把画像阈值真正压入份额与档数计算（非提示）；`NextChainScenarioTests` 覆盖"画像只改优先级"场景。未编译验证 |
| ⑦ | AI 决策记忆 | `ios/NextDecisionMemory.swift`；`NextAppModel.swift:628 updateDecisionMemory`；`DecisionMemoryView.swift` | 🟡 | 端到端接线已读码确认：`records(from:…research:news:profile:)` 捕获 报价/持仓/NAS研究/NAS新闻/画像 → 持久化 `decision-memory-v1.json`（179/267/128 行）→ `confirmDecisionFilled`(653) 写成交、`markDecisionSkipped`(664)；含 merge/expire/review。12 项单测存在，未编译 |
| ⑧ | 手机与 NAS 真正协同 | `ios/NASService.swift fetchResearch/fetchNews`；`server/app.py /v1/research /v1/news` | 🟡 | 手机端刷新循环实读 NAS 研究 + 新闻；服务端接口本环境实测可达（见 B）。需真机+真 NAS 联调 |
| ⑨ | 新闻→持仓→计划 | `ios/NextNewsImpact.swift`；`server/advisor.py fetch_headlines`；`market.html` 新闻面板 | 🟠→🟡 | 引擎 + 接口 + UI + 测试齐备；**缺口：行业词映射无数据源**（见 F-1） |

## B. NAS / 服务端（本环境可实测）

| 模块 | 状态 | 证据 |
|---|---|---|
| 单元测试 | ✅ | `python -m unittest` = **100 passed**（venv python 带 tzdata） |
| 真实行情源（日 K / 报价） | ✅ | 本环境启动服务（端口 8799）实测：`/v1/market/daily/600519` 返回腾讯真实日 K（640 根，2024-03-04 起）；`/v1/market/quotes?codes=600519` 返回 `{贵州茅台, 1335.00, source:Tencent qt.gtimg.cn}` |
| 真实分钟源 | ✅ | `workers.fetch_minute("600519")` 取 267 条真实分钟（09:30→15:30） |
| 研究统计缓存 | ✅ | `app.py /v1/research/<code>` 按最新分钟戳缓存（`put_research_stats`）；本环境实证计算 |
| 新闻接口 | ⚠️ | `/v1/news/<code>` 调 `advisor.fetch_headlines`（Google News RSS）。沙箱无法连通 Google → 优雅降级 `state:unavailable`，**不伪造标题**（无 Mock）；生产 NAS 可正常拉取 |
| DeepSeek AI | ⚠️ | `/health` 显示 `aiProvider: missing_key`：沙箱未配置 `DEEPSEEK_API_KEY`，代码已优雅处理；真实 key 待联调 |
| `/health` 与 worker 状态 | ✅ | 实测返回真实 worker 状态（daily-archive 4/4、factor-research ok、minute-archive idle 收盘时段） |

## C. Web 网页

| 页面/功能 | 状态 | 证据 |
|---|---|---|
| `market.html` 长期分时统计面板 | ✅ | JS 语法 `node --check` 通过；面板 `renderMinuteStats` 由真实 `/v1/research` 渲染 |
| `market.html` 新闻与计划影响面板 | ✅ | JS 语法通过；`loadNews`+`newsLevel` 词表；无外部脚本报错 |
| 账本保存冲突保护 | ✅ | `test_domain.py` 服务端测试覆盖 |
| 五套主题首页/画像页 | ✅ | run `39935846686` 截图 8 张已下载核验（editorial 加 AI 头像 + 插画人物后全部真实渲染） |

## D. iOS 质量（编译 / 测试 / 主题截图）

| 项目 | 状态 | 证据 |
|---|---|---|
| iOS App target 编译（含 ThemeHome 新视觉） | ✅ | run `39957249993`（及 `39935846686`）：`Theme screenshots` 作业 `xcodebuild build`（Debug/模拟器）通过并产出 8 张截图 |
| `swift test`（core 包，76 项） | ✅ | run `39957249993`：`Core logic tests` 步骤 exit 0，日志 76/76 全跑、**0 failure markers**。曾有的 4 项失败实为 3 个生产 bug（见 F-2），已修 |
| 五套主题模拟器截图 | ✅ | run `39957249993` artifact `guanpan-theme-screenshots`（1–8 全部下载核验） |
| editorial 主题：AI 顾问头像 | ✅ | `1_editorial.png`：问候区右上角金色渐变圆头像 + 「AI 今日指导」卡头像角标，均真实渲染 |
| editorial 主题：装饰插画人物 | ✅ | `1_editorial.png`：「真实持仓」上方背景可见低透明度人形轮廓（头部+裙身），融入暖色背景 |
| XCUITest 实机 | ❌/⏳ | 当前环境无 xcodebuild/模拟器，依赖远端 CI 与真机 |

## E. 本环境已复核的真实证据（可复现）

1. **NAS 测试 100 通过**：`cd server && <venv>/python -m unittest discover -s tests -q` → `Ran 100 tests ... OK`。
2. **真实数据链路脚本** `server/_verify_realdata.py`：抓真实日 K（640 根）+ 真实当日分钟（267 条）+ 真实报价（茅台 1335.00）+ `research.minute_stats` 真实计算 + 新闻优雅降级。输出全部为真实上游数字，无 Mock。
3. **部署态服务实测**：启动 `app.py`（端口 8799），`/health`、`/v1/market/daily/600519`、`/v1/market/quotes` 均返回真实数据。
4. **市场状态引擎读码确认**：`NextMarketStateEngine.classify` 真算 return20/priceVsMA20/量比，含数据不足拒判门槛。
5. **决策记忆端到端读码确认**：快照捕获 报价/持仓/NAS研究/NAS新闻/画像，持久化 + 成交确认 + 复盘。

## F. 已知 🟠 / ❌ 与修复路径

| 编号 | 项目 | 状态 | 缺口 / 修复路径 |
|---|---|---|---|
| F-1 | 新闻行业词映射 | 🟠 | `NextNewsImpactEngine.belongs(_:code:name:industryWords:)` 支持行业词，但 `NextCandidatePlans.scan` 未注入（持仓无行业字段、无分类数据源）。当前按 name/code 精确匹配已可用。**修复**：接入行业分类（NAS 持仓 payload 增加 `industry` 字段 + 端到端解码），再在 `evaluate` 透传 `industryWords`。非 Mock，不硬编造假表。 |
| F-2 | ~~iOS core 测试 4 项失败~~ | ✅ 已修（run `39957249993`） | 4 项失败实为 3 个**生产 bug**（非测试问题）：①`NextGridPlanner.plan` 把 `minuteSampleCount` 硬编码 0，网格永远出不了 ready 计划（⑤智能网格在生产同样失效）→ 给 `NextDataConfidence.assess` 加 `intradayRequired` 参数（默认 true），网格按「日K≥60+行情新鲜」评估；②`belongs` 漏全名命中（"纳指ETF"去 ETF 后仅 2 字被 ≥3 门槛挡掉）→ 加全名 contains 匹配；③停牌 `.pauseGrid` 只收网格不收已 ready 做T → 停牌=全场暂停，同时撤回做T与网格。未弱化任何测试断言。 |
| F-3 | 五套主题信息密度 | 🟡→部分✅ | run `39935846686` 8 张截图已下载；editorial（含新头像/插画）已核验，其余主题待逐页与 `_ref/*.png` 对比补差距。 |
| F-4 | 真机/真 NAS 联调 | ❌（环境缺） | DeepSeek key、APNs、真机签名需用户环境演练。 |
| F-5 | 新闻生产可达性 | ⚠️ | Google News RSS 在 CN 网络受限；生产 NAS 需确认出口可达，否则降级为 unavailable（已正确实现）。 |

## 结论

- **本环境可验证项已全部实测通过**：NAS 100 测试、真实行情/分钟/报价/研究链路、网页 JS、市场状态与决策记忆的接线逻辑。
- **iOS 全绿**（run `39957249993`）：App target 编译 + `swift test` 76 项全过（0 failure）+ 五套主题截图 8 张已下载核验；editorial 主题新增 AI 顾问头像 + 装饰插画人物（用户「1和3」）截图确认真实渲染。
- **当前卡点**：F-1 新闻行业词真实注入、F-4 真机/真 NAS 联调（DeepSeek key/APNs/签名需用户环境）、F-3 其余主题逐页密度对比、F-5 新闻生产可达性（CN 网络）。F-2 已关闭。
- 不把"源码存在 / 文件存在 / 算法文件存在"当作完成。以上状态均附可复核证据。
