"""Independent NAS archive workers. No worker reads the mobile sync preference.

NAS 的定位是「纯数据仓库」——只负责采集/归档（日 K、分时、分红事件、新闻），
不跑因子研究、不下判断、不生成 AI 结论。研究全部在手机端完成；
只有当手机 AI 需要 NAS 上的历史数据时才按需向 NAS 拉取，这与隧道无关，
属于正常的数据同步。
"""
import json
import os
import threading
import time
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo
from market import symbol_for, fetch_tencent_daily, fetch_dividend_events
import calendar_cn
from crossmarket import fetch_snapshots, archive_rows, should_sample

SHANGHAI = ZoneInfo("Asia/Shanghai")
# 演示标的**默认不再常驻采集**。以前这四个代码被无条件并进采集集合，
# 结果是：服务只要开着，每 30 分钟为 4 只用户可能根本不看的 demo ETF 打一次上游日 K，
# 盘中每分钟还要为它们拉一次分时，每天再查一次分红——全是白烧的请求。
# 真正需要归档的标的来自：手机 /v1/market/track 登记过的、账本里的真实持仓、已归档过的。
# 想预热演示数据就显式设 GUANPAN_ARCHIVE_DEMO=159941,563020，空着就老实待着。
DEFAULT_CODES = tuple(code.strip() for code in os.environ.get("GUANPAN_ARCHIVE_DEMO", "").split(",") if code.strip())
EMPTY_NOTE = ("还没有需要归档的标的：手机还没请求过任何行情。"
              "打开某只标的或加自选会调用 /v1/market/track 登记，之后自动开始归档。")


def parse_minute(body, code):
    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end < start: raise ValueError("invalid minute response")
    node = json.loads(body[start:end + 1]).get("data", {}).get(symbol_for(code), {}).get("data", {})
    day = node.get("date", "")
    rows = node.get("data") or node.get("items")
    if not isinstance(rows, list) or len(day) != 8 or not day.isdigit(): raise ValueError("minute source missing")
    result = {}
    last_volume = None
    for row in rows:
        parts = row.split() if isinstance(row, str) else []
        if len(parts) < 2 or len(parts[0]) != 4 or not parts[0].isdigit(): continue
        try:
            hour, minute = int(parts[0][:2]), int(parts[0][2:])
            price = Decimal(parts[1]); cumulative = Decimal(parts[2]) if len(parts) > 2 else None
            if not (9 <= hour <= 15 and 0 <= minute <= 59 and price.is_finite() and price > 0): continue
            if cumulative is not None and (not cumulative.is_finite() or cumulative < 0): continue
            stamp = datetime.strptime(day + parts[0], "%Y%m%d%H%M").replace(tzinfo=SHANGHAI)
            if stamp > datetime.now(timezone.utc): continue
            volume = str(cumulative - last_volume) if cumulative is not None and last_volume is not None and cumulative >= last_volume else None
            if cumulative is not None: last_volume = cumulative
            result[stamp.isoformat()] = {"timestamp": stamp.isoformat(), "price": str(price), "volume": volume, "iopv": None}
        except (ValueError, ArithmeticError): continue
    if not result: raise ValueError("no validated minute rows")
    return [result[key] for key in sorted(result)]


def fetch_minute(code):
    symbol = symbol_for(code)
    url = "https://web.ifzq.gtimg.cn/appstock/app/minute/query?" + urlencode({"code": symbol, "_var": "min_data_" + symbol})
    with urlopen(Request(url, headers={"Referer": "https://gu.qq.com/", "User-Agent": "GuanpanProNext/3"}), timeout=12) as response:
        if response.status != 200: raise OSError("minute source unavailable")
        return parse_minute(response.read(2_000_000).decode("utf-8"), code)


