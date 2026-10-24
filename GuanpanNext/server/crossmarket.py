"""跨市场先行信号的数据层：只**采集与归档**，不计算任何领先关系。

为什么单独放一层
----------------
116–145 那套（日韩午休修复 → A股午后修复）要能被证伪，前提是先有
**日韩自己的分钟级历史**。手机端只能拿到「此刻一个快照」，没有历史就永远只能
凭感觉说「日韩今天上午反弹了」。所以 NAS 在这里的职责只有一件事：
每分钟把 4 个海外市场的快照落库，慢慢攒出一份可回放的数据集。

三条不许越界的规矩（写进代码而不是写在文档里）
----------------------------------------------
1. **不在这里算相关性、胜率、"领先 X 分钟"**。NAS 是仓库，研究在手机端。
   这里出现任何 `correlation` / `winRate` 都说明越界了。
2. **源本身就是快照，不是分钟线**。所以这里存的是「我们几点几分看到的价」，
   不是「交易所那一刻的成交」。字段名用 `observedAt`（我们看到的时刻）
   与 `sourceAt`（源自己报的时刻），两者都存，方便以后判断数据可信度。
3. **源时间过期的样本一律丢弃**。收盘后源会一直返回最后成交价，
   把它当成「新的一分钟」存进去，会凭空造出一段横盘，进而污染回放结论。
   `MAX_SOURCE_AGE_SECONDS` 之外的一律不落库，并在返回里说明原因。
"""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

# 采集范围：只收海外 4 个市场。A股自己的分钟线由 market/minute 归档负责，
# 不重复采集（重复采集等于同一份数据存两遍，还会对不上）。
MARKETS = {
    "japan": {"symbol": "b_NKY", "name": "日经225", "timeZone": "Asia/Tokyo", "shape": "b"},
    "korea": {"symbol": "b_KOSPI", "name": "韩国KOSPI", "timeZone": "Asia/Seoul", "shape": "b"},
    "hongKong": {"symbol": "rt_hkHSTECH", "name": "恒生科技", "timeZone": "Asia/Hong_Kong", "shape": "hk"},
    "unitedStates": {"symbol": "gb_$ndx", "name": "纳斯达克100", "timeZone": "America/New_York", "shape": "gb"},
}

SINA_ENDPOINT = "https://hq.sinajs.cn/list="
# 源时间超过这么久没更新，说明那个市场已经休市/停更，快照不能当成新观测。
MAX_SOURCE_AGE_SECONDS = 300


def _tz(key):
    return ZoneInfo(MARKETS[key]["timeZone"])


def _number(text):
    try:
        value = float(str(text).strip())
    except (TypeError, ValueError):
        return None
    return value if value == value and abs(value) != float("inf") else None


def _stamp(key, date_text, time_text):
    """把源自己报的「日期 + 时间」按该市场时区解析成 aware datetime。

    解析不出来就返回 None —— 宁可丢一个样本，也不猜时间。
    """
    date_text = (date_text or "").strip().replace("/", "-")
    time_text = (time_text or "").strip()
    if not date_text or not time_text:
        return None
    text = f"{date_text} {time_text}"
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            naive = datetime.strptime(text, fmt)
        except ValueError:
            continue
        return naive.replace(tzinfo=_tz(key))
    return None


_DATE_FIELD = re.compile(r"^\d{4}[-/]\d{2}[-/]\d{2}$")
_TIME_FIELD = re.compile(r"^\d{2}:\d{2}:\d{2}$")
_DATETIME_FIELD = re.compile(r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})$")


def _source_stamp(key, fields):
    """从字段里**找**源时间，不写死下标。

    实测过三种排布（2026-10-23）：日经/KOSPI 是「时间,日期,更新时间」，
    恒生科技是「...,日期,时间」，纳指是一个字段里带 "2026-10-24 05:30:00"。
    写死下标的后果是恒生科技永远取不到时间、样本全被丢掉——而且是静默丢掉。

    多个时刻字段同时存在时取**最早**那个：收盘后源会同时给「报价时间」与
    「更新时间」，用较晚的会把十几分钟前的旧价当成新鲜数据。
    """
    for text in fields:
        match = _DATETIME_FIELD.match(text.strip())
        if match:
            return _stamp(key, match.group(1), match.group(2))
    date_index = next((index for index, text in enumerate(fields) if _DATE_FIELD.match(text.strip())), None)
    if date_index is None:
        return None
    times = [(index, text.strip()) for index, text in enumerate(fields) if _TIME_FIELD.match(text.strip())]
    if not times:
        return None
    _, earliest = min(times, key=lambda pair: pair[1])
    return _stamp(key, fields[date_index], earliest)


