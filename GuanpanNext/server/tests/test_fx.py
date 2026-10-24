"""125 汇率上下文（NAS 侧）：USD/CNY 买卖价中点 + 时间戳 + 过期即拒收 + 来源名称验证。

这四项不是"多采少采"的问题，而是**数据真假**的问题：
  * 只取单点（买价或卖价）会系统性偏移半个点差 → 必须取中点；
  * 没有源时间戳就无从判断新旧 → 必须具有时间戳，否则拒收；
  * 过期的汇率被当成今天的实时值，等于拿昨天的汇率解释今天的涨跌 → 过期即拒收；
  * 来源名称未验证的值，数字再合理也不许落库、更不许进入手机决策上下文。
"""
import http.client
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path

import fx
from app import make_handler
from domain import NextDatabase

UTC = timezone.utc
NOW = datetime(2026, 10, 24, 6, 0, tzinfo=UTC)

# 实测 2026-10-24 的新浪外汇响应（GB18030 编码，这里用 ASCII 近似构造）。
SINA_LINE = ('var hq_str_fx_susdcny="03:00:01,6.6702000000,6.6704000000,6.6704000000,'
             '40.0000000000,6.6730000000,6.6739000000,6.6699000000,6.6704000000,'
             '在岸人民币,0.0000,0.0000,0.0040,此行情由新浪财经计算得出,0.0000,0.0000,,2026-10-24";')


def body_with(time_text="03:00:01", date_text="2026-10-24", bid="6.6702", ask="6.6704"):
    return ('var hq_str_fx_susdcny="' + time_text + ',' + bid + ',' + ask +
            ',6.6704000000,40.0000000000,6.6730000000,6.6739000000,6.6699000000,6.6704000000,'
            '在岸人民币,0.0000,0.0000,0.0040,此行情由新浪财经计算得出,0.0000,0.0000,,' + date_text + '";')


class FXParseTests(unittest.TestCase):
    def test_parsesMidpointFromBidAndAsk(self):
        samples = fx.parse_sina(SINA_LINE, now=NOW)
        self.assertEqual(len(samples), 1)
        sample = samples[0]
        self.assertEqual(sample["pair"], "USDCNY")
        self.assertAlmostEqual(sample["bid"], 6.6702, places=6)
        self.assertAlmostEqual(sample["ask"], 6.6704, places=6)
        # 中点 = (买价 + 卖价) / 2：单取买价或卖价都会偏移半个点差。
        self.assertAlmostEqual(sample["mid"], (6.6702 + 6.6704) / 2, places=6)
        self.assertEqual(sample["sourceName"], "Sina fx")

    def test_sourceStampIsParsedAsExchangeTime(self):
        samples = fx.parse_sina(SINA_LINE, now=NOW)
        stamp = samples[0]["sourceAt"]
        self.assertIsNotNone(stamp, "必须解析出源时间戳")
        parsed = datetime.fromisoformat(stamp)
        # 源按北京时间报 03:00:01 → UTC 应为前一日 19:00:01。
        self.assertEqual(parsed.astimezone(UTC).hour, 19)
        self.assertEqual(parsed.astimezone(UTC).minute, 0)

    def test_missingTimeIsDropped(self):
        body = 'var hq_str_fx_susdcny=",' + "6.6702,6.6704" + ',6.6704,40,6.6730,6.6739,6.6699,6.6704,在岸人民币,0,0,0.0040,此行情由新浪财经计算得出,0,0,,2026-10-24";'
        samples = fx.parse_sina(body, now=NOW)
        rows, dropped = fx.archive_rows(samples, now=NOW)
        self.assertEqual(rows, [])
        self.assertTrue(any(d["reason"] == "noSourceTime" for d in dropped), dropped)

    def test_unknownPairIsIgnored(self):
        samples = fx.parse_sina('var hq_str_fx_seurusd="01:00:00,1,1.0001,1,1,1,1,1,1,欧元美元,0,0,0,x,0,0,,2026-10-24";', now=NOW)
        self.assertEqual(len(samples), 0, "只采登记的 USD/CNY")

    def test_emptyResponseProducesNothing(self):
        self.assertEqual(fx.parse_sina("", now=NOW), [])
        rows, dropped = fx.archive_rows([], now=NOW)
        self.assertEqual(rows, [])
        self.assertEqual(dropped, [])


