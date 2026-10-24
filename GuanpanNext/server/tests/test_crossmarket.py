"""跨市场快照归档的验收测试（116–145 的数据底座）。

重点不是「能不能解析」，而是**这套数据能不能支撑证伪**：

1. 源只给快照、不给分钟线 —— 所以我们存 `observedAt`（我们看到的时刻）
   与 `sourceAt`（源自己报的时刻），两者都要能追溯；
2. 收盘后源一直返回最后成交价 —— 这类样本必须被丢掉，否则回放会凭空
   多出一段横盘，把「午后修复」的结论污染成假的；
3. 日期必须按各市场自己的时区切 —— 用上海时区切美股会把一个交易日劈成两天；
4. 数据不够 30 天时必须明说不够，不能靠 3 天样本给出「稳定领先」。
"""
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import crossmarket
from domain import InvalidData, NextDatabase

SH = timezone(timedelta(hours=8))

# 2026-10-23 收盘后的真实响应片段（已实测），用于锁定解析口径。
SINA_BODY = "\n".join([
    'var hq_str_b_NKY="日经225指数,62692.9400,-214.90,-0.34,2:12 AM,14:12:00,2026-10-23,14:30:01,62667.0500,62907.8400,62786.8900,61462.6100,0";',
    'var hq_str_b_KOSPI="韩国KOSPI指数,5550.3000,16.53,0.30,2:27 AM,14:27:00,2026-10-23,14:32:40,5403.1700,5533.7700,5550.3000,5305.9800,0";',
    'var hq_str_rt_hkHSTECH="HSTECH,恒生科技指数,3813.430,3793.930,3896.930,3781.230,3871.660,77.730,2.050,0.000,0.000,69278778.137,1804013037,0.000,0.000,6198.680,3781.150,2026/10/23,16:08:30,,,,,,";',
    'var hq_str_gb_$ndx="纳斯达克100,28957.5283,-0.00,2026-10-24 05:30:00,-1.1595,28847.8158,29161.0295,28825.7245,31361.3691,22841.4180,1047600000,1170896904,0,0.00,--,0.00,0.00,0.00,0.00,0,0,0.0000,0.00,0.00,,Oct 23 05:16PM EDT,28958.6878,0,1,2026,0.0000,0.0000,0.0000,0.0000,0.0000";',
])


def day_points(count, start_price=100.0, day="2026-10-23"):
    """造一天的点，每点间隔 1 分钟，时间基准用 UTC 22:00（东京次日上午）。"""
    base = datetime.fromisoformat(day + "T00:00:00").replace(tzinfo=timezone.utc)
    return [{"market": "japan", "stamp": (base + timedelta(minutes=index)).isoformat(),
             "price": str(start_price + index * 0.1), "changePercent": "0.1"} for index in range(count)]


class SinaParsingTests(unittest.TestCase):
    def test_parses_all_four_markets_with_source_times(self):
        now = datetime(2026, 10, 23, 9, 0, tzinfo=timezone.utc)
        samples = crossmarket.parse_sina(SINA_BODY, now=now)
        self.assertEqual([s["market"] for s in samples], ["hongKong", "japan", "korea", "unitedStates"])
        by_market = {s["market"]: s for s in samples}
        self.assertAlmostEqual(by_market["japan"]["price"], 62692.94, places=2)
        self.assertAlmostEqual(by_market["korea"]["changePercent"], 0.30, places=2)
        # 恒生科技：第 7 个字段是现价，第 9 个是涨跌幅
        self.assertAlmostEqual(by_market["hongKong"]["price"], 3871.66, places=2)
        self.assertAlmostEqual(by_market["hongKong"]["changePercent"], 2.05, places=2)
        self.assertAlmostEqual(by_market["unitedStates"]["price"], 28957.5283, places=4)
        # 源时间必须带上各市场自己的时区：日经 14:12 是东京时间
        japan_at = datetime.fromisoformat(by_market["japan"]["sourceAt"])
        self.assertEqual(japan_at.utcoffset(), timedelta(hours=9))
        # 回归：日经同时给了「报价时间 14:12」和「更新时间 14:30」，
        # 必须取较早的那个，否则 18 分钟前的旧价会被当成新鲜数据。
        self.assertEqual(japan_at.strftime("%H:%M:%S"), "14:12:00")
        # 回归：恒生科技曾经因为字段下标写死而永远取不到时间、样本被静默丢光。
        self.assertIsNotNone(by_market["hongKong"]["sourceAt"])
        self.assertEqual(datetime.fromisoformat(by_market["hongKong"]["sourceAt"]).strftime("%H:%M:%S"), "16:08:30")
        self.assertEqual(datetime.fromisoformat(by_market["unitedStates"]["sourceAt"]).utcoffset(),
                         timedelta(hours=-4))

    def test_unknown_symbol_and_empty_payload_are_ignored(self):
        body = 'var hq_str_sh000001="上证指数,3727.75";\nvar hq_str_b_NKY="";'
        self.assertEqual(crossmarket.parse_sina(body), [])