def parse_sina(body, now=None):
    """解析新浪多行响应 → 样本列表。

    只认 `MARKETS` 里登记的符号；解析不出时间的整条丢弃（不是"用 now 补上"）。
    """
    now = now or datetime.now(timezone.utc)
    by_symbol = {meta["symbol"]: key for key, meta in MARKETS.items()}
    samples = []
    for line in (body or "").split("\n"):
        if "hq_str_" not in line or '="' not in line:
            continue
        try:
            head, rest = line.split("hq_str_", 1)
            symbol, payload = rest.split('="', 1)
        except ValueError:
            continue
        symbol = symbol.strip()
        payload = payload.rsplit('"', 1)[0]
        key = by_symbol.get(symbol)
        if key is None or not payload:
            continue
        fields = payload.split(",")
        shape = MARKETS[key]["shape"]
        price = change_percent = None
        if shape == "b" and len(fields) >= 7:
            # 日经/KOSPI：名称,现价,涨跌额,涨跌幅,时间文字,时间,日期,更新时间
            price = _number(fields[1])
            change_percent = _number(fields[3])
        elif shape == "hk" and len(fields) >= 19:
            # 恒生科技：代码,名称,今开,昨收,最高,最低,现价,涨跌额,涨跌幅,... 日期,时间
            price = _number(fields[6])
            change_percent = _number(fields[8])
        elif shape == "gb" and len(fields) >= 5:
            # 纳指100：名称,现价,涨跌额,"日期 时间",涨跌幅,...
            price = _number(fields[1])
            change_percent = _number(fields[4])
        if price is None or price <= 0:
            continue
        source_at = _source_stamp(key, fields)
        samples.append({"market": key, "name": MARKETS[key]["name"], "symbol": symbol,
                        "price": price, "changePercent": change_percent,
                        "sourceAt": source_at.isoformat() if source_at else None,
                        "observedAt": now.astimezone(timezone.utc).isoformat()})
    # 固定返回顺序，测试与日志才好比对
    samples.sort(key=lambda item: item["market"])
    return samples


def fetch_snapshots(opener=urlopen, endpoint=SINA_ENDPOINT, now=None, timeout=10):
    """拉一次 4 个市场的快照。一次请求覆盖全部符号，不给 NAS 每分钟发 4 个请求。"""
    symbols = ",".join(MARKETS[key]["symbol"] for key in MARKETS)
    request = Request(endpoint + symbols, headers={
        "Referer": "https://finance.sina.com.cn",
        "User-Agent": "GuanpanProNext/3 (NAS cross-market archive)",
    })
    with opener(request, timeout=timeout) as response:
        if response.status != 200:
            raise OSError("cross market source unavailable")
        # 新浪返回 GB18030；这里只用数字字段，用 replace 保守解码即可。
        body = response.read(200_000).decode("gb18030", "replace")
    return parse_sina(body, now=now)


