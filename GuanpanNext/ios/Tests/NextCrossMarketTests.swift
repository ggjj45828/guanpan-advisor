import XCTest
@testable import GuanpanAdvisorCore

/// 跨市场模块（116–145）的可回放验证。
///
/// 这些用例刻意只测**能在当前环境算出来的东西**：时区对齐、午休信息差、
/// 防未来数据、样本不足拒绝出结论、假设确认/拒绝、背离、隔夜消化、执行层过滤。
/// 需要真实行情源/真机的部分不在这里假装通过。
final class NextCrossMarketTests: XCTestCase {

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - 136/137 时区、午休、冬夏令时

    func testMarketStatusUsesLocalSessionIncludingLunchBreak() {
        let calendar = NextMarketCalendar()
        // 2026-10-23 是周五。北京时间 10:00 = 02:00 UTC。
        XCTAssertEqual(calendar.status(.china, at: utc(2026, 10, 23, 2, 0)), .open)
        // 北京时间 12:00 = 04:00 UTC，A股午休。
        XCTAssertEqual(calendar.status(.china, at: utc(2026, 10, 23, 4, 0)), .lunchBreak)
        // 北京时间 15:30 = 07:30 UTC，已收盘。
        XCTAssertEqual(calendar.status(.china, at: utc(2026, 10, 23, 7, 30)), .closed)
        // 东京 10:00 = 01:00 UTC，日本连续交易（无午休）。
        XCTAssertEqual(calendar.status(.japan, at: utc(2026, 10, 23, 1, 0)), .open)
        // 纽约 12:00（EDT）= 16:00 UTC，正在交易。
        XCTAssertEqual(calendar.status(.unitedStates, at: utc(2026, 7, 15, 16, 0)), .open)
        // 周日整体休市。
        XCTAssertEqual(calendar.status(.china, at: utc(2026, 10, 25, 2, 0)), .weekend)
    }

    func testHolidayAndDaylightSavingShiftAreHandledNotHardcoded() {
        var calendar = NextMarketCalendar()
        calendar.holidays[.japan] = ["2026-10-23"]
        XCTAssertEqual(calendar.status(.japan, at: utc(2026, 10, 23, 1, 0)), .holiday)

        // 美股开盘 09:30 本地时间：冬令时 = 14:30 UTC，夏令时 = 13:30 UTC。
        // 手写偏移一定会在这里错，必须靠 TimeZone。
        XCTAssertEqual(calendar.status(.unitedStates, at: utc(2026, 1, 15, 14, 31)), .open)
        XCTAssertEqual(calendar.status(.unitedStates, at: utc(2026, 1, 15, 13, 31)), .preOpen)
        XCTAssertEqual(calendar.status(.unitedStates, at: utc(2026, 7, 15, 13, 31)), .open)
    }

    // MARK: - 119 午休信息差 + 135 不使用未来数据

