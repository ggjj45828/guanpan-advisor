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

    /// 造一天 `points` 个点、**每分钟**一个（9:30 起）。
    /// 5 分钟窗口下每天产出 `points - 11` 个当日窗口——用来制造
    /// 「分钟观测很多、独立交易日只有 1 天」的场景。
    private func makeDenseDay(offset: Int, points: Int, leadStep: Double, followStep: Double)
        -> (lead: [NextMarketPoint], follow: [NextMarketPoint]) {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        for index in 0..<points {
            let time = stamp(dayOffset: offset, minute: 9 * 60 + 30 + index)
            lead.append(NextMarketPoint(timestamp: time, value: 100 * (1 + leadStep * Double(index))))
            follow.append(NextMarketPoint(timestamp: time, value: 50 * (1 + followStep * Double(index))))
        }
        return (lead, follow)
    }

    /// 造一天 11 个点（9:30–9:40），只产出 **1 个**当日窗口：
    /// 9:35 的领先窗口配 9:35→9:40 的跟随段，其余点的跟随段都落到次日。
    private func makeSparseDay(offset: Int, leadStep: Double, followStep: Double)
        -> (lead: [NextMarketPoint], follow: [NextMarketPoint]) {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        for index in 0..<11 {
            let time = stamp(dayOffset: offset, minute: 9 * 60 + 30 + index)
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

    // MARK: 独立交易日是唯一样本单位（分钟数据很多 ≠ 独立证据很多）

    /// 同一天 69 个分钟点、59 个领先窗口：观测条数很多，
    /// 但独立交易日只有 1 —— 样本量不许被窗口数量灌水。
    func testDenseSingleDayCountsAsOneSession() {
        let day = makeDenseDay(offset: 0, points: 69, leadStep: 0.001, followStep: 0.0005)
        let validation = NextLeadValidationEngine.validate(
            code: "513520", lead: .japan, leadSeries: day.lead, followSeries: day.follow,
            windowMinutes: 5, cutoff: stamp(dayOffset: 1, minute: 9 * 60))
        XCTAssertEqual(validation.sessions, 1, "59 个窗口也只算 1 个独立交易日")
        XCTAssertEqual(validation.directionalDays, 1, "同一天多个窗口仍只贡献 1 个方向性交易日")
        XCTAssertEqual(validation.tier, .insufficient)
        XCTAssertEqual(validation.holdout.state, .insufficient)
        XCTAssertFalse(validation.allowsForwardReplication)
        XCTAssertTrue(validation.tierBlockNote.contains("1 个独立交易日"), validation.tierBlockNote)
    }

    /// 10 天 × 每天 59 个窗口 = 590 条记录，但独立交易日只有 10：
    /// 记录数不许冒充样本量——引擎如实判「样本不足」，而不是拿 590 条记录说事。
    func testManyRecordsFewDaysCannotPoseAsManySessions() {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        for offset in 0..<10 {
            let day = makeDenseDay(offset: offset, points: 69, leadStep: 0.001, followStep: 0.0005)
            lead.append(contentsOf: day.lead)
            follow.append(contentsOf: day.follow)
        }
        let validation = NextLeadValidationEngine.validate(
            code: "513520", lead: .japan, leadSeries: lead, followSeries: follow,
            windowMinutes: 5, cutoff: stamp(dayOffset: 20, minute: 15 * 60))
        XCTAssertEqual(validation.sessions, 10, "590 条记录也只算 10 个独立交易日")
        XCTAssertEqual(validation.directionalDays, 10)
        XCTAssertEqual(validation.tier, .insufficient, "10 个交易日：样本不足，不是拒绝也不是候选")
        XCTAssertFalse(validation.allowsForwardReplication)
        XCTAssertTrue(validation.tierBlockNote.contains("10 个独立交易日"), validation.tierBlockNote)
    }

    /// 单日集中度**恰好 50%**：不否定，但绝不晋升——踩线不算过关。
    /// 构造口径：1 天 59 个窗口 + 59 天各 1 个窗口 → 观测集中度 59/118 = 0.5。
    func testConcentrationExactlyAtBarStaysProvisional() {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        let dense = makeDenseDay(offset: 0, points: 69, leadStep: 0.001, followStep: 0.0005)
        lead.append(contentsOf: dense.lead)
        follow.append(contentsOf: dense.follow)
        for offset in 1..<60 {
            let day = makeSparseDay(offset: offset, leadStep: 0.001, followStep: 0.0005)
            lead.append(contentsOf: day.lead)
            follow.append(contentsOf: day.follow)
        }
        let validation = NextLeadValidationEngine.validate(
            code: "513520", lead: .japan, leadSeries: lead, followSeries: follow,
            windowMinutes: 5, cutoff: stamp(dayOffset: 70, minute: 15 * 60))
        XCTAssertEqual(validation.sessions, 60)
        XCTAssertEqual(validation.concentrationShare, 0.5, accuracy: 0.0001,
                       "59 个窗口 + 59 个单窗口日 → 集中度恰好踩线")
        XCTAssertEqual(validation.tier, .provisional, "恰好 50%：不否定也不晋升")
        XCTAssertFalse(validation.allowsForwardReplication)
        XCTAssertTrue(validation.tierBlockNote.contains("踩在门槛线"), validation.tierBlockNote)
    }

    /// 集中度 49.x%（低于门槛）也不够：其他门槛不过，照样不得晋升。
    /// 集中度过关只是必要条件，从来不是充分条件。
    func testConcentrationBelowBarStillBlockedByOtherGates() {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        let dense = makeDenseDay(offset: 0, points: 69, leadStep: 0.001, followStep: 0.0005)
        lead.append(contentsOf: dense.lead)
        follow.append(contentsOf: dense.follow)
        for offset in 1..<61 {
            let day = makeSparseDay(offset: offset, leadStep: 0.001, followStep: 0.0005)
            lead.append(contentsOf: day.lead)
            follow.append(contentsOf: day.follow)
        }
        let validation = NextLeadValidationEngine.validate(
            code: "513520", lead: .japan, leadSeries: lead, followSeries: follow,
            windowMinutes: 5, cutoff: stamp(dayOffset: 70, minute: 15 * 60))
        XCTAssertEqual(validation.sessions, 61)
        XCTAssertLessThan(validation.concentrationShare, NextLeadValidationEngine.maximumSingleDayShare)
        XCTAssertGreaterThan(validation.concentrationShare, 0.45, "集中度应略低于 50%")
        XCTAssertEqual(validation.tier, .provisional, "集中度过关 ≠ 能晋升：61 天未到长期门槛")
        XCTAssertFalse(validation.allowsForwardReplication)
        XCTAssertTrue(validation.tierBlockNote.contains("未到长期门槛"), validation.tierBlockNote)
    }

    // MARK: 留出段硬门槛：不足时连验证性置信区间都不给

    /// 边界值：200 行（留出段触发/对照恰好各 30）→ 才给区间；
    /// 196 行（留出段只能切出 59 行、触发 29 < 30）→ 状态与区间都不给。
    /// 样本不足不许被包装成具有验证意义的置信区间。
    func testHoldoutGivesIntervalOnlyAtBoundary() {
        var enough: [NextEvidenceRow] = []
        for day in 0..<200 {
            let triggered = day % 2 == 0
            enough.append(NextEvidenceRow(day: dayKey(day), dataComplete: true,
                                          triggered: triggered, confirmed: triggered))
        }
        let pass = NextEvidenceEngine.holdout(enough)
        XCTAssertEqual(pass.eligibleSessions, 200)
        XCTAssertEqual(pass.holdoutSessions, 60)
        XCTAssertEqual(pass.triggerCount, 30)
        XCTAssertEqual(pass.controlCount, 30)
        XCTAssertNotNil(pass.edgeInterval, "踩满门槛就必须给区间")
        XCTAssertEqual(pass.state, .candidateRequiresReplication)

        // 留出段要 60 行（触发/对照各 30）。196 行按 70/30 只能切出 59 行：
        // 触发 29、对照 30 —— 差一行都不给验证性置信区间。
        var justShort: [NextEvidenceRow] = []
        for day in 0..<196 {
            let triggered = day % 2 == 0
            justShort.append(NextEvidenceRow(day: dayKey(day), dataComplete: true,
                                             triggered: triggered, confirmed: triggered))
        }
        let fail = NextEvidenceEngine.holdout(justShort)
        XCTAssertEqual(fail.holdoutSessions, 59)
        XCTAssertEqual(fail.triggerCount, 29)
        XCTAssertEqual(fail.state, .insufficient)
        XCTAssertNil(fail.edgeInterval, "差一天也不给验证性置信区间")
        XCTAssertTrue(fail.note.contains("样本不足"))
    }

    // MARK: 去掉极值日后关系消失 → 不得晋升

    /// 200 天全部「有方向」、集中度也只有三成，但相关性是 3 个极端日撑起来的：
    /// 去掉它们之后关系消失 —— 这是否定，不是「再攒攒」。
    /// 注意 `makeDay` 是 5 分钟间距、5 分钟窗口只回退 1 个点，
    /// 所以窗口涨跌 ≈ `leadStep` 本身：0.005 → 0.5%，够过 0.30% 触发阈值。
    func testRelationshipVanishingWithoutTopDaysCannotPromote() {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        for offset in 0..<200 {
            let day: (lead: [NextMarketPoint], follow: [NextMarketPoint])
            if offset < 3 {
                // 3 个极端日：两边都大幅同向，权重盖过其余日子。
                day = makeDay(offset: offset, leadStep: 0.05, followStep: 0.05)
            } else if offset % 2 == 0 {
                day = makeDay(offset: offset, leadStep: 0.005, followStep: 0.005)
            } else {
                // 奇数日跟随反向：去掉极端日后，剩下的日子并没有关系。
                day = makeDay(offset: offset, leadStep: 0.005, followStep: -0.005)
            }
            lead.append(contentsOf: day.lead)
            follow.append(contentsOf: day.follow)
        }
        let validation = NextLeadValidationEngine.validate(
            code: "513520", lead: .japan, leadSeries: lead, followSeries: follow,
            windowMinutes: 5, cutoff: stamp(dayOffset: 210, minute: 15 * 60))
        XCTAssertGreaterThanOrEqual(validation.directionalDays, NextLeadValidationEngine.minimumDirectionalDays)
        XCTAssertLessThan(validation.concentrationShare, NextLeadValidationEngine.maximumSingleDayShare)
        XCTAssertLessThan(validation.correlationWithoutTopDays ?? 1,
                          NextLeadValidationEngine.minimumCorrelationWithoutTopDays,
                          "去掉贡献最大的 3 天后关系必须消失")
        XCTAssertEqual(validation.tier, .rejected)
        XCTAssertFalse(validation.allowsForwardReplication)
        XCTAssertTrue(validation.tierBlockNote.contains("去掉贡献最大的"), validation.tierBlockNote)
    }

    // MARK: 未来数据不得进入样本统计

    /// cutoff 之后的交易日一天都不进统计：60 天的序列、cutoff 卡在第 30 天开盘前
    /// → 只有 30 个独立交易日。把 cutoff 之后的数据算进来等于用未来作弊。
    func testFutureDaysNeverEnterSessionStats() {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        for offset in 0..<60 {
            let day = makeDay(offset: offset, leadStep: 0.005, followStep: 0.0025)
            lead.append(contentsOf: day.lead)
            follow.append(contentsOf: day.follow)
        }
        let validation = NextLeadValidationEngine.validate(
            code: "513520", lead: .japan, leadSeries: lead, followSeries: follow,
            windowMinutes: 5, cutoff: stamp(dayOffset: 30, minute: 9 * 60))
        XCTAssertEqual(validation.sessions, 30, "cutoff 之后的日子一天都不算")
        XCTAssertEqual(validation.tier, .insufficient)
        XCTAssertTrue(validation.tierBlockNote.contains("30 个独立交易日"), validation.tierBlockNote)
    }

    private func dayKey(_ offset: Int) -> String {
        NextLeadValidationEngine.dayKey(calendar.date(byAdding: .day, value: offset,
                                                      to: stamp(dayOffset: 0, minute: 9 * 60))!)
    }
}
