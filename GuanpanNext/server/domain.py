"""Fresh securities schema. No legacy database, OTC model or broker adapter."""
import json
import re
import sqlite3
import hashlib
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
import uuid


class InvalidData(ValueError):
    pass


class Conflict(Exception):
    pass


# 跨市场快照允许的市场键。与 crossmarket.MARKETS 的键保持一致；
# 这里不 import crossmarket，避免「数据层依赖采集层」——采集层依赖数据层才对。
CROSS_MARKETS = ("japan", "korea", "hongKong", "unitedStates")

# 125 汇率上下文允许的交易对。刻意只登记 USD/CNY 一个：
# 采不到的货币对宁可让手机端显示「未接入」，也不拿没验证过的源凑数。
FX_PAIRS = ("USDCNY",)
# 被承认的**来源名称**。来源名称未验证的汇率一律不许落库、也不许进入手机决策上下文。
# 与 fx.VERIFIED_SOURCE_NAMES 保持一致；这里不 import fx，避免数据层依赖采集层。
FX_VERIFIED_SOURCE_NAMES = ("Sina fx",)


def strict_iso_date(value):
    """Accept only canonical Gregorian YYYY-MM-DD dates used by the iOS wire models."""
    if not isinstance(value, str) or re.fullmatch(r"\d{4}-\d{2}-\d{2}", value) is None:
        raise ValueError("date must use YYYY-MM-DD")
    parsed = date.fromisoformat(value)
    if parsed.isoformat() != value:
        raise ValueError("date must use canonical YYYY-MM-DD")
    return parsed


