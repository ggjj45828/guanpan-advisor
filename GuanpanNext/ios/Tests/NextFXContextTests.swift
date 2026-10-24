import XCTest
@testable import GuanpanAdvisorCore

/// 125 汇率上下文。
///
/// 这一项的全部价值在于「别把汇率的影响算到标的头上」，
/// 所以用例集中在门槛与失效保护：数据不够不给数、过期不用、可疑不信、缺失不假设 0。
///
/// 另有汇率的数据纪律：来源必须明确、必须有交易所时间戳、新鲜度只按交易所时间戳算，
/// 且**刚收到 ≠ 数据新**——手机/NAS 的旧值不能伪装成实时；汇率也永远不能单独触发计划。
final class NextFXContextTests: XCTestCase {

    private func shanghai(_ y: Int, _ m: Int, _ d: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    /// 造一个来源完整的点：默认「源时间戳 = 收到的时刻」，来源按 NAS 归档，
    /// 来源名称默认取已验证的 "Sina fx"。
    /// 要造「刚收到旧值」「来源未验证」这类场景，单独传 receivedAt / source / sourceName。
    private func point(exchangeAt: Date, receivedAt: Date? = nil, rate: Double,
                       source: NextFXSource = .nasArchive,
                       sourceName: String = "Sina fx") -> NextFXPoint {
        NextFXPoint(exchangeAt: exchangeAt, receivedAt: receivedAt ?? exchangeAt,
                    rate: rate, source: source, sourceName: sourceName)
    }

    /// 连续 N 个交易日，每天 9:00 一个点，汇率从 startRate 每天 +drift。
    private func series(days: Int, startRate: Double, dailyDrift: Double = 0,
                        endingAt end: Date) -> [NextFXPoint] {
        (0..<days).map { index in
            let offset = Double(-(days - 1 - index)) * 86_400
            return point(exchangeAt: end.addingTimeInterval(offset),
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

    // MARK: - 数据纪律：来源 / 交易所时间戳 / 新鲜度

    func test_unknownSourceIsNeverRealTime() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let points = [point(exchangeAt: shanghai(2026, 10, 23, 9, 45), rate: 100, source: .unknown)]
        let context = NextFXContextEngine.context(market: .japan, series: points, now: now)
        guard case let .suspicious(reason) = context.state else {
            return XCTFail("来源不明必须判可疑：\(context.state)")
        }
        XCTAssertTrue(reason.contains("来源不明"), reason)
        XCTAssertFalse(context.isRealTime, "来源不明绝不能当实时值")
        XCTAssertFalse(context.isUsable)
    }

    func test_missingExchangeTimestampIsNeverRealTime() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let noStamp = NextFXPoint(exchangeAt: nil, receivedAt: now, rate: 100,
                                  source: .nasArchive, sourceName: "Sina fx")
        let context = NextFXContextEngine.context(market: .japan, series: [noStamp], now: now)
        guard case let .missing(reason) = context.state else {
            return XCTFail("没有交易所时间戳必须判缺失：\(context.state)")
        }
        XCTAssertTrue(reason.contains("交易所时间戳"), reason)
        XCTAssertFalse(context.isRealTime)
        XCTAssertFalse(NextFXContextEngine.isRealTime(noStamp, now: now))
    }

    /// 核心防伪装用例：值很旧（交易所时间戳 3 天前），但**刚刚才被读出来**。
    /// 它仍然是旧值——「刚收到」不能当新鲜的证据。
    func test_justReceivedOldValueIsStillStale() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let oldExchangeTime = shanghai(2026, 10, 20, 9, 0)
        let cached = [point(exchangeAt: oldExchangeTime, receivedAt: now, rate: 100),
                      point(exchangeAt: oldExchangeTime, receivedAt: now, rate: 100.3)]
        let context = NextFXContextEngine.context(market: .japan, series: cached, now: now)
        guard case .stale = context.state else {
            return XCTFail("刚读出来的旧值依然必须判过期：\(context.state)")
        }
        if case let .stale(age) = context.freshness {
            XCTAssertGreaterThan(age, 26, "新鲜度按交易所时间戳算，应为几十小时")
        } else {
            XCTFail("新鲜度必须是过期：\(context.freshness)")
        }
        XCTAssertFalse(context.isRealTime, "旧值不能伪装成实时")
        XCTAssertFalse(NextFXContextEngine.isRealTime(cached.last!, now: now))
    }

    func test_deviceCacheOldValueIsNotRealTime() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let cached = [point(exchangeAt: shanghai(2026, 10, 21, 9, 0), receivedAt: now,
                            rate: 100, source: .deviceCache)]
        let context = NextFXContextEngine.context(market: .japan, series: cached, now: now)
        XCTAssertFalse(context.isRealTime, "本机缓存里的旧值不是实时值")
        XCTAssertTrue(context.note.contains("来源"), context.note)
    }