class ArchiveGateTests(unittest.TestCase):
    def test_stale_source_is_dropped_not_archived(self):
        """收盘后源一直返回最后成交价 —— 这种样本进库就会伪造横盘。"""
        now = datetime(2026, 10, 23, 8, 0, tzinfo=timezone.utc)
        stale = {"market": "japan", "price": 62692.94,
                 "sourceAt": (now - timedelta(minutes=30)).isoformat(), "observedAt": now.isoformat()}
        rows, dropped = crossmarket.archive_rows([stale], now=now)
        self.assertEqual(rows, [])
        self.assertEqual(dropped[0]["reason"], "staleSource")

    def test_missing_source_time_is_dropped(self):
        now = datetime(2026, 10, 23, 8, 0, tzinfo=timezone.utc)
        rows, dropped = crossmarket.archive_rows([{"market": "korea", "price": 5550.3, "sourceAt": None}], now=now)
        self.assertEqual(rows, [])
        self.assertEqual(dropped[0]["reason"], "noSourceTime")

    def test_fresh_sample_is_archived_with_utc_stamp(self):
        now = datetime(2026, 10, 23, 5, 13, tzinfo=timezone.utc)
        sample = {"market": "japan", "price": 62692.94, "changePercent": -0.34,
                  "sourceAt": "2026-10-23T14:12:00+09:00", "observedAt": now.isoformat()}
        rows, dropped = crossmarket.archive_rows([sample], now=now)
        self.assertEqual(dropped, [])
        self.assertEqual(rows[0]["stamp"], "2026-10-23T05:12:00+00:00")
        self.assertEqual(rows[0]["price"], "62692.94")

    def test_invalid_price_is_rejected(self):
        now = datetime(2026, 10, 23, 5, 13, tzinfo=timezone.utc)
        rows, dropped = crossmarket.archive_rows(
            [{"market": "japan", "price": 0, "sourceAt": now.isoformat()}], now=now)
        self.assertEqual(rows, [])
        self.assertEqual(dropped[0]["reason"], "invalidPrice")


class DayGroupingTests(unittest.TestCase):
    def test_days_are_split_by_each_market_timezone(self):
        """同一时刻，美股按纽约日期、日经按东京日期归属，不能都用上海日期。"""
        stamp = "2026-10-23T22:00:00+00:00"  # 纽约 10-23 18:00 / 东京 10-24 07:00
        rows = [{"market": "unitedStates", "stamp": stamp, "price": "28957.5"},
                {"market": "japan", "stamp": stamp, "price": "62692.9"}]
        series = crossmarket.group_series(rows)
        self.assertEqual(list(series["unitedStates"]), ["2026-10-23"])
        self.assertEqual(list(series["japan"]), ["2026-10-24"])

    def test_points_are_sorted_within_day(self):
        rows = [{"market": "japan", "stamp": "2026-10-23T02:00:00+00:00", "price": "1"},
                {"market": "japan", "stamp": "2026-10-23T01:00:00+00:00", "price": "2"}]
        points = crossmarket.group_series(rows)["japan"]["2026-10-23"]
        self.assertEqual([p["price"] for p in points], [2.0, 1.0])


class AvailabilityTests(unittest.TestCase):
    def test_fewer_than_thirty_days_is_reported_as_insufficient(self):
        rows = day_points(48, day="2026-10-23") + day_points(48, day="2026-10-22")
        report = crossmarket.availability(rows, minimum_days=30)
        self.assertFalse(report["japan"]["sufficient"])
        self.assertIn("需 ≥30 天", report["japan"]["note"])
        self.assertFalse(report["_meta"]["anySufficient"])
        # 没有归档的市场要如实报 0 天，而不是请假
        self.assertEqual(report["korea"]["days"], 0)

    def test_thirty_days_is_sufficient(self):
        rows = []
        base = datetime(2026, 9, 1, tzinfo=timezone.utc)
        for index in range(30):
            stamp = (base + timedelta(days=index)).isoformat()
            rows.append({"market": "japan", "stamp": stamp, "price": "62692.9"})
        report = crossmarket.availability(rows, minimum_days=30)
        self.assertTrue(report["japan"]["sufficient"])
        self.assertTrue(report["_meta"]["anySufficient"])