def preregister_fingerprint(lead_market, follow_code, lead_minutes, window_days,
                            frozen_at, window_start, window_end):
    """假设一旦注册就不可变：指纹由全部假设字段算出，重算不一致即判漂移。

    排序键固定 + separators 紧凑，保证「同一假设永远得到同一指纹」，
    也保证任何人改了其中任一字段都会让落库指纹与重算指纹对不上
    （drifted），从而让研究作废，而不是悄悄变成一个能拟合结果的假设。
    """
    canonical = json.dumps(
        {"leadMarket": str(lead_market), "followCode": str(follow_code),
         "leadMinutes": int(lead_minutes), "windowDays": int(window_days),
         "frozenAt": str(frozen_at), "windowStart": str(window_start),
         "windowEnd": str(window_end)},
        ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def validate_book_json(text):
    if not isinstance(text, str):
        raise InvalidData("bookJSON must be a JSON string")
    def reject(value):
        raise InvalidData("non-finite number")
    try:
        book = json.loads(text, parse_float=Decimal, parse_constant=reject)
        if not isinstance(book, dict) or book.get("schemaVersion") != 1:
            raise InvalidData("unsupported book schema")
        allowed = {"schemaVersion", "id", "cash", "positions", "fills", "cashMovements", "incomeEvents", "dividendEvents", "history", "importedAt"}
        if set(book) - allowed:
            raise InvalidData("unexpected fields; legacy backups are not accepted")
        def number(value, minimum=Decimal(0)):
            if isinstance(value, bool) or not isinstance(value, (Decimal, int)):
                raise InvalidData("invalid numeric field")
            d = Decimal(value)
            if not d.is_finite() or (minimum is not None and d < minimum):
                raise InvalidData("invalid numeric range")
            return d
        def code(value):
            if not isinstance(value, str) or re.fullmatch(r"[0-9]{6}", value) is None:
                raise InvalidData("invalid exchange code")
        def identifier(value):
            if not isinstance(value, str): raise InvalidData("invalid UUID identifier")
            try: uuid.UUID(value)
            except (ValueError, AttributeError): raise InvalidData("invalid UUID identifier")
        identifier(book.get("id"))
        if "importedAt" in book: number(book["importedAt"], minimum=None)
        number(book["cash"])
        positions = book["positions"]
        if not isinstance(positions, list):
            raise InvalidData("positions must be a list")
        seen = set()
        position_required = {"code", "name", "units", "bookCost"}
        # iOS 3.4.1+ 在持仓里带 acquiredAt（建仓日，用于分红归属）；网页端忽略该字段。
        # 不放行它，整个账本上传会被 400 拒绝，网页账本永远拿不到 iOS 的真实成本。
        position_allowed = position_required | {"acquiredAt"}
        for p in positions:
            if not isinstance(p, dict) or not position_required <= set(p) or set(p) - position_allowed:
                raise InvalidData("invalid position fields")
            code(p["code"])
            if p["code"] in seen or not isinstance(p["name"], str):
                raise InvalidData("duplicate code or invalid name")
            seen.add(p["code"])
            if type(p["units"]) is not int or p["units"] < 0:
                raise InvalidData("units must be a nonnegative integer")
            number(p["bookCost"])
        if not isinstance(book.get("fills"), list) or not isinstance(book.get("history"), list):
            raise InvalidData("fills/history must be arrays")
        movements = book.get("cashMovements", [])
        if not isinstance(movements, list):
            raise InvalidData("cashMovements must be an array")
        for movement in movements:
            if not isinstance(movement, dict) or set(movement) != {"id", "date", "amount", "reason"}:
                raise InvalidData("invalid cash movement fields")
            identifier(movement["id"])
            number(movement["amount"], minimum=None)
            number(movement["date"], minimum=None)
            if not isinstance(movement["reason"], str) or not movement["reason"].strip():
                raise InvalidData("cash movement reason is required")
        income_events = book.get("incomeEvents", [])
        if not isinstance(income_events, list):
            raise InvalidData("incomeEvents must be an array")
        for event in income_events:
            required = {"id", "kind", "name", "payDate", "grossAmount", "tax", "status", "note"}
            optional = {"code", "exDate", "units", "perUnit", "receivedAt"}
            if not isinstance(event, dict) or required - set(event) or set(event) - required - optional:
                raise InvalidData("invalid income event fields")
            if event["kind"] not in ("etfDistribution", "cashInterest", "other") or event["status"] not in ("expected", "received"):
                raise InvalidData("invalid income kind/status")
            if not isinstance(event["id"], str) or not isinstance(event["name"], str) or not isinstance(event["note"], str):
                raise InvalidData("invalid income text fields")
            identifier(event["id"])
            number(event["grossAmount"]); number(event["tax"])
            if Decimal(event["tax"]) > Decimal(event["grossAmount"]):
                raise InvalidData("income tax exceeds gross amount")
            number(event["payDate"], minimum=None)
            if "exDate" in event: number(event["exDate"], minimum=None)
            if "receivedAt" in event: number(event["receivedAt"], minimum=None)
            if "units" in event and (type(event["units"]) is not int or event["units"] <= 0):
                raise InvalidData("invalid income units")
            if "perUnit" in event: number(event["perUnit"])
            if "code" in event: code(event["code"])
            if event["kind"] == "etfDistribution" and "code" not in event:
                raise InvalidData("ETF distribution requires a code")
            if event["status"] == "received" and "receivedAt" not in event:
                raise InvalidData("received income requires a receivedAt date")
        dividend_events = book.get("dividendEvents", [])
        if not isinstance(dividend_events, list):
            raise InvalidData("dividendEvents must be an array")
        for event in dividend_events:
            if not isinstance(event, dict) or set(event) - {"code", "date", "amountPerShare", "isEstimated", "recordDate", "payDate"} or not {"code", "date", "amountPerShare"}.issubset(event):
                raise InvalidData("invalid dividend event fields")
            code(event["code"])
            try: strict_iso_date(event["date"])
            except ValueError: raise InvalidData("invalid dividend event date")
            number(event["amountPerShare"])
            if event.get("isEstimated") not in (None, True, False):
                raise InvalidData("invalid dividend estimate marker")
            for field in ("recordDate", "payDate"):
                if field in event and event[field] is not None:
                    try: strict_iso_date(event[field])
                    except ValueError: raise InvalidData("invalid dividend date field")
        for fill in book["fills"]:
            if not isinstance(fill, dict) or set(fill) != {"id", "date", "code", "side", "units", "price", "fee", "realized"}:
                raise InvalidData("invalid fill fields")
            identifier(fill["id"])
            code(fill["code"])
            if fill["side"] not in ("buy", "sell") or type(fill["units"]) is not int or fill["units"] <= 0:
                raise InvalidData("invalid fill side/units")
            for key in ("price", "fee"): number(fill[key])
            for key in ("date", "realized"): number(fill[key], minimum=None)
        for point in book["history"]:
            if not isinstance(point, dict) or set(point) != {"id", "date", "total", "externalFlow"}:
                raise InvalidData("invalid history point")
            identifier(point["id"])
            number(point["total"])
            number(point["date"], minimum=None)
            number(point["externalFlow"], minimum=None)
        return book
    except (KeyError, TypeError, json.JSONDecodeError, InvalidOperation) as error:
        raise InvalidData("invalid securities book") from error

def convert_legacy_web_book(source):
    """Convert the old /api/data ETF ledger to the independent Next book schema.

    This is a preview-only conversion. It intentionally ignores the old `fund`
    section and returns counts so the caller can ask the user to review before
    writing anything to the real ledger.
    """
    if isinstance(source, str):
        try:
            source = json.loads(source, parse_float=Decimal, parse_constant=lambda _: None)
        except (json.JSONDecodeError, TypeError):
            raise InvalidData("旧版网页数据不是有效 JSON")
    if not isinstance(source, dict):
        raise InvalidData("旧版网页数据必须是 JSON 对象")
    if isinstance(source.get("data"), dict):
        source = source["data"]
    db = source.get("db") if isinstance(source.get("db"), dict) else source

    def amount(value, default=Decimal(0)):
        if isinstance(value, bool) or value is None:
            return default
        try:
            result = Decimal(str(value))
            return result if result.is_finite() else default
        except (InvalidOperation, ValueError):
            return default

    def code(value):
        return value if isinstance(value, str) and re.fullmatch(r"[0-9]{6}", value) else None

    def timestamp(value):
        if isinstance(value, (int, float, Decimal)) and not isinstance(value, bool):
            result = float(value)
            return result - 978307200 if result > 0 else 0.0
        if not isinstance(value, str) or not value.strip():
            return 0.0
        raw = value.strip()
        try:
            if len(raw) == 10 and raw.isdigit():
                parsed = datetime.strptime(raw, "%Y%m%d").replace(tzinfo=timezone.utc)
            else:
                parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed.timestamp() - 978307200
        except ValueError:
            try:
                return datetime.combine(date.fromisoformat(raw[:10]), datetime.min.time(), timezone.utc).timestamp() - 978307200
            except ValueError:
                return 0.0

    def stable_id(prefix, *parts):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "guanpan-advisor:" + prefix + ":" + ":".join(map(str, parts))))

    holdings = db.get("hold") if isinstance(db.get("hold"), list) else []
    positions, seen = [], set()
    skipped_positions = 0
    for index, row in enumerate(holdings):
        if not isinstance(row, dict) or not code(row.get("code")):
            skipped_positions += 1
            continue
        code_value = row["code"]
        units_value = amount(row.get("num"))
        if units_value < 0 or units_value != units_value.to_integral_value():
            raise InvalidData(f"{code_value} 持仓份额不是非负整数，无法安全转换")
        if code_value in seen:
            raise InvalidData(f"旧版网页中证券 {code_value} 有重复持仓，请先在网页合并")
        seen.add(code_value)
        units = int(units_value)
        cost_per_unit = amount(row.get("cost"))
        if cost_per_unit < 0:
            raise InvalidData(f"{code_value} 成本价不能为负数")
        positions.append({"code": code_value, "name": str(row.get("name") or code_value),
                          "units": units, "bookCost": cost_per_unit * units})

    fills, fill_keys = [], set()
    trade_rows = []
    for row in (db.get("trades") if isinstance(db.get("trades"), list) else []):
        if isinstance(row, dict): trade_rows.append((row, "modern"))
    for row in (source.get("tr") if isinstance(source.get("tr"), list) else []):
        if isinstance(row, dict): trade_rows.append((row, "legacy"))
    skipped_trades = 0
    for row, kind in trade_rows:
        trade_code = code(row.get("code"))
        side = row.get("side")
        quantity = amount(row.get("num", row.get("quantity")))
        price = amount(row.get("price"))
        if not trade_code or side not in ("buy", "sell"):
            skipped_trades += 1
            continue
        if quantity <= 0 or quantity != quantity.to_integral_value() or price <= 0:
            raise InvalidData(f"{trade_code} 有交易流水的份额或价格无效，转换已停止")
        raw_date = row.get("date", row.get("d"))
        date_value = timestamp(raw_date)
        if date_value <= 0:
            raise InvalidData(f"{trade_code} 有交易流水缺少可识别日期")
        key = (trade_code, side, int(quantity), str(price), int(date_value))
        if key in fill_keys:
            continue
        fill_keys.add(key)
        fee = amount(row.get("fee"))
        realized = amount(row.get("realized", row.get("profit")))
        fills.append({"id": stable_id("fill", *key), "date": date_value, "code": trade_code,
                      "side": side, "units": int(quantity), "price": price,
                      "fee": fee, "realized": realized})

    cash = amount(source.get("cash"))
    if cash < 0:
        raise InvalidData("旧版网页现金为负，转换已停止")
    cash_movements = []
    for index, row in enumerate(source.get("cashlog") if isinstance(source.get("cashlog"), list) else []):
        if not isinstance(row, dict): continue
        value = amount(row.get("amt"))
        if row.get("type") == "out": value = -value
        elif row.get("type") != "in": continue
        raw_date = row.get("date")
        when = timestamp(raw_date)
        if value == 0 or when <= 0: continue
        cash_movements.append({"id": stable_id("cash", index, when, value), "date": when,
                               "amount": value, "reason": str(row.get("note") or ("现金转入" if value > 0 else "现金转出"))})

    history = []
    for index, row in enumerate(source.get("snap", source.get("snapshots", [])) if isinstance(source.get("snap", source.get("snapshots", [])), list) else []):
        if not isinstance(row, dict) or row.get("scope", "all") != "all": continue
        when = timestamp(row.get("d", row.get("date")))
        total = amount(row.get("total"), amount(row.get("mv")) + cash)
        if when > 0 and total >= 0:
            history.append({"id": stable_id("history", index, when), "date": when, "total": total, "externalFlow": Decimal(0)})

    legacy_dividends = []
    dividend_source = source.get("etfDividendEvents", source.get("dividendEvents", db.get("etfDividendEvents", [])))
    if isinstance(dividend_source, list):
        seen_dividends = set()
        for row in dividend_source:
            if not isinstance(row, dict): continue
            event_code = code(row.get("code")); event_date = row.get("date")
            amount_per_share = amount(row.get("amountPerShare"))
            if not event_code or not isinstance(event_date, str) or re.fullmatch(r"\d{4}-\d{2}-\d{2}", event_date) is None or amount_per_share <= 0:
                continue
            key = (event_code, event_date)
            if key in seen_dividends: continue
            seen_dividends.add(key)
            event = {"code": event_code, "date": event_date, "amountPerShare": amount_per_share}
            if row.get("isEstimated") is True: event["isEstimated"] = True
            elif row.get("isEstimated") is False: event["isEstimated"] = False
            legacy_dividends.append(event)

    if not ("cash" in source or positions or fills or history or cash_movements or legacy_dividends):
        raise InvalidData("未找到可转换的现金、场内持仓或交易流水")
    book = {"schemaVersion": 1, "id": str(uuid.uuid4()), "cash": cash, "positions": positions,
            "fills": fills, "cashMovements": cash_movements, "incomeEvents": [], "dividendEvents": legacy_dividends, "history": history,
            "importedAt": datetime.now(timezone.utc).timestamp() - 978307200}
    encoded = json.dumps(book, ensure_ascii=False, separators=(",", ":"), default=float)
    validate_book_json(encoded)
    watches = db.get("watch") if isinstance(db.get("watch"), list) else []
    watch_codes = list(dict.fromkeys(row.get("code") for row in watches
                                     if isinstance(row, dict) and code(row.get("code"))))
    return {"book": book, "summary": {"cash": cash, "positions": len(positions), "fills": len(fills),
            "cashMovements": len(cash_movements), "history": len(history),
            "watchCodes": watch_codes,
            "skippedPositions": skipped_positions, "skippedTrades": skipped_trades,
            "dividendEvents": len(legacy_dividends),
            "ignoredOTCFunds": len((source.get("fund") or {}).get("hold", [])) if isinstance(source.get("fund"), dict) and isinstance((source.get("fund") or {}).get("hold", []), list) else 0}}


