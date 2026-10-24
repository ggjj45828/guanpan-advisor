"""Independent NAS service and local web console for Guanpan Pro Next.

The service intentionally has no application passphrase.  It is designed for a
trusted home LAN / VPN; the iOS app and the web console make real-book writes
explicit and revision-checked.
"""
import json
import os
import uuid
from zoneinfo import ZoneInfo
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from datetime import datetime, timezone
from urllib.parse import parse_qs, urlparse
import news
from domain import (Conflict, InvalidData, NextDatabase, convert_legacy_web_book,
                     strict_iso_date)
from market import (fetch_indices, fetch_tencent_quotes, fetch_tencent_daily, fetch_dividend_events, fetch_kline,
                    fetch_quotes, fetch_daily,
                    symbol_for, DIVIDEND_RULES_VERSION as dividend_rules_version)
from workers import start_workers
import research
import diagnose
import crossmarket

WEB_ROOT = Path(__file__).with_name("web")


def code_version():
    """部署代码版本号，用来确认“覆盖文件 + 重启”是否真的生效。

    更新后 /health 里的 codeVersion 必须变成新包里的值；没变就说明文件没覆盖到
    容器实际挂载的目录，或者容器没重启（Python 已加载的模块不会自动重载）。
    """
    try:
        return Path(__file__).with_name("VERSION").read_text(encoding="utf-8").strip() or "unknown"
    except OSError:
        return "unknown"


def code_source():
    """这次跑起来用的是宿主机同步进来的代码，还是镜像里 bake 进去的旧代码。

    start.sh 启动时写 .code-source：挂载源里没有 app.py 时会**静默退回镜像内置版本**，
    服务照常起来、心跳也正常，于是「部署没生效」这件事从外面完全看不出来
    （表现就是 /health 没有 codeVersion、模型名还是旧的、新增功能不出现）。
    把这个来源写进 /health，一眼就能判定：
      "host <路径>"  = 用的是你解压进去的新代码（正常）
      "image ..."    = 挂载没落到位，跑的还是镜像里的旧代码（去查 GUANPAN_CODE_DIR）
    """
    try:
        return Path(__file__).with_name(".code-source").read_text(encoding="utf-8").strip() or "unknown"
    except OSError:
        return "unknown"


