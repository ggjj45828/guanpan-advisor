import XCTest
@testable import GuanpanAdvisorCore

/// 逐 ETF 长期验证的测试重点不在「算得对」，而在**不敢乱下结论**：
/// 样本不足要说不足，对照组一样好要说不成立，分不开要说分不开。
final class NextLeadValidationTests: XCTestCase {

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    private func stamp(dayOffset: Int, minute: Int) -> Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 1
        parts.day = 5
        parts.hour = minute / 60
        parts.minute = minute % 60
        let base = calendar.date(from: parts)!
        return calendar.date(byAdding: .day, value: dayOffset, to: base)!
    }

    /// 造一天 20 个点、每 5 分钟一个。
    /// `leadStep` / `followStep` 都是「每 5 分钟」的小数涨跌幅。
    private func makeDay(offset: Int, leadStep: Double, followStep: Double)
        -> (lead: [NextMarketPoint], follow: [NextMarketPoint]) {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        for index in 0..<20 {
            let time = stamp(dayOffset: offset, minute: 10 * 60 + index * 5)
            lead.append(NextMarketPoint(timestamp: time, value: 100 * (1 + leadStep * Double(index))))
            follow.append(NextMarketPoint(timestamp: time, value: 50 * (1 + followStep * Double(index))))
        }
        return (lead, follow)
    }

    // MARK: Wilson

    func testWilsonIntervalNarrowsWithSampleSize() throws {
        let small = try XCTUnwrap(NextEvidenceEngine.wilson(successes: 6, trials: 10))
        let large = try XCTUnwrap(NextEvidenceEngine.wilson(successes: 60, trials: 100))
        XCTAssertLessThan(small.lower, large.lower)
        XCTAssertLessThan(large.lower, large.upper)
        XCTAssertGreaterThan(large.lower, 0.4)
    }

    func testWilsonReturnsNilWithoutTrials() {
        XCTAssertNil(NextEvidenceEngine.wilson(successes: 0, trials: 0))
    }

    // MARK: 留出段 + 对照组

    func testHoldoutRefusesToJudgeBelowMinimumSessions() {
        let rows = (0..<40).map { day in
            NextEvidenceRow(day: String(format: "2026-01-%02d", day + 1),
                            dataComplete: true, triggered: day % 2 == 0, confirmed: day % 2 == 0)
        }
        let assessment = NextEvidenceEngine.holdout(rows)
        XCTAssertEqual(assessment.state, .insufficient)
        XCTAssertTrue(assessment.note.contains("样本不足"))
        XCTAssertNil(assessment.edgeInterval)
    }

    /// 这是最关键的一条：触发日 60% 的确认率，如果未触发日也有 60%，
    /// 那就什么也没证明。必须判「分不开」而不是「候选」。
    /// 注意不能判「不成立」——同样的数据也证明不了不成立。
    func testHoldoutRefusesToCallEqualRatesACandidate() throws {
        var rows: [NextEvidenceRow] = []
        for day in 0..<240 {
            let triggered = day % 2 == 0
            // 触发组与对照组确认率都约 60%，但编排成不同排列，避免完全相同的模式。
            let confirmed = (day % 5) < 3
            rows.append(NextEvidenceRow(day: dayKey(day), dataComplete: true,
                                        triggered: triggered, confirmed: confirmed))
        }
        let assessment = NextEvidenceEngine.holdout(rows)
        XCTAssertEqual(assessment.state, .inconclusive)
        let edge = try XCTUnwrap(assessment.edgeInterval)
        XCTAssertGreaterThan(edge.upper, NextEvidenceEngine.practicalEdge)
        XCTAssertFalse(assessment.supportsEdge)
        XCTAssertTrue(assessment.note.contains("不显著不等于没有关系"))
    }

    /// 触发组比对照组更差时，才有把握否定：差值的区间上界 ≤ 5 个百分点。
    /// 反向关系不是「负相关的机会」，这条测试把它钉死。
    func testHoldoutRejectsWhenTriggerIsWorseThanControl() throws {
        var rows: [NextEvidenceRow] = []
        for day in 0..<240 {
            let triggered = day % 2 == 0
            rows.append(NextEvidenceRow(day: dayKey(day), dataComplete: true,
                                        triggered: triggered, confirmed: !triggered))
        }
        let assessment = NextEvidenceEngine.holdout(rows)
        XCTAssertEqual(assessment.state, .noStableRelationship)
        let edge = try XCTUnwrap(assessment.edgeInterval)
        XCTAssertLessThanOrEqual(edge.upper, NextEvidenceEngine.practicalEdge)
        XCTAssertTrue(assessment.note.contains("有把握"))
    }

    func testHoldoutCallsCandidateWhenTriggerBeatsControl() throws {
        var rows: [NextEvidenceRow] = []
        for day in 0..<240 {
            let triggered = day % 2 == 0
            rows.append(NextEvidenceRow(day: dayKey(day), dataComplete: true,
                                        triggered: triggered, confirmed: triggered))
        }
        let assessment = NextEvidenceEngine.holdout(rows)
        XCTAssertEqual(assessment.state, .candidateRequiresReplication)
        let edge = try XCTUnwrap(assessment.edgeInterval)
        XCTAssertGreaterThan(edge.lower, 0)
        XCTAssertEqual(assessment.triggerRate, 1.0)
        XCTAssertEqual(assessment.controlRate, 0.0)
        XCTAssertTrue(assessment.supportsEdge)
    }

    /// 数据够但分不开：既不能说成立，也不能说否定。
    /// 触发组 70%、对照组 62%，差值 8 个百分点看着像优势，但区间跨 0，只能承认「还不知道」。
    func testHoldoutStaysInconclusiveWhenEdgeStraddlesZero() throws {
        var rows: [NextEvidenceRow] = []
        for day in 0..<240 {
            let triggered = day % 2 == 0
            let confirmed: Bool
            if triggered {
                confirmed = (day % 10) < 7
            } else {
                confirmed = (day % 100) < 62
            }
            rows.append(NextEvidenceRow(day: dayKey(day), dataComplete: true,
                                        triggered: triggered, confirmed: confirmed))
        }
        let assessment = NextEvidenceEngine.holdout(rows)
        XCTAssertEqual(assessment.state, .inconclusive)
        let edge = try XCTUnwrap(assessment.edgeInterval)
        XCTAssertLessThanOrEqual(edge.lower, 0)
        XCTAssertGreaterThan(edge.upper, NextEvidenceEngine.practicalEdge)
    }

    /// 缺数据的日子不能被当成「没兑现」，否则缺数据会变成不利证据。
    func testIncompleteDaysAreExcludedFromBothSides() {
        var rows: [NextEvidenceRow] = []
        for day in 0..<240 {
            rows.append(NextEvidenceRow(day: dayKey(day), dataComplete: true,
                                        triggered: day % 2 == 0, confirmed: day % 2 == 0))
        }
        // 塞 40 个缺数据的日子，全部「未确认」。若被算进对照组，会拉低对照率并伪造优势。
        for day in 240..<280 {
            rows.append(NextEvidenceRow(day: dayKey(day), dataComplete: false,
                                        triggered: false, confirmed: false))
        }
        let assessment = NextEvidenceEngine.holdout(rows)
        XCTAssertEqual(assessment.eligibleSessions, 240)
        XCTAssertEqual(assessment.holdoutSessions, 72)
    }

    // MARK: 逐日聚合

    func testSessionPairsAggregateByDayAndRespectCutoff() {
        let trig = makeDay(offset: 0, leadStep: 0.005, followStep: 0.0025)
        let cutoff = stamp(dayOffset: 0, minute: 10 * 60 + 30)
        let within = NextLeadValidationEngine.sessionPairs(lead: trig.lead, follow: trig.follow,
                                                          minutes: 5, cutoff: cutoff)
        XCTAssertEqual(within.count, 1)
        XCTAssertGreaterThanOrEqual(within[0].observations, 5)
        XCTAssertGreaterThan(within[0].leadChange, 0)

        // cutoff 落在开盘前：一个配对都不该产出。
        let before = NextLeadValidationEngine.sessionPairs(lead: trig.lead, follow: trig.follow,
                                                           minutes: 5, cutoff: stamp(dayOffset: 0, minute: 9 * 60))
        XCTAssertTrue(before.isEmpty)
    }

    func testValidationSaysInsufficientBelowProvisionalBar() {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        for offset in 0..<30 {
            let day = makeDay(offset: offset, leadStep: 0.005, followStep: 0.0025)
            lead.append(contentsOf: day.lead)
            follow.append(contentsOf: day.follow)
        }
        let validation = NextLeadValidationEngine.validate(
            code: "513520", lead: .japan, leadSeries: lead, followSeries: follow,
            windowMinutes: 5, cutoff: stamp(dayOffset: 40, minute: 15 * 60))
        XCTAssertEqual(validation.tier, .insufficient)
        XCTAssertEqual(validation.sessions, 30)
        XCTAssertFalse(validation.allowsForwardReplication)
        XCTAssertEqual(validation.holdout.state, .insufficient)
    }

    /// 长期候选：200 天，触发日跟随同向，对照日跟随反向。
    func testValidationReachesCandidateOnlyWithEnoughSessions() {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        for offset in 0..<200 {
            let isTrigger = offset % 2 == 0
            let day = isTrigger
                ? makeDay(offset: offset, leadStep: 0.005, followStep: 0.0025)
                : makeDay(offset: offset, leadStep: 0.0005, followStep: -0.004)
            lead.append(contentsOf: day.lead)
            follow.append(contentsOf: day.follow)
        }
        let validation = NextLeadValidationEngine.validate(
            code: "513520", lead: .japan, leadSeries: lead, followSeries: follow,
            windowMinutes: 5, cutoff: stamp(dayOffset: 210, minute: 15 * 60))
        XCTAssertEqual(validation.sessions, 200)
        XCTAssertEqual(validation.holdout.state, .candidateRequiresReplication)
        XCTAssertEqual(validation.tier, .candidate)
        XCTAssertTrue(validation.allowsForwardReplication)
        XCTAssertGreaterThan(validation.directionalWinRate ?? 0, 0.9)
        XCTAssertEqual(validation.directionalShare, 0.5, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(validation.directionalShare, NextLeadValidationEngine.minimumDirectionalShare)
        XCTAssertTrue(validation.note.contains("长期候选"))
    }

    // MARK: 防「伪相关」：单日极端事件不能升级

    /// 190 天几乎不动、10 天暴涨跟涨。日级相关系数可能很漂亮，
    /// 但「有方向的交易日」只有 10 天——这种关系不能升级为稳定领先关系。
    func testSingleExtremeEventCannotBePromoted() {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        for offset in 0..<200 {
            let extreme = offset % 20 == 0
            let day = extreme
                ? makeDay(offset: offset, leadStep: 0.05, followStep: 0.05)
                : makeDay(offset: offset, leadStep: 0.0005, followStep: 0.0005)
            lead.append(contentsOf: day.lead)
            follow.append(contentsOf: day.follow)
        }
        let validation = NextLeadValidationEngine.validate(
            code: "513520", lead: .japan, leadSeries: lead, followSeries: follow,
            windowMinutes: 5, cutoff: stamp(dayOffset: 210, minute: 15 * 60))
        XCTAssertEqual(validation.directionalDays, 10)
        // 少数事件日碰巧相关：这是**否定**，不是「再等等」。
        XCTAssertEqual(validation.tier, .rejected)
        XCTAssertFalse(validation.allowsForwardReplication)
        XCTAssertTrue(validation.tierBlockNote.contains("没有稳定领先关系"))
        // 方向性交易日太少，所以「方向命中率」本身也不该被当成有效结论展示。
        XCTAssertTrue(validation.note.contains("10 个方向性交易日"))
    }

    /// 方向性交易日够多，但其中一天贡献超过一半 → 这条关系其实是「某一天的关系」。
    func testConcentratedSingleDayBlocksPromotion() {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        for offset in 0..<300 {
            if offset == 0 {
                // 一天的大幅同向跳空：贡献权重会把其它日子全部盖掉。
                lead.append(contentsOf: makeDay(offset: offset, leadStep: 0.08, followStep: 0.08).lead)
                follow.append(contentsOf: makeDay(offset: offset, leadStep: 0.08, followStep: 0.08).follow)
                continue
            }
            let isTrigger = offset % 2 == 0
            let day = isTrigger
                ? makeDay(offset: offset, leadStep: 0.005, followStep: 0.0025)
                : makeDay(offset: offset, leadStep: 0.0005, followStep: -0.004)
            lead.append(contentsOf: day.lead)
            follow.append(contentsOf: day.follow)
        }
        let validation = NextLeadValidationEngine.validate(
            code: "513520", lead: .japan, leadSeries: lead, followSeries: follow,
            windowMinutes: 5, cutoff: stamp(dayOffset: 310, minute: 15 * 60))
        XCTAssertGreaterThanOrEqual(validation.directionalDays, NextLeadValidationEngine.minimumDirectionalDays)
        XCTAssertGreaterThan(validation.concentrationShare, NextLeadValidationEngine.maximumSingleDayShare)
        XCTAssertEqual(validation.tier, .rejected)
        XCTAssertTrue(validation.tierBlockNote.contains("某一天"))
        XCTAssertFalse(validation.allowsForwardReplication)
    }

    // MARK: 台账

    func testLedgerUpsertsAndKeepsLatestState() throws {
        var ledger = NextLeadLedger()
        XCTAssertTrue(ledger.summary.contains("还没有任何逐 ETF"))
        XCTAssertTrue(ledger.candidateCodes.isEmpty)

        let weak = NextLeadValidation(code: "513520", lead: .japan, windowMinutes: 15, sessions: 30,
                                      dailyCorrelation: 0.3, directionalWinRate: 0.55, stability: 0.7,
                                      holdout: NextEvidenceEngine.holdout([]), tier: .insufficient,
                                      cutoff: stamp(dayOffset: 0, minute: 15 * 60))
        ledger.record(weak, at: stamp(dayOffset: 1, minute: 9 * 60))
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertTrue(ledger.candidateCodes.isEmpty)

        // 同一 (ETF, 领先市场) 再记一次：必须覆盖，不是追加。
        var strong = weak
        strong = NextLeadValidation(code: "513520", lead: .japan, windowMinutes: 15, sessions: 200,
                                    dailyCorrelation: 0.6, directionalWinRate: 0.8, stability: 0.9,
                                    holdout: NextHoldoutAssessment(
                                        state: .candidateRequiresReplication, eligibleSessions: 200,
                                        splitIndex: 140, holdoutSessions: 60, triggerCount: 30,
                                        controlCount: 30, triggerRate: 0.8, controlRate: 0.3,
                                        triggerInterval: NextRateInterval(lower: 0.6, upper: 0.9),
                                        controlInterval: NextRateInterval(lower: 0.15, upper: 0.5),
                                        edgeInterval: NextRateInterval(lower: 0.1, upper: 0.75),
                                        note: "候选"),
                                    tier: .candidate, cutoff: stamp(dayOffset: 2, minute: 15 * 60))
        ledger.record(strong, at: stamp(dayOffset: 3, minute: 9 * 60))
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.candidateCodes, ["513520"])

        let entry = try XCTUnwrap(ledger.entry(code: "513520", lead: .japan))
        XCTAssertEqual(entry.sessions, 200)
        XCTAssertEqual(entry.evidenceState, .candidateRequiresReplication)
        XCTAssertEqual(entry.edgeLower ?? 0, 0.1, accuracy: 0.0001)
    }

    func testLedgerRoundTripsThroughCoding() throws {
        var ledger = NextLeadLedger()
        let validation = NextLeadValidation(code: "159866", lead: .japan, windowMinutes: 15, sessions: 120,
                                            dailyCorrelation: 0.4, directionalWinRate: 0.62, stability: 0.8,
                                            holdout: NextEvidenceEngine.holdout([]), tier: .provisional,
                                            cutoff: stamp(dayOffset: 0, minute: 15 * 60))
        ledger.record(validation, at: stamp(dayOffset: 1, minute: 9 * 60))
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(NextLeadLedger.self, from: data)
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries[0].code, "159866")
        XCTAssertEqual(decoded.entries[0].sessions, 120)
    }

    private func dayKey(_ offset: Int) -> String {
        NextLeadValidationEngine.dayKey(calendar.date(byAdding: .day, value: offset,
                                                      to: stamp(dayOffset: 0, minute: 9 * 60))!)
    }
}
