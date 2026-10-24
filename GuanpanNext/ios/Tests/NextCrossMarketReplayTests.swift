import XCTest
@testable import GuanpanAdvisorCore

/// 历史回放验证器的验收：它必须能**证伪**。
///
/// 三条最关键的用例：
/// 1. 12:50 之后的数据不能影响假设（知识截断是结构性的）；
/// 2. 没有真实规律时必须明确输出「没有稳定领先关系」；
/// 3. 有真实规律时必须认出来（否则这个工具只会一律说不）。
final class NextCrossMarketReplayTests: XCTestCase {

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 构造一个 A股 交易日：上午 09:30–11:30、下午 13:00–15:00，韩国同步提供全天数据。
    /// `afternoon` 是 13:00 之后的收盘价序列（第一个点用于确认窗口）。
    private func day(offset: Int, morningClose: Double, afternoon: [Double],
                     overseasRepair: Double = 0.8) -> NextReplayDay {
        let base = utc(2026, 1, 5, 0, 0)   // 周一
        let date = base.addingTimeInterval(Double(offset) * 86_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func stamp(_ hour: Int, _ minute: Int) -> Date {
            let dayStart = calendar.startOfDay(for: date)
            return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: dayStart)!
        }
        let previousClose = 100.0
        // 上午：从 100 平滑走到 morningClose。
        let morningTimes = stride(from: 9 * 60 + 30, through: 11 * 60 + 30, by: 30).map { $0 }
        let morning = morningTimes.enumerated().map { index, minute in
            let ratio = Double(index) / Double(max(1, morningTimes.count - 1))
            let value = previousClose + (morningClose - previousClose) * ratio
            return NextMarketPoint(timestamp: stamp(minute / 60, minute % 60), value: value)
        }
        let afternoonPoints = afternoon.enumerated().map { index, value in
            NextMarketPoint(timestamp: stamp(13, index * 30), value: value)
        }
        let local = NextCrossMarketDaySeries(market: .china, previousClose: previousClose,
                                             points: morning + afternoonPoints)
        // 韩国：11:30 时 -1.0%，12:50 时 -1.0 + repair。
        let korea = NextCrossMarketDaySeries(market: .korea, previousClose: previousClose, points: [
            NextMarketPoint(timestamp: stamp(9, 0), value: 100.0),
            NextMarketPoint(timestamp: stamp(11, 30), value: 99.0),
            NextMarketPoint(timestamp: stamp(12, 50), value: 99.0 + overseasRepair),
            NextMarketPoint(timestamp: stamp(15, 30), value: 99.0 + overseasRepair)
        ])
        return NextReplayDay(date: date, code: "512480", name: "半导体设备ETF",
                             local: local, overseas: [korea])
    }

    // MARK: - 135 冻结：午后数据不能影响假设

    func testCutoffFreezesHypothesisSoAfternoonCannotChangeDecision() {
        let rule = NextReplayHypothesisRule.lunchRepair
        let calendar = NextMarketCalendar()
        // 两个交易日在 12:50 之前完全相同，只有一个午后上涨、一个午后下跌。
        let rising = NextReplayEngine.replay(day: day(offset: 0, morningClose: 99.5, afternoon: [99.6, 100.2, 100.6]),
                                             rule: rule, calendar: calendar)
        let falling = NextReplayEngine.replay(day: day(offset: 0, morningClose: 99.5, afternoon: [99.6, 99.0, 98.4]),
                                              rule: rule, calendar: calendar)
        // 假设的输入必须一模一样：说明决策没有偷看午后。
        XCTAssertEqual(rising.overseasRepair, falling.overseasRepair)
        XCTAssertEqual(rising.localMorningChange, falling.localMorningChange)
        XCTAssertNotEqual(rising.outcome, .noHypothesis)
        XCTAssertNotEqual(falling.outcome, .noHypothesis)
        // 只有「结果」不同。
        XCTAssertEqual(rising.outcome, .confirmedFollowThrough)
        XCTAssertEqual(falling.outcome, .confirmedFailed)
    }

    func testAfternoonRallyCannotRetroactivelyCreateHypothesis() {
        // 上午已经 +0.5%，不满足「上午下跌」门槛：午后暴涨也不能补出一个假设。
        let result = NextReplayEngine.replay(day: day(offset: 0, morningClose: 100.5, afternoon: [101, 103, 106]),
                                             rule: .lunchRepair, calendar: NextMarketCalendar())
        XCTAssertEqual(result.outcome, .noHypothesis)
        XCTAssertTrue(result.note.contains("未达门槛"), result.note)
    }

