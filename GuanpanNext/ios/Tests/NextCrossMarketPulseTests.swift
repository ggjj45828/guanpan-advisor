import XCTest
@testable import GuanpanAdvisorCore

/// 140 / 141 的验收：首页「跨市场脉搏」与持仓「外部市场影响」。
///
/// 这组用例只盯一件事：**界面不许把「休市」「过期」「没验证过」说成「现在怎样」。**
final class NextCrossMarketPulseTests: XCTestCase {

    private func shanghai(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    private func archive(rows: [(NextCrossMarket, String, Double, Double?)]) -> NextCrossMarketArchive {
        var byMarket: [NextCrossMarket: [String: [NextMarketPoint]]] = [:]
        var dayChange: [NextCrossMarket: [String: Double]] = [:]
        for (market, stamp, price, change) in rows {
            let date = ISO8601DateFormatter().date(from: stamp)!
            let key = NextCrossMarketFeed.dayKey(date, market: market)
            byMarket[market, default: [:]][key, default: []].append(NextMarketPoint(timestamp: date, value: price))
            if let change { dayChange[market, default: [:]][key] = change }
        }
        return NextCrossMarketArchive(byMarket: byMarket, dayChange: dayChange, reportedRows: rows.count)
    }

    func test_pulseWithoutDataSaysSoInsteadOfFakingPrices() {
        let pulse = NextCrossMarketPulseBuilder.build(archive: nil, now: shanghai("2026-10-23T10:00:00+08:00"))
        XCTAssertFalse(pulse.hasAnyData)
        XCTAssertEqual(pulse.headline, "暂无跨市场数据")
        XCTAssertEqual(pulse.rows.count, 4)
        XCTAssertTrue(pulse.rows.allSatisfy { $0.priceText == "—" })
        XCTAssertTrue(pulse.subtitle.contains("暂无稳定领先关系"))
    }

    func test_closedMarketIsNotUsableAndSaysLastObservation() {
        // 东京 15:30 收盘；北京时间 19:00 时日本已收盘
        let data = archive(rows: [(.japan, "2026-10-23T06:30:00+00:00", 62692.94, -0.34)])
        let pulse = NextCrossMarketPulseBuilder.build(archive: data, now: shanghai("2026-10-23T19:00:00+08:00"))
        let japan = pulse.rows.first { $0.market == .japan }!
        XCTAssertEqual(japan.stateText, "已收盘")
        XCTAssertFalse(japan.usable, "休市的数据不能算可用实时信息")
        XCTAssertTrue(japan.ageText.hasPrefix("最后"), "休市时应该说最后观测时间，不能假装是现在")
        XCTAssertEqual(japan.changeText, "-0.34%")
    }

    func test_openMarketWithFreshDataIsUsable() {
        // 北京时间 10:00 = 东京 11:00，日经上午盘中
        let data = archive(rows: [(.japan, "2026-10-23T01:58:00+00:00", 62692.94, 0.82)])
        let pulse = NextCrossMarketPulseBuilder.build(archive: data, now: shanghai("2026-10-23T10:00:00+08:00"))
        let japan = pulse.rows.first { $0.market == .japan }!
        XCTAssertEqual(japan.stateText, "交易中")
        XCTAssertTrue(japan.usable)
        XCTAssertTrue(pulse.headline.contains("日经 +0.82%"))
    }

    func test_staleOpenMarketIsNotUsable() {
        // 盘中但最后一条是 90 分钟前 → 数据已经不可信
        let data = archive(rows: [(.japan, "2026-10-23T00:30:00+00:00", 62692.94, 0.82)])
        let pulse = NextCrossMarketPulseBuilder.build(archive: data, now: shanghai("2026-10-23T10:00:00+08:00"))
        let japan = pulse.rows.first { $0.market == .japan }!
        XCTAssertFalse(japan.usable)
        XCTAssertEqual(japan.tone, .warn)
    }

    func test_subtitleCountsOnlyMarketsWithEnoughDays() {
        var rows: [(NextCrossMarket, String, Double, Double?)] = []
        for index in 0..<30 {
            let day = String(format: "2026-09-%02d", index + 1)
            rows.append((.japan, "\(day)T02:00:00+00:00", 62000 + Double(index), 0.1))
        }
        let pulse = NextCrossMarketPulseBuilder.build(archive: archive(rows: rows),
                                                      now: shanghai("2026-09-30T10:00:00+08:00"))
        XCTAssertTrue(pulse.subtitle.contains("可回放验证"))
        XCTAssertEqual(pulse.archivedDays[.japan], 30)
        XCTAssertEqual(pulse.archivedDays[.korea], 0)
    }

    func test_lunchNoteOnlyAppearsDuringChinaLunchBreak() {
        // 北京时间 12:10 = A股午休；日经/KOSPI 也在午休时段（东京 13:10）
        let data = archive(rows: [
            (.japan, "2026-10-23T01:30:00+00:00", 62000, 0.1),   // 东京 10:30
            (.japan, "2026-10-23T04:00:00+00:00", 62350, 0.5),   // 东京 13:00
            (.korea, "2026-10-23T01:30:00+00:00", 5500, 0.1),
            (.korea, "2026-10-23T04:00:00+00:00", 5522, 0.4),
        ])
        let duringLunch = NextCrossMarketPulseBuilder.build(archive: data, now: shanghai("2026-10-23T12:10:00+08:00"))
        XCTAssertNotNil(duringLunch.lunchNote, "A股午休时应给出午休期间的外部变化")
        XCTAssertTrue(duringLunch.lunchNote?.contains("A股午休期间") ?? false)

        let afterClose = NextCrossMarketPulseBuilder.build(archive: data, now: shanghai("2026-10-23T19:00:00+08:00"))
        XCTAssertNil(afterClose.lunchNote, "非午休时段不该出现午休提示")
    }

    func test_holdingImpactAdmitsNoStableLead() {
        let pulse = NextCrossMarketPulseBuilder.build(archive: nil, now: shanghai("2026-10-23T10:00:00+08:00"))
        let impact = NextHoldingAbroadImpactBuilder.impact(code: "513100", studies: [], pulse: pulse)
        XCTAssertFalse(impact.hasStableLead)
        XCTAssertTrue(impact.summary.contains("暂无稳定领先关系"))
    }

    func test_holdingImpactReportsLeadWhenStudyIsUsable() {
        let window = NextLeadLagWindow(minutes: 15, sampleCount: 120, independentDays: 45,
                                       correlation: 0.34, sameDirectionRate: 0.61,
                                       wilsonLowerBound: 0.68, bonferroniP: 0.006, holdoutDays: 15,
                                       meanFollowReturn: 0.12, medianFollowReturn: 0.09,
                                       positiveRatio: 0.58, maxAdverseReturn: -0.8, stability: 1)
        let study = NextLeadLagStudy(lead: .japan, followCode: "513100",
                                     verdict: .usable(best: window, windows: [window], periodDays: 60,
                                                      lastValidated: shanghai("2026-10-23T15:00:00+08:00")))
        let pulse = NextCrossMarketPulseBuilder.build(archive: nil, now: shanghai("2026-10-23T10:00:00+08:00"))
        let impact = NextHoldingAbroadImpactBuilder.impact(code: "513100", studies: [study], pulse: pulse)
        XCTAssertTrue(impact.hasStableLead)
        XCTAssertTrue(impact.summary.contains("领先约 15 分钟"))
    }

    func test_holdingImpactIgnoresOtherCodesAndInsufficientStudies() {
        let study = NextLeadLagStudy(lead: .japan, followCode: "510300",
                                     verdict: .insufficient("样本不足"))
        let pulse = NextCrossMarketPulseBuilder.build(archive: nil, now: shanghai("2026-10-23T10:00:00+08:00"))
        let impact = NextHoldingAbroadImpactBuilder.impact(code: "513100", studies: [study], pulse: pulse)
        XCTAssertFalse(impact.hasStableLead)
    }
}