def archive_rows(samples, now=None, max_age_seconds=MAX_SOURCE_AGE_SECONDS):
    """把样本整理成可入库行，并明确哪些被丢掉、为什么。

    返回 `(rows, dropped)`：
      rows    = [{"market","stamp","price","changePercent","source","observedAt"}]
      dropped = [{"market","reason"}]，reason ∈ noSourceTime / staleSource / sourceInFuture / invalidPrice
    """
    now = now or datetime.now(timezone.utc)
    rows, dropped = [], []
    for sample in samples or []:
        if not isinstance(sample, dict):
            continue
        market = sample.get("market")
        if market not in MARKETS:
            continue
        price = _number(sample.get("price"))
        if price is None or price <= 0:
            dropped.append({"market": market, "reason": "invalidPrice"})
            continue
        source_text = sample.get("sourceAt")
        if not source_text:
            dropped.append({"market": market, "reason": "noSourceTime"})
            continue
        try:
            source_at = datetime.fromisoformat(str(source_text))
        except ValueError:
            dropped.append({"market": market, "reason": "noSourceTime"})
            continue
        if source_at.tzinfo is None:
            source_at = source_at.replace(tzinfo=_tz(market))
        age = (now - source_at.astimezone(timezone.utc)).total_seconds()
        if age < -120:
            dropped.append({"market": market, "reason": "sourceInFuture"})
            continue
        if age > max_age_seconds:
            dropped.append({"market": market, "reason": "staleSource"})
            continue
        rows.append({
            "market": market,
            "stamp": source_at.astimezone(timezone.utc).isoformat(),
            "price": str(price),
            "changePercent": None if sample.get("changePercent") is None else str(sample["changePercent"]),
            "source": MARKETS[market]["symbol"],
            "observedAt": (sample.get("observedAt") or now.astimezone(timezone.utc).isoformat()),
        })
    rows.sort(key=lambda item: (item["market"], item["stamp"]))
    return rows, dropped


def group_series(rows):
    """按「市场 → 该市场本地日期 → 时间升序的点」分组。

    日期必须按各市场自己的时区切：用上海时区切纳斯达克，会把美股一个交易日
    劈成两天，回放时"隔夜变化"直接算错。
    """
    series = {}
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        market = row.get("market")
        if market not in MARKETS:
            continue
        price = _number(row.get("price"))
        stamp_text = row.get("stamp")
        if price is None or price <= 0 or not stamp_text:
            continue
        try:
            stamp = datetime.fromisoformat(str(stamp_text))
        except ValueError:
            continue
        if stamp.tzinfo is None:
            stamp = stamp.replace(tzinfo=timezone.utc)
        local = stamp.astimezone(_tz(market))
        series.setdefault(market, {}).setdefault(local.date().isoformat(), []).append({
            "timestamp": stamp.astimezone(timezone.utc).isoformat(),
            "price": price,
            "changePercent": _number(row.get("changePercent")),
        })
    for days in series.values():
        for points in days.values():
            points.sort(key=lambda item: item["timestamp"])
    return series


def availability(rows, minimum_days=30, now=None):
    """这个市场到底有没有足够的数据支撑研究。这是「敢说不」的地方。

    手机端的回放器要求「提出假设的样本 ≥ 30 个交易日」；这里提前把每个市场的
    可用天数算清楚，不够就直说不够，别让用户以为工具在跑、其实一直是空的。
    """
    now = now or datetime.now(timezone.utc)
    series = group_series(rows)
    report = {}
    for key, meta in MARKETS.items():
        days = series.get(key, {})
        ordered = sorted(days)
        count = len(ordered)
        latest = None
        for day in ordered:
            for point in days[day]:
                latest = point["timestamp"]
        lag = None
        if latest:
            try:
                lag = round((now - datetime.fromisoformat(latest)).total_seconds() / 60, 1)
            except ValueError:
                lag = None
        report[key] = {
            "market": key,
            "name": meta["name"],
            "symbol": meta["symbol"],
            "days": count,
            "samples": sum(len(points) for points in days.values()),
            "firstDay": ordered[0] if ordered else None,
            "lastDay": ordered[-1] if ordered else None,
            "latestAt": latest,
            "latestAgeMinutes": lag,
            "minimumDays": minimum_days,
            "sufficient": count >= minimum_days,
            "note": (f"{meta['name']} 已归档 {count} 个交易日（需 ≥{minimum_days} 天才能验证领先关系）"
                     if count < minimum_days else
                     f"{meta['name']} 已归档 {count} 个交易日，可参与回放验证"),
        }
    report["_meta"] = {
        "source": "Sina snapshot sampled every minute (no exchange-grade minute bars)",
        "minimumDays": minimum_days,
        "anySufficient": any(report[key]["sufficient"] for key in MARKETS),
        "statement": ("日韩/港股/美股的分钟级历史只能靠 NAS 自己采样攒出来；"
                      "样本不够时手机端必须显示「暂无稳定领先关系」，不得用少量样本下结论。"),
    }
    return report