class FXArchiveTests(unittest.TestCase):
    def test_freshSampleIsAccepted(self):
        # 源时间戳 = 1 小时前 → 新鲜。
        stamp = (NOW.astimezone(fx.BEIJING) - timedelta(hours=1)).replace(tzinfo=None)
        body = body_with(time_text=stamp.strftime("%H:%M:%S"), date_text=stamp.strftime("%Y-%m-%d"))
        rows, dropped = fx.archive_rows(fx.parse_sina(body, now=NOW), now=NOW)
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual(dropped, [])
        self.assertIsNotNone(rows[0]["stamp"])

    def test_staleSampleIsRejected(self):
        # 过期即拒收：源时间戳 30 小时前 → 直接丢弃，不落库。
        stamp = (NOW.astimezone(fx.BEIJING) - timedelta(hours=30)).replace(tzinfo=None)
        body = body_with(time_text=stamp.strftime("%H:%M:%S"), date_text=stamp.strftime("%Y-%m-%d"))
        rows, dropped = fx.archive_rows(fx.parse_sina(body, now=NOW), now=NOW)
        self.assertEqual(rows, [], "过期的汇率必须被拒收")
        self.assertEqual(dropped[0]["reason"], "staleSource")

    def test_futureTimestampIsRejected(self):
        stamp = (NOW.astimezone(fx.BEIJING) + timedelta(hours=5)).replace(tzinfo=None)
        body = body_with(time_text=stamp.strftime("%H:%M:%S"), date_text=stamp.strftime("%Y-%m-%d"))
        rows, dropped = fx.archive_rows(fx.parse_sina(body, now=NOW), now=NOW)
        self.assertEqual(rows, [])
        self.assertEqual(dropped[0]["reason"], "sourceInFuture")

    def test_invalidPriceIsRejected(self):
        samples = [{"pair": "USDCNY", "bid": 0, "ask": 6.6704, "mid": 3.0,
                    "sourceAt": NOW.isoformat(), "observedAt": NOW.isoformat(),
                    "sourceName": "Sina fx"}]
        rows, dropped = fx.archive_rows(samples, now=NOW)
        self.assertEqual(rows, [])
        self.assertEqual(dropped[0]["reason"], "invalidPrice")

    def test_invertedBidAskIsRejected(self):
        samples = [{"pair": "USDCNY", "bid": 6.6704, "ask": 6.6702, "mid": 6.6703,
                    "sourceAt": NOW.isoformat(), "observedAt": NOW.isoformat(),
                    "sourceName": "Sina fx"}]
        rows, dropped = fx.archive_rows(samples, now=NOW)
        self.assertEqual(rows, [], "买价 > 卖价 说明字段错位，不当成真汇率")
        self.assertEqual(dropped[0]["reason"], "invalidPrice")

    def test_wideSpreadIsRejected(self):
        samples = [{"pair": "USDCNY", "bid": 6.0, "ask": 8.0, "mid": 7.0,
                    "sourceAt": NOW.isoformat(), "observedAt": NOW.isoformat(),
                    "sourceName": "Sina fx"}]
        rows, dropped = fx.archive_rows(samples, now=NOW)
        self.assertEqual(rows, [], "点差过大 → 源异常，拒收")
        self.assertEqual(dropped[0]["reason"], "spreadTooWide")

    def test_unverifiedSourceNameIsRejected(self):
        # 来源名称未验证：数字再合理也不许落库。
        samples = [{"pair": "USDCNY", "bid": 6.6702, "ask": 6.6704, "mid": 6.6703,
                    "sourceAt": NOW.isoformat(), "observedAt": NOW.isoformat(),
                    "sourceName": "Some Random Feed"}]
        rows, dropped = fx.archive_rows(samples, now=NOW)
        self.assertEqual(rows, [])
        self.assertEqual(dropped[0]["reason"], "unverifiedSource")

    def test_missingSourceNameIsRejected(self):
        samples = [{"pair": "USDCNY", "bid": 6.6702, "ask": 6.6704, "mid": 6.6703,
                    "sourceAt": NOW.isoformat(), "observedAt": NOW.isoformat()}]
        rows, dropped = fx.archive_rows(samples, now=NOW)
        self.assertEqual(rows, [], "没有来源名称 = 来源未验证")
        self.assertEqual(dropped[0]["reason"], "unverifiedSource")


class FXStorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.db = NextDatabase(Path(self.temp.name) / "fx.sqlite3")

    def tearDown(self):
        self.temp.cleanup()

    def test_putAndGetRoundTrip(self):
        stamp = (NOW - timedelta(hours=1)).isoformat()
        rows = [{"pair": "USDCNY", "stamp": stamp, "bid": "6.6702", "ask": "6.6704",
                 "mid": "6.6703", "observedAt": NOW.isoformat(), "sourceName": "Sina fx"}]
        result = self.db.put_fx_samples(rows, NOW.isoformat())
        self.assertEqual(result["accepted"], 1)
        self.assertEqual(result["rejected"], 0)
        stored = self.db.get_fx_samples()
        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0]["mid"], "6.6703")
        self.assertEqual(stored[0]["sourceName"], "Sina fx")

    def test_duplicateStampIsDeduplicated(self):
        stamp = (NOW - timedelta(hours=1)).isoformat()
        rows = [{"pair": "USDCNY", "stamp": stamp, "bid": "6.6702", "ask": "6.6704",
                 "mid": "6.6703", "observedAt": NOW.isoformat(), "sourceName": "Sina fx"}]
        self.db.put_fx_samples(rows, NOW.isoformat())
        self.db.put_fx_samples(rows, NOW.isoformat())
        self.assertEqual(len(self.db.get_fx_samples()), 1, "同一时刻重复采到不写两行")

    def test_storageRejectsUnverifiedSource(self):
        stamp = (NOW - timedelta(hours=1)).isoformat()
        rows = [{"pair": "USDCNY", "stamp": stamp, "bid": "6.6702", "ask": "6.6704",
                 "mid": "6.6703", "observedAt": NOW.isoformat(), "sourceName": "Unknown Feed"}]
        result = self.db.put_fx_samples(rows, NOW.isoformat())
        self.assertEqual(result["accepted"], 0)
        self.assertEqual(result["rejected"], 1, "来源未验证在落库这一层也要拦住")

    def test_storageRejectsInvalidNumbers(self):
        stamp = (NOW - timedelta(hours=1)).isoformat()
        rows = [{"pair": "USDCNY", "stamp": stamp, "bid": "-1", "ask": "6.6704",
                 "mid": "6.6703", "observedAt": NOW.isoformat(), "sourceName": "Sina fx"}]
        result = self.db.put_fx_samples(rows, NOW.isoformat())
        self.assertEqual(result["accepted"], 0)

    def test_unknownPairIsRejectedByStorage(self):
        stamp = (NOW - timedelta(hours=1)).isoformat()
        rows = [{"pair": "JPYCNY", "stamp": stamp, "bid": "0.042", "ask": "0.0421",
                 "mid": "0.04205", "observedAt": NOW.isoformat(), "sourceName": "Sina fx"}]
        result = self.db.put_fx_samples(rows, NOW.isoformat())
        self.assertEqual(result["accepted"], 0, "只登记 USD/CNY")

    def test_countsReportCoverage(self):
        for hours in (1, 2, 3):
            rows = [{"pair": "USDCNY", "stamp": (NOW - timedelta(hours=hours)).isoformat(),
                     "bid": "6.6702", "ask": "6.6704", "mid": "6.6703",
                     "observedAt": NOW.isoformat(), "sourceName": "Sina fx"}]
            self.db.put_fx_samples(rows, NOW.isoformat())
        counts = self.db.fx_counts()
        self.assertEqual(counts["USDCNY"]["samples"], 3)


