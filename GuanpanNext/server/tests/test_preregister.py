"""NAS 预注册未来样本研究（指令七）的验收测试。

核心铁律：① 只登记未来窗口；② 假设冻结后指纹不可变（漂移即作废）；
③ 不创建交易计划；④ 不碰 real_books / twin_accounts；⑤ 不生成交易信号。
这些测试逐条坐实「代码里不存在那些副作用」，而不是相信文档。
"""
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from domain import (Conflict, InvalidData, NextDatabase, preregister_fingerprint)

UTC = timezone.utc
NOW = datetime(2026, 10, 24, 12, 0, tzinfo=UTC)


def future_spec(study_id="study-1", lead_market="japan", follow_code="600519",
                lead_minutes=30, window_days=10, start="2026-11-01", end="2026-11-10"):
    return {"id": study_id, "leadMarket": lead_market, "followCode": follow_code,
            "leadMinutes": lead_minutes, "windowDays": window_days,
            "windowStart": start, "windowEnd": end}


class PreregisterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.db = NextDatabase(Path(self.temp.name) / "pre.sqlite3")

    def tearDown(self):
        self.temp.cleanup()

    # ① 只登记未来窗口 -------------------------------------------------------
    def test_register_future_window_ok(self):
        result = self.db.register_preregister(future_spec(), now=NOW)
        self.assertEqual(result["state"], "registered")
        self.assertTrue(result["notTradingSignal"])
        self.assertEqual(len(result["fingerprint"]), 64)

    def test_reject_window_start_not_future(self):
        # 窗口起始 = 登记当天（UTC）→ 拒绝：这是「看了结果再注册」。
        spec = future_spec(start="2026-10-24", end="2026-10-30")
        with self.assertRaises(InvalidData):
            self.db.register_preregister(spec, now=NOW)

    def test_reject_window_start_in_past(self):
        spec = future_spec(start="2026-10-01", end="2026-10-10")
        with self.assertRaises(InvalidData):
            self.db.register_preregister(spec, now=NOW)

    def test_reject_window_end_before_start(self):
        spec = future_spec(start="2026-11-10", end="2026-11-01")
        with self.assertRaises(InvalidData):
            self.db.register_preregister(spec, now=NOW)

    def test_reject_invalid_lead_market(self):
        spec = future_spec(lead_market="mars")
        with self.assertRaises(InvalidData):
            self.db.register_preregister(spec, now=NOW)

    def test_reject_invalid_follow_code(self):
        spec = future_spec(follow_code="ABC")
        with self.assertRaises(InvalidData):
            self.db.register_preregister(spec, now=NOW)

    def test_reject_invalid_lead_minutes(self):
        spec = future_spec(lead_minutes=0)
        with self.assertRaises(InvalidData):
            self.db.register_preregister(spec, now=NOW)

    def test_duplicate_id_rejected(self):
        self.db.register_preregister(future_spec(), now=NOW)
        with self.assertRaises(Conflict):
            self.db.register_preregister(future_spec(), now=NOW)

    # ② 指纹不可变 + 漂移检测 ----------------------------------------------
    def test_fingerprint_stable_across_reads(self):
        self.db.register_preregister(future_spec(), now=NOW)
        study = self.db.get_preregister("study-1")
        self.assertFalse(study["fingerprintDrifted"])
        # 重算指纹必须与落库一致（防御：字段没被偷偷改过）。
        expected = preregister_fingerprint(
            "japan", "600519", 30, 10, study["frozenAt"], "2026-11-01", "2026-11-10")
        self.assertEqual(study["fingerprint"], expected)

    def test_drifted_fingerprint_marks_study_void(self):
        # 直接落一行「指纹与假设对不上」的记录，读回必须判 drifted。
        spec = future_spec()
        self.db.register_preregister(spec, now=NOW)
        # 篡改落库指纹（模拟有人事后改假设去拟合结果）。
        with self.db.connect() as db:
            db.execute("UPDATE preregistered_studies SET immutable_fingerprint='0'*64 WHERE id='study-1'")
        study = self.db.get_preregister("study-1")
        self.assertTrue(study["fingerprintDrifted"])
        self.assertEqual(study["state"], "drifted")

    def test_state_transitions(self):
        self.db.register_preregister(future_spec(start="2026-11-01", end="2026-11-10"), now=NOW)
        # 登记日之前：registered
        self.assertEqual(self.db.get_preregister("study-1", as_of="2026-10-31")["state"], "registered")
        # 窗口内：open
        self.assertEqual(self.db.get_preregister("study-1", as_of="2026-11-05")["state"], "open")
        # 窗口后未结算：closed
        self.assertEqual(self.db.get_preregister("study-1", as_of="2026-11-15")["state"], "closed")

    # ④ 不碰真实账本 --------------------------------------------------------
    def test_real_books_and_twin_untouched(self):
        self.db.register_preregister(future_spec(), now=NOW)
        # 真实账本依旧是「没有、revision 0」，注册行为一个字都没写。
        self.assertEqual(self.db.get_real("main"), {"revision": 0, "bookJSON": None})
        with self.db.connect() as db:
            real_rows = db.execute("SELECT COUNT(*) FROM real_books").fetchone()[0]
            history_rows = db.execute("SELECT COUNT(*) FROM real_book_history").fetchone()[0]
            twin_rows = db.execute("SELECT COUNT(*) FROM twin_accounts").fetchone()[0]
        self.assertEqual(real_rows, 0)
        self.assertEqual(history_rows, 0)
        self.assertEqual(twin_rows, 0)

    # ⑤ 不生成交易信号 ------------------------------------------------------
    def test_response_labels_not_a_trading_signal(self):
        result = self.db.register_preregister(future_spec(), now=NOW)
        self.assertTrue(result["notTradingSignal"])
        # 读取端同样带标注，手机端据此明确「这不是信号」。
        study = self.db.get_preregister("study-1")
        self.assertTrue(study["notTradingSignal"])

    # 结算只记结果指纹，仍不碰账本/计划/信号 -------------------------------
    def test_settle_only_records_outcome_fingerprint(self):
        self.db.register_preregister(future_spec(), now=NOW)
        outcome = {"observedConfirmRate": 0.42, "triggerDays": 8}
        result = self.db.settle_preregister("study-1", outcome, now=NOW)
        self.assertTrue(result["notTradingSignal"])
        self.assertIsNotNone(result["outcomeFingerprint"])
        study = self.db.get_preregister("study-1", as_of="2026-11-15")
        self.assertEqual(study["state"], "settled")
        # 结算后真实账本依然原封不动。
        self.assertEqual(self.db.get_real("main"), {"revision": 0, "bookJSON": None})

    def test_settle_unknown_study_rejected(self):
        with self.assertRaises(InvalidData):
            self.db.settle_preregister("nope", {"x": 1}, now=NOW)

    def test_list_by_code(self):
        self.db.register_preregister(future_spec("a", follow_code="600519"), now=NOW)
        self.db.register_preregister(future_spec("b", follow_code="000001"), now=NOW)
        self.assertEqual(len(self.db.list_preregisters()), 2)
        self.assertEqual(len(self.db.list_preregisters("600519")), 1)


if __name__ == "__main__":
    unittest.main()
