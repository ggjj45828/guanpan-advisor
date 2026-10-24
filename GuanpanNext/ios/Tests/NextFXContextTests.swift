import XCTest
@testable import GuanpanAdvisorCore

/// 125 汇率上下文。
///
/// 这一项的全部价值在于「别把汇率的影响算到标的头上」，
/// 所以用例集中在门槛与失效保护：数据不够不给数、过期不用、可疑不信、缺失不假设 0。
final class NextFXContextTests: XCTestCase {

    private func shanghai(_ y: Int, _ m: Int, _ d: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    /// 连续 N 个交易日，每天 9:00 一个点，汇率从 startRate 每天 +drift。
    private func series(days: Int, startRate: Double, dailyDrift: Double = 0,
                        endingAt end: Date) -> [NextFXPoint] {
        (0..<days).map { index in
            let offset = Double(-(days - 1 - index)) * 86_400
            return NextFXPoint(timestamp: end.addingTimeInterval(offset),
                               rate: startRate * (1 + dailyDrift * Double(index) / 100))
        }
    }

    // MARK: - 市场映射

    func test_chinaHasNoCurrencyLayer() {
        let context = NextFXContextEngine.context(market: .china, series: [], now: Date())
        XCTAssertEqual(context.state, .notApplicable)
        XCTAssertFalse(context.isUsable)
        XCTAssertTrue(context.note.contains("无汇率层"), context.note)
    }

    func test_eachOverseasMarketMapsToItsPair() {
        XCTAssertEqual(NextFXPair.pair(for: .japan), .jpyCny)
        XCTAssertEqual(NextFXPair.pair(for: .unitedStates), .usdCny)
        XCTAssertEqual(NextFXPair.pair(for: .hongKong), .hkdCny)
        XCTAssertEqual(NextFXPair.pair(for: .korea), .krwCny)
        XCTAssertNil(NextFXPair.pair(for: .china))
    }

    // MARK: - 失效保护

    func test_missingSeriesIsNotTreatedAsZero() {
        let context = NextFXContextEngine.context(market: .japan, series: [], now: shanghai(2026, 10, 23, 10, 0))
        guard case .missing = context.state else {
            return XCTFail("没有汇率数据必须明说缺失：\(context.state)")
        }
        XCTAssertFalse(context.isUsable)
        XCTAssertTrue(context.note.contains("不会假设汇率为 0"), "必须点明不会假装汇率没变")
        XCTAssertNil(NextFXContextEngine.adjust(localPercent: 1.2, context: context),
                     "缺失时不能给出拆分，否则等于把汇率影响算进标的")
    }

    func test_staleRateIsRefused() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let old = [NextFXPoint(timestamp: now.addingTimeInterval(-30 * 3600), rate: 100),
                   NextFXPoint(timestamp: now.addingTimeInterval(-29 * 3600), rate: 100.2)]
        let context = NextFXContextEngine.context(market: .japan, series: old, now: now)
        guard case let .stale(reason) = context.state else {
            return XCTFail("超过 26 小时必须判过期：\(context.state)")
        }
        XCTAssertTrue(reason.contains("小时"), reason)
        XCTAssertFalse(context.isUsable)
        XCTAssertNil(NextFXContextEngine.adjust(localPercent: 1.0, context: context))
    }