def attach_quote_iopv(rows, quote):
    """Attach only a same-session, near-time ETF IOPV to the latest sample.

    保留为纯工具函数（test_domain 直接测试），但后台 minute_loop 已不再调用：
    实时 IOPV 由手机端直连行情自取，NAS 不再为此额外拉实时行情。
    """
    if not rows or not quote or not quote.get("iopv") or quote.get("providerInstrumentType") != "ETF":
        return rows
    quote_time = datetime.fromisoformat(quote["time"])
    last_time = datetime.fromisoformat(rows[-1]["timestamp"])
    if quote_time.astimezone(SHANGHAI).date() == last_time.astimezone(SHANGHAI).date() and abs((quote_time - last_time).total_seconds()) <= 300:
        rows[-1]["iopv"] = quote["iopv"]
    return rows


def start_workers(database, daily_fetcher=fetch_tencent_daily, minute_fetcher=fetch_minute, cross_fetcher=fetch_snapshots):
    """Each loop owns its own timer and failure handling; sync APIs never stop them."""
    def tracked():
        with database.connect() as connection:
            rows = connection.execute("SELECT code FROM daily_bars UNION SELECT DISTINCT code FROM minute_archive").fetchall()
        # Also collect real holdings without modifying the book or tracked-instrument table.
        holdings = set()
        try:
            stored = database.get_real("main")
            book = json.loads(stored["bookJSON"]) if stored.get("bookJSON") else {}
            for position in book.get("positions", []):
                if position.get("units", 0) > 0:
                    code = position.get("code")
                    symbol_for(code)
                    holdings.add(code)
        except (ValueError, TypeError, KeyError):
            pass
        return sorted(set(DEFAULT_CODES) | set(database.tracked_instruments()) | {row[0] for row in rows} | holdings)

    def update(name, state, detail):
        database.put_worker_status(name, datetime.now(timezone.utc).isoformat(), state, detail[:500])

    def missing_note(failed):
        """把失败代码与异常类型写进 detail。

        只报 "6/7 codes archived" 时无从下手：不知道是哪一只、也不知道是抓不到
        还是解析失败。这里点名到代码（最多 8 只），排查直接省掉一轮翻日志。
        """
        if not failed:
            return ""
        return "; missing " + ", ".join(failed[:8]) + ("…" if len(failed) > 8 else "")

    def daily_loop():
        update("daily-archive", "starting", "worker starting")
        while True:
            # 休市日不抓：日 K 源会返回最后成交的一条，日复一日地重复归档同一根 K 线，
            # 只会让「归档天数」虚高，而回放器是按交易日数算样本的。
            if not calendar_cn.is_a_share_trading_day(datetime.now(SHANGHAI)):
                update("daily-archive", "idle",
                       calendar_cn.describe(datetime.now(SHANGHAI)) + "；不抓大陆标的的日 K，历史归档保持可用")
                time.sleep(1800); continue
            codes = tracked()
            if not codes:
                update("daily-archive", "idle", EMPTY_NOTE)
                time.sleep(1800); continue
            failures = []
            for code in codes:
                try: database.put_daily(code, daily_fetcher(code), datetime.now(timezone.utc).isoformat())
                except Exception as error: failures.append(f"{code}:{type(error).__name__}")  # Last verified archive stays available.
            update("daily-archive", "ok" if not failures else "degraded",
                   f"{len(codes) - len(failures)}/{len(codes)} codes archived; next run in 30m{missing_note(failures)}")
            time.sleep(1800)

    def minute_loop():
        update("minute-archive", "starting", "worker starting")
        while True:
            local = datetime.now(SHANGHAI)
            # 先过交易日历再过时段：调休上班的周末（1/4、2/14 等）虽然上班，
            # 但交易所不开市，以前只看 weekday 会在这些日子白抓一整天。
            if not calendar_cn.is_a_share_trading_day(local):
                update("minute-archive", "idle",
                       calendar_cn.describe(local) + "；不抓大陆指数与分时，历史归档保持可用")
                time.sleep(300); continue
            if (9, 15) <= (local.hour, local.minute) <= (11, 35) or (13, 0) <= (local.hour, local.minute) <= (15, 5):
                codes = tracked()
                if not codes:
                    update("minute-archive", "idle", EMPTY_NOTE)
                    time.sleep(60); continue
                failures = []
                for code in codes:
                    try:
                        # 分时归档是研究工作的重要数据（用户 2026-10-24 明确要求保留）。
                        # 但「额外实时行情」不再由 NAS 拉取：IOPV 由手机端直连行情自取，
                        # NAS 只归档分时，把实时行情的带宽全部留给手机直连。
                        rows = minute_fetcher(code)
                        database.put_minute(code, rows, datetime.now(timezone.utc).isoformat())
                    except Exception as error: failures.append(f"{code}:{type(error).__name__}")
                update("minute-archive", "ok" if not failures else "degraded",
                       f"{len(codes) - len(failures)}/{len(codes)} codes collected; next attempt in 1m{missing_note(failures)}")
            else:
                update("minute-archive", "idle", "outside mainland market collection window; historical archive remains available")
            time.sleep(60)

    def cross_loop():
        """跨市场快照采集（116–145 的数据来源）。

        为什么需要一个独立线程：日经/KOSPI/恒生科技/纳指**没有分钟线接口**，
        只有"此刻一个价"。想验证「午休期间日韩修复 → A股午后修复」，
        就必须自己按分钟攒出历史；攒不出来就只能永远凭感觉。

        两条克制：
        1. 只在上海时间 08:00–16:10 采（覆盖日韩全天 + 港股全天）；
           纳指此时是收盘后的最后价，每天因此只有很少几个点，这是如实记录，
           不为了凑点数在夜里空转。
        2. 源时间过期的样本由 `archive_rows` 直接丢掉，不落库。
           收盘后源会一直返回最后成交价，把它当新观测会让回放凭空多出一段横盘。
        """
        update("cross-market", "starting", "worker starting")
        while True:
            local = datetime.now(SHANGHAI)
            if not should_sample(local):
                update("cross-market", "idle",
                       "outside 08:00-16:10 Asia/Shanghai sampling window; archived samples remain available")
                time.sleep(300); continue
            try:
                samples = cross_fetcher()
                rows, dropped = archive_rows(samples, now=datetime.now(timezone.utc))
                if rows:
                    result = database.put_cross_samples(rows, datetime.now(timezone.utc).isoformat())
                    detail = f"{result['accepted']} samples archived from {len({r['market'] for r in rows})} markets; next sample in 1m"
                    if dropped:
                        detail += "; dropped " + ", ".join(sorted({f"{d['market']}:{d['reason']}" for d in dropped}))[:160]
                    update("cross-market", "ok", detail)
                else:
                    reasons = ", ".join(sorted({f"{d['market']}:{d['reason']}" for d in dropped})) or "no samples parsed"
                    update("cross-market", "degraded", f"no fresh sample: {reasons}"[:500])
            except Exception as error:  # noqa: BLE001 - 采集失败不能影响其它线程
                update("cross-market", "degraded", f"fetch failed: {type(error).__name__}: {error}"[:500])
            time.sleep(60)

    def dividend_loop():
        update("dividend-archive", "starting", "dividend collector starting")
        while True:
            codes = tracked()
            if not codes:
                update("dividend-archive", "idle", EMPTY_NOTE)
                time.sleep(86400); continue
            failures = []; collected = 0
            for code in codes:
                try:
                    events = fetch_dividend_events(code)
                    database.put_dividend_events(code, events, datetime.now(timezone.utc).isoformat())
                    collected += 1
                except Exception as error: failures.append(f"{code}:{type(error).__name__}")
            update("dividend-archive", "ok" if not failures else "degraded",
                   f"{collected}/{len(codes)} codes checked; ETF F10 events separated from qfq/raw estimates; history retained{missing_note(failures)}")
            time.sleep(86400)

    for name, target in (("daily-archive", daily_loop), ("minute-archive", minute_loop),
                         ("cross-market", cross_loop), ("dividend-archive", dividend_loop)):
        threading.Thread(target=target, name=name, daemon=True).start()