    // MARK: - 证伪：没有规律时必须明说

    func testReplayRefusesToInventPatternWhenConfirmationRarelyHappens() {
        var days: [NextReplayDay] = []
        for index in 0..<60 {
            // 40 天的午后第一点直接低于上午收盘 → A股不确认。
            let afternoon = index < 40 ? [99.2, 99.0, 98.8] : [99.6, 100.2, 100.4]
            days.append(day(offset: index * 7, morningClose: 99.5, afternoon: afternoon))
        }
        let report = NextReplayEngine.run(days: days, rule: .lunchRepair)
        guard case let .noStableEvidence(reason) = report.verdict else {
            return XCTFail("确认率不足时不允许输出规律：\(report.verdict.headline)")
        }
        XCTAssertTrue(report.verdict.headline.contains("没有稳定领先关系"), report.verdict.headline)
        XCTAssertTrue(reason.contains("不成立") || reason.contains("少于"), reason)
        XCTAssertEqual(report.confirmedCount, 20)
        XCTAssertEqual(report.hypothesisCount, 60)
    }

    func testReplayReportsInsufficientSamplesInsteadOfGuessing() {
        let days = (0..<5).map { day(offset: $0 * 7, morningClose: 99.5, afternoon: [99.6, 100.2, 100.4]) }
        let report = NextReplayEngine.run(days: days, rule: .lunchRepair)
        guard case let .noStableEvidence(reason) = report.verdict else {
            return XCTFail("样本只有 5 天不能下结论")
        }
        XCTAssertTrue(reason.contains("少于 30"), reason)
    }

    // MARK: - 有真实规律时必须认出来（否则工具只会一律说不）

    func testReplayConfirmsPatternWhenItActuallyHolds() {
        var days: [NextReplayDay] = []
        for index in 0..<60 {
            let drift = 100.4 + Double(index % 3) * 0.1
            days.append(day(offset: index * 7, morningClose: 99.5, afternoon: [99.6, drift, drift + 0.2]))
        }
        let report = NextReplayEngine.run(days: days, rule: .lunchRepair)
        guard case let .evidence(stats) = report.verdict else {
            return XCTFail("真实成立的关系应被识别：\(report.verdict.headline)")
        }
        XCTAssertEqual(stats.hypothesisDays, 60)
        XCTAssertEqual(stats.confirmedDays, 60)
        XCTAssertEqual(stats.followThroughDays, 60)
        XCTAssertEqual(stats.confirmationRate, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(stats.medianAfternoonReturn, 0)
        XCTAssertEqual(stats.stability, 1)
        XCTAssertTrue(report.verdict.headline.contains("规律成立"))
    }

    func testReplaySkipsDaysWithoutOverseasData() {
        let base = day(offset: 0, morningClose: 99.5, afternoon: [99.6, 100.2, 100.4])
        let noOverseas = NextReplayDay(date: base.date, code: base.code, name: base.name,
                                       local: base.local, overseas: [])
        let result = NextReplayEngine.replay(day: noOverseas, rule: .lunchRepair,
                                             calendar: NextMarketCalendar())
        XCTAssertEqual(result.outcome, .noHypothesis)
        XCTAssertTrue(result.note.contains("缺少海外数据"), result.note)
    }

    // MARK: - 回放器不产生交易语义

    func testReplayProducesResearchOutcomeOnly() {
        // 回放结果只有四种研究结论，不含价格/份额/资金字段——它不是模拟账户。
        XCTAssertEqual(NextReplayOutcome.allCases.count, 4)
        XCTAssertEqual(Set(NextReplayOutcome.allCases.map(\.rawValue)),
                       ["noHypothesis", "confirmedFollowThrough", "confirmedFailed", "rejectedNoConfirmation"])
    }

    /// 146 研究工具页面的显示口径：四种结论都必须有中文标签，
    /// 且「未产生假设」不能被写成「失败」——不交易也是一个正确结果。
    func testEveryReplayOutcomeHasChineseLabel() {
        for outcome in NextReplayOutcome.allCases {
            XCTAssertFalse(outcome.label.isEmpty)
            let hasChinese = outcome.label.unicodeScalars.contains { scalar in scalar.value > 0x2E80 }
            XCTAssertTrue(hasChinese, "\(outcome) 的标签必须是中文，不能把英文枚举名漏到界面上")
        }
        XCTAssertEqual(NextReplayOutcome.noHypothesis.label, "未产生假设")
    }
}