    func test_futureTimestampIsSuspicious() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let future = [NextFXPoint(timestamp: now.addingTimeInterval(3600), rate: 100)]
        let context = NextFXContextEngine.context(market: .japan, series: future, now: now)
        guard case .suspicious = context.state else {
            return XCTFail("未来时间戳必须判可疑：\(context.state)")
        }
    }

    func test_abnormalJumpIsSuspiciousNotBelieved() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let jump = [NextFXPoint(timestamp: shanghai(2026, 10, 22, 9, 0), rate: 100),
                    NextFXPoint(timestamp: shanghai(2026, 10, 23, 9, 0), rate: 100),
                    NextFXPoint(timestamp: shanghai(2026, 10, 23, 9, 30), rate: 105)]
        let context = NextFXContextEngine.context(market: .japan, series: jump, now: now)
        guard case let .suspicious(reason) = context.state else {
            return XCTFail("单日 5% 跳变应先怀疑数据：\(context.state)")
        }
        XCTAssertTrue(reason.contains("怀疑数据"), reason)
    }

    func test_noIntradayChangeYetIsMissing() {
        let now = shanghai(2026, 10, 23, 9, 0)
        let morningOnly = [NextFXPoint(timestamp: now.addingTimeInterval(-60), rate: 100)]
        let context = NextFXContextEngine.context(market: .japan, series: morningOnly, now: now)
        guard case .missing = context.state else {
            return XCTFail("今天还没有两个点，算不出今日变动：\(context.state)")
        }
    }

    // MARK: - 样本门槛

    func test_availableButBelowSampleBarSaysSo() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let points = [NextFXPoint(timestamp: shanghai(2026, 10, 23, 9, 0), rate: 100),
                      NextFXPoint(timestamp: shanghai(2026, 10, 23, 9, 30), rate: 100.4),
                      NextFXPoint(timestamp: shanghai(2026, 10, 23, 9, 45), rate: 100.5)]
        let context = NextFXContextEngine.context(market: .japan, series: points, now: now)
        guard case .available = context.state else {
            return XCTFail("当天有变动就应判可用：\(context.state)")
        }
        XCTAssertTrue(context.isUsable)
        XCTAssertFalse(context.meetsSampleBar, "只有 1 个交易日，不够算平均干扰度")
        XCTAssertTrue(context.note.contains("不足"), context.note)
        XCTAssertEqual(context.todayPercent ?? 0, 0.5, accuracy: 0.001)
    }

    func test_enoughDaysMeetsSampleBar() {
        let now = shanghai(2026, 10, 23, 10, 0)
        var points = series(days: 22, startRate: 100, dailyDrift: 0.01,
                            endingAt: shanghai(2026, 10, 22, 9, 0))
        points.append(NextFXPoint(timestamp: shanghai(2026, 10, 23, 9, 0), rate: 100.2))
        points.append(NextFXPoint(timestamp: shanghai(2026, 10, 23, 9, 45), rate: 100.4))
        let context = NextFXContextEngine.context(market: .japan, series: points, now: now)
        XCTAssertTrue(context.isUsable)
        XCTAssertTrue(context.meetsSampleBar, "22 个交易日应满足 20 天门槛")
        XCTAssertTrue(context.note.contains("可算平均干扰度"), context.note)
    }

    // MARK: - 换算

    func test_cnyReturnCompoundsNotAdds() {
        // 标的 +1%，日元 +2% → 人民币口径 1.01 × 1.02 - 1 = 3.02%
        let value = NextFXContextEngine.cnyReturn(localPercent: 1, fxPercent: 2)
        XCTAssertEqual(value, 3.02, accuracy: 0.0001)
    }

    func test_fxDominatedDayIsCalledOut() {
        let now = shanghai(2026, 10, 23, 10, 0)
        // 日元贬值：同样的日元换到更少的人民币 → rate 从 100 跌到 99.1（−0.9%）
        let points = [NextFXPoint(timestamp: shanghai(2026, 10, 23, 9, 0), rate: 100),
                      NextFXPoint(timestamp: shanghai(2026, 10, 23, 9, 45), rate: 99.1)]
        let context = NextFXContextEngine.context(market: .japan, series: points, now: now)
        // 日经跌 0.2%，日元贬 0.9% → 人民币计价跌约 1.10%，主要是汇率
        guard let adjustment = NextFXContextEngine.adjust(localPercent: -0.2, context: context) else {
            return XCTFail("汇率可用时应能拆分")
        }
        XCTAssertTrue(adjustment.isFXDominated)
        XCTAssertEqual(adjustment.cnyPercent, -1.098, accuracy: 0.01)
        XCTAssertTrue(adjustment.note.contains("汇率解释了"), adjustment.note)
        XCTAssertTrue(adjustment.note.contains("不能全算在标的头上"), adjustment.note)
    }

    func test_stockDrivenDayIsNotBlamedOnFX() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let points = [NextFXPoint(timestamp: shanghai(2026, 10, 23, 9, 0), rate: 100),
                      NextFXPoint(timestamp: shanghai(2026, 10, 23, 9, 45), rate: 100.05)]
        let context = NextFXContextEngine.context(market: .japan, series: points, now: now)
        guard let adjustment = NextFXContextEngine.adjust(localPercent: 1.8, context: context) else {
            return XCTFail("汇率可用时应能拆分")
        }
        XCTAssertFalse(adjustment.isFXDominated)
        XCTAssertTrue(adjustment.note.contains("标的是主要因素"), adjustment.note)
    }

    func test_bothFlatDoesNotDivideByZero() {
        XCTAssertEqual(NextFXContextEngine.fxShare(localPercent: 0, fxPercent: 0), 0)
    }
}
