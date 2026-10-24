"""125 汇率上下文的 NAS 侧采集：只采 USD/CNY 的**买卖价中点**，带时间戳，过期即拒收。

为什么单独放一层、以及这层只做三件事
-----------------------------------
A股 里的跨境 ETF（如 513520 追踪日经）有两个涨跌来源：海外标的本身，和汇率。
不把汇率那一层拆开，「日经涨了 A股 怎么没跟」就可能被误读成跟随失败。

本机（NAS）的职责被刻意限制死，只有三件事：
1. **直连采集**一个交易对：USD/CNY。不是四个，也不是"顺便全采"——
   少而准，采不到的就不采，宁可手机端显示「未接入」。
2. **只取买卖价中点**：源给的是买价与卖价，中点才是可引用的率；
   单取买价或卖价都会系统性偏移半个点差。
3. **过期即拒收**：源时间戳超过 MAX_AGE_SECONDS 的样本直接丢弃并记录原因，
   绝不让一条昨天的汇率被当成今天的实时值。

它**不**做的事（与 125 的整体定位一致，写进代码而不是写在文档里）：
   * 不参与任何交易决策：这里出现的字段只有买价/卖价/中点/时间戳，
     没有价格建议、没有份额、没有方向；
   * 不生成信号：它只进入**风险上下文**，用来解释涨跌，不做买卖理由；
   * 不猜时间：解析不出源时间戳就整条丢弃，不用「NAS 当前时间」冒充当下。

实测源格式（2026-10-24，新浪外汇 `fx_susdcny`）：
    var hq_str_fx_susdcny="03:00:01,6.6702,6.6704,6.6704,40.0,6.6730,6.6739,6.6699,6.6704,在岸人民币,...,0.0040,此行情由新浪财经计算得出,...,,2026-10-24";
    下标：0 时间，1 买价，2 卖价，3 现价，4 成交量，5 今开，6 最高，7 最低，8 昨收，9 名称，17 日期
    （时间戳：日期 + 时间 按北京时间解析，即源自己报的时刻 = 交易所时间戳）
"""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

# 只采 USD/CNY。125 的口径就是这一个交易对，多了反而引入没验证过的源。
# `source` 是**来源名称**：它必须是一个可验证的名字，手机端只认登记过的名字，
# 来源名称未验证的汇率一律不许进入手机的决策上下文（见 iOS 端 NextFXSourceName）。
PAIRS = {
    "USDCNY": {"symbol": "fx_susdcny", "name": "在岸人民币", "source": "Sina fx"},
}

# 本机能产生的、且被手机端承认的来源名称。改/加数据源时必须先在这里登记，
# 否则采上来的值在手机端会被判「来源未验证」而不得进入决策上下文。
VERIFIED_SOURCE_NAMES = ("Sina fx",)

SINA_ENDPOINT = "https://hq.sinajs.cn/list="

# 源时间戳超过这么久，说明这条汇率已经不能代表当下 → 过期即拒收。
# 与手机端 NextFXContextEngine.staleHours(26) 保持同一口径，
# 免得 NAS 说还新鲜、手机说过期。
MAX_AGE_SECONDS = 26 * 3600

# 点差上限：中点必须由合理的买卖价算出。点差过大说明源在异常状态（或字段解析错位），
# 这类样本一律丢弃，绝不让一个错的中点被当成汇率。
MAX_SPREAD_RATIO = 0.02

try:
    BEIJING = ZoneInfo("Asia/Shanghai")
except Exception:  # 没有时区数据时退化为固定 +8，绝不因此崩溃
    BEIJING = timezone(timedelta(hours=8))

_DATE_FIELD = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_TIME_FIELD = re.compile(r"^\d{2}:\d{2}:\d{2}$")


def _number(text):
    try:
        value = float(str(text).strip())
    except (TypeError, ValueError):
        return None
    return value if value == value and abs(value) != float("inf") else None