def make_handler(database, market_fetcher=fetch_quotes, daily_fetcher=fetch_daily, dividend_fetcher=fetch_dividend_events):
    class Handler(BaseHTTPRequestHandler):
        server_version = "GuanpanAdvisor/1"

        def log_message(self, format, *args):
            # Personal book data and query strings are deliberately not logged.
            pass

        def reply(self, status, value):
            body = json.dumps(value, ensure_ascii=False, default=float).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers(); self.wfile.write(body)

        def html(self, name="index.html"):
            body = (WEB_ROOT / name).read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers(); self.wfile.write(body)

        def do_GET(self):
            parsed = urlparse(self.path); path = parsed.path
            if path == "/v1/advisor/inventory":
                # NAS 顾问入口已停用：NAS 只提供长期数据研究、机会扫描和新闻；
                # 最终 AI 指导由手机端统一生成（unifiedAIBlock）。
                return self.reply(410, {"error": "NAS 顾问入口已停用；NAS 只提供长期数据研究，最终 AI 指导由手机端统一生成。",
                                        "code": "nas_advisor_retired"})
            if path in ("/", "/index.html"):
                return self.html()
            if path in ("/market", "/market.html"):
                return self.html("market.html")
            if path in ("/classic", "/classic.html"):
                # 旧版实验页面已停用：它暴露过虚拟网格成交，且有一个把模拟结果
                # 写回真实账本的控件。文件仅留作迁移参考，不再作为产品 UI 提供。
                return self.reply(410, {"error": "旧版实验页面已停用；请使用真实持仓顾问页面。",
                                        "code": "legacy_classic_removed"})
            if path == "/health":
                return self.reply(200, {"service": "guanpan-advisor", "schemaVersion": 1, "authentication": "none", "web": True,
                                        "codeVersion": code_version(), "codeSource": code_source(),
                                        "workers": database.worker_health()})
            if path == "/v1/diagnose":
                # 出网自检：把「没外网 / 时钟不准 / DNS-IPv6 黑洞」三种原因分开。
                # 只读、不写库；探测有超时上限，不会拖死服务。
                try:
                    return self.reply(200, diagnose.collect())
                except Exception as error:  # noqa: BLE001 - 自检本身失败也要给出原因
                    return self.reply(503, {"error": f"diagnose failed: {type(error).__name__}: {error}"})
            if path == "/v1/ai/verify":
                # NAS 不再代理任何大模型：手机端 API key 只保存在本机钥匙串，
                # 连通性在手机上直接验证。NAS 只是数据仓库，不是研究员、也不是第二个顾问。
                return self.reply(410, {"error": "NAS AI 辅助已停用；AI key 仅保存在手机本地，请在手机设置中验证。",
                                        "code": "nas_ai_retired"})
            if path == "/api/data":
                try: return self.reply(200, {"ok": True, **database.get_legacy_inbox("main")})
                except InvalidData as error: return self.reply(400, {"error": str(error)})
            if path == "/api/web/data":
                # 旧版网页的整包数据（localStorage 的替代品）。只读，不会动真实账本。
                try: return self.reply(200, {"ok": True, **database.get_web_snapshot("classic")})
                except InvalidData as error: return self.reply(400, {"error": str(error)})
            if path == "/v1/legacy/books/main":
                try:
                    legacy = database.get_legacy_inbox("main")
                    if legacy["data"] is None:
                        return self.reply(200, {"revision": legacy["revision"], "book": None, "summary": None})
                    converted = convert_legacy_web_book(legacy["data"])
                    return self.reply(200, {"revision": legacy["revision"], **converted})
                except InvalidData as error: return self.reply(422, {"error": str(error), "revision": database.get_legacy_inbox("main")["revision"]})
            if path == "/v1/cross/availability":
                # 跨市场数据「够不够验证领先关系」。手机端据此决定显示结论还是
                # 显示「暂无稳定领先关系」——这条判定必须由数据说话，不能由愿望说话。
                try:
                    rows = database.get_cross_samples()
                    return self.reply(200, crossmarket.availability(rows))
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            if path == "/v1/cross/series":
                # 只要原始观测，不返回任何统计结论：NAS 是仓库，研究在手机端做。
                query = parse_qs(parsed.query)
                market = query.get("market", [None])[0]
                days_text = query.get("days", [""])[0]
                try:
                    days = int(days_text) if days_text else None
                    rows = database.get_cross_samples(market=market, days=days)
                    return self.reply(200, {"source": "NAS cross-market snapshot archive",
                                            "markets": crossmarket.group_series(rows),
                                            "rows": len(rows)})
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            if path.startswith("/v1/research/preregister"):
                # 预注册未来样本研究（指令七）：只登记未来窗口 + 不可变指纹，
                # 不建计划、不改账本、不发信号。列表/读取都带 notTradingSignal 标注。
                try:
                    if path == "/v1/research/preregister":
                        return self.reply(200, {"studies": database.list_preregisters(),
                                                "notTradingSignal": True,
                                                "note": "预注册未来样本研究：只登记未来观察窗口与不可变指纹，不是交易信号。"})
                    study_id = path.rsplit("/", 1)[-1]
                    as_of = parse_qs(parsed.query).get("asOf", [None])[0]
                    if as_of:
                        try: strict_iso_date(as_of)
                        except ValueError: return self.reply(400, {"error": "invalid asOf date"})
                    study = database.get_preregister(study_id, as_of=as_of)
                    if study is None:
                        return self.reply(404, {"error": "study not found", "notTradingSignal": True})
                    return self.reply(200, study)
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            if path.startswith("/v1/research/"):
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    # 长期分时统计：1/5/20/60/120 日窗口的 VWAP 偏离、振幅、往返次数、
                    # 支撑压力、波动率、成交量与数据完整度/新鲜度。纯计算，不缓存也不伪造。
                    # 结果按「最新分钟戳」缓存：归档有新数据就重算，没有就直接复用，
                    # 既不让手机端每次重算，也不会读到与归档不一致的旧结论。
                    # 注意：这是**被动按需计算**——只有手机来问才跑，NAS 不存在后台研究循环。
                    try:
                        minute_rows = database.get_minute_range(code, 130)
                    except (InvalidData, ValueError):
                        minute_rows = []
                    latest = minute_rows[-1].get("timestamp", "") if minute_rows else ""
                    cached = database.get_research_stats(code)
                    if cached["stats"] is not None and latest and cached["stamp"] == latest:
                        stats = cached["stats"]
                    else:
                        stats = research.minute_stats(minute_rows)
                        if latest:
                            database.put_research_stats(code, latest, stats)
                    # factors / ai 恒为 None：NAS 已不再生成因子与 AI 结论（研究交给手机端）。
                    # 键保留是为了让旧版客户端解码不报错，历史上写入的残留记录不再回传，
                    # 避免手机读到与本机规则不一致的过期结论。
                    return self.reply(200, {"factors": None,
                                            "ai": None,
                                            "minuteStats": stats,
                                            "researchOwner": "mobile"})
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            if path.startswith("/v1/news/"):
                # 新闻 → 行业/证券 → 真实持仓 → 当前计划。手机端要能反复取标题来核对
                # 「重大事件有没有让原计划失效」，所以这里必须有独立、可缓存的入口。
                try:
                    code = path.rsplit("/", 1)[-1]
                    meta = symbol_for(code)
                    name = meta.get("name") if isinstance(meta, dict) else None
                    cached = database.get_news(code)
                    fresh = False
                    if cached["body"] and cached["updatedAt"]:
                        try:
                            age = (datetime.now(timezone.utc)
                                   - datetime.fromisoformat(cached["updatedAt"])).total_seconds()
                            fresh = age < 15 * 60
                        except ValueError:
                            fresh = False
                    if fresh:
                        body = cached["body"]
                    else:
                        body = news.fetch_headlines(code, name or code)
                        database.put_news(code, body)
                    return self.reply(200, {"code": code, "name": name, **body,
                                            "fetchedAt": cached["updatedAt"] if fresh else None,
                                            "cached": fresh})
                except (InvalidData, ValueError) as error:
                    return self.reply(400, {"error": str(error)})
                except Exception:
                    return self.reply(502, {"error": "news source unavailable"})
            if path.startswith("/v1/backtests/runs/"):
                return self.reply(410, {"error": "模拟回测入口已停用；产品只保留真实持仓顾问。",
                                        "code": "backtest_removed"})
            if path.startswith("/v1/backtests/"):
                return self.reply(410, {"error": "模拟回测入口已停用；产品只保留真实持仓顾问。",
                                        "code": "backtest_removed"})
            if path.startswith("/v1/simulations/"):
                # 数字孪生 / 虚拟账户已下线：产品只允许真实账户。这里保留 410，
                # 让旧客户端与旧收藏脚本明确知道「接口没了」，而不是拿到一份假的模拟数据。
                return self.reply(410, {"error": "数字孪生与虚拟账户已下线：观盘只使用真实持仓与真实成交。",
                                        "code": "simulation_removed"})
            if path == "/v1/market/indices":
                try: return self.reply(200, {"indices": fetch_indices()})
                except Exception: return self.reply(502, {"error": "index source unavailable"})
            if path == "/v1/market/kline":
                symbol = parse_qs(parsed.query).get("symbol", [""])[0]
                try: return self.reply(200, {"symbol": symbol, "bars": fetch_kline(symbol)})
                except (ValueError, InvalidData) as error: return self.reply(400, {"error": str(error)})
                except Exception: return self.reply(502, {"error": "index kline source unavailable"})
            if path.startswith("/v1/market/minutes/"):
                # 多日分时的**原始行情**，给手机端的「历史回放验证器」(146) 用。
                # 为什么要有这个入口：回放需要连续 30+ 个交易日的分钟线，而
                # `/v1/research/{code}` 只回统计结果、`/v1/market/minute/{code}` 只回一天。
                # 一天一个请求意味着过隧道 30–60 次，慢且更容易断；这里一次给全。
                # 只回行情，不带任何统计或结论——回放要自己算才有意义。
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    query = parse_qs(parsed.query)
                    days_text = query.get("days", ["60"])[0]
                    try: days = int(days_text)
                    except (TypeError, ValueError): raise InvalidData("days 必须是整数")
                    if not 1 <= days <= 120: raise InvalidData("days 取值范围 1–120")
                    grouped = research.group_by_day(database.get_minute_range(code, days))
                    return self.reply(200, {
                        "code": code, "days": days, "source": "NAS 1-minute archive",
                        "dayCount": len(grouped),
                        "points": sum(len(items) for items in grouped.values()),
                        "series": {day: [{"timestamp": item["at"].isoformat(), "price": str(item["price"])}
                                         for item in items]
                                   for day, items in sorted(grouped.items())},
                    })
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            if path.startswith("/v1/market/minute/"):
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    day = parse_qs(parsed.query).get("day", [datetime.now().astimezone().date().isoformat()])[0]
                    return self.reply(200, database.get_minute(code, day))
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            if path.startswith("/v1/market/dividends/"):
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    cached = database.get_dividend_events(code)
                    now = datetime.now(timezone.utc)
                    fresh = False
                    stale_rules = bool(cached) and cached.get("rulesVersion") != dividend_rules_version
                    if cached:
                        try: fresh = (now - datetime.fromisoformat(cached["fetchedAt"])).total_seconds() < 24 * 3600
                        except ValueError: pass
                        # 规则版本变了就必须重抓：否则旧缓存里那条"假分红"会继续返回，
                        # 服务端改了算法、App 上还是老结果，看起来像没修好。
                        if stale_rules: fresh = False
                    if not fresh:
                        try:
                            rows = dividend_fetcher(code)
                            database.put_dividend_events(code, rows, now.isoformat(), dividend_rules_version, replace=stale_rules)
                            cached = database.get_dividend_events(code)
                        except Exception:
                            if cached is None: raise
                    return self.reply(200, cached or {"code": code, "source": "NAS dividend archive", "fetchedAt": None, "events": []})
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
                except Exception: return self.reply(503, {"error": "no dividend archive or verified source available"})
            if path.startswith("/v1/market/daily/"):
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    cached = database.get_daily(code)
                    if cached is None:
                        rows = daily_fetcher(code)
                        database.put_daily(code, rows, datetime.now(timezone.utc).isoformat())
                        cached = database.get_daily(code)
                    return self.reply(200, cached)
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
                except Exception: return self.reply(503, {"error": "daily source unavailable and no NAS cache"})
            if path == "/v1/market/quotes":
                try:
                    raw = parse_qs(parsed.query, strict_parsing=True).get("codes", [""])[0]
                    codes = raw.split(",") if raw else []
                    if not 1 <= len(codes) <= 60 or len(set(codes)) != len(codes):
                        raise InvalidData("provide 1–60 unique exchange codes")
                    for code in codes: symbol_for(code)
                    return self.reply(200, {"quotes": market_fetcher(codes)})
                except (InvalidData, ValueError) as error:
                    return self.reply(400, {"error": str(error)})
                except Exception:
                    return self.reply(502, {"error": "quote source unavailable; local cache remains authoritative"})
            if path.startswith("/v1/real/books/"):
                parts = path.strip("/").split("/")
                try:
                    # /v1/real/books/<id>/history        版本列表
                    # /v1/real/books/<id>/history/<rev>  单个版本正文
                    if len(parts) >= 5 and parts[4] == "history":
                        if len(parts) == 6:
                            return self.reply(200, database.real_history_body(parts[3], int(parts[5])))
                        return self.reply(200, database.real_history(parts[3]))
                    # ?meta=1 只回修订号与 hasBook，不带 bookJSON。
                    # 手机端做连通性检查、上传前修订核对都该走这里；
                    # 账本正文只在真正上传/下载时才传，别让一次检测顺着隧道搬整份账本。
                    if parse_qs(parsed.query).get("meta", ["0"])[0] in ("1", "true", "yes"):
                        return self.reply(200, database.get_real_meta(parts[3]))
                    return self.reply(200, database.get_real(parts[3]))
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            self.reply(404, {"error": "unknown route"})

        def do_DELETE(self):
            """删除 NAS 上保存的账本历史版本。

            当前生效版本不允许删；`DELETE .../history?keep=N` 只保留最近 N 个。
            """
            parsed = urlparse(self.path); path = parsed.path
            parts = path.strip("/").split("/")
            try:
                if len(parts) >= 4 and parts[:3] == ["v1", "real", "books"] and len(parts) >= 5 and parts[4] == "history":
                    book_id = parts[3]
                    if len(parts) == 6:
                        revision = database.delete_real_history(book_id, int(parts[5]))
                        return self.reply(200, {"ok": True, "deleted": revision})
                    keep = int(parse_qs(parsed.query).get("keep", ["20"])[0])
                    removed = database.prune_real_history(book_id, keep)
                    return self.reply(200, {"ok": True, "kept": keep, "removed": removed})
                return self.reply(404, {"error": "unknown route"})
            except Conflict as error: return self.reply(409, {"error": str(error)})
            except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})

        def do_POST(self):
            path = urlparse(self.path).path
            if path == "/v1/advisor/analyze":
                self.close_connection = True
                return self.reply(410, {"error": "NAS 只提供长期数据研究、机会扫描和新闻；最终AI指导由手机端统一生成。",
                                        "code": "nas_advisor_retired"})
            if path.startswith("/v1/backtests/"):
                self.close_connection = True
                return self.reply(410, {"error": "模拟回测入口已停用；产品只保留真实持仓顾问。",
                                        "code": "backtest_removed"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 16 * 1024 * 1024:
                    return self.reply(413, {"error": "invalid body size"})
                value = json.loads(self.rfile.read(length))
                if not isinstance(value, dict): raise InvalidData("JSON object required")
                if path == "/v1/ai/analyze":
                    self.close_connection = True
                    return self.reply(410, {"error": "NAS AI顾问入口已停用；NAS只提供研究证据，手机端生成唯一最终指导。",
                                            "code": "nas_ai_advisor_retired"})
                if path.startswith("/v1/simulations/"):
                    return self.reply(410, {"error": "数字孪生与虚拟账户已下线：观盘只使用真实持仓与真实成交。",
                                            "code": "simulation_removed"})
                if path == "/api/data":
                    if value.get("mode") != "legacy-stage-confirmed":
                        raise InvalidData("legacy staging requires explicit migration action")
                    revision = database.put_legacy_inbox("main", value.get("expectedRevision"), value.get("data"))
                    return self.reply(200, {"ok": True, "revision": revision})
                if path == "/api/web/data":
                    # 旧版网页 POST 的形状是 {tok, data}。没有 data 就拒，别猜。
                    payload = value.get("data")
                    if not isinstance(payload, dict):
                        raise InvalidData("web snapshot requires a data object")
                    expected = value.get("expectedRevision")
                    revision = database.put_web_snapshot("classic", payload,
                                                         int(expected) if isinstance(expected, int) else None)
                    return self.reply(200, {"ok": True, "revision": revision})
                if path == "/v1/legacy/books/main":
                    converted = convert_legacy_web_book(value.get("data", value))
                    return self.reply(200, {"revision": database.get_legacy_inbox("main")["revision"], **converted})
                if path.startswith("/v1/real/books/"):
                    if value.get("mode") != "manual-confirmed":
                        raise InvalidData("real books require explicit manual confirmation")
                    revision = database.put_real(path.rsplit("/", 1)[-1], value.get("expectedRevision"), value.get("bookJSON"))
                    return self.reply(200, {"revision": revision})
                if path.startswith("/v1/market/track/"):
                    if value.get("mode") != "track-confirmed":
                        raise InvalidData("instrument tracking requires explicit confirmation")
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    database.track_instrument(code, datetime.now(timezone.utc).isoformat())
                    return self.reply(200, {"code": code, "tracked": True})
                if path == "/v1/research/preregister":
                    # 预注册：只登记，绝不生成信号/计划/账本写入。
                    study = database.register_preregister(value)
                    return self.reply(200, {
                        **study,
                        "note": ("这不是交易信号：预注册研究只登记未来观察窗口与不可变指纹，"
                                 "不创建交易计划、不改真实账本、不生成交易信号。")})
                if path.startswith("/v1/research/preregister/") and path.endswith("/settle"):
                    # 结算子路由：只记录结果指纹，同样不建计划/不改账本/不发信号。
                    study_id = path[len("/v1/research/preregister/"):-len("/settle")].strip("/")
                    result = database.settle_preregister(study_id, value.get("outcome") or value)
                    return self.reply(200, {**result,
                                            "note": "结算仅记录结果指纹；这仍不是交易信号。"})
                self.reply(404, {"error": "unknown route"})
            except Conflict:
                self.reply(409, {"error": "revision conflict; no changes saved"})
            except (InvalidData, ValueError, UnicodeError) as error:
                self.reply(400, {"error": str(error)})

    return Handler


if __name__ == "__main__":
    root = Path(os.environ.get("GUANPAN_NEXT_DATA", "/data")); root.mkdir(parents=True, exist_ok=True)
    database = NextDatabase(root / "guanpan-advisor.sqlite3")
    start_workers(database)
    # 容器内监听端口 = 宿主机端口（并行顾问副本默认 8786）：
    # 少一层映射就少一处"改了外面没改里面"的坑。要换端口用 GUANPAN_ADVISOR_PORT，
    # compose 的映射也跟着同一个变量走。
    try: port = int(os.environ.get("GUANPAN_ADVISOR_PORT", "8786"))
    except ValueError: port = 8786
    ThreadingHTTPServer(("0.0.0.0", port), make_handler(database)).serve_forever()