    func test_freshAvailableValueStatesRealTime() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let fresh = [point(exchangeAt: shanghai(2026, 10, 23, 9, 0), rate: 100),
                     point(exchangeAt: shanghai(2026, 10, 23, 9, 45), rate: 100.4)]
        let context = NextFXContextEngine.context(market: .japan, series: fresh, now: now)
        XCTAssertTrue(context.isRealTime, "源时间戳很新且来源可追溯 → 才是实时")
        XCTAssertTrue(context.note.contains("实时"), context.note)
        XCTAssertTrue(context.note.contains("来源"), context.note)
    }

    func test_provenanceNoteStatesSourceStampAndFreshness() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let fresh = [point(exchangeAt: shanghai(2026, 10, 23, 9, 0), rate: 100),
                     point(exchangeAt: shanghai(2026, 10, 23, 9, 45), rate: 100.4)]
        let context = NextFXContextEngine.context(market: .japan, series: fresh, now: now)
        let note = context.provenanceNote
        XCTAssertTrue(note.contains("来源"), note)
        XCTAssertTrue(note.contains("交易所时间戳"), note)
        XCTAssertTrue(note.contains("新鲜度"), note)
    }

    // MARK: - 来源名称未验证 → 不得进入决策上下文（即使有数字）

    func test_unverifiedSourceNameBlocksDecisionContext() {
        let now = shanghai(2026, 10, 23, 10, 0)
        // 数字、时间戳、来源类型全都正常，唯独来源名称没登记过。
        let points = [point(exchangeAt: shanghai(2026, 10, 23, 9, 0), rate: 100,
                            sourceName: "Some Random Feed"),
                      point(exchangeAt: shanghai(2026, 10, 23, 9, 45), rate: 100.4,
                            sourceName: "Some Random Feed")]
        let context = NextFXContextEngine.context(market: .japan, series: points, now: now)
        XCTAssertFalse(context.isSourceVerified, "来源名称未验证")
        guard case let .suspicious(reason) = context.state else {
            return XCTFail("来源名称未验证必须判可疑，不能因为有数字就放行：\(context.state)")
        }
        XCTAssertTrue(reason.contains("来源名称未验证"), reason)
        XCTAssertFalse(context.entersDecisionContext, "有数字也不许进决策上下文")
        XCTAssertFalse(context.isUsable)
        XCTAssertNil(NextFXContextEngine.adjust(localPercent: 1.0, context: context))
        guard let note = context.decisionContextGateNote else {
            return XCTFail("被拦在外面时必须说明原因")
        }
        XCTAssertTrue(note.contains("来源名称未验证"), note)
        XCTAssertTrue(note.contains("即使有汇率数字"), note)
        XCTAssertFalse(NextFXContextEngine.entersDecisionContext(points.last!, now: now))
    }

    func test_missingSourceNameBlocksDecisionContext() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let noName = [point(exchangeAt: shanghai(2026, 10, 23, 9, 0), rate: 100, sourceName: ""),
                      point(exchangeAt: shanghai(2026, 10, 23, 9, 45), rate: 100.4, sourceName: "")]
        let context = NextFXContextEngine.context(market: .japan, series: noName, now: now)
        XCTAssertFalse(context.isSourceVerified, "没有来源名称 = 未验证")
        XCTAssertFalse(context.entersDecisionContext)
        XCTAssertTrue(context.decisionContextGateNote?.contains("无来源名称") == true,
                      context.decisionContextGateNote ?? "无")
    }

    func test_verifiedSourceNameAllowsDecisionContext() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let good = [point(exchangeAt: shanghai(2026, 10, 23, 9, 0), rate: 100),
                    point(exchangeAt: shanghai(2026, 10, 23, 9, 45), rate: 100.4)]
        let context = NextFXContextEngine.context(market: .japan, series: good, now: now)
        XCTAssertTrue(context.isSourceVerified)
        XCTAssertTrue(context.isUsable)
        // 三道门都过：来源名称已验证 + 数据可用 + 可作为实时值。
        XCTAssertTrue(context.entersDecisionContext, "来源已验证且新鲜时才进决策上下文")
        XCTAssertNil(context.decisionContextGateNote)
        XCTAssertTrue(NextFXContextEngine.entersDecisionContext(good.last!, now: now))
    }

    func test_verifiedNamesAreRegistered() {
        XCTAssertTrue(NextFXSourceName.isVerified("Sina fx"))
        XCTAssertFalse(NextFXSourceName.isVerified("Some Random Feed"))
        XCTAssertFalse(NextFXSourceName.isVerified(""))
        XCTAssertFalse(NextFXSourceName.isVerified(nil))
    }

    // MARK: - 汇率永远不能单独触发做T/网格

    func test_fxNeverAuthorizesDoTOrGrid() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let bigMove = [point(exchangeAt: shanghai(2026, 10, 23, 9, 0), rate: 100),
                       point(exchangeAt: shanghai(2026, 10, 23, 9, 45), rate: 101.2)]
        let context = NextFXContextEngine.context(market: .japan, series: bigMove, now: now)
        // 就算汇率动得再大，它的授权也只有一个取值：never。
        XCTAssertEqual(context.planEligibility, .never)
        XCTAssertTrue(context.planEligibility.note.contains("不能单独触发做T或网格"),
                      context.planEligibility.note)
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
        let old = [point(exchangeAt: now.addingTimeInterval(-30 * 3600), rate: 100),
                   point(exchangeAt: now.addingTimeInterval(-29 * 3600), rate: 100.2)]
        let context = NextFXContextEngine.context(market: .japan, series: old, now: now)
        guard case let .stale(reason) = context.state else {
            return XCTFail("超过 26 小时必须判过期：\(context.state)")
        }
        XCTAssertTrue(reason.contains("小时"), reason)
        XCTAssertFalse(context.isUsable)
        XCTAssertFalse(context.isRealTime)
        XCTAssertNil(NextFXContextEngine.adjust(localPercent: 1.0, context: context))
    }

    func test_futureTimestampIsSuspicious() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let future = [point(exchangeAt: now.addingTimeInterval(3600), rate: 100)]
        let context = NextFXContextEngine.context(market: .japan, series: future, now: now)
        guard case .suspicious = context.state else {
            return XCTFail("未来时间戳必须判可疑：\(context.state)")
        }
    }

    func test_abnormalJumpIsSuspiciousNotBelieved() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let jump = [point(exchangeAt: shanghai(2026, 10, 22, 9, 0), rate: 100),
                    point(exchangeAt: shanghai(2026, 10, 23, 9, 0), rate: 100),
                    point(exchangeAt: shanghai(2026, 10, 23, 9, 30), rate: 105)]
        let context = NextFXContextEngine.context(market: .japan, series: jump, now: now)
        guard case let .suspicious(reason) = context.state else {
            return XCTFail("单日 5% 跳变应先怀疑数据：\(context.state)")
        }
        XCTAssertTrue(reason.contains("怀疑数据"), reason)
    }

    func test_noIntradayChangeYetIsMissing() {
        let now = shanghai(2026, 10, 23, 9, 0)
        let morningOnly = [point(exchangeAt: now.addingTimeInterval(-60), rate: 100)]
        let context = NextFXContextEngine.context(market: .japan, series: morningOnly, now: now)
        guard case .missing = context.state else {
            return XCTFail("今天还没有两个点，算不出今日变动：\(context.state)")
        }
    }

    // MARK: - 样本门槛

    func test_availableButBelowSampleBarSaysSo() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let points = [point(exchangeAt: shanghai(2026, 10, 23, 9, 0), rate: 100),
                      point(exchangeAt: shanghai(2026, 10, 23, 9, 30), rate: 100.4),
                      point(exchangeAt: shanghai(2026, 10, 23, 9, 45), rate: 100.5)]
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
        points.append(point(exchangeAt: shanghai(2026, 10, 23, 9, 0), rate: 100.2))
        points.append(point(exchangeAt: shanghai(2026, 10, 23, 9, 45), rate: 100.4))
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
        let points = [point(exchangeAt: shanghai(2026, 10, 23, 9, 0), rate: 100),
                      point(exchangeAt: shanghai(2026, 10, 23, 9, 45), rate: 99.1)]
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
        let points = [point(exchangeAt: shanghai(2026, 10, 23, 9, 0), rate: 100),
                      point(exchangeAt: shanghai(2026, 10, 23, 9, 45), rate: 100.05)]
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