    func testLunchShockOnlyUsesDataBeforeTheCheckpoint() {
        // 午休窗口取 A股自己的（11:30–13:00）；韩国是**被观察方**，它自己不停盘。
        let calendar = NextMarketCalendar()
        guard let lunch = calendar.lunchBreak(.china, at: utc(2026, 10, 23, 4, 0)) else {
            return XCTFail("A股应能取到午休区间")
        }
        let series = [
            NextMarketPoint(timestamp: lunch.start.addingTimeInterval(-600), value: 99.0),
            NextMarketPoint(timestamp: lunch.end.addingTimeInterval(-600), value: 99.7),
            // 12:55 之后的数据不允许进入午休信息差，否则就是把 13:00 的结果当成 12:50 已知。
            NextMarketPoint(timestamp: lunch.end.addingTimeInterval(-300), value: 105.0)
        ]
        guard let shock = NextLunchBreakEngine.shock(market: .korea, series: series, previousClose: 100,
                                                     lunch: lunch) else {
            return XCTFail("应能算出午休信息差")
        }
        XCTAssertEqual(shock.preLunchChange, -1.0, accuracy: 0.0001)
        XCTAssertEqual(shock.lateLunchChange, -0.3, accuracy: 0.0001)
        XCTAssertEqual(shock.shock, 0.7, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(shock.lateLunch, lunch.end.addingTimeInterval(-600))
        XCTAssertTrue(shock.note.contains("修复"))
    }

    // MARK: - 117/134 Lead-Lag：有真实关系才给结论

    func testLeadLagFindsRelationOnlyWhenFollowReallyLagsLead() {
        let start = utc(2026, 10, 23, 1, 0)
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        var leadValue = 100.0
        var followValue = 100.0
        var previousChange = 0.0
        for index in 0..<80 {
            let stamp = start.addingTimeInterval(Double(index) * 300)
            let change = sin(Double(index) * 0.2) * 0.3
            leadValue *= (1 + change / 100)
            lead.append(NextMarketPoint(timestamp: stamp, value: leadValue))
            // 跟随者用的是**上一根**领先变化：领先 5 分钟。
            follow.append(NextMarketPoint(timestamp: stamp, value: followValue))
            followValue *= (1 + previousChange / 100)
            previousChange = change
        }
        let study = NextLeadLagEngine.study(lead: .korea, leadSeries: lead, followCode: "512480",
                                            followSeries: follow, lastValidated: start.addingTimeInterval(80 * 300))
        guard case let .usable(best, windows, _, _) = study.verdict else {
            return XCTFail("构造出的领先关系应被识别：\(study.summary)")
        }
        XCTAssertGreaterThan(best.correlation, 0.7, "相关系数应明显为正")
        XCTAssertGreaterThanOrEqual(best.sampleCount, NextLeadLagEngine.minimumSamples)
        XCTAssertTrue(windows.contains { $0.minutes == 5 }, "至少测试了 5 分钟窗口")
        XCTAssertTrue(study.summary.contains("领先"))
    }

    func testLeadLagRefusesToInventRelationFromUnrelatedSeries() {
        let start = utc(2026, 10, 23, 1, 0)
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        for index in 0..<80 {
            let stamp = start.addingTimeInterval(Double(index) * 300)
            lead.append(NextMarketPoint(timestamp: stamp, value: 100 + sin(Double(index) * 0.2) * 2))
            follow.append(NextMarketPoint(timestamp: stamp, value: 50 + cos(Double(index) * 1.7) * 3))
        }
        let study = NextLeadLagEngine.study(lead: .japan, leadSeries: lead, followCode: "512480",
                                            followSeries: follow, lastValidated: start)
        if case .usable = study.verdict { XCTFail("无关序列不允许生成领先关系") }
        XCTAssertTrue(study.summary.contains("暂无稳定领先关系"), study.summary)
        XCTAssertNil(study.best)
    }

    func testLeadLagRefusesWhenSamplesAreTooFew() {
        let start = utc(2026, 10, 23, 1, 0)
        let lead = (0..<10).map { NextMarketPoint(timestamp: start.addingTimeInterval(Double($0) * 300), value: 100 + Double($0)) }
        let follow = (0..<10).map { NextMarketPoint(timestamp: start.addingTimeInterval(Double($0) * 300), value: 50 + Double($0) * 0.5) }
        let study = NextLeadLagEngine.study(lead: .korea, leadSeries: lead, followCode: "512480",
                                            followSeries: follow, lastValidated: start)
        if case .usable = study.verdict { XCTFail("10 个样本不足以判断领先关系") }
    }

    // MARK: - 128 假设必须先被 A股自己确认

    func testHypothesisIsRejectedWithoutLocalPriceAndVolumeConfirmation() {
        let created = utc(2026, 10, 23, 5, 0)          // 13:00 北京时间
        let deadline = created.addingTimeInterval(600) // 13:10
        let hypothesis = NextCrossHypothesis(code: "512480", createdAt: created, confirmDeadline: deadline,
                                             statement: "午后修复", overseasEvidence: ["韩国科技反弹 1.2%"])
        let local = (2...8).map {
            NextMarketPoint(timestamp: created.addingTimeInterval(Double($0) * 60), value: 99.5)
        }
        let judged = NextHypothesisJudge.judge(hypothesis, local: local, vwap: 100,
                                               referencePrice: 99.8, volumeRecovered: false,
                                               now: deadline.addingTimeInterval(600))
        XCTAssertEqual(judged.state, .rejected)
        XCTAssertFalse(judged.state.allowsPlan)
        XCTAssertTrue(judged.resolution?.contains("放弃") == true, judged.resolution ?? "")
    }

    func testHypothesisIsConfirmedOnlyByLocalEvidence() {
        let created = utc(2026, 10, 23, 5, 0)
        let deadline = created.addingTimeInterval(600)
        let hypothesis = NextCrossHypothesis(code: "512480", createdAt: created, confirmDeadline: deadline,
                                             statement: "午后修复", overseasEvidence: ["韩国科技反弹 1.2%"])
        let local = (2...8).map {
            NextMarketPoint(timestamp: created.addingTimeInterval(Double($0) * 60), value: 100.6)
        }
        let judged = NextHypothesisJudge.judge(hypothesis, local: local, vwap: 100,
                                               referencePrice: 99.8, volumeRecovered: true,
                                               now: deadline.addingTimeInterval(60))
        XCTAssertEqual(judged.state, .confirmed)
        XCTAssertTrue(judged.state.allowsPlan)
        XCTAssertTrue(judged.resolution?.contains("VWAP") == true)
    }

    // MARK: - 122 背离 / 123 隔夜消化 / 124 执行层

    func testDivergenceNeedsMeaningfulGapNotJustOppositeSigns() {
        let now = utc(2026, 10, 23, 5, 30)
        let overseas = [
            NextMarketPoint(timestamp: now.addingTimeInterval(-1800), value: 100),
            NextMarketPoint(timestamp: now, value: 102)     // +2%
        ]
        let local = [
            NextMarketPoint(timestamp: now.addingTimeInterval(-1800), value: 1.400),
            NextMarketPoint(timestamp: now, value: 1.4014)  // +0.1%
        ]
        let signal = NextDivergenceDetector.detect(overseas: overseas, local: local,
                                                   lookbackMinutes: 30, thresholdPercent: 0.3, now: now)
        XCTAssertEqual(signal?.direction, .potentialCatchUp)
        XCTAssertTrue(signal?.note.contains("不直接买") == true)

        // 海外只动了 0.25%，不到门槛，不能算背离。
        let mildOverseas = [
            NextMarketPoint(timestamp: now.addingTimeInterval(-1800), value: 100),
            NextMarketPoint(timestamp: now, value: 100.25)
        ]
        XCTAssertNil(NextDivergenceDetector.detect(overseas: mildOverseas, local: local,
                                                   lookbackMinutes: 30, thresholdPercent: 0.3, now: now))
    }

    func testOvernightAbsorptionSaysWhenNewsIsAlreadyPriced() {
        guard let assessment = NextAbsorptionEngine.assess(overnightChange: -2.0, previousClose: 100,
                                                           openPrice: 97.7, currentPrice: 97.5) else {
            return XCTFail("应该能算出隔夜消化")
        }
        XCTAssertGreaterThan(assessment.absorbedRatio, 0.9)
        XCTAssertTrue(assessment.verdict.contains("已计价"), assessment.verdict)
    }

    func testExecutionFilterBlocksChasingWhenPremiumOrSpreadIsTooWide() {
        let expensive = NextETFExecution.assess(price: 1.02, iopv: 1.00, bestBid: 1.019, bestAsk: 1.021)
        XCTAssertFalse(expensive.allowsChasing)
        XCTAssertTrue(expensive.verdict.contains("溢价"), expensive.verdict)

        let wide = NextETFExecution.assess(price: 1.000, iopv: 1.000, bestBid: 0.995, bestAsk: 1.005)
        XCTAssertFalse(wide.allowsChasing, "价差 1% 会吃掉利润，不能追")

        let normal = NextETFExecution.assess(price: 1.001, iopv: 1.000, bestBid: 1.0005, bestAsk: 1.0015)
        XCTAssertTrue(normal.allowsChasing)
    }

    // MARK: - 138 新鲜度 / 130 上下文

    func testStaleOrClosedMarketCannotFeedTodaysConclusion() {
        let stale = NextCrossMarketFreshness(market: .japan, source: "fixture",
                                             observedAt: utc(2026, 10, 23, 1, 0), ageMinutes: 45,
                                             marketStatus: .open)
        XCTAssertFalse(stale.usable)
        XCTAssertEqual(stale.weight, 0)
        XCTAssertTrue(stale.note.contains("不参与今日判断"))

        let holiday = NextCrossMarketFreshness(market: .japan, source: "fixture",
                                              observedAt: utc(2026, 10, 23, 1, 0), ageMinutes: 3,
                                              marketStatus: .holiday)
        XCTAssertFalse(holiday.usable)
        XCTAssertTrue(holiday.note.contains("休市"))

        let live = NextCrossMarketFreshness(market: .korea, source: "fixture",
                                            observedAt: utc(2026, 10, 23, 1, 0), ageMinutes: 3,
                                            marketStatus: .open)
        XCTAssertTrue(live.usable)
        XCTAssertEqual(live.weight, 1)
    }

    func testContextBlocksPlanUntilHypothesisIsConfirmed() {
        var context = NextCrossMarketContext()
        context.hypothesis = NextCrossHypothesis(code: "512480", createdAt: utc(2026, 10, 23, 5, 0),
                                                 confirmDeadline: utc(2026, 10, 23, 5, 10),
                                                 statement: "午后修复", overseasEvidence: ["韩国科技 +1.2%"])
        XCTAssertFalse(context.allowsPlan, "海外信号本身不能直接放行交易计划")

        context.hypothesis?.state = .confirmed
        XCTAssertTrue(context.allowsPlan)

        context.abroad[.korea] = NextCrossMarketFreshness(market: .korea, source: "fixture",
                                                          observedAt: utc(2026, 10, 23, 5, 8), ageMinutes: 2,
                                                          marketStatus: .open)
        XCTAssertEqual(context.usableMarketCount, 1)
        XCTAssertTrue(context.contextLines.contains { $0.contains("韩国") })
    }
}