class FXRouteTests(unittest.TestCase):
    """档案 → 手机研究响应的完整路径。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.db = NextDatabase(Path(self.temp.name) / "fxroute.sqlite3")
        for hours in (1, 2):
            self.db.put_fx_samples(
                [{"pair": "USDCNY", "stamp": (NOW - timedelta(hours=hours)).isoformat(),
                  "bid": "6.6702", "ask": "6.6704", "mid": "6.6703",
                  "observedAt": NOW.isoformat(), "sourceName": "Sina fx"}], NOW.isoformat())
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.db))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.port = self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.temp.cleanup()

    def get(self, path):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("GET", path); response = conn.getresponse()
        data = response.read().decode(); conn.close()
        import json
        return response.status, json.loads(data)

    def test_seriesReturnsMidpointAndStamp(self):
        status, body = self.get("/v1/fx/series?days=7")
        self.assertEqual(status, 200)
        self.assertEqual(len(body["rows"]), 2)
        row = body["rows"][0]
        self.assertEqual(row["pair"], "USDCNY")
        self.assertIn("mid", row)
        self.assertIn("stamp", row, "必须带时间戳")
        self.assertIn("sourceName", row, "必须带来源名称")

    def test_responseMarksRiskContextOnly(self):
        status, body = self.get("/v1/fx/series")
        self.assertEqual(status, 200)
        self.assertTrue(body["riskContextOnly"], "汇率只进入风险上下文")
        self.assertTrue(body["notTradingSignal"], "汇率不是交易信号")
        self.assertIn("不生成价格", body["note"])
        self.assertIn("份额", body["note"])
        self.assertIn("方向", body["note"])
        # 返回体里不能有价格/份额/方向这类交易字段。
        for banned in ("limitPrice", "units", "direction", "planKind"):
            self.assertNotIn(banned, body, f"汇率响应里不该出现 {banned}")

    def test_verifiedSourceNamesAreExposed(self):
        status, body = self.get("/v1/fx/series")
        self.assertEqual(status, 200)
        self.assertIn("Sina fx", body["verifiedSourceNames"])

    def test_emptyArchiveReturnsEmptyRowsNotFakeValue(self):
        empty = NextDatabase(Path(self.temp.name) / "empty.sqlite3")
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(empty))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=10)
        conn.request("GET", "/v1/fx/series"); response = conn.getresponse()
        import json
        body = json.loads(response.read().decode()); conn.close()
        server.shutdown(); server.server_close()
        self.assertEqual(body["rows"], [], "没有数据时不能补一条假汇率")

    def test_invalidDaysIsRejected(self):
        status, _ = self.get("/v1/fx/series?days=abc")
        self.assertEqual(status, 400)

    def test_unknownPairIsRejected(self):
        status, _ = self.get("/v1/fx/series?pair=JPYCNY")
        self.assertEqual(status, 400)


class FXCollectionFailureTests(unittest.TestCase):
    """采集失败降级：失败只记录，不写兜底值。"""

    def test_fetchFailureRaisesAndStoresNothing(self):
        def failing(*args, **kwargs):
            raise OSError("network down")
        with self.assertRaises(OSError):
            fx.fetch_snapshots(opener=failing, now=NOW)
        # 失败后不产生任何样本（没有兜底值）。
        self.assertEqual(fx.parse_sina("", now=NOW), [])

    def test_archiverNeverInventsRows(self):
        # 传入畸形样本时只丢弃，不伪造。
        rows, dropped = fx.archive_rows([None, "x", 42], now=NOW)
        self.assertEqual(rows, [])
        self.assertEqual(dropped, [], "非字典样本直接忽略，不伪造")


if __name__ == "__main__":
    unittest.main()
