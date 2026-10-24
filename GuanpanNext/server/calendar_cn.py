"""A 股交易日历（2026 年）。

为什么 NAS 需要它：跨市场线程按上海时间 08:00–16:10 采样，
大陆指数的抓取窗口与 A 股开市时间重叠。休市日源仍会返回「最后一个成交价」，
如果照抓，归档里会出现一整段不存在的横盘——这正是回放器最怕的污染源
（`crossmarket.archive_rows` 已经会丢掉源时间过期的样本，但没有交易日历，
它没法区分「收盘后重复的最后价」与「休市日压根没开市」）。

口径说明（重要）：
- 交易日 = 周一至周五 且 不在法定假日里。
- **周末调休上班日不是交易日**：2026 年 1/4、2/14、2/28、5/9、9/20、10/10
  虽然上班，但沪深交易所不开市。把它们当交易日会去抓一堆不存在的行情。
- 假日表按《国务院办公厅关于 2026 年部分节假日安排的通知》（2025-11-04）整理，
  只列落在工作日的假日；落在周末的假日不影响判定（周末本来就休市）。
  交易所另有临时休市安排时，以交易所公告为准——所以这张表带年份，不做无限外推。
"""
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

try:
    SHANGHAI = ZoneInfo("Asia/Shanghai")
except Exception:  # Windows 上没装 tzdata 时 ZoneInfo 会失败
    # 中国 1991 年后不再有夏令时，固定 +08:00 与 Asia/Shanghai 完全等价。
    # 这里退化成固定偏移是为了让服务与测试在没有 tzdata 的机器上也能跑，
    # 而不是让整个采集器因为缺一个时区库就起不来。
    SHANGHAI = timezone(timedelta(hours=8), "Asia/Shanghai")

# 2026 年落在工作日的休市日（周末假日不重复列）。
A_SHARE_HOLIDAYS_2026 = {
    "2026-01-01", "2026-01-02",                                  # 元旦（1/3 为周六）
    "2026-02-16", "2026-02-17", "2026-02-18",
    "2026-02-19", "2026-02-20", "2026-02-23",                    # 春节 2/15–2/23
    "2026-04-06",                                                # 清明 4/4–4/6
    "2026-05-01", "2026-05-04", "2026-05-05",                    # 劳动节 5/1–5/5
    "2026-06-19",                                                # 端午 6/19–6/21
    "2026-09-25",                                                # 中秋 9/25–9/27
    "2026-10-01", "2026-10-02",
    "2026-10-05", "2026-10-06", "2026-10-07",                    # 国庆 10/1–10/7
}

# 调休上班的周末：公司上班，交易所不开市。列出来是为了让判定逻辑显式说明
# 「不是漏判，是刻意判休市」。
A_SHARE_MAKEUP_WORKDAYS_2026 = {
    "2026-01-04", "2026-02-14", "2026-02-28",
    "2026-05-09", "2026-09-20", "2026-10-10",
}

CALENDARS = {2026: A_SHARE_HOLIDAYS_2026}


def to_shanghai_date(value):
    """把 datetime（任意时区）或 date/ISO 字符串统一成上海日期。"""
    if isinstance(value, datetime):
        return (value.astimezone(SHANGHAI) if value.tzinfo else value.replace(tzinfo=SHANGHAI)).date()
    if isinstance(value, date):
        return value
    if isinstance(value, str):
        return date.fromisoformat(value[:10])
    raise TypeError("expect date, datetime or ISO date string")


def is_a_share_trading_day(value):
    """A 股是否开市。

    未知年份返回 **False** 而不是 True：宁可少抓一天，
    也不要在没有日历的年份里假装每天都是交易日。
    """
    day = to_shanghai_date(value)
    if day.weekday() >= 5:
        return False
    holidays = CALENDARS.get(day.year)
    if holidays is None:
        return False
    return day.isoformat() not in holidays


def mainland_indices_should_fetch(value):
    """大陆指数今天该不该抓。休市日不抓，避免把「最后一个成交价」写成新观测。"""
    return is_a_share_trading_day(value)


def describe(value):
    """给状态行用的一句人话，方便在 NAS 状态页上直接看懂为什么没抓。"""
    day = to_shanghai_date(value)
    if is_a_share_trading_day(day):
        return f"{day.isoformat()} 是 A 股交易日"
    if day.weekday() >= 5:
        if day.isoformat() in A_SHARE_MAKEUP_WORKDAYS_2026:
            return f"{day.isoformat()} 是调休上班日，但交易所不开市"
        return f"{day.isoformat()} 是周末，A 股休市"
    if CALENDARS.get(day.year) is None:
        return f"{day.isoformat()} 不在已知交易日历年份内，按休市处理（不猜）"
    return f"{day.isoformat()} 是 A 股法定休市日"


MAINLAND_INDEX_NAMES = ("上证指数", "深证成指", "创业板指", "沪深300")
MAINLAND_INDEX_SECIDS = ("1.000001", "0.399001", "0.399006", "1.000300")


def is_mainland_index_name(name):
    return name in MAINLAND_INDEX_NAMES


def is_mainland_index_secid(secid):
    return secid in MAINLAND_INDEX_SECIDS