class NextDatabase:
    """Compare-and-swap manual snapshots; real and research tables are separate."""
    def __init__(self, filename):
        self.filename = str(filename)
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                -- 旧版网页（观盘 Pro 智能看盘）的数据包：它本来只存 localStorage，
                -- 换端口/清缓存就全丢。存到 NAS 后，任何设备打开都能拉回来。
                CREATE TABLE IF NOT EXISTS web_snapshots (
                    id TEXT PRIMARY KEY, revision INTEGER NOT NULL, body TEXT NOT NULL, updated_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS legacy_inbox (
                    id TEXT PRIMARY KEY, revision INTEGER NOT NULL, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS real_books (
                    id TEXT PRIMARY KEY, revision INTEGER NOT NULL, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS real_book_history (
                    id TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL,
                    PRIMARY KEY(id, revision));
                CREATE TABLE IF NOT EXISTS daily_bars (code TEXT PRIMARY KEY, fetched_at TEXT NOT NULL, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS dividend_archive (
                    code TEXT PRIMARY KEY, fetched_at TEXT NOT NULL, body TEXT NOT NULL,
                    rules_version INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS minute_archive (
                    code TEXT NOT NULL, stamp TEXT NOT NULL, body TEXT NOT NULL, fetched_at TEXT NOT NULL,
                    PRIMARY KEY(code, stamp));
                CREATE TABLE IF NOT EXISTS research_runs (
                    id TEXT PRIMARY KEY, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS research_stats (
                    code TEXT PRIMARY KEY, stamp TEXT NOT NULL, body TEXT NOT NULL, updated_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS news_cache (
                    code TEXT PRIMARY KEY, body TEXT NOT NULL, updated_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS tracked_instruments (
                    code TEXT PRIMARY KEY, added_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS worker_status (
                    name TEXT PRIMARY KEY, updated_at TEXT NOT NULL, state TEXT NOT NULL, detail TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS experiments (
                    id TEXT PRIMARY KEY, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS twin_accounts (
                    id TEXT PRIMARY KEY, revision INTEGER NOT NULL, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS twin_account_history (
                    id TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL,
                    PRIMARY KEY(id, revision));
                -- 跨市场先行信号的数据底座（116–145）。海外 4 个市场只提供快照、
                -- 不提供分钟线，所以这里存的是「我们每分钟看到的价格」，一行一个观测。
                -- 主键用 (market, stamp)：同一时刻重复采到不会写两行。
                CREATE TABLE IF NOT EXISTS cross_market_samples (
                    market TEXT NOT NULL, stamp TEXT NOT NULL, price TEXT NOT NULL,
                    change_percent TEXT, source TEXT, observed_at TEXT NOT NULL,
                    PRIMARY KEY(market, stamp));
                CREATE INDEX IF NOT EXISTS idx_cross_market_stamp ON cross_market_samples(stamp);
                -- 预注册的未来样本研究（指令七）。它只做一件事：**登记**一个
                -- 「未来观察窗口 + 不可变指纹」的假设，绝不下场。
                -- ① 只登记未来观察窗口：window_start 必须在登记时刻之后，否则就是
                --    「看了结果再注册」，预注册的意义就没了。
                -- ② 只登记不可变指纹：fingerprint 由假设字段算出并落库，注册后没有
                --    任何 UPDATE 路径改这些字段；重算不一致即判 drifted（假设被篡改/漂移）。
                -- ③ 不创建交易计划、④ 不改真实账本（real_books/twin_accounts 不碰）、
                -- ⑤ 不允许成为交易信号（不进 signalReplications、不进 CrossMarketLoop 闸门）。
                -- 这五条用「代码里根本不存在那些副作用」来保证，而不是靠文档提醒。
                CREATE TABLE IF NOT EXISTS preregistered_studies (
                    id TEXT PRIMARY KEY,
                    lead_market TEXT NOT NULL,
                    follow_code TEXT NOT NULL,
                    lead_minutes INTEGER NOT NULL,
                    window_days INTEGER NOT NULL,
                    frozen_at TEXT NOT NULL,
                    window_start TEXT NOT NULL,
                    window_end TEXT NOT NULL,
                    registered_at TEXT NOT NULL,
                    immutable_fingerprint TEXT NOT NULL,
                    settled_at TEXT,
                    outcome_fingerprint TEXT);
                CREATE INDEX IF NOT EXISTS idx_preregister_code ON preregistered_studies(follow_code);
                -- 125 汇率上下文：USD/CNY 买卖价中点。存的是「源几点几分报的价」，
                -- 以及「我们几点几分收到的」——两个都存，新鲜度只认前者。
                -- 主键用 (pair, stamp)：同一时刻重复采到不会写两行。
                -- 它只进入风险上下文，本表不派生任何价格/份额/方向。
                CREATE TABLE IF NOT EXISTS fx_samples (
                    pair TEXT NOT NULL, stamp TEXT NOT NULL,
                    bid TEXT NOT NULL, ask TEXT NOT NULL, mid TEXT NOT NULL,
                    observed_at TEXT NOT NULL,
                    source_name TEXT NOT NULL,
                    PRIMARY KEY(pair, stamp));
                CREATE INDEX IF NOT EXISTS idx_fx_stamp ON fx_samples(stamp);
            """)
            # 老库升级：`dividend_archive` 早期没有 rules_version 列。
            # 加不上（列已存在）就忽略 —— SQLite 没有 ADD COLUMN IF NOT EXISTS。
            try:
                db.execute("ALTER TABLE dividend_archive ADD COLUMN rules_version INTEGER NOT NULL DEFAULT 0")
            except sqlite3.OperationalError:
                pass
            # 老库升级：`fx_samples` 早期版本没有 source_name 列。
            # 这张表没有历史数据可留，缺列就直接重建——保证「来源名称」字段一定有值，
            # 否则老库里存着没有来源的汇率，等于把未验证的值伪装成有效汇率。
            fx_columns = {row[1] for row in db.execute("PRAGMA table_info(fx_samples)")}
            if fx_columns and "source_name" not in fx_columns:
                db.execute("DROP TABLE fx_samples")
                db.execute(
                    "CREATE TABLE IF NOT EXISTS fx_samples ("
                    "pair TEXT NOT NULL, stamp TEXT NOT NULL,"
                    "bid TEXT NOT NULL, ask TEXT NOT NULL, mid TEXT NOT NULL,"
                    "observed_at TEXT NOT NULL, source_name TEXT NOT NULL,"
                    "PRIMARY KEY(pair, stamp))")
            # 已退役/改名的后台任务（2026-10-24）：NAS 改为纯数据仓库，`factor-research`
            # 研究线程已删除；`dividend-research` 已改名为 `dividend-archive`（它只是分红
            # 采集器，不该挂 research 的名字）。旧库里的心跳行若留着，`worker_health()`
            # 会永远把它算成 stale —— 既是假警报，还会经 K4/K5 冒到手机通知中心。启动时清掉。
            db.execute("DELETE FROM worker_status WHERE name IN ('factor-research', 'dividend-research')")

    def connect(self):
        return sqlite3.connect(self.filename, timeout=15)

    @staticmethod
    def validate_id(book_id):
        if not isinstance(book_id, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,80}", book_id) is None:
            raise InvalidData("invalid id")

    def get_real(self, book_id):
        self.validate_id(book_id)
        with self.connect() as db:
            row = db.execute("SELECT revision, body FROM real_books WHERE id=?", (book_id,)).fetchone()
        return {"revision": row[0], "bookJSON": row[1]} if row else {"revision": 0, "bookJSON": None}

    def get_real_meta(self, book_id):
        """只回修订号与「有没有账本」，不带正文。

        手机端做连通性检查、上传前修订核对走这里。`body IS NOT NULL` 在库里就地判断，
        不把正文读进内存也不上线，避免一次检测顺着隧道搬整份账本。
        """
        self.validate_id(book_id)
        with self.connect() as db:
            row = db.execute("SELECT revision, (body IS NOT NULL) AS has_book FROM real_books WHERE id=?",
                             (book_id,)).fetchone()
        return {"revision": row[0] if row else 0, "hasBook": bool(row and row[1])}

    def put_real(self, book_id, expected, book_json):
        self.validate_id(book_id)
        if type(expected) is not int or expected < 0:
            raise InvalidData("invalid expectedRevision")
        validate_book_json(book_json)
        # The exact JSON text is stored; no float re-encoding of money occurs.
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT revision FROM real_books WHERE id=?", (book_id,)).fetchone()
            revision = current[0] if current else 0
            if revision != expected:
                raise Conflict("revision changed; manual conflict resolution required")
            revision += 1
            db.execute("INSERT OR REPLACE INTO real_books VALUES (?, ?, ?)", (book_id, revision, book_json))
            db.execute("INSERT INTO real_book_history VALUES (?, ?, ?)", (book_id, revision, book_json))
        return revision

    def real_history(self, book_id):
        """NAS 侧保存的账本版本列表（每次写入都会留一份完整 JSON）。

        只返回元数据，不回传整份账本 —— 网页/手机要恢复某个版本时再单取。
        """
        self.validate_id(book_id)
        with self.connect() as db:
            current = db.execute("SELECT revision FROM real_books WHERE id=?", (book_id,)).fetchone()
            rows = db.execute(
                "SELECT revision, length(body) FROM real_book_history WHERE id=? ORDER BY revision DESC",
                (book_id,)).fetchall()
        latest = current[0] if current else 0
        return {"bookId": book_id, "current": latest,
                "versions": [{"revision": r, "bytes": size, "current": r == latest} for r, size in rows]}

    def real_history_body(self, book_id, revision):
        self.validate_id(book_id)
        if type(revision) is not int or revision <= 0:
            raise InvalidData("invalid revision")
        with self.connect() as db:
            row = db.execute("SELECT body FROM real_book_history WHERE id=? AND revision=?",
                             (book_id, revision)).fetchone()
        if not row:
            raise InvalidData("revision not found")
        return {"revision": revision, "bookJSON": row[0]}

    def delete_real_history(self, book_id, revision):
        """删除一个历史版本。当前生效版本不能删 —— 删了就没有可回滚的锚点。"""
        self.validate_id(book_id)
        if type(revision) is not int or revision <= 0:
            raise InvalidData("invalid revision")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT revision FROM real_books WHERE id=?", (book_id,)).fetchone()
            if current and current[0] == revision:
                raise Conflict("cannot delete the current revision; write a new revision first")
            cursor = db.execute("DELETE FROM real_book_history WHERE id=? AND revision=?", (book_id, revision))
            if cursor.rowcount == 0:
                raise InvalidData("revision not found")
        return revision

    def prune_real_history(self, book_id, keep=20):
        """只保留最近 keep 个版本（含当前版本），更早的删掉。返回被删数量。"""
        self.validate_id(book_id)
        if type(keep) is not int or keep < 1:
            raise InvalidData("keep must be a positive integer")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT revision FROM real_books WHERE id=?", (book_id,)).fetchone()
            latest = current[0] if current else 0
            rows = db.execute("SELECT revision FROM real_book_history WHERE id=? ORDER BY revision DESC",
                              (book_id,)).fetchall()
            doomed = [r for (r,) in rows[keep:] if r != latest]
            for revision in doomed:
                db.execute("DELETE FROM real_book_history WHERE id=? AND revision=?", (book_id, revision))
        return len(doomed)

    def get_web_snapshot(self, snapshot_id="classic"):
        self.validate_id(snapshot_id)
        with self.connect() as db:
            row = db.execute("SELECT revision, body, updated_at FROM web_snapshots WHERE id=?", (snapshot_id,)).fetchone()
        if not row:
            return {"revision": 0, "data": None, "updatedAt": None}
        return {"revision": row[0], "data": json.loads(row[1]), "updatedAt": row[2]}

    def put_web_snapshot(self, snapshot_id, data, expected=None):
        """旧版网页的整包数据。expected 为 None 时不校验（老网页不带修订号），
        带了就必须相等，否则 409 —— 两个设备同时写不会互相覆盖。"""
        self.validate_id(snapshot_id)
        if not isinstance(data, dict):
            raise InvalidData("web snapshot must be an object")
        body = json.dumps(data, ensure_ascii=False, separators=(",", ":"), default=str)
        if len(body.encode("utf-8")) > 16 * 1024 * 1024:
            raise InvalidData("web snapshot exceeds 16 MiB")
        now = datetime.now(timezone.utc).isoformat()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT revision FROM web_snapshots WHERE id=?", (snapshot_id,)).fetchone()
            current = row[0] if row else 0
            if expected is not None and int(expected) != current:
                raise Conflict("web snapshot revision changed")
            revision = current + 1
            db.execute("INSERT OR REPLACE INTO web_snapshots (id, revision, body, updated_at) VALUES (?, ?, ?, ?)",
                       (snapshot_id, revision, body, now))
            db.execute("COMMIT")
        return revision

    def get_legacy_inbox(self, inbox_id="main"):
        self.validate_id(inbox_id)
        with self.connect() as db:
            row = db.execute("SELECT revision, body FROM legacy_inbox WHERE id=?", (inbox_id,)).fetchone()
        return {"revision": row[0], "data": json.loads(row[1])} if row else {"revision": 0, "data": None}

    def put_legacy_inbox(self, inbox_id, expected, data):
        self.validate_id(inbox_id)
        if type(expected) is not int or expected < 0 or not isinstance(data, dict):
            raise InvalidData("invalid legacy staging request")
        # Validate conversion before persistence. This staging table never writes
        # to real_books and has its own revision history/CAS boundary.
        convert_legacy_web_book(data)
        body = json.dumps(data, ensure_ascii=False, separators=(",", ":"), default=str)
        if len(body.encode("utf-8")) > 16 * 1024 * 1024:
            raise InvalidData("legacy snapshot exceeds 16 MiB")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT revision FROM legacy_inbox WHERE id=?", (inbox_id,)).fetchone()
            revision = row[0] if row else 0
            if revision != expected:
                raise Conflict("legacy snapshot revision changed")
            revision += 1
            db.execute("INSERT OR REPLACE INTO legacy_inbox VALUES (?, ?, ?)", (inbox_id, revision, body))
        return revision

    def get_daily(self, code):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit(): raise InvalidData("invalid exchange code")
        with self.connect() as db:
            row = db.execute("SELECT fetched_at, body FROM daily_bars WHERE code=?", (code,)).fetchone()
        return {"code": code, "source": "Tencent newfqkline qfqday", "fetchedAt": row[0], "bars": json.loads(row[1])} if row else None

    def put_daily(self, code, rows, stamp):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit() or not isinstance(rows, list) or not rows or not isinstance(stamp, str):
            raise InvalidData("invalid daily bars")
        incoming = {}
        for row in rows:
            if not isinstance(row, dict) or set(row) != {"date", "open", "close", "high", "low", "volume"}:
                raise InvalidData("invalid daily bar fields")
            day = row["date"]
            if not isinstance(day, str): raise InvalidData("invalid daily bar date")
            try:
                strict_iso_date(day)
                prices = {key: Decimal(str(row[key])) for key in ("open", "close", "high", "low", "volume")}
            except (ValueError, InvalidOperation): raise InvalidData("invalid daily bar values")
            if (any(not value.is_finite() for value in prices.values()) or
                    min(prices[key] for key in ("open", "close", "high", "low")) <= 0 or prices["volume"] < 0 or
                    prices["low"] > min(prices["open"], prices["close"]) or prices["high"] < max(prices["open"], prices["close"])):
                raise InvalidData("invalid daily OHLCV range")
            normalized = {"date": day, **{key: str(prices[key]) for key in ("open", "close", "high", "low", "volume")}}
            incoming[day] = normalized
        with self.connect() as db:
            previous = db.execute("SELECT body FROM daily_bars WHERE code=?", (code,)).fetchone()
            merged = {}
            if previous:
                try:
                    for row in json.loads(previous[0]):
                        if isinstance(row, dict) and isinstance(row.get("date"), str): merged[row["date"]] = row
                except (ValueError, TypeError): pass
            # Keep every archived day. A newly validated source row may update
            # that day's OHLCV, but a shorter upstream window never prunes history.
            merged.update(incoming)
            body = json.dumps([merged[key] for key in sorted(merged)], ensure_ascii=False)
            db.execute("INSERT OR REPLACE INTO daily_bars VALUES (?, ?, ?)", (code, stamp, body))

    def put_minute(self, code, rows, fetched_at):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit() or not isinstance(rows, list) or not rows:
            raise InvalidData("invalid minute archive")
        validated = []
        for row in rows:
            if not isinstance(row, dict) or set(row) != {"timestamp", "price", "volume", "iopv"}:
                raise InvalidData("invalid minute row")
            stamp, price, volume, iopv = row["timestamp"], row["price"], row["volume"], row["iopv"]
            if not isinstance(stamp, str) or "T" not in stamp:
                raise InvalidData("invalid minute timestamp")
            try:
                numeric_price = Decimal(str(price))
                numeric_volume = Decimal(str(volume)) if volume is not None else None
                numeric_iopv = Decimal(str(iopv)) if iopv is not None else None
            except (InvalidOperation, ValueError):
                raise InvalidData("invalid minute values")
            if (not numeric_price.is_finite() or numeric_price <= 0 or
                    (numeric_volume is not None and (not numeric_volume.is_finite() or numeric_volume < 0)) or
                    (numeric_iopv is not None and (not numeric_iopv.is_finite() or numeric_iopv <= 0))):
                raise InvalidData("invalid minute values")
            # A later raw minute pull must not erase a previously verified IOPV sample.
            validated.append((code, stamp, json.dumps(row, ensure_ascii=False), fetched_at))
        with self.connect() as db:
            for code, stamp, body, fetched_at in validated:
                existing = db.execute("SELECT body FROM minute_archive WHERE code=? AND stamp=?", (code, stamp)).fetchone()
                if existing:
                    prior = json.loads(existing[0])
                    incoming = json.loads(body)
                    if incoming.get("iopv") is None and prior.get("iopv") is not None:
                        incoming["iopv"] = prior["iopv"]
                        body = json.dumps(incoming, ensure_ascii=False)
                db.execute("INSERT OR REPLACE INTO minute_archive VALUES (?, ?, ?, ?)", (code, stamp, body, fetched_at))

    def get_dividend_events(self, code):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit(): raise InvalidData("invalid exchange code")
        with self.connect() as db:
            row = db.execute("SELECT fetched_at, body, rules_version FROM dividend_archive WHERE code=?", (code,)).fetchone()
        return {"code": code,
                "source": "Eastmoney fund F10 implemented distribution history + stock corporate actions + qfq/raw estimate",
                "fetchedAt": row[0], "rulesVersion": row[2], "events": json.loads(row[1])} if row else None

    def put_dividend_events(self, code, events, fetched_at, rules_version=0, replace=False):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit() or not isinstance(events, list) or not isinstance(fetched_at, str):
            raise InvalidData("invalid dividend archive")
        deduped = {}
        for item in events:
            if not isinstance(item, dict) or set(item) - {"code", "date", "amountPerShare", "isEstimated", "recordDate", "payDate"} or not {"code", "date", "amountPerShare"}.issubset(item):
                raise InvalidData("invalid dividend event")
            if item["code"] != code or not isinstance(item["date"], str): raise InvalidData("dividend code/date mismatch")
            try: strict_iso_date(item["date"]); amount = Decimal(str(item["amountPerShare"]))
            except (ValueError, InvalidOperation): raise InvalidData("invalid dividend date/amount")
            if not amount.is_finite() or amount <= 0 or item.get("isEstimated") not in (None, True, False):
                raise InvalidData("invalid dividend amount/provenance")
            event = {"code": code, "date": item["date"], "amountPerShare": str(amount), "isEstimated": item.get("isEstimated")}
            for field in ("recordDate", "payDate"):
                value = item.get(field)
                if value is not None:
                    if not isinstance(value, str): raise InvalidData("invalid dividend date field")
                    try: strict_iso_date(value)
                    except ValueError: raise InvalidData("invalid dividend date field")
                    event[field] = value
            deduped[item["date"]] = event
        with self.connect() as db:
            previous = db.execute("SELECT body FROM dividend_archive WHERE code=?", (code,)).fetchone()
            merged = {}
            # 默认与旧缓存合并（防某个源偶发只返回部分历史时把老记录冲掉）。
            # 但换了识别规则时必须整体替换 —— 否则新规则算出来是"没有分红"，
            # 这里会继续把旧的那条假分红合并回去，等于白改。
            if previous and not replace:
                try:
                    for old in json.loads(previous[0]):
                        if isinstance(old, dict) and old.get("code") == code and isinstance(old.get("date"), str): merged[old["date"]] = old
                except (ValueError, TypeError): pass
            for day, event in deduped.items():
                old = merged.get(day)
                if old and old.get("isEstimated") is False and event.get("isEstimated") is True: continue
                merged[day] = event
            body = json.dumps([merged[key] for key in sorted(merged)], ensure_ascii=False)
            db.execute("INSERT OR REPLACE INTO dividend_archive (code, fetched_at, body, rules_version) VALUES (?, ?, ?, ?)",
                       (code, fetched_at, body, int(rules_version)))

    def get_minute(self, code, day):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit() or not isinstance(day, str): raise InvalidData("invalid minute query")
        try: date.fromisoformat(day)
        except ValueError: raise InvalidData("invalid minute query")
        with self.connect() as db:
            rows = db.execute("SELECT body FROM minute_archive WHERE code=? AND stamp LIKE ? ORDER BY stamp",
                              (code, day + "%")).fetchall()
        return {"code": code, "day": day, "source": "Tencent minute query", "rows": [json.loads(row[0]) for row in rows]}

    def get_minute_range(self, code, days=120):
        """取最近 N 个自然日内的全部分时行（升序）。

        长期统计（1/5/20/60/120 日）要跨日读，所以不能只按单日查。
        只读不写：归档由 minute 采集线程负责，这里不制造任何数据。
        """
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit():
            raise InvalidData("invalid minute query")
        if not isinstance(days, int) or days <= 0 or days > 400:
            raise InvalidData("invalid minute window")
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).date().isoformat()
        with self.connect() as db:
            rows = db.execute("SELECT body FROM minute_archive WHERE code=? AND stamp >= ? ORDER BY stamp",
                              (code, cutoff)).fetchall()
        return [json.loads(row[0]) for row in rows]

    # MARK: 跨市场快照归档（116–145 的数据底座）

    def put_cross_samples(self, rows, fetched_at):
        """写海外市场快照。只做校验与去重，**不计算任何领先关系**。

        校验口径：market 必须在登记表里，stamp 必须是带时区的 ISO 时间，
        price 必须是正的有限数。任一不合法整行丢弃（不是整批失败）——
        一个市场源坏了不能把另外三个市场的样本一起丢。
        """
        if not isinstance(rows, list):
            raise InvalidData("invalid cross market rows")
        accepted, rejected = 0, 0
        with self.connect() as db:
            for row in rows:
                if not isinstance(row, dict):
                    rejected += 1
                    continue
                market = row.get("market")
                stamp = row.get("stamp")
                if market not in CROSS_MARKETS:
                    rejected += 1
                    continue
                if not isinstance(stamp, str) or "T" not in stamp:
                    rejected += 1
                    continue
                try:
                    price = Decimal(str(row.get("price")))
                    change = (None if row.get("changePercent") in (None, "")
                              else Decimal(str(row.get("changePercent"))))
                except (InvalidOperation, ValueError):
                    rejected += 1
                    continue
                if not price.is_finite() or price <= 0 or (change is not None and not change.is_finite()):
                    rejected += 1
                    continue
                db.execute(
                    "INSERT OR REPLACE INTO cross_market_samples VALUES (?, ?, ?, ?, ?, ?)",
                    (market, stamp, str(price),
                     None if change is None else str(change),
                     str(row.get("source") or ""),
                     str(row.get("observedAt") or fetched_at)))
                accepted += 1
        return {"accepted": accepted, "rejected": rejected, "fetchedAt": fetched_at}

    def get_cross_samples(self, market=None, days=None, since=None):
        """按市场取快照（升序）。days 表示「最近 N 个自然日」，since 表示起始日期。"""
        if market is not None and market not in CROSS_MARKETS:
            raise InvalidData("invalid cross market")
        clauses, args = [], []
        if market:
            clauses.append("market=?")
            args.append(market)
        if since:
            try:
                date.fromisoformat(since)
            except (ValueError, TypeError):
                raise InvalidData("invalid since date")
            clauses.append("stamp >= ?")
            args.append(since)
        elif days:
            if not isinstance(days, int) or days <= 0 or days > 400:
                raise InvalidData("invalid cross market window")
            cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).date().isoformat()
            clauses.append("stamp >= ?")
            args.append(cutoff)
        sql = "SELECT market, stamp, price, change_percent FROM cross_market_samples"
        if clauses:
            sql += " WHERE " + " AND ".join(clauses)
        sql += " ORDER BY stamp"
        with self.connect() as db:
            rows = db.execute(sql, tuple(args)).fetchall()
        return [{"market": row[0], "stamp": row[1], "price": row[2], "changePercent": row[3]} for row in rows]

    def cross_market_counts(self):
        """每个市场各存了多少行、覆盖到哪天 —— 用于「数据够不够做研究」的判断。"""
        with self.connect() as db:
            rows = db.execute(
                "SELECT market, COUNT(*), MIN(stamp), MAX(stamp) FROM cross_market_samples GROUP BY market"
            ).fetchall()
        return {row[0]: {"samples": row[1], "firstAt": row[2], "lastAt": row[3]} for row in rows}

    # MARK: 125 汇率上下文（USD/CNY 买卖价中点）

    def put_fx_samples(self, rows, fetched_at):
        """写 USD/CNY 中点样本。只做校验与去重，**不派生任何交易结论**。

        校验口径：pair 必须在登记表里，stamp 必须是带时区的 ISO 时间，
        bid/ask/mid 必须是正的有限数且 bid <= ask。任一不合法整行丢弃。
        过期样本在进入这里之前就已被 fx.archive_rows 拒收。
        """
        if not isinstance(rows, list):
            raise InvalidData("invalid fx rows")
        accepted, rejected = 0, 0
        with self.connect() as db:
            for row in rows:
                if not isinstance(row, dict):
                    rejected += 1
                    continue
                pair = row.get("pair")
                stamp = row.get("stamp")
                if pair not in FX_PAIRS:
                    rejected += 1
                    continue
                if not isinstance(stamp, str) or "T" not in stamp:
                    rejected += 1
                    continue
                try:
                    bid = Decimal(str(row.get("bid")))
                    ask = Decimal(str(row.get("ask")))
                    mid = Decimal(str(row.get("mid")))
                except (InvalidOperation, ValueError):
                    rejected += 1
                    continue
                if (not bid.is_finite() or not ask.is_finite() or not mid.is_finite()
                        or bid <= 0 or ask <= 0 or mid <= 0 or bid > ask):
                    rejected += 1
                    continue
                # 来源名称未验证 → 落库就拒。没有登记过的名字，数字再合理也不算有效汇率。
                source_name = row.get("sourceName")
                if source_name not in FX_VERIFIED_SOURCE_NAMES:
                    rejected += 1
                    continue
                db.execute(
                    "INSERT OR REPLACE INTO fx_samples VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (pair, stamp, str(bid), str(ask), str(mid),
                     str(row.get("observedAt") or fetched_at), source_name))
                accepted += 1
        return {"accepted": accepted, "rejected": rejected, "fetchedAt": fetched_at}

    def get_fx_samples(self, pair=None, days=None, since=None):
        """按交易对取中点样本（升序）。days 表示「最近 N 个自然日」。"""
        if pair is not None and pair not in FX_PAIRS:
            raise InvalidData("invalid fx pair")
        clauses, args = [], []
        if pair:
            clauses.append("pair=?")
            args.append(pair)
        if since:
            try:
                date.fromisoformat(since)
            except (ValueError, TypeError):
                raise InvalidData("invalid since date")
            clauses.append("stamp >= ?")
            args.append(since)
        elif days:
            if not isinstance(days, int) or days <= 0 or days > 400:
                raise InvalidData("invalid fx window")
            cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).date().isoformat()
            clauses.append("stamp >= ?")
            args.append(cutoff)
        sql = "SELECT pair, stamp, bid, ask, mid, observed_at, source_name FROM fx_samples"
        if clauses:
            sql += " WHERE " + " AND ".join(clauses)
        sql += " ORDER BY stamp"
        with self.connect() as db:
            rows = db.execute(sql, tuple(args)).fetchall()
        return [{"pair": row[0], "stamp": row[1], "bid": row[2], "ask": row[3],
                 "mid": row[4], "observedAt": row[5], "sourceName": row[6]} for row in rows]

    def fx_counts(self):
        """每个交易对各存了多少行、覆盖到哪天 —— 用于「数据够不够解释涨跌」。"""
        with self.connect() as db:
            rows = db.execute(
                "SELECT pair, COUNT(*), MIN(stamp), MAX(stamp), MIN(observed_at), MAX(observed_at) "
                "FROM fx_samples GROUP BY pair").fetchall()
        return {row[0]: {"samples": row[1], "firstAt": row[2], "lastAt": row[3],
                         "firstObservedAt": row[4], "lastObservedAt": row[5]} for row in rows}

    def get_research(self, run_id):
        self.validate_id(run_id)
        with self.connect() as db:
            row = db.execute("SELECT body FROM research_runs WHERE id=?", (run_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def put_research(self, run_id, body):
        self.validate_id(run_id)
        if not isinstance(body, dict): raise InvalidData("invalid research body")
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO research_runs VALUES (?, ?)", (run_id, json.dumps(body, ensure_ascii=False)))

    # MARK: 预注册的未来样本研究（指令七）

    def register_preregister(self, spec, now=None):
        """登记一个预注册未来样本研究。五条铁律全在这里卡死：

        ① 窗口必须真正在未来（window_start > 登记日），否则「看了结果再注册」。
        ② 假设冻结于登记时刻（frozen_at = 登记时刻），注册后无 UPDATE 路径改假设。
        ③ 不创建交易计划、④ 不碰 real_books / twin_accounts、⑤ 不生成交易信号。
           本方法只往 preregistered_studies 写一行，对这些表一个字都不碰。
        """
        now = now or datetime.now(timezone.utc)
        if not isinstance(spec, dict): raise InvalidData("invalid preregister spec")
        study_id = spec.get("id")
        self.validate_id(study_id)
        lead_market = spec.get("leadMarket")
        follow_code = spec.get("followCode")
        lead_minutes = spec.get("leadMinutes")
        window_days = spec.get("windowDays")
        window_start = spec.get("windowStart")
        window_end = spec.get("windowEnd")
        if lead_market not in CROSS_MARKETS:
            raise InvalidData("invalid lead market")
        if not isinstance(follow_code, str) or re.fullmatch(r"\d{6}", follow_code) is None:
            raise InvalidData("invalid follow code")
        if not isinstance(lead_minutes, int) or not (1 <= lead_minutes <= 600):
            raise InvalidData("invalid lead minutes")
        if not isinstance(window_days, int) or not (1 <= window_days <= 400):
            raise InvalidData("invalid window days")
        try:
            ws = strict_iso_date(window_start)
            we = strict_iso_date(window_end)
        except ValueError:
            raise InvalidData("invalid window date")
        if we < ws:
            raise InvalidData("window end before start")
        # ① 未来窗口：登记日（UTC）必须严格早于窗口起始日。
        today = now.astimezone(timezone.utc).date()
        if ws <= today:
            raise InvalidData("future observation window must start in the future")
        frozen_at = now.astimezone(timezone.utc).isoformat()
        fp = preregister_fingerprint(lead_market, follow_code, lead_minutes,
                                     window_days, frozen_at, window_start, window_end)
        with self.connect() as db:
            # 同一 id 重复注册直接失败：不允许「换个假设覆盖旧注册」来作弊。
            existing = db.execute("SELECT id FROM preregistered_studies WHERE id=?",
                                  (study_id,)).fetchone()
            if existing:
                raise Conflict("preregister id already exists")
            db.execute(
                "INSERT INTO preregistered_studies VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (study_id, lead_market, follow_code, int(lead_minutes), int(window_days),
                 frozen_at, window_start, window_end, frozen_at, fp, None, None))
        return {"id": study_id, "fingerprint": fp, "frozenAt": frozen_at,
                "state": "registered", "notTradingSignal": True}

    def get_preregister(self, study_id, as_of=None):
        """读回预注册研究，并**重算指纹核对漂移**。

        漂移（drifted）意味着假设字段被改过 —— 此时研究作废，state 直接标
        drifted，绝不能让它继续被当成有效证据。as_of 用于测试里固定「今天」。
        """
        self.validate_id(study_id)
        with self.connect() as db:
            row = db.execute(
                "SELECT lead_market, follow_code, lead_minutes, window_days, frozen_at, "
                "window_start, window_end, registered_at, immutable_fingerprint, "
                "settled_at, outcome_fingerprint FROM preregistered_studies WHERE id=?",
                (study_id,)).fetchone()
        if not row:
            return None
        (lead_market, follow_code, lead_minutes, window_days, frozen_at, window_start,
         window_end, registered_at, fp, settled_at, outcome_fingerprint) = row
        recomputed = preregister_fingerprint(lead_market, follow_code, lead_minutes,
                                             window_days, frozen_at, window_start, window_end)
        drifted = recomputed != fp
        as_of_date = strict_iso_date(as_of) if as_of else datetime.now(timezone.utc).date()
        if settled_at:
            state = "settled"
        elif as_of_date < strict_iso_date(window_start):
            state = "registered"
        elif as_of_date <= strict_iso_date(window_end):
            state = "open"
        else:
            state = "closed"
        return {"id": study_id, "leadMarket": lead_market, "followCode": follow_code,
                "leadMinutes": lead_minutes, "windowDays": window_days,
                "frozenAt": frozen_at, "windowStart": window_start, "windowEnd": window_end,
                "registeredAt": registered_at, "fingerprint": fp,
                "fingerprintDrifted": drifted,
                "state": ("drifted" if drifted else state),
                "settledAt": settled_at, "outcomeFingerprint": outcome_fingerprint,
                "notTradingSignal": True}

    def list_preregisters(self, follow_code=None):
        with self.connect() as db:
            if follow_code:
                rows = db.execute(
                    "SELECT id, follow_code FROM preregistered_studies WHERE follow_code=?",
                    (follow_code,)).fetchall()
            else:
                rows = db.execute(
                    "SELECT id, follow_code FROM preregistered_studies").fetchall()
        return [{"id": r[0], "followCode": r[1]} for r in rows]

    def settle_preregister(self, study_id, outcome, now=None):
        """结算：只把「结果指纹」记下来。绝不做计划/改账本/发信号。

        outcome 是任意可被 JSON 化的观测结论（比如窗口内跟随确认率）。
        这里只存它的指纹作为不可变记录，不解释、不交易、不下任何信号。
        """
        self.validate_id(study_id)
        if not isinstance(outcome, dict):
            raise InvalidData("invalid outcome")
        now = now or datetime.now(timezone.utc)
        settled_at = now.astimezone(timezone.utc).isoformat()
        outcome_fp = hashlib.sha256(json.dumps(outcome, ensure_ascii=False,
                                               sort_keys=True, default=str).encode("utf-8")).hexdigest()
        with self.connect() as db:
            row = db.execute("SELECT id FROM preregistered_studies WHERE id=?",
                             (study_id,)).fetchone()
            if not row:
                raise InvalidData("unknown preregistered study")
            db.execute(
                "UPDATE preregistered_studies SET settled_at=?, outcome_fingerprint=? WHERE id=?",
                (settled_at, outcome_fp, study_id))
        return {"id": study_id, "settledAt": settled_at,
                "outcomeFingerprint": outcome_fp, "notTradingSignal": True}

    def get_research_stats(self, code):
        """长期分时统计缓存。键里带最新分钟戳：归档有新数据就自动失效，不会读到旧结论。"""
        self.validate_id(code)
        with self.connect() as db:
            row = db.execute("SELECT stamp, body FROM research_stats WHERE code=?", (code,)).fetchone()
        if not row:
            return {"stamp": None, "stats": None}
        return {"stamp": row[0], "stats": json.loads(row[1])}

    def put_research_stats(self, code, stamp, stats):
        self.validate_id(code)
        if not isinstance(stats, dict) or not isinstance(stamp, str) or not stamp:
            raise InvalidData("invalid research stats")
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO research_stats VALUES (?, ?, ?, ?)",
                       (code, stamp, json.dumps(stats, ensure_ascii=False), datetime.now(timezone.utc).isoformat()))

    def get_news(self, code):
        """新闻缓存：正文不落库，只落标题与链接，最多 15 分钟。"""
        self.validate_id(code)
        with self.connect() as db:
            row = db.execute("SELECT body, updated_at FROM news_cache WHERE code=?", (code,)).fetchone()
        if not row:
            return {"body": None, "updatedAt": None}
        return {"body": json.loads(row[0]), "updatedAt": row[1]}

    def put_news(self, code, body):
        self.validate_id(code)
        if not isinstance(body, dict):
            raise InvalidData("invalid news body")
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO news_cache VALUES (?, ?, ?)",
                       (code, json.dumps(body, ensure_ascii=False), datetime.now(timezone.utc).isoformat()))

    def track_instrument(self, code, added_at):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit() or not isinstance(added_at, str) or not added_at:
            raise InvalidData("invalid tracked instrument")
        with self.connect() as db:
            db.execute("INSERT OR IGNORE INTO tracked_instruments VALUES (?, ?)", (code, added_at))

    def tracked_instruments(self):
        with self.connect() as db:
            rows = db.execute("SELECT code FROM tracked_instruments ORDER BY added_at, code").fetchall()
        return [row[0] for row in rows]

    def put_worker_status(self, name, updated_at, state, detail):
        if not isinstance(name, str) or re.fullmatch(r"[a-z-]{1,40}", name) is None:
            raise InvalidData("invalid worker name")
        if state not in ("starting", "idle", "ok", "degraded") or not isinstance(updated_at, str) or not updated_at:
            raise InvalidData("invalid worker status")
        if not isinstance(detail, str) or len(detail) > 500:
            raise InvalidData("invalid worker detail")
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO worker_status VALUES (?, ?, ?, ?)", (name, updated_at, state, detail))

    def worker_status(self):
        with self.connect() as db:
            rows = db.execute("SELECT name, updated_at, state, detail FROM worker_status ORDER BY name").fetchall()
        return [{"name": row[0], "updatedAt": row[1], "state": row[2], "detail": row[3]} for row in rows]

    def worker_health(self, now=None, stale_after_seconds=2400):
        """Expose stored worker heartbeat plus computed freshness; never report old OK as live."""
        now = now or datetime.now(timezone.utc)
        result = []
        for item in self.worker_status():
            try:
                updated = datetime.fromisoformat(item["updatedAt"])
                if updated.tzinfo is None: updated = updated.replace(tzinfo=timezone.utc)
                age = max(0, int((now - updated.astimezone(timezone.utc)).total_seconds()))
                parseable = True
            except (TypeError, ValueError):
                age = None; parseable = False
            stale = not parseable or age is None or age > stale_after_seconds
            result.append({**item, "ageSeconds": age, "stale": stale,
                           "health": "stale" if stale else item["state"]})
        return result

    def put_experiment(self, experiment_id, body):
        self.validate_id(experiment_id)
        if not isinstance(body, dict): raise InvalidData("experiment result must be an object")
        encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
        if len(encoded.encode("utf-8")) > 16 * 1024 * 1024: raise InvalidData("experiment result exceeds 16 MiB")
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO experiments VALUES (?, ?)", (experiment_id, encoded))

    def get_experiment(self, experiment_id):
        self.validate_id(experiment_id)
        with self.connect() as db:
            row = db.execute("SELECT body FROM experiments WHERE id=?", (experiment_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def get_twin_account(self, strategy):
        if strategy not in tuple("ABCDEFGH"): raise InvalidData("strategy must be A–H")
        with self.connect() as db:
            row = db.execute("SELECT revision, body FROM twin_accounts WHERE id=?", (strategy,)).fetchone()
        return {"revision": row[0], "account": json.loads(row[1])} if row else {"revision": 0, "account": None}

    def put_twin_account(self, strategy, expected_revision, account):
        if strategy not in tuple("ABCDEFGH"): raise InvalidData("strategy must be A–H")
        if type(expected_revision) is not int or expected_revision < 0 or not isinstance(account, dict):
            raise InvalidData("simulation revision/account is invalid")
        encoded = json.dumps(account, ensure_ascii=False, separators=(",", ":"))
        if len(encoded.encode("utf-8")) > 16 * 1024 * 1024: raise InvalidData("simulation account exceeds 16 MiB")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT revision FROM twin_accounts WHERE id=?", (strategy,)).fetchone()
            revision = row[0] if row else 0
            if revision != expected_revision: raise Conflict("simulation revision changed")
            revision += 1
            db.execute("INSERT OR REPLACE INTO twin_accounts VALUES (?, ?, ?)", (strategy, revision, encoded))
            db.execute("INSERT INTO twin_account_history VALUES (?, ?, ?)", (strategy, revision, encoded))
        return revision

    def twin_account_history(self, strategy):
        if strategy not in tuple("ABCDEFGH"): raise InvalidData("strategy must be A–H")
        with self.connect() as db:
            rows = db.execute("SELECT revision, body FROM twin_account_history WHERE id=? ORDER BY revision", (strategy,)).fetchall()
        return [{"revision": row[0], "account": json.loads(row[1])} for row in rows]