class DomainStorageTests(unittest.TestCase):
    def setUp(self):
        # Windows 上 sqlite 文件句柄在 WAL 模式下可能还没释放，
        # 忽略清理错误（与 test_domain 保持一致），不让清理失败冒充测试失败。
        self.root = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.db = NextDatabase(Path(self.root.name) / "cross.sqlite3")

    def tearDown(self):
        self.root.cleanup()

    def test_round_trip_and_dedupe_by_market_and_stamp(self):
        rows = [{"market": "japan", "stamp": "2026-10-23T05:12:00+00:00", "price": "62692.94",
                 "changePercent": "-0.34", "source": "b_NKY", "observedAt": "2026-10-23T05:12:30+00:00"}]
        first = self.db.put_cross_samples(rows, "2026-10-23T05:12:30+00:00")
        self.assertEqual(first["accepted"], 1)
        # 同一市场同一时刻重复采到：覆盖而不是新增一行
        self.db.put_cross_samples(rows, "2026-10-23T05:12:40+00:00")
        stored = self.db.get_cross_samples(market="japan")
        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0]["price"], "62692.94")

    def test_unknown_market_and_bad_price_are_rejected(self):
        result = self.db.put_cross_samples([
            {"market": "atlantis", "stamp": "2026-10-23T05:12:00+00:00", "price": "1"},
            {"market": "japan", "stamp": "2026-10-23T05:13:00+00:00", "price": "-5"},
        ], "2026-10-23T05:13:30+00:00")
        self.assertEqual(result["accepted"], 0)
        self.assertEqual(result["rejected"], 2)
        self.assertEqual(self.db.get_cross_samples(), [])

    def test_counts_report_coverage_per_market(self):
        self.db.put_cross_samples(day_points(3, day="2026-10-23"), "2026-10-23T00:05:00+00:00")
        counts = self.db.cross_market_counts()
        self.assertEqual(counts["japan"]["samples"], 3)
        self.assertEqual(counts["japan"]["firstAt"], "2026-10-23T00:00:00+00:00")

    def test_invalid_market_query_is_rejected(self):
        with self.assertRaises(InvalidData):
            self.db.get_cross_samples(market="atlantis")


class CrossMarketEndpointTests(unittest.TestCase):
    """HTTP 层：只有原始观测，没有任何「领先关系」结论 —— 结论属于手机端。"""

    def setUp(self):
        import http.client
        import json
        import threading
        from http.server import ThreadingHTTPServer
        from app import make_handler
        self.http = http.client
        self.json = json
        self.root = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.db = NextDatabase(Path(self.root.name) / "cross-http.sqlite3")
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.db, lambda codes: []))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(); self.root.cleanup()

    def get(self, path):
        connection = self.http.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=5)
        connection.request("GET", path)
        response = connection.getresponse()
        body = self.json.loads(response.read())
        status = response.status
        connection.close()
        return status, body

    def test_availability_says_insufficient_without_archive(self):
        status, body = self.get("/v1/cross/availability")
        self.assertEqual(status, 200)
        self.assertFalse(body["_meta"]["anySufficient"])
        self.assertEqual(body["japan"]["days"], 0)
        self.assertIn("需 ≥30 天", body["japan"]["note"])

    def test_series_returns_grouped_points_and_no_verdict(self):
        self.db.put_cross_samples(day_points(5), "2026-10-23T00:05:00+00:00")
        status, body = self.get("/v1/cross/series?market=japan")
        self.assertEqual(status, 200)
        self.assertEqual(body["rows"], 5)
        self.assertEqual(set(body["markets"]), {"japan"})
        # 只回数据，不回结论：出现 correlation/winRate 就说明数据层越界了
        self.assertNotIn("correlation", self.json.dumps(body))
        self.assertNotIn("winRate", self.json.dumps(body))

    def test_series_rejects_unknown_market(self):
        status, body = self.get("/v1/cross/series?market=atlantis")
        self.assertEqual(status, 400)
        self.assertIn("error", body)


if __name__ == "__main__":
    unittest.main()
