# 观盘 Next · NAS 数据仓库

此包为观盘 NAS 服务（已取代旧 30001 服务）。Compose 项目名为 `guanpan-advisor`，容器监听与 NAS 映射端口均为 `8786`，数据卷为 `guanpan_advisor_data`。

**定位：纯数据仓库。** 只采集与归档日 K、分时、分红事件、新闻；**不跑因子研究、不下判断、不生成 AI 结论**。研究与最终 AI 指导全部在手机端完成——手机 AI 需要 NAS 的历史数据时才按需来取。

## 部署

1. 在 NAS 上新建独立目录，把完整源码包解压进去。不要覆盖旧版目录。
2. 确认端口 `8786` 可用。服务端口变量名为 `GUANPAN_ADVISOR_PORT`，默认 8786。
   - **不需要任何大模型密钥**：NAS 不再调用 DeepSeek（`/v1/ai/*`、`/v1/advisor/*` 均返回 410）。`.env` 里旧的 `DEEPSEEK_API_KEY` 可留可删，填了不起作用。
   - 默认不采集演示标的。需要用演示数据预热时显式设置 `GUANPAN_ARCHIVE_DEMO=159941,563020`。
3. 在新目录运行（服务代码构建进独立镜像，不挂载旧版宿主机源码目录）：

   ```sh
   docker compose -p guanpan-advisor up -d --build
   docker compose -p guanpan-advisor ps
   docker compose -p guanpan-advisor logs --tail=100
   ```

4. 打开 `http://NAS内网地址:8786/health`，确认 `codeVersion` 为本包版本，并核对 `workers` 只有三条采集线程：`daily-archive` / `minute-archive` / `dividend-archive`。网页是 `http://NAS内网地址:8786/`。
5. 首次部署库为空。iOS 设置只保存一个 NAS 地址；填入 `http://NAS内网地址:8786`，由用户主动下载/上传并核对账本。

`update.sh` 只会重建当前目录内名字严格为 `guanpan-advisor` 的 Compose 项目，不会搜索、停止或覆盖其它 Guanpan 容器。升级请先备份 `guanpan_advisor_data`。

## 出网自检（行情 502/503 时先跑这个）

手机与网页只能看到 502/503，看不出是环境问题还是源站问题。这一个请求会把三种常见原因分开：

```sh
curl -s http://NAS内网地址:8786/v1/diagnose | python -m json.tool
# 或进容器直接跑：
docker exec -it <容器名> python diagnose.py
```

看 `verdict.cause`：

| cause | 含义与处理 |
|---|---|
| `clock_skew` | 系统时钟偏差过大（Z4Pro 断电后 RTC 复位常见）。HTTPS 会在握手阶段失败，所有源同时挂。校准时间后重启容器。 |
| `dns_ipv6_blackhole` | 只解析到 IPv6 而后端没有 IPv6 出口。关掉容器/路由的 IPv6 或让 DNS 只返回 A 记录。 |
| `no_egress` | 连公网 registry 也不通：容器整体没有外网出口，检查网关与容器网络。 |
| `market_source_blocked` | 公网通，但三个行情域名全挂：DNS 污染或源站域名变更。 |
| `ok` | 外网/DNS/TLS/时钟均正常，问题在源站或解析漂移，稍后重试。 |

自检只读、不写库；每项探测都有超时上限。

## 对外接口

| 接口 | 用途 |
|---|---|
| `GET /health` | 服务标识、`codeVersion`、三条采集线程的心跳与状态 |
| `GET /v1/diagnose` | 出网自检（DNS/ TCP / TLS / 时钟偏差） |
| `GET /v1/market/quotes?codes=` | 行情（1–60 个代码）；失败返回 502，不回空数组冒充 |
| `GET /v1/market/{daily,minute,kline}/{code}` | 日 K / 分时 / K 线；有缓存则回落缓存 |
| `GET /v1/market/dividends/{code}` | 分红事件（已核实与推算分开标注） |
| `GET /v1/news/{code}` | 新闻标题（Google News RSS） |
| `GET /v1/research/{code}` | 分时统计；`factors`/`ai` **恒为 null**（研究已归手机端），`researchOwner: mobile` |
| `GET /v1/real/books/main` | 真实账本正文 |
| `GET /v1/real/books/main?meta=1` | **只回 `revision` 与 `hasBook`，不带正文**。手机做连通性检查与上传前修订核对走这个 |
| `POST /v1/real/books/main` | 上传账本（需 `mode: manual-confirmed` + `expectedRevision` 防覆盖） |
| `/v1/ai/*`、`/v1/advisor/*`、`/v1/backtests/*`、`/v1/simulations/*` | 已退役，恒返回 410 |

## 未完成 / 部署前需知

- 服务没有应用登录认证，只能放在受信任 LAN/VPN；不要直接暴露公网。
- NAS 需能访问行情源与 Google News RSS。**用 `/v1/diagnose` 先确认**，别靠猜。
- 采集默认按需：只有手机 `/v1/market/track` 登记过、账本真实持仓、或已归档过的代码才会持续采集；没有标的时 `/health` 显示 `idle`。
- 分时数据从服务实际运行后的采集开始累积，不会补造旧历史。
- 交易规则使用 iOS 保存且带来源、核验时间的证券规则；未核实规则、未知 T+0/T+1、缺少行情或可卖份额时不生成具体方案。
- 本地策略是透明的历史筛选启发式，不是经验证的预测模型。任何限价参考都不是券商订单。
