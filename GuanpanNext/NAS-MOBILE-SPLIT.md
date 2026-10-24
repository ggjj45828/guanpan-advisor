# NAS ↔ 手机 数据分工与穿透流量平衡（2026-10-24 定）

> 核心矛盾：**NAS 拉来的数据若要同步给手机，就走手机↔NAS 的穿透隧道，消耗穿透流量。**
> 因此平衡点不是“谁拉”，而是“**谁的数据必须过隧道**”。
> 原则：**实时归手机直连（零穿透）；NAS 只做归档，不主动推手机；研究全部在手机端。**

> **定位（同日二次定调）**：NAS **不需要后台研究**了。NAS ＝ 纯数据仓库（日 K / 分时 / 分红 / 新闻的采集与归档）。
> 研究、因子、判断、最终 AI 指导**全部在手机端**；只有当手机 AI 需要 NAS 上的历史数据做研究时，才向 NAS 取数。
> **同步就是正常的数据同步，跟隧道没关系**——不要为了“谁算”而额外造穿透流量。

## 1. 分工表

| 数据 | 谁来拉 | 是否过穿透隧道 | 说明 |
|---|---|---|---|
| 实时报价（价/涨跌/盘口） | **手机直连**（腾讯→东财→新浪） | **否** | `refreshQuotes` 已改为**直连优先**；NAS 仅直连全失败时兜底 |
| IOPV | **手机直连**（腾讯第 78 字段） | **否** | `NextTencentQuoteParser` 已解析 ETF IOPV；不依赖 NAS，省隧道 |
| 当日分时图 | **手机直连**（`fetchIntraday`） | **否** | 图表本地算，秒级刷新不出隧道 |
| 日 K（展示） | 直连优先（腾讯/东财，约 640 日足够看图） | 否（必要时） | 需要 >640 天超长历史时，才按需向 NAS 拉（低频） |
| 分时归档（分钟库） | **NAS**（`minute_loop`） | 否（NAS 本地） | 纯归档；为手机按需取数留存长期分时；**NAS 不把它推给手机** |
| 日 K 归档（1000 天） | **NAS**（`daily_loop` + `put_daily` 合并） | 否（NAS 本地） | 上游单次约 640，NAS 按日期合并、从不裁剪，日更累积到 1000+ |
| 分红事件 / 新闻 | **NAS**（`dividend_loop` / 新闻入口） | 否（NAS 本地） | **数据采集，不是研究**；手机按需取，不在 NAS 上做判断 |
| 因子 / 研究 / AI 结论 | **手机端** | — | NAS **已无**后台研究循环；`/v1/research/*` 只是被动按需计算归档统计 |
| 账本同步 | **手机 → NAS**（上行） | 是（**小包、低频、必要**） | 唯一常规穿透流量；只传账本 JSON，不传行情 |

## 2. 已落地的代码改动

1. **`server/workers.py` · `minute_loop`**：删掉每分钟“额外拉实时报价”（`quote_fetcher`）——原先只为给最新分时点挂 IOPV，每分钟每只代码多拉一次报价，是穿透流量大头。**分时归档（`minute_fetcher`）保留**（用户明确：分时数据很重要）。`attach_quote_iopv` 作为纯工具函数保留（供测试/未来复用）。
2. **`server/workers.py` · `start_workers`**：移除未再使用的 `quote_fetcher` 形参及 `fetch_tencent_quotes` 导入。
3. **`server/market.py`**：日 K 拉取上限 640 → 1000（腾讯 param / 东财 lmt）；配合 `domain.put_daily` 的“按日期合并、从不裁剪”，NAS 可累积保存 1000+ 天日 K。
4. **`ios/Sources/NextAppModel.swift` · `refreshQuotes`**：改为**手机直连优先**（腾讯首源自带 IOPV），NAS 仅在直连全失败时兜底。实时行情不再经 NAS 隧道。
5. **`ios/Sources/NextAppModel.swift` · `refreshDaily`**：改为**直连优先**，NAS 仅兜底/补超长历史。
6. **`server/workers.py`**：**删除 `research_loop` 与 `research_factors`**，`start_workers` 线程只剩 `daily-archive` / `minute-archive` / `dividend-archive` 三个采集线程。NAS 不再产出因子与 AI 结论。
7. **`server/app.py` · `/v1/research/{code}`**：`factors` / `ai` 恒返回 `null`（键保留以兼容旧客户端解码），并新增 `researchOwner: "mobile"`。历史上写入的 `factors-*` / `deepseek-*` 残留记录**不再回传**，避免手机读到与本机规则不一致的过期结论。接口本身保留，作为“手机来问才现算归档统计”的被动通道。
8. **`server/research.py`**：模块头注明定位＝**被动按需计算**（把分时归档换成窗口统计），不是后台研究员。

## 3. 验收要点（Mac/真机轮次）

- **IOPV 不丢**：手机直连腾讯 ETF 报价第 78 字段 → 图表 IOPV 线/溢价/分红按 IOPV 计息均可用（`NextCore.swift:301`）。
- **穿透流量下降**：手机前台刷新只走“手机↔上游”，不再“手机↔NAS↔上游”；NAS 后台零实时报价拉取。
- **NAS 只归档**：分时、日 K（累积到 1000+）、分红、新闻；`worker_status` 里**不再出现 `factor-research`**。
- **直连失败仍可用**：直连全挂时回退 NAS 兜底（异常路径，非常态）。
- **研究不落 NAS**：`/v1/research/{code}` 返回 `factors=null`、`ai=null`，手机端因子/AI 结论均由本机规则生成。

## 4. 后续说明（需 Mac 编译/真机验证）

- `refreshDaily` 已改为**直连优先、NAS 仅兜底/补超长历史**——日 K 图表不再让 NAS 数据经隧道下行（此前 NAS 优先）。
- 分钟历史（指定某日）仍走 NAS `fetchMinute`（按需、低频），属研究型拉取，用户主动查看某日分时才发生，可接受。
- `put_research` / `get_research` / `get_research_stats` 保留在 `domain.py`：前者仅剩测试使用与历史数据读取，`get_research_stats` 是 `/v1/research` 的按需缓存，不是研究循环。
