"""A 股交易日历与「休市日不抓大陆指数」的验收测试。

这一项不是「多抓少抓」的问题，而是**数据真假**的问题：
休市日源依然返回最后一个成交价，照抓就会在归档里造出一段不存在的横盘。
回放器按交易日数算样本，这些假日子会同时抬高样本量与「稳定程度」。
"""
import unittest
from datetime import date, datetime, timezone

import calendar_cn
import market


class CalendarTests(unittest.TestCase):

    def test_normal_weekdays_are_trading_days(self):
        for day in ("2026-01-05", "2026-02-24", "2026-03-02", "2026-11-30", "2026-12-31"):
            self.assertTrue(calendar_cn.is_a_share_trading_day(day), day)

    def test_spring_festival_is_closed(self):
        for day in ("2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19",
                    "2026-02-20", "2026-02-23"):
            self.assertFalse(calendar_cn.is_a_share_trading_day(day), day)
        self.assertTrue(calendar_cn.is_a_share_trading_day("2026-02-24"))

    def test_other_holidays_are_closed(self):
        for day in ("2026-01-01", "2026-01-02", "2026-04-06", "2026-05-01",
                    "2026-05-04", "2026-05-05", "2026-06-19", "2026-09-25",
                    "2026-10-01", "2026-10-07"):
            self.assertFalse(calendar_cn.is_a_share_trading_day(day), day)
        self.assertTrue(calendar_cn.is_a_share_trading_day("2026-10-08"))

    def test_weekends_are_closed(self):
        self.assertFalse(calendar_cn.is_a_share_trading_day("2026-01-03"))
        self.assertFalse(calendar_cn.is_a_share_trading_day("2026-10-11"))

    def test_makeup_workdays_are_still_market_holidays(self):
        # 1/4、2/14、9/20 都是「要上班的周日」，但交易所不开市。
        for day in sorted(calendar_cn.A_SHARE_MAKEUP_WORKDAYS_2026):
            self.assertFalse(calendar_cn.is_a_share_trading_day(day), day)
        self.assertIn("调休上班日", calendar_cn.describe("2026-09-20"))

    def test_unknown_year_is_treated_as_closed(self):
        # 没有日历的年份不猜：宁可少抓，也不假装每天开市。
        self.assertFalse(calendar_cn.is_a_share_trading_day("2027-03-02"))

    def test_datetime_is_converted_to_shanghai_date(self):
        # 2026-10-01 08:00 UTC = 16:00 上海，仍是 10/1，休市。
        stamp = datetime(2026, 10, 1, 8, 0, tzinfo=timezone.utc)
        self.assertFalse(calendar_cn.is_a_share_trading_day(stamp))
        # 2026-10-07 17:00 UTC = 10/8 01:00 上海，已经是节后。
        after = datetime(2026, 10, 7, 17, 0, tzinfo=timezone.utc)
        self.assertTrue(calendar_cn.is_a_share_trading_day(after))

    def test_describe_names_the_reason(self):
        self.assertIn("法定休市日", calendar_cn.describe("2026-10-01"))
        self.assertIn("周末", calendar_cn.describe("2026-01-03"))
        self.assertIn("交易日", calendar_cn.describe("2026-03-02"))


class IndexFetchFilterTests(unittest.TestCase):

    HOLIDAY = datetime(2026, 10, 1, 3, 0, tzinfo=timezone.utc)
    TRADING_DAY = datetime(2026, 10, 22, 3, 0, tzinfo=timezone.utc)

    def setUp(self):
        self.original_east = market._fetch_eastmoney_indices
        self.original_sina = market._fetch_sina_indices

    def tearDown(self):
        market._fetch_eastmoney_indices = self.original_east
        market._fetch_sina_indices = self.original_sina

    def test_source_list_excludes_mainland_on_holiday(self):
        holiday = market.active_index_sources(now=self.HOLIDAY)
        names = {name for name, _ in holiday}
        self.assertEqual(names & set(calendar_cn.MAINLAND_INDEX_NAMES), set())
        self.assertIn("日经225", names)

    def test_source_list_keeps_mainland_on_trading_day(self):
        trading = market.active_index_sources(now=self.TRADING_DAY)
        names = {name for name, _ in trading}
        self.assertEqual(len(trading), 10)
        self.assertEqual(names & set(calendar_cn.MAINLAND_INDEX_NAMES), set(calendar_cn.MAINLAND_INDEX_NAMES))

    def test_holiday_strips_mainland_from_result(self):
        market._fetch_eastmoney_indices = lambda now=None: [
            {"name": "上证指数", "symbol": "1.000001", "price": 2.0},
            {"name": "日经225", "symbol": "100.N225", "price": 1.0},
        ]
        quotes = market.fetch_indices(now=self.HOLIDAY)
        self.assertEqual([quote["name"] for quote in quotes], ["日经225"])

    def test_trading_day_keeps_mainland_in_result(self):
        market._fetch_eastmoney_indices = lambda now=None: [
            {"name": "上证指数", "symbol": "1.000001", "price": 2.0},
            {"name": "日经225", "symbol": "100.N225", "price": 1.0},
        ]
        quotes = market.fetch_indices(now=self.TRADING_DAY)
        self.assertEqual([quote["name"] for quote in quotes], ["上证指数", "日经225"])

    def test_sina_fallback_also_strips_mainland(self):
        def broken(now=None):
            raise OSError("eastmoney down")

        market._fetch_eastmoney_indices = broken
        market._fetch_sina_indices = lambda now=None: [
            {"name": "上证指数", "symbol": "s_sh000001", "price": 2.0},
            {"name": "恒生指数", "symbol": "rt_hkHSI", "price": 3.0},
        ]
        quotes = market.fetch_indices(now=self.HOLIDAY)
        self.assertEqual([quote["name"] for quote in quotes], ["恒生指数"])


if __name__ == "__main__":
    unittest.main()
