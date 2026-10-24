import XCTest
@testable import GuanpanAdvisorCore

/// 回放冻结的测试重点：**冻结时点之后的数据不能用来判断条件**，
/// 以及缺数据时必须停在「等后续数据」，不能填一个看起来合理的数字。
final class NextReplayFreezeTests: XCTestCase {

    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = zone
        return value
    }

    private func day(_ offset: Int = 0) -> Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 3
        parts.day = 10
        let base = calendar.date(from: parts)!
        return calendar.date(byAdding: .day, value: offset, to: base)!
    }

    private func stamp(minute: Int, offset: Int = 0) -> Date {
        let base = day(offset)
        return calendar.date(byAdding: .minute, value: minute, to: base)!
    }

    private func series(_ values: [(Int, Double)], offset: Int = 0) -> [NextMarketPoint] {
        values.map { NextMarketPoint(timestamp: stamp(minute: $0.0, offset: offset), value: $0.1) }
    }

    /// 条件满足（领先市场 11:00→12:50 +1%），且午后确实上涨的完整一天。
    private func completeDay(offset: Int = 0) -> (leader: [NextMarketPoint], asset: [NextMarketPoint]) {
        let leader = series([(10 * 60, 100), (11 * 60, 100), (12 * 60 + 50, 101)], offset: offset)
        let asset = series([(10 * 60, 50), (12 * 60 + 50, 50.2), (13 * 60, 50.3),
                            (13 * 60 + 30, 50.8), (14 * 60, 51), (14 * 60 + 30, 51.1),
                            (15 * 60, 51.2)], offset: offset)
        return (leader, asset)
    }

    // MARK: 规格校验

    func testStandardHypothesisIsValid() {
        XCTAssertEqual(NextReplayFreezeEngine.validate(.standard), [])
    }

    func testConditionReadingPastCutoffIsRejected() {
        let bad = NextFrozenHypothesis(
            id: "peek", cutoffMinute: 12 * 60 + 50, expectedDirection: 1,
            baselineMinute: 13 * 60, confirmMinute: 13 * 60 + 30, horizonMinutes: [14 * 60],
            conditions: [NextFrozenCondition(series: .leader, fromMinute: 13 * 60 + 10,
                                             toMinute: 13 * 60 + 40, op: .gte,
                                             threshold: 0.005, upperThreshold: nil)])
        let problems = NextReplayFreezeEngine.validate(bad)
        XCTAssertFalse(problems.isEmpty)
        XCTAssertTrue(problems.contains { $0.contains("未来数据") })
    }

    func testOutcomeTimesMustFollowCutoff() {
        let bad = NextFrozenHypothesis(
            id: "early", cutoffMinute: 12 * 60 + 50, expectedDirection: 1,
            baselineMinute: 12 * 60 + 30, confirmMinute: 13 * 60, horizonMinutes: [14 * 60],
            conditions: [NextFrozenCondition(series: .leader, fromMinute: 11 * 60,
                                             toMinute: 12 * 60 + 50, op: .gte,
                                             threshold: 0.005, upperThreshold: nil)])
        XCTAssertTrue(NextReplayFreezeEngine.validate(bad).contains { $0.contains("必须晚于冻结时点") })
    }

    func testZeroDirectionAndEmptyIdAreRejected() {
        let bad = NextFrozenHypothesis(
            id: "  ", cutoffMinute: 12 * 60 + 50, expectedDirection: 0,
            baselineMinute: 13 * 60, confirmMinute: 13 * 60 + 30, horizonMinutes: [13 * 60],
            conditions: [])
        let problems = NextReplayFreezeEngine.validate(bad)
        XCTAssertTrue(problems.contains { $0.contains("id") })
        XCTAssertTrue(problems.contains { $0.contains("预期方向") })
        XCTAssertTrue(problems.contains { $0.contains("条件数量") })
        XCTAssertTrue(problems.contains { $0.contains("必须在结果基准之后") })
    }

    // MARK: 冻结时点是真的物理截断

    /// 12:50 那根观测在 13:05 才到 → 冻结时点看不到它。
    /// 结果必须是「冻结段数据不全」，而不是偷偷用 13:05 的价格算条件。
    func testObservationArrivingAfterCutoffCannotSatisfyCondition() {
        let leader = series([(10 * 60, 100), (11 * 60, 100), (13 * 60 + 5, 101)])
        let asset = series([(13 * 60, 50), (13 * 60 + 30, 51)])
        let outcome = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                      leader: leader, leaderZone: zone,
                                                      asset: asset, assetZone: zone)
        XCTAssertFalse(outcome.triggered)
        XCTAssertEqual(outcome.state, .incompleteAtCutoff)
        XCTAssertNil(outcome.confirmed)
    }

    /// 冻结段完整、午后上涨 → 假设兑现。
    func testTriggeredAndConfirmedWhenPriceFollowsThrough() {
        let data = completeDay()
        let outcome = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                      leader: data.leader, leaderZone: zone,
                                                      asset: data.asset, assetZone: zone)
        XCTAssertTrue(outcome.triggered)
        XCTAssertEqual(outcome.state, .evaluated)
        XCTAssertEqual(outcome.confirmed, true)
        XCTAssertEqual(outcome.confirmReturn ?? 0, 50.8 / 50.3 - 1, accuracy: 0.0005)
        XCTAssertEqual(outcome.horizonReturns.count, 3)
        XCTAssertFalse(outcome.note.contains("等后续数据"))
    }

    /// 同一个下午跌了 → 方向相反，判未兑现。
    func testSameAfternoonDeclineIsNotConfirmed() {
        let leader = series([(10 * 60, 100), (11 * 60, 100), (12 * 60 + 50, 101)])
        let asset = series([(13 * 60, 50), (13 * 60 + 30, 49.4), (14 * 60, 49.3),
                            (14 * 60 + 30, 49.2), (15 * 60, 49.1)])
        let outcome = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                      leader: leader, leaderZone: zone,
                                                      asset: asset, assetZone: zone)
        XCTAssertEqual(outcome.state, .evaluated)
        XCTAssertEqual(outcome.confirmed, false)
    }

    /// 条件不成立 → 当天不产生假设，而不是「未兑现」。
    /// 这两件事在统计上完全不同：前者不该进分母。
    func testConditionFailureYieldsNoHypothesis() {
        let leader = series([(10 * 60, 100), (11 * 60, 101), (12 * 60 + 50, 100.5)])
        let asset = series([(13 * 60, 50), (13 * 60 + 30, 51)])
        let outcome = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                      leader: leader, leaderZone: zone,
                                                      asset: asset, assetZone: zone)
        XCTAssertFalse(outcome.triggered)
        XCTAssertEqual(outcome.state, .noHypothesis)
        XCTAssertNil(outcome.confirmed)
        XCTAssertTrue(outcome.note.contains("不产生假设"))
    }

    /// 结果段数据还没到 → 停在等待，不许填。
    func testMissingOutcomeIsAwaitingNotFabricated() {
        let leader = series([(10 * 60, 100), (11 * 60, 100), (12 * 60 + 50, 101)])
        let asset = series([(10 * 60, 50), (12 * 60 + 50, 50.2)])
        let outcome = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                      leader: leader, leaderZone: zone,
                                                      asset: asset, assetZone: zone)
        XCTAssertTrue(outcome.triggered)
        XCTAssertEqual(outcome.state, .awaitingPostCutoffData)
        XCTAssertNil(outcome.confirmed)
        XCTAssertNil(outcome.confirmReturn)
        XCTAssertTrue(outcome.note.contains("等后续数据"))
    }

    func testFrozenPeriodOnlyUsesSameDayPoints() throws {
        // 前一天有一条 12:50 = 200 的点，不能拿来当今天的条件输入。
        let leader = series([(11 * 60, 100), (12 * 60 + 50, 101)]) + series([(12 * 60 + 50, 200)], offset: -1)
        let asset = series([(13 * 60, 50), (13 * 60 + 30, 51)])
        let outcome = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                      leader: leader, leaderZone: zone,
                                                      asset: asset, assetZone: zone)
        XCTAssertTrue(outcome.triggered)
        let observed = try XCTUnwrap(outcome.conditionResults.first?.observed)
        XCTAssertEqual(observed, 0.01, accuracy: 0.0001)
    }

    // MARK: 指纹与重跑校验

    func testFingerprintIsStableForSameInput() {
        let data = completeDay()
        let first = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                    leader: data.leader, leaderZone: zone,
                                                    asset: data.asset, assetZone: zone)
        let second = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                     leader: data.leader, leaderZone: zone,
                                                     asset: data.asset, assetZone: zone)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.fingerprint.count, 16)
    }

    func testFingerprintChangesWhenDataChanges() {
        let data = completeDay()
        let original = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                       leader: data.leader, leaderZone: zone,
                                                       asset: data.asset, assetZone: zone)
        var tampered = data.asset
        tampered[3] = NextMarketPoint(timestamp: tampered[3].timestamp, value: 50.4)
        let changed = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                      leader: data.leader, leaderZone: zone,
                                                      asset: tampered, assetZone: zone)
        XCTAssertNotEqual(original.fingerprint, changed.fingerprint)
    }

    func testVerifyReportsIdenticalDriftedAndMissing() {
        let data = completeDay()
        let frozen = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                     leader: data.leader, leaderZone: zone,
                                                     asset: data.asset, assetZone: zone)
        XCTAssertEqual(NextReplayFreezeEngine.verify(frozen: [frozen], rerun: [frozen]), .identical)

        var tampered = data.asset
        tampered[3] = NextMarketPoint(timestamp: tampered[3].timestamp, value: 51.5)
        let drifted = NextReplayFreezeEngine.evaluate(hypothesis: .standard, day: day(),
                                                      leader: data.leader, leaderZone: zone,
                                                      asset: tampered, assetZone: zone)
        guard case let .drifted(days) = NextReplayFreezeEngine.verify(frozen: [frozen], rerun: [drifted]) else {
            return XCTFail("数据被改过必须判 drifted")
        }
        XCTAssertEqual(days, [frozen.day])

        guard case let .missing(days2) = NextReplayFreezeEngine.verify(frozen: [frozen], rerun: []) else {
            return XCTFail("没重跑出来必须判 missing")
        }
        XCTAssertEqual(days2, [frozen.day])
        XCTAssertTrue(NextReplayFreezeEngine.verify(frozen: [frozen], rerun: [drifted]).label.contains("冻结已失效"))
    }

    func testClockFormatting() {
        XCTAssertEqual(NextReplayFreezeEngine.clock(12 * 60 + 50), "12:50")
        XCTAssertEqual(NextReplayFreezeEngine.clock(9 * 60 + 30), "09:30")
    }
}
