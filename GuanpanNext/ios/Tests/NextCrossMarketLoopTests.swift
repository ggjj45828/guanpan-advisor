import XCTest
@testable import GuanpanAdvisorCore

/// 跨市场闭环：信号 → 假设 → A股 确认 → Risk Guard → 做T/网格/不交易 → 复盘。
///
/// 这组用例盯的是「闭环会不会把背景当结论」：
/// 海外涨了不等于能做T；没确认的取消不是失败；没信号必须明确说不交易。
final class NextCrossMarketLoopTests: XCTestCase {

    /// A股 交易时段内的一个时刻：2026-10-23 13:10（上海），已过午休。
    private func afternoon() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 23
        comps.hour = 13; comps.minute = 10
        return calendar.date(from: comps)!
    }

    private func point(_ base: Date, _ offsetMinutes: Double, _ value: Double) -> NextMarketPoint {
        NextMarketPoint(timestamp: base.addingTimeInterval(offsetMinutes * 60), value: value)
    }

    /// 脉搏：A股 交易中、日本可用、归档 40 天（第①②步因此能通过）。
    private func openPulse(days: Int = 40, base: Date) -> NextCrossMarketPulse {
        let row = NextCrossMarketPulseRow(
            market: .japan, status: .open, price: 62_000, changePercent: 0.82,
            observedAt: base.addingTimeInterval(-60), ageMinutes: 1, usable: true)
        return NextCrossMarketPulse(generatedAt: base, rows: [row],
                                    archivedDays: [.japan: days, .korea: days, .hongKong: days],
                                    minimumDays: 30, lunchNote: nil)
    }

    private func usableStudy(_ code: String = "513520") -> NextLeadLagStudy {
        let window = NextLeadLagWindow(minutes: 15, sampleCount: 60, correlation: 0.45,
                                       sameDirectionRate: 0.62, meanFollowReturn: 0.1,
                                       medianFollowReturn: 0.08, positiveRatio: 0.56,
                                       maxAdverseReturn: -0.3, stability: 0.8)
        return NextLeadLagStudy(lead: .japan, followCode: code,
                                verdict: .usable(best: window, windows: [window],
                                                 periodDays: 60, lastValidated: Date(timeIntervalSince1970: 1_790_000_000)))
    }

    private func fullWeight(_ code: String = "513520") -> NextRollingValidity {
        NextRollingValidity(lead: .japan, followCode: code, studies: [:],
                            verdict: .usable(days: 120, weight: 1.0))
    }

    private func weakWeight(_ code: String = "513520") -> NextRollingValidity {
        NextRollingValidity(lead: .japan, followCode: code, studies: [:],
                            verdict: .usable(days: 20, weight: 0.6))
    }

    /// 日本 09:35 -1%、11:20 仍 -1%、12:45 回到 +0.2% → 午休 shock ≈ +1.2pp（≥0.30 门槛）。
    private func repairOverseas(base: Date) -> [NextMarketPoint] {
        [point(base, -215, 62_000), point(base, -110, 61_380),
         point(base, -25, 62_124), point(base, -5, 62_130)]
    }

    /// 完全横盘的海外序列：不产生任何信号。
    private func flatOverseas(base: Date) -> [NextMarketPoint] {
        [point(base, -215, 62_000), point(base, -110, 62_000),
         point(base, -25, 62_001), point(base, -5, 62_001)]
    }

    /// 本地分时：从 1.000 一路抬到 1.018（低点抬高）。
    private func risingLocal(base: Date) -> [NextMarketPoint] {
        (0..<10).map { index in point(base, Double(index) - 9, 1.000 + Double(index) * 0.002) }
    }

    /// 本地分时：从 1.000 一路走低（没有低点抬高）。
    private func weakLocal(base: Date) -> [NextMarketPoint] {
        (0..<10).map { index in point(base, Double(index) - 9, 1.000 - Double(index) * 0.002) }
    }

    /// 还在确认窗口内的假设：创建于 40 分钟前，30 分钟后到期。
    private func openHypothesis(base: Date) -> NextCrossHypothesis {
        NextCrossHypothesis(code: "513520",
                            createdAt: base.addingTimeInterval(-40 * 60),
                            confirmDeadline: base.addingTimeInterval(30 * 60),
                            statement: "午后修复",
                            overseasEvidence: ["日本午休期间修复 +1.20 个百分点"])
    }

    /// 确认窗口已经过去的假设：必须判「假设失效」，而不是继续挂着。
    private func expiredHypothesis(base: Date) -> NextCrossHypothesis {
        NextCrossHypothesis(code: "513520",
                            createdAt: base.addingTimeInterval(-60 * 60),
                            confirmDeadline: base.addingTimeInterval(-10 * 60),
                            statement: "午后修复",
                            overseasEvidence: ["日本午休期间修复 +1.20 个百分点"])
    }

    // MARK: 信号 / 不交易

    func test_noSignalIsAFormalNoTrade() {
        let base = afternoon()
        let outcome = NextCrossMarketLoop.evaluate(
            code: "513520", now: base,
            overseas: [.japan: flatOverseas(base: base)], local: risingLocal(base: base), vwap: 1.0,
            volumeRecovered: true, studies: [usableStudy()], rollings: [fullWeight()],
            pulse: openPulse(base: base))
        XCTAssertNil(outcome.signal)
        XCTAssertEqual(outcome.gate, .noTrade(reason: "没有达到门槛的跨市场信号"))
        XCTAssertTrue(outcome.headline.contains("不交易"))
        XCTAssertTrue(outcome.explanation.contains { $0.contains("不交易，且不生成任何计划") })
    }

    func test_overseasRepairAloneNeverBecomesDoT() {
        let base = afternoon()
        let outcome = NextCrossMarketLoop.evaluate(
            code: "513520", now: base,
            overseas: [.japan: repairOverseas(base: base)], local: weakLocal(base: base), vwap: 1.0,
            volumeRecovered: false, studies: [usableStudy()], rollings: [fullWeight()],
            pulse: openPulse(base: base))
        XCTAssertEqual(outcome.signal?.kind, .lunchRepair, "午休修复信号应当被识别出来")
        guard case let .noTrade(reason) = outcome.gate else {
            return XCTFail("海外证据不能替代 A股 确认，这里必须是 noTrade")
        }
        XCTAssertTrue(reason.contains("未确认"))
        XCTAssertEqual(outcome.hypothesis?.state, .pending, "同一时刻提出的假设只能等确认，不能自己变成 confirmed")
        XCTAssertTrue(outcome.explanation.contains { $0.contains("不算错过") })
    }

    func test_expiredHypothesisIsRejectedAndStaysNoTrade() {
        let base = afternoon()
        let outcome = NextCrossMarketLoop.evaluate(
            code: "513520", now: base,
            overseas: [.japan: repairOverseas(base: base)], local: weakLocal(base: base), vwap: 1.0,
            volumeRecovered: false, studies: [usableStudy()], rollings: [fullWeight()],
            pulse: openPulse(base: base), existing: expiredHypothesis(base: base))
        XCTAssertEqual(outcome.hypothesis?.state, .rejected, "确认窗口已过且没有价格/量能确认 → 失效")
        guard case let .noTrade(reason) = outcome.gate else { return XCTFail("失效的假设不能变成动作") }
        XCTAssertTrue(reason.contains("假设失效"))
    }

    // MARK: Risk Guard

    func test_confirmedWithFullWeightAllowsDoT() {
        let base = afternoon()
        let outcome = NextCrossMarketLoop.evaluate(
            code: "513520", now: base,
            overseas: [.japan: repairOverseas(base: base)], local: risingLocal(base: base), vwap: 0.99,
            volumeRecovered: true, studies: [usableStudy()], rollings: [fullWeight()],
            pulse: openPulse(base: base), existing: openHypothesis(base: base))
        XCTAssertEqual(outcome.hypothesis?.state, .confirmed)
        XCTAssertTrue(outcome.gate.allowsDirectional, "确认 + 满权重 + 执行层放行 → 允许做T")
        guard case let .doT(reason) = outcome.gate else { return XCTFail("应为 doT") }
        XCTAssertTrue(reason.contains("已由 A股 确认"))
    }

    func test_confirmedButDecayedRelationOnlyAllowsGrid() {
        let base = afternoon()
        let outcome = NextCrossMarketLoop.evaluate(
            code: "513520", now: base,
            overseas: [.japan: repairOverseas(base: base)], local: risingLocal(base: base), vwap: 0.99,
            volumeRecovered: true, studies: [usableStudy()], rollings: [weakWeight()],
            pulse: openPulse(base: base), existing: openHypothesis(base: base))
        guard case .grid = outcome.gate else {
            return XCTFail("权重不足 1.0 时应降级为网格")
        }
        XCTAssertFalse(outcome.gate.allowsDirectional, "关系不稳时只做网格，不做方向")
        XCTAssertTrue(outcome.gate.allowsAnyPlan)
    }

    func test_executionFilterBlocksEvenWhenConfirmed() {
        let base = afternoon()
        let blocked = NextExecutionFilter(premiumPercent: 2.0, spreadPercent: 0.1,
                                          verdict: "ETF 溢价 2.00% 偏高", allowsChasing: false)
        let outcome = NextCrossMarketLoop.evaluate(
            code: "513520", now: base,
            overseas: [.japan: repairOverseas(base: base)], local: risingLocal(base: base), vwap: 0.99,
            volumeRecovered: true, execution: blocked,
            studies: [usableStudy()], rollings: [fullWeight()],
            pulse: openPulse(base: base), existing: openHypothesis(base: base))
        guard case let .noTrade(reason) = outcome.gate else {
            return XCTFail("溢价过高时方向再对也不能追")
        }
        XCTAssertTrue(reason.contains("执行层拦截"), "执行层拦截不能被说成数据不足")
        XCTAssertFalse(outcome.gate.allowsAnyPlan)
    }

    func test_insufficientArchiveStopsBeforeAnyDecision() {
        let base = afternoon()
        let outcome = NextCrossMarketLoop.evaluate(
            code: "513520", now: base,
            overseas: [.japan: repairOverseas(base: base)], local: risingLocal(base: base), vwap: 0.99,
            volumeRecovered: true, studies: [usableStudy()], rollings: [fullWeight()],
            pulse: openPulse(days: 5, base: base), existing: openHypothesis(base: base))
        guard case let .noTrade(reason) = outcome.gate else {
            return XCTFail("归档不足 30 天时任何决定都不成立")
        }
        XCTAssertTrue(reason.contains("归档深度"))
    }

    // MARK: 144 复盘

    func test_reviewCountsCorrectCancellationAsSuccess() {
        let record = NextLoopRecord(code: "513520", at: afternoon(),
                                    gate: .noTrade(reason: "A股 未确认"),
                                    statement: "午后修复", referencePrice: 1.000)
        let review = NextLoopReviewer.review(record, laterPrice: 0.985)
        XCTAssertEqual(review.outcome, .avoidedLoss)
        XCTAssertTrue(review.outcome.isSuccess, "正确的取消必须算成功")
        XCTAssertTrue(review.note.contains("取消是对的"))
    }

    func test_reviewRecordsMissAsFactNotFailure() {
        let record = NextLoopRecord(code: "513520", at: afternoon(),
                                    gate: .noTrade(reason: "A股 未确认"),
                                    statement: "午后修复", referencePrice: 1.000)
        let review = NextLoopReviewer.review(record, laterPrice: 1.012)
        XCTAssertEqual(review.outcome, .missedGain)
        XCTAssertFalse(review.outcome.isSuccess, "踏空不算失败，但也不该记成成功")
        XCTAssertTrue(review.note.contains("不算错"))
    }

    func test_reviewDoTOutcomeIsJudgedByDirection() {
        let record = NextLoopRecord(code: "513520", at: afternoon(),
                                    gate: .doT(reason: "已确认"),
                                    statement: "午后修复", referencePrice: 1.000)
        XCTAssertEqual(NextLoopReviewer.review(record, laterPrice: 0.99).outcome, .failedFollowThrough)
        XCTAssertEqual(NextLoopReviewer.review(record, laterPrice: 1.01).outcome, .followThrough)
    }

    func test_reviewWithoutReferencePriceGivesNoConclusion() {
        let record = NextLoopRecord(code: "513520", at: afternoon(),
                                    gate: .noTrade(reason: "无信号"),
                                    statement: nil, referencePrice: nil)
        let review = NextLoopReviewer.review(record, laterPrice: 1.01)
        XCTAssertEqual(review.outcome, .noSignal)
        XCTAssertNil(review.movePercent, "没有参考价就不许编一个涨跌幅")
    }
}
