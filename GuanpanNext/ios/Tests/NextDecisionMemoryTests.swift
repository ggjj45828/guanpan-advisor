import XCTest
@testable import GuanpanAdvisorCore

/// 决策记忆 / 新闻影响 / 画像硬约束 三条链路的回归测试。
/// 这些测试锁住的是「AI 有没有真的在读数据、有没有真的受约束」，
/// 而不是文案或页面是否存在。
final class NextDecisionMemoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1792375200)

    // MARK: - 夹具

    private func snapshot(price: String = "1.400", state: String = "窄幅震荡", strategy: String = "做T",
                          headline: String = "反T · 先卖后买", limitPrice: String? = "1.420",
                          limitUnits: Int? = 3000, vwapDeviation: Double = 0.4,
                          nasDays: Int = 20, nasStale: Bool = false,
                          validUntil: Date? = nil, risks: [String] = [],
                          news: [String] = [], confidence: String = "高") -> NextDecisionSnapshot {
        NextDecisionSnapshot(price: price, previousClose: "1.396", quoteSource: "test", quoteAt: now,
                             units: 10_000, averageCost: "1.38",
                             nasDays: nasDays, nasVwap20: "1.398", nasCloseVsVwap20: vwapDeviation,
                             nasAmplitude60: 1.6, nasRoundTrips60: 2.4, nasVolatility120: 1.1,
                             nasSupportP10: "1.360", nasResistanceP90: "1.440",
                             nasStale: nasStale, nasEnoughForLongTerm: nasDays >= 5,
                             newsTitles: news, profileTags: ["中期", "做T活跃"],
                             state: state, strategy: strategy, headline: headline,
                             evidence: ["VWAP 1.398"], risks: risks,
                             validUntil: validUntil ?? now.addingTimeInterval(3600 * 2),
                             invalidConditions: ["跌破 1.36"],
                             limitPrice: limitPrice, limitUnits: limitUnits,
                             expectedNetGain: "3.80", expectedCostReduction: "0.0004",
                             confidenceLevel: confidence)
    }

    private func record(_ snapshot: NextDecisionSnapshot) -> NextDecisionRecord {
        NextDecisionRecord(code: "159941", name: "纳指ETF", createdAt: now, snapshot: snapshot)
    }

    // MARK: - 变化解释

    func testDiffExplainsWhatChangedWithTraceableNumbers() {
        let old = snapshot()
        let new = snapshot(price: "1.430", state: "趋势上涨", strategy: "持有",
                           headline: "持有", limitPrice: nil, limitUnits: nil,
                           vwapDeviation: 1.9, nasStale: true, confidence: "中")
        let changes = NextDecisionDiff.compare(old: old, new: new)
        XCTAssertTrue(changes.contains { $0.contains("市场状态从「窄幅震荡」变为「趋势上涨」") })
        XCTAssertTrue(changes.contains { $0.contains("策略从「做T」变为「持有」") })
        XCTAssertTrue(changes.contains { $0.contains("+2.14%") }, "价格变化要带具体幅度：\(changes)")
        XCTAssertTrue(changes.contains { $0.contains("VWAP") })
        XCTAssertTrue(changes.contains { $0.contains("过期") })
        XCTAssertTrue(changes.contains { $0.contains("限价从 ¥1.420 变为 ¥无") })
        XCTAssertTrue(changes.contains { $0.contains("置信度从 高 变为 中") })
    }

    func testDiffIgnoresTinyPriceJitter() {
        // 0.1% 的抖动不值得改判：结论没变就不该冒出「变化说明」。
        let changes = NextDecisionDiff.compare(old: snapshot(price: "1.400"), new: snapshot(price: "1.4014"))
        XCTAssertTrue(changes.isEmpty, "微小价格抖动不应产生改判记录：\(changes)")
    }

    func testReviseOnlyAppendsWhenSomethingActuallyChanged() {
        var memory = record(snapshot())
        XCTAssertNil(memory.revise(with: snapshot(), at: now.addingTimeInterval(60)))
        XCTAssertTrue(memory.revisions.isEmpty)
        let revision = memory.revise(with: snapshot(price: "1.450", headline: "持有"), at: now.addingTimeInterval(120))
        XCTAssertNotNil(revision)
        XCTAssertEqual(memory.revisions.count, 1)
        XCTAssertEqual(memory.revisions[0].fromHeadline, "反T · 先卖后买")
        XCTAssertEqual(memory.revisions[0].toHeadline, "持有")
        XCTAssertFalse(memory.revisions[0].changes.isEmpty)
        // 快照本身不能被改写：记忆要保留「当时」。
        XCTAssertEqual(memory.snapshot.price, "1.400")
    }

    func testMergeKeepsOnePendingRecordPerDayAndRecordsRevision() {
        let first = record(snapshot())
        let second = record(snapshot(price: "1.450", headline: "持有"))
        let merged = NextDecisionMemory.merge(existing: [first], incoming: [second])
        XCTAssertEqual(merged.count, 1, "同一天同一只只保留一条待处理记录")
        XCTAssertEqual(merged[0].snapshot.price, "1.400", "保留的是当时那一份快照")
        XCTAssertEqual(merged[0].revisions.count, 1)
    }

    func testExpireMarksExpiredWithoutProducingAnyFill() {
        let expiredAt = now.addingTimeInterval(-60)
        let open = record(snapshot(validUntil: expiredAt))
        let result = NextDecisionMemory.expire([open], at: now, quoteFor: { _ in Decimal(string: "1.400") })
        XCTAssertEqual(result[0].outcome, .expired)
        XCTAssertFalse(result[0].outcome.isFilled)
        XCTAssertNil(result[0].review.filledPrice)
        XCTAssertTrue(result[0].review.note.contains("未记录到真实成交"))
    }

    func testExpireInvalidatesWhenPriceBreaksAwayFromPlan() {
        let open = record(snapshot(limitPrice: "1.420"))
        let result = NextDecisionMemory.expire([open], at: now, quoteFor: { _ in Decimal(string: "1.500") })
        XCTAssertEqual(result[0].outcome, .invalidated)
        XCTAssertTrue(result[0].review.note.contains("原计划失效"))
    }

    func testReviewUsesRealFillAndNeverClaimsProfit() {
        var record = self.record(snapshot())
        record.outcome = .filled
        record.review.filledPrice = "1.418"
        record.review.filledUnits = 3000
        let review = NextDecisionMemory.review(record, laterPrice: Decimal(string: "1.404")!, at: now)
        XCTAssertEqual(review.filledUnits, 3000)
        XCTAssertEqual(review.laterChangePercent ?? 0, -0.9887, accuracy: 0.01)
        XCTAssertTrue(review.note.contains("仅复盘记录"), "复盘不能变成收益账户：\(review.note)")
    }

    func testReviewWithoutFillDoesNotPretendToHaveTraded() {
        let record = self.record(snapshot())
        let review = NextDecisionMemory.review(record, laterPrice: Decimal(string: "1.430")!, at: now)
        XCTAssertNil(review.filledPrice)
        XCTAssertTrue(review.note.contains("未记录真实成交"))
    }

    // MARK: - 143 闭环记录并入决策记忆

    /// 一个拦截态的闭环产出：已验证领先关系 + 午休修复信号 + 已确认假设。
    private func interceptOutcome(code: String = "513520", at: Date? = nil) -> NextLoopOutcome {
        let stamp = at ?? now
        return NextLoopOutcome(
            code: code, at: stamp,
            gate: .intercept(reason: "跨市场信号（已验证领先关系）作为风险拦截器：暂停已有候选计划并要求重算"),
            signal: NextLoopSignal(kind: .lunchRepair, market: .japan,
                                   evidence: "日本午休期间修复 +1.20 个百分点", strength: 1.2),
            hypothesis: NextCrossHypothesis(code: code, createdAt: stamp.addingTimeInterval(-40 * 60),
                                            confirmDeadline: stamp.addingTimeInterval(30 * 60),
                                            statement: "午后修复", overseasEvidence: ["日本午休修复"]),
            chain: NextReasoningChain(code: code, steps: []),
            explanation: ["假设「午后修复」，证据：日本午休期间修复 +1.20 个百分点",
                          "「午休修复」来自已通过逐 ETF 长期验证 + 预注册前瞻复现的领先关系"])
    }

    /// 什么都没评估的一天：没有信号也没有假设。闭环的正式结论是「今天没有达到门槛的信号」。
    private func quietOutcome(code: String = "513520", at: Date? = nil) -> NextLoopOutcome {
        NextLoopOutcome(code: code, at: at ?? now,
                        gate: .clear(reason: "没有达到门槛的跨市场信号"),
                        signal: nil, hypothesis: nil,
                        chain: NextReasoningChain(code: code, steps: []),
                        explanation: ["跨市场今天没有达到门槛的信号：不参与计划决策，不生成任何计划"])
    }

    private func loopQuote() -> NextQuote {
        NextQuote(code: "513520", name: "日经ETF", price: Decimal(string: "1.400")!,
                  previousClose: Decimal(string: "1.396")!, time: now, source: "test")
    }

    /// 闭环「什么都没评估」的一天不落盘：记忆页不该被每天每只股票的「无信号」填满。
    func testLoopOutcomeWithoutSignalOrHypothesisIsNotRemembered() {
        let records = NextDecisionMemory.loopRecords(
            from: [quietOutcome()], names: ["513520": "日经ETF"], quotes: [:],
            unitsFor: { _ in 0 }, sessionEndFor: { NextMarketClock.sessionClose($0) })
        XCTAssertTrue(records.isEmpty, "没有信号也没有假设的一天不该占记忆")
    }

    /// 落盘的闭环记录必须搬「当时」的事实：闸门、假设标题、当时本地价、逐行解释；
    /// 并且必须没有限价与份额——跨市场不生成计划。
    func testLoopRecordCapturesGateStatementAndReferencePrice() {
        let outcome = interceptOutcome()
        let records = NextDecisionMemory.loopRecords(
            from: [outcome], names: ["513520": "日经ETF"], quotes: ["513520": loopQuote()],
            unitsFor: { _ in 10_000 }, sessionEndFor: { NextMarketClock.sessionClose($0) })
        guard let record = records.first else { return XCTFail("有信号又有假设时必须落盘") }
        XCTAssertEqual(record.origin, .crossLoop)
        XCTAssertEqual(record.code, "513520")
        XCTAssertEqual(record.snapshot.state, "风险拦截 · 暂停并需重算")
        XCTAssertEqual(record.snapshot.headline, outcome.headline)
        XCTAssertEqual(record.snapshot.price, "1.4",
                       "当时本地价必须原样留下，供事后核对。注意 Decimal 插值会去掉尾零（1.400 → 1.4）：指导路径与闭环路径共用同一格式 \"\\(quote.price)\"，两边必须一致")
        XCTAssertEqual(record.snapshot.quoteSource, "test")
        XCTAssertEqual(record.snapshot.units, 10_000)
        XCTAssertEqual(record.snapshot.evidence, outcome.explanation, "逐行解释必须全文保留")
        XCTAssertEqual(record.snapshot.risks, [outcome.gate.reason])
        XCTAssertNil(record.snapshot.limitPrice, "跨市场不生成计划，闭环记录没有限价")
        XCTAssertNil(record.snapshot.limitUnits, "闭环记录没有份额")
        XCTAssertEqual(record.snapshot.confidenceLevel, "低", "闭环结论只作风险上下文，置信度照实写低")
        XCTAssertEqual(record.snapshot.validUntil, NextMarketClock.sessionClose(now),
                       "闭环记录的自然终点是当日收盘")
        XCTAssertEqual(record.outcome, .pending)
        XCTAssertNil(record.review.filledPrice, "没有任何自动成交路径")
    }

    /// 没有报价时不编数字：price 留空，由界面说「无报价」。
    func testLoopSnapshotWithoutQuoteLeavesPriceEmpty() {
        let outcome = interceptOutcome()
        let snapshot = NextDecisionMemory.loopSnapshot(outcome: outcome, quote: nil, units: 0,
                                                       validUntil: NextMarketClock.sessionClose(now))
        XCTAssertNil(snapshot.price)
        XCTAssertNil(snapshot.quoteSource)
        XCTAssertEqual(snapshot.headline, outcome.headline, "没有报价不影响结论与解释落盘")
    }

    /// 同一天同一只证券：指导记录与闭环记录是两件不同的事实，都必须留着。
    func testLoopRecordAndGuidanceRecordCoexistSameDaySameCode() {
        let guidance = record(snapshot())
        let loop = NextDecisionMemory.loopRecords(
            from: [interceptOutcome(code: "159941")], names: ["159941": "纳指ETF"],
            quotes: [:], unitsFor: { _ in 0 }, sessionEndFor: { NextMarketClock.sessionClose($0) })[0]
        let merged = NextDecisionMemory.merge(existing: [], incoming: [guidance, loop])
        XCTAssertEqual(merged.count, 2, "计划建议与跨市场风险姿态是同一天的两件事，不能互相吞掉")
        XCTAssertTrue(merged.contains { $0.origin == .guidance })
        XCTAssertTrue(merged.contains { $0.origin == .crossLoop })
    }

    /// 同一天同一来源的闭环记录只留一条：闸门或标题变了写改判轨迹，「当时」的快照不改。
    func testLoopRecordsDedupPerDayAndRecordRevision() {
        let first = NextDecisionMemory.loopRecords(
            from: [interceptOutcome()], names: ["513520": "日经ETF"], quotes: [:],
            unitsFor: { _ in 0 }, sessionEndFor: { NextMarketClock.sessionClose($0) })[0]
        let changedGate = NextLoopOutcome(
            code: "513520", at: now.addingTimeInterval(600),
            gate: .clear(reason: "拦截已解除"),
            signal: NextLoopSignal(kind: .lunchRepair, market: .japan, evidence: "e", strength: 1.2),
            hypothesis: nil,
            chain: NextReasoningChain(code: "513520", steps: []),
            explanation: ["拦截解除"])
        let second = NextDecisionMemory.loopRecords(
            from: [changedGate], names: ["513520": "日经ETF"], quotes: [:],
            unitsFor: { _ in 0 }, sessionEndFor: { NextMarketClock.sessionClose($0) })[0]
        let merged = NextDecisionMemory.merge(existing: [first], incoming: [second])
        XCTAssertEqual(merged.count, 1, "同一天同一只同一来源只保留一条")
        XCTAssertEqual(merged[0].snapshot.state, "风险拦截 · 暂停并需重算", "保留的是当时那一份")
        XCTAssertEqual(merged[0].revisions.count, 1, "闸门变化必须写进改判轨迹")
    }

    /// 闭环记录过期时的措辞必须说清「不涉及成交」——不能套用计划那条「未记录到真实成交」。
    func testLoopRecordExpiresAtSessionEndWithoutImplyingTrade() {
        let loop = NextDecisionMemory.loopRecords(
            from: [interceptOutcome()], names: ["513520": "日经ETF"], quotes: [:],
            unitsFor: { _ in 0 }, sessionEndFor: { NextMarketClock.sessionClose($0) })[0]
        let result = NextDecisionMemory.expire([loop], at: now.addingTimeInterval(86_400),
                                               quoteFor: { _ in Decimal(string: "1.400") })
        XCTAssertEqual(result[0].outcome, .expired)
        XCTAssertFalse(result[0].outcome.isFilled)
        XCTAssertTrue(result[0].review.note.contains("不涉及成交"), "闭环记录不是计划：\(result[0].review.note)")
        XCTAssertFalse(result[0].review.note.contains("未记录到真实成交"))
    }

    /// 旧备份没有 origin 键：解码时按「今日指导」处理，老用户升级不丢记忆。
    func testOldBackupWithoutOriginKeyDecodesAsGuidance() {
        let original = record(snapshot())
        let data = try! JSONEncoder().encode(original)
        var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "origin")
        let stripped = try! JSONSerialization.data(withJSONObject: json)
        let decoded = try! JSONDecoder().decode(NextDecisionRecord.self, from: stripped)
        XCTAssertEqual(decoded.origin, .guidance)
        XCTAssertEqual(decoded.code, original.code)
        XCTAssertEqual(decoded.snapshot.headline, original.snapshot.headline)
    }

    // MARK: - 新闻 → 持仓 → 计划

    func testMajorHeadlineInvalidatesReadyTPlan() {
        let impact = NextNewsImpactEngine.evaluate(
            code: "159941", name: "纳指ETF",
            titles: [NextNewsInput(title: "纳指ETF 159941 公告：基金份额持有人大会决议停牌", source: "测试源")],
            hasTPlan: true, hasGridPlan: false, now: now)
        XCTAssertEqual(impact.severity, .major)
        XCTAssertEqual(impact.action, .pauseGrid, "停牌意味着无法成交，网格必须暂停")
        let item = guidanceItem(tPlan: .ready(tPlan()), gridPlan: nil)
        let applied = NextNewsImpactEngine.apply(impact, to: item)
        XCTAssertFalse(applied.isActionable)
        XCTAssertNotNil(applied.newsImpact)
        XCTAssertTrue(applied.riskNotes.contains { $0.contains("停牌") })
    }

    func testDelistingHeadlineInvalidatesTPlan() {
        let impact = NextNewsImpactEngine.evaluate(
            code: "159941", name: "纳指ETF",
            titles: [NextNewsInput(title: "某基金发布退市风险提示")],
            hasTPlan: true, hasGridPlan: true, now: now)
        XCTAssertEqual(impact.action, .invalidateT)
        let applied = NextNewsImpactEngine.apply(impact, to: guidanceItem(tPlan: .ready(tPlan()), gridPlan: nil))
        XCTAssertFalse(applied.tPlan?.isReady == true)
        XCTAssertFalse(applied.isActionable)
    }

    func testUnrelatedOrNeutralHeadlinesChangeNothing() {
        let impact = NextNewsImpactEngine.evaluate(
            code: "159941", name: "纳指ETF",
            titles: [NextNewsInput(title: "今天天气不错")],
            hasTPlan: true, hasGridPlan: true, now: now)
        XCTAssertTrue(impact.isEmpty)
        XCTAssertEqual(impact.action, .none)
        let item = guidanceItem(tPlan: .ready(tPlan()), gridPlan: nil)
        let applied = NextNewsImpactEngine.apply(impact, to: item)
        XCTAssertTrue(applied.isActionable)
        XCTAssertTrue(applied.riskNotes.isEmpty)
    }

    func testWatchLevelHeadlineOnlyAddsNote() {
        let impact = NextNewsImpactEngine.evaluate(
            code: "159941", name: "纳指ETF",
            titles: [NextNewsInput(title: "纳指ETF 管理费费率下调 0.05%")],
            hasTPlan: true, hasGridPlan: false, now: now)
        XCTAssertEqual(impact.severity, .watch)
        XCTAssertEqual(impact.action, .watch)
        let applied = NextNewsImpactEngine.apply(impact, to: guidanceItem(tPlan: .ready(tPlan()), gridPlan: nil))
        XCTAssertTrue(applied.isActionable, "关注级新闻不能直接否掉计划")
        XCTAssertFalse(applied.riskNotes.isEmpty)
    }

    func testHeadlineMustBelongToTheHolding() {
        XCTAssertTrue(NextNewsImpactEngine.belongs("159941 今日放量", code: "159941", name: "纳指ETF"))
        XCTAssertTrue(NextNewsImpactEngine.belongs("纳指ETF 盘中溢价", code: "159941", name: "纳指ETF"))
        XCTAssertTrue(NextNewsImpactEngine.belongs("半导体板块走强", code: "512480", name: "半导体ETF",
                                                   industryWords: ["半导体"]))
        XCTAssertFalse(NextNewsImpactEngine.belongs("白酒板块走强", code: "512480", name: "半导体ETF",
                                                    industryWords: ["半导体"]))
    }

    // MARK: - 画像硬约束

    func testPlanCapsTranslateProfileIntoHardLimits() {
        var profile = NextInvestorProfile()
        profile.thresholds.maxTUnitsRatio = 0.25
        profile.thresholds.gridMaxTiers = 3
        profile.thresholds.gridMaxCashRatio = 0.4
        let book = NextBook(cash: 100_000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 10_000, bookCost: Decimal(string: "13800")!)
        ])
        let caps = NextPlanCaps.make(profile: profile, nasStats: nil, book: book, code: "159941",
                                     lotSize: 100, now: now)
        XCTAssertEqual(caps.maxTUnits, 2500)
        XCTAssertEqual(caps.maxGridTiers, 3)
        XCTAssertEqual(caps.maxGridCash, Decimal(string: "40000"))
        XCTAssertTrue(caps.gridNotes.first?.contains("40%") == true)
    }

    func testTPlannerCapsUnitsByProfileRatio() {
        let book = NextBook(cash: 50_000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 10_000, bookCost: Decimal(string: "13800")!)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: Decimal(string: "1.400")!,
                              previousClose: Decimal(string: "1.396")!, time: now, source: "test")
        let result = NextTradeTPlanner.plan(kind: .reverse, book: book, quote: quote, daily: dailyBars(),
                                            intraday: oscillatingMinutes(), rules: rules(),
                                            orderBook: orderBook(),
                                            caps: NextPlanCaps(maxTUnits: 2000, tUnitsNote: "测试上限",
                                                               nasRoundTrips60: 2.4, nasDays: 60,
                                                               nasVolumeCoverage60: 0.92,
                                                               nasVwapHighDeviation60: 0.008,
                                                               nasVwapLowDeviation60: -0.007),
                                            now: now)
        guard case let .ready(plan) = result else {
            return XCTFail("反T 应能出价：\(result)")
        }
        XCTAssertEqual(plan.units, 2000, "份额必须被画像上限压住，而不是只在界面上提示")
        XCTAssertTrue(plan.evidence.contains { $0.contains("测试上限") })
        XCTAssertTrue(plan.evidence.contains { $0.contains("压到 2000 份") })
    }

    func testGridPlannerHonoursTierAndCashCaps() {
        let book = NextBook(cash: 100_000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 10_000, bookCost: Decimal(string: "13800")!)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: Decimal(string: "1.400")!,
                              previousClose: Decimal(string: "1.396")!, time: now, source: "test")
        let check = NextGridCheck(code: "159941", name: "纳指ETF", barCount: 120, score: 80, grade: .suitable,
                                  annualVolatilityPercent: 20, avgAmplitudePercent: 1.6, avgTurnoverYi: 2.0,
                                  rangeBoundRatio: 0.6, atExtreme: false, isOnExchange: true, isETF: true,
                                  reasons: ["区间震荡"], warnings: [])
        let result = NextGridPlanner.plan(book: book, quote: quote, daily: dailyBars(), gridCheck: check,
                                          rules: rules(),
                                          nasRange: NextNasRange(low: Decimal(string: "1.3600")!,
                                                                 high: Decimal(string: "1.4400")!,
                                                                 days: 60, source: "fixture"),
                                          orderBook: orderBook(),
                                          caps: NextPlanCaps(maxGridTiers: 2, maxGridCash: Decimal(string: "15000"),
                                                             gridNotes: ["资金封顶 15%"]),
                                          now: now)
        guard case let .ready(plan) = result else {
            return XCTFail("网格应能出价：\(result)")
        }
        XCTAssertLessThanOrEqual(plan.maxCashUsage, Decimal(string: "15000")!, "买入档资金占用不得超过画像上限")
        XCTAssertTrue(plan.reasons.contains { $0.contains("档数从") })
        XCTAssertTrue(plan.reasons.contains { $0.contains("资金封顶 15%") })
    }

    // MARK: - 夹具构造

    /// 五档盘口夹具：围绕 1.400 现价，价差约 0.14%，买卖合计深度过百手。
    private func orderBook() -> NextOrderBookSnapshot {
        let bids: [(Double, Int)] = [(1.399, 1500), (1.398, 1800), (1.397, 2000), (1.396, 2200), (1.395, 2500)]
        let asks: [(Double, Int)] = [(1.401, 1500), (1.402, 1800), (1.403, 2000), (1.404, 2200), (1.405, 2500)]
        return NextOrderBookSnapshot(code: "159941", observedAt: now.addingTimeInterval(-5), source: "fixture",
                                     bids: bids.map { NextBookLevel(price: Decimal(string: String(format: "%.3f", $0.0))!, units: $0.1) },
                                     asks: asks.map { NextBookLevel(price: Decimal(string: String(format: "%.3f", $0.0))!, units: $0.1) })
    }

    private func rules() -> NextInstrumentRules {
        NextInstrumentRules(code: "159941", market: "SZ", assetClass: .etf, settlement: .t0, lotSize: 100,
                            feePerTrade: Decimal(string: "0.10"), source: "fixture", verifiedAt: now)
    }

    private func tPlan() -> NextTPlan {
        NextTPlan(kind: .reverse, code: "159941", name: "纳指ETF", sellPrice: Decimal(string: "1.42")!,
                  buyPrice: Decimal(string: "1.38")!, units: 3000, grossSpread: Decimal(string: "0.04")!,
                  feeTotal: Decimal(string: "0.20")!, netGain: Decimal(string: "119.80")!,
                  costReductionPerUnit: Decimal(string: "0.012")!, trampleRisk: "踏空风险", downsideRisk: "",
                  volumeSupport: "成交充足", validUntil: now.addingTimeInterval(3600),
                  cancelConditions: ["跌破 VWAP"], evidence: ["VWAP 1.398"],
                  confidence: NextDataConfidence.assess(quote: nil, now: now, dailyBarCount: 120,
                                                        minuteSampleCount: 200),
                  historyMissRate: nil)
    }

    private func guidanceItem(tPlan: NextTPlannerResult?, gridPlan: NextGridPlannerResult?) -> NextGuidanceItem {
        NextGuidanceItem(code: "159941", name: "纳指ETF", state: .narrowRange, strategy: .tTrade,
                         headline: "反T · 先卖后买", whyToday: ["振幅 2.9%"],
                         tPlan: tPlan, gridPlan: gridPlan, recovery: nil,
                         confidence: NextDataConfidence.assess(quote: nil, now: now, dailyBarCount: 120,
                                                               minuteSampleCount: 200),
                         portfolioNote: nil, riskNotes: [], score: 5, rank: 1, isActionable: true)
    }

    private func dailyBars() -> [NextChartSample] {
        // 120 根：1.38–1.42 区间反复，振幅约 1.4%，不创 60 日极端。
        (0..<120).map { index in
            let center = index % 2 == 0 ? 1.386 : 1.414
            let price = Decimal(string: String(format: "%.3f", center))!
            return NextChartSample(timestamp: now.addingTimeInterval(Double(index - 120) * 86_400),
                                   open: price,
                                   high: price * Decimal(string: "1.007")!,
                                   low: price * Decimal(string: "0.993")!,
                                   close: price, iopv: nil, volume: 3_000_000)
        }
    }

    private func oscillatingMinutes() -> [NextChartSample] {
        let count = 60
        return (0..<count).map { index in
            // 09:30 起每分钟一条，价格在 1.38–1.42 之间来回，保证 VWAP 与高低点都成立。
            // **时间戳截至当前时点**：以前整段被放在 now 之后，生产代码按
            // 「不读未来行情」正确过滤完只剩开头一个点，分时统计因此为空。
            let price = Decimal(string: String(format: "%.3f", index % 2 == 0 ? 1.386 : 1.414))!
            return NextChartSample(timestamp: now.addingTimeInterval(Double(index - (count - 1)) * 60),
                                   open: price,
                                   high: price * Decimal(string: "1.002")!,
                                   low: price * Decimal(string: "0.998")!,
                                   close: price, iopv: nil, volume: 10_000)
        }
    }
}