def _stamp(date_text, time_text):
    """把源自己报的「日期 + 时间」按北京时间解析成 aware datetime。

    解析不出来就返回 None —— 宁可丢一个样本，也不用 NAS 当前时间冒充当下。
    """
    date_text = (date_text or "").strip()
    time_text = (time_text or "").strip()
    if not date_text or not time_text:
        return None
    try:
        naive = datetime.strptime(f"{date_text} {time_text}", "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    return naive.replace(tzinfo=BEIJING)


def _source_stamp(fields):
    """从字段里**找**源时间：日期优先取下标 17，时间取下标 0。

    不写死「只认某一个下标」：源换行/改字段顺序时，用一个正则扫描还能救回来；
    但扫描不到时返回 None（丢弃），绝不猜。
    """
    date_text = None
    if len(fields) > 17 and _DATE_FIELD.match(fields[17].strip()):
        date_text = fields[17].strip()
    if date_text is None:
        date_text = next((f.strip() for f in fields if _DATE_FIELD.match(f.strip())), None)
    time_text = fields[0].strip() if fields and _TIME_FIELD.match(fields[0].strip()) else None
    if time_text is None:
        time_text = next((f.strip() for f in fields if _TIME_FIELD.match(f.strip())), None)
    return _stamp(date_text, time_text)


def parse_sina(body, now=None):
    """解析新浪外汇响应 → 样本列表（含买卖价与中点）。

    只认 PAIRS 里登记的符号；解析不出时间或价格不合法的整条丢弃。
    """
    now = now or datetime.now(timezone.utc)
    by_symbol = {meta["symbol"]: pair for pair, meta in PAIRS.items()}
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
        pair = by_symbol.get(symbol)
        if pair is None or not payload:
            continue
        fields = payload.split(",")
        if len(fields) < 10:
            continue
        bid = _number(fields[1])
        ask = _number(fields[2])
        last = _number(fields[3])
        stamp = _source_stamp(fields)
        samples.append({
            "pair": pair,
            "symbol": symbol,
            # 来源名称：手机上只认验证过的名字，未验证的名字不得进入决策上下文。
            "sourceName": PAIRS[pair]["source"],
            "bid": bid,
            "ask": ask,
            "last": last,
            "mid": None if bid is None or ask is None else (bid + ask) / 2,
            "sourceAt": stamp.isoformat() if stamp else None,
            "observedAt": now.astimezone(timezone.utc).isoformat(),
        })
    samples.sort(key=lambda item: item["pair"])
    return samples


def fetch_snapshots(opener=urlopen, endpoint=SINA_ENDPOINT, now=None, timeout=10):
    """直连源拉一次 USD/CNY。一次请求覆盖登记的全部符号。"""
    symbols = ",".join(meta["symbol"] for meta in PAIRS.values())
    request = Request(endpoint + symbols, headers={
        "Referer": "https://finance.sina.com.cn",
        "User-Agent": "GuanpanProNext/3 (NAS fx archive)",
    })
    with opener(request, timeout=timeout) as response:
        if response.status != 200:
            raise OSError("fx source unavailable")
        # 新浪返回 GB18030；这里只取数字与 ASCII 字段，保守解码即可。
        body = response.read(200_000).decode("gb18030", "replace")
    return parse_sina(body, now=now)


def archive_rows(samples, now=None, max_age_seconds=MAX_AGE_SECONDS,
                 max_spread_ratio=MAX_SPREAD_RATIO):
    """把样本整理成可入库行，并明确哪些被丢掉、为什么。

    返回 `(rows, dropped)`：
      rows    = [{"pair","stamp","bid","ask","mid","observedAt","sourceName"}]
      dropped = [{"pair","reason"}]
      reason ∈ noSourceTime / staleSource / sourceInFuture / invalidPrice /
               spreadTooWide / unverifiedSource

    「过期即拒收」就落在下面：源时间戳太旧 → staleSource，直接不入库。
    另外「来源名称未验证」同样拒收：名字不在登记名单里的值，
    就算数字再合理也不许落库，更不许进入手机的决策上下文。
    """
    now = now or datetime.now(timezone.utc)
    rows, dropped = [], []
    for sample in samples or []:
        if not isinstance(sample, dict):
            continue
        pair = sample.get("pair")
        if pair not in PAIRS:
            continue
        # 来源名称必须已验证：没有登记过的名字，一律不当成有效汇率。
        if sample.get("sourceName") not in VERIFIED_SOURCE_NAMES:
            dropped.append({"pair": pair, "reason": "unverifiedSource"})
            continue
        bid = _number(sample.get("bid"))
        ask = _number(sample.get("ask"))
        mid = _number(sample.get("mid"))
        if bid is None or ask is None or mid is None or bid <= 0 or ask <= 0 or mid <= 0:
            dropped.append({"pair": pair, "reason": "invalidPrice"})
            continue
        if bid > ask:
            dropped.append({"pair": pair, "reason": "invalidPrice"})
            continue
        # 点差过大：源异常或字段错位，不当成真汇率。
        if (ask - bid) / mid > max_spread_ratio:
            dropped.append({"pair": pair, "reason": "spreadTooWide"})
            continue
        source_text = sample.get("sourceAt")
        if not source_text:
            dropped.append({"pair": pair, "reason": "noSourceTime"})
            continue
        try:
            source_at = datetime.fromisoformat(str(source_text))
        except ValueError:
            dropped.append({"pair": pair, "reason": "noSourceTime"})
            continue
        if source_at.tzinfo is None:
            source_at = source_at.replace(tzinfo=BEIJING)
        age = (now - source_at.astimezone(timezone.utc)).total_seconds()
        if age < -120:
            dropped.append({"pair": pair, "reason": "sourceInFuture"})
            continue
        if age > max_age_seconds:
            dropped.append({"pair": pair, "reason": "staleSource"})
            continue
        rows.append({
            "pair": pair,
            "stamp": source_at.astimezone(timezone.utc).isoformat(),
            "bid": str(bid),
            "ask": str(ask),
            "mid": str(mid),
            "observedAt": sample.get("observedAt") or now.astimezone(timezone.utc).isoformat(),
            "sourceName": sample.get("sourceName"),
        })
    rows.sort(key=lambda item: (item["pair"], item["stamp"]))
    return rows, dropped
