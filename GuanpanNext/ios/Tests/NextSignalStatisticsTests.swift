import XCTest
@testable import GuanpanAdvisorCore

/// 134 防伪相关与多重检验 + 148 预注册前瞻复现。
///
/// 这组用例守的是同一条底线：**好看的相关系数不等于可用的信号**。
/// 旧口径把同一天里的分钟配对当独立样本，单日 80 根 K 线就能凑出「显著」，
/// 再乘上 8 个窗口随便挑一个，几乎必然能挑出一个假关系。
/// 这里逐条把那些漏洞钉死。
final class NextSignalStatisticsTests: XCTestCase {

    // MARK: - 基本工具

    private func shanghai(_ y: Int, _ m: Int, _ d: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    private func window(minutes: Int = 15,
                        independentDays: Int = 40, sampleCount: Int = 120,
                        correlation: Double = 0.42, wilson: Double = 0.68,
                        bonferroniP: Double = 0.004, holdoutDays: Int = 12,
                        stability: Double = 0.8) -> NextLeadLagWindow {
        NextLeadLagWindow(minutes: minutes, sampleCount: sampleCount,
                          independentDays: independentDays, correlation: correlation,
                          sameDirectionRate: 0.62, wilsonLowerBound: wilson,
                          bonferroniP: bonferroniP, holdoutDays: holdoutDays,
                          meanFollowReturn: 0.1, medianFollowReturn: 0.08,
                          positiveRatio: 0.56, maxAdverseReturn: -0.3, stability: stability)
    }

    private func replication(code: String = "513520",
                             registered: [String] = [],
                             confirmed: [String] = [],
                             refuted: [String] = []) -> NextSignalReplication {
        NextSignalReplication(lead: NextCrossMarket.japan.rawValue, followCode: code,
                              minutes: 15, windowDays: nil,
                              registeredDays: registered, confirmedDays: confirmed, refutedDays: refuted)
    }

    // MARK: - 统计工具

    func testWilsonLowerBoundSitsBelowPointEstimate() {
        let lower = NextLeadLagEngine.wilsonLowerBound(successes: 12, trials: 20)
        XCTAssertLessThan(lower, 0.6, "点估计 60% 时，下界必须明显更低")
        XCTAssertGreaterThan(lower, 0.3, "但也不能低到毫无信息")
        XCTAssertEqual(NextLeadLagEngine.wilsonLowerBound(successes: 0, trials: 0), 0,
                       "没有样本时下界是 0，不是 NaN")
    }

    func testWilsonLowerBoundShrinksWithFewerSamples() {
        let many = NextLeadLagEngine.wilsonLowerBound(successes: 18, trials: 30)
        let few = NextLeadLagEngine.wilsonLowerBound(successes: 6, trials: 10)
        XCTAssertGreaterThan(many, few, "同样 60% 的胜率，样本越少越不可信")
    }

    func testFisherPIsSmallForStrongRelationAndLargeForNoise() {
        let strong = NextLeadLagEngine.fisherTwoSidedP(r: 0.55, n: 40)
        let noise = NextLeadLagEngine.fisherTwoSidedP(r: 0.05, n: 40)
        XCTAssertLessThan(strong, 0.01, "强相关在 40 个独立交易日下应当显著")
        XCTAssertGreaterThan(noise, 0.5, "0.05 的相关性在 40 天里就是噪声")
        XCTAssertEqual(NextLeadLagEngine.fisherTwoSidedP(r: 0.9, n: 3), 1,
                       "样本不足 4 个直接返回 1，不做假显著")
    }

    func testBonferroniGrowsWithWindowCount() {
        let single = NextLeadLagEngine.fisherTwoSidedP(r: 0.35, n: 40)
        let adjusted = min(1, single * 8)
        XCTAssertGreaterThan(adjusted, single, "比较 8 个窗口必须付多重比较的代价")
    }

    // MARK: - 统计门槛

    func test_perfectWindowPassesEveryBar() {
        XCTAssertTrue(window().passesStatisticalBar)
    }

    func test_sampleCountAloneIsNotEvidence() {
        // 分钟配对 500 个、独立交易日只有 3 天：这是最典型的假显著。
        let fake = window(independentDays: 3, sampleCount: 500)
        XCTAssertFalse(fake.passesStatisticalBar, "分钟配对再多也不能顶替独立交易日")
    }

    func test_holdoutDaysMustBePresent() {
        XCTAssertFalse(window(holdoutDays: 2).passesStatisticalBar,
                       "留出段没有样本，就无法验证后段是否仍成立")
    }

    func test_weakCorrelationFailsEvenWithPlentyOfDays() {
        XCTAssertFalse(window(correlation: 0.12).passesStatisticalBar)
    }

    func test_unstableRelationFails() {
        XCTAssertFalse(window(stability: 0.2).passesStatisticalBar)
    }

    func test_lowWilsonLowerBoundFails() {
        // 点估计可能好看，但置信下界贴近掷硬币 —— 不能当信号。
        XCTAssertFalse(window(wilson: 0.48).passesStatisticalBar)
    }

    func test_bonferroniInsignificantFails() {
        XCTAssertFalse(window(bonferroniP: 0.21).passesStatisticalBar)
    }

    // MARK: - 148 预注册

    func test_statisticsAloneNeverAuthorizesTrading() {
        let study = NextLeadLagStudy(lead: .japan, followCode: "513520",
                                     verdict: .usable(best: window(), windows: [window()],
                                                      periodDays: 60, lastValidated: Date()))
        XCTAssertTrue(study.passesStatisticalBar, "统计层面是通过的")
        XCTAssertFalse(study.eligibleForTradingSignal, "但没有预注册，默认就是不许交易")
        XCTAssertTrue(study.signalEligibilityNote.contains("预注册"), study.signalEligibilityNote)
    }

    func test_threeForwardConfirmationsAuthorizeTrading() {
        let days = ["2026-10-20", "2026-10-21", "2026-10-22"]
        let record = replication(registered: days, confirmed: days)
        let study = NextLeadLagStudy(lead: .japan, followCode: "513520",
                                     verdict: .usable(best: window(), windows: [window()],
                                                      periodDays: 60, lastValidated: Date()),
                                     replication: record)
        XCTAssertTrue(study.eligibleForTradingSignal, "3 次前瞻兑现后才可以当信号")
        XCTAssertEqual(record.confirmedCount, 3)
    }

    func test_twoConfirmationsAreNotEnough() {
        let days = ["2026-10-20", "2026-10-21"]
        let record = replication(registered: days, confirmed: days)
        XCTAssertFalse(NextSignalReplicationEngine.allowsTradingSignal(record),
                       "差一次就是不达标，不能四舍五入")
    }

    func test_suspendedReplicationBlocksEvenWithManyConfirmations() {
        let confirmed = ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"]
        let refuted = ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11"]
        let record = replication(registered: confirmed + refuted,
                                 confirmed: confirmed, refuted: refuted)
        XCTAssertTrue(record.isSuspended)
        XCTAssertEqual(record.confirmedCount, 4, "兑现次数本身够")
        XCTAssertFalse(NextSignalReplicationEngine.allowsTradingSignal(record),
                       "但未兑现更多，这条关系必须停用")
    }

    func test_registrationHappensOnlyOncePerDay() {
        let day = shanghai(2026, 10, 23, 10, 0)
        var list = NextSignalReplicationEngine.register([], lead: .japan, followCode: "513520",
                                                        minutes: 15, windowDays: nil, at: day)
        list = NextSignalReplicationEngine.register(list, lead: .japan, followCode: "513520",
                                                    minutes: 15, windowDays: nil,
                                                    at: day.addingTimeInterval(3600))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].registeredCount, 1, "一天反复刷新不能刷出多次登记")
    }

    func test_registrationDoesNotResetPastConfirmations() {
        let day = shanghai(2026, 10, 23, 10, 0)
        let existing = replication(registered: ["2026-10-22"], confirmed: ["2026-10-22"])
        let list = NextSignalReplicationEngine.register([existing], lead: .japan, followCode: "513520",
                                                        minutes: 15, windowDays: nil, at: day)
        XCTAssertEqual(list[0].confirmedCount, 1, "新登记不能把过去的兑现清零")
        XCTAssertEqual(list[0].registeredCount, 2)
    }

    // MARK: - 结算

    func test_settleJudgesOnlyRegisteredPastDays() {
        let day1 = shanghai(2026, 10, 21, 9, 30)
        let day2 = shanghai(2026, 10, 22, 9, 30)
        let today = shanghai(2026, 10, 23, 9, 30)
        // 两天都上涨，方向一致 → 两天都应判兑现
        let lead = [NextMarketPoint(timestamp: day1, value: 100),
                    NextMarketPoint(timestamp: day1.addingTimeInterval(5 * 3600), value: 101),
                    NextMarketPoint(timestamp: day2, value: 101),
                    NextMarketPoint(timestamp: day2.addingTimeInterval(5 * 3600), value: 102)]
        let follow = [NextMarketPoint(timestamp: day1, value: 2.0),
                      NextMarketPoint(timestamp: day1.addingTimeInterval(5 * 3600), value: 2.02),
                      NextMarketPoint(timestamp: day2, value: 2.02),
                      NextMarketPoint(timestamp: day2.addingTimeInterval(5 * 3600), value: 2.05)]
        let record = replication(registered: ["2026-10-21", "2026-10-22"])
        let settled = NextSignalReplicationEngine.settle([record], market: .japan,
                                                         leadSeries: lead, followSeries: follow, at: today)
        XCTAssertEqual(settled[0].confirmedCount, 2)
        XCTAssertEqual(settled[0].refutedCount, 0)
    }

    func test_settleCountsDisagreementAsRefuted() {
        let day1 = shanghai(2026, 10, 21, 9, 30)
        let today = shanghai(2026, 10, 23, 9, 30)
        let lead = [NextMarketPoint(timestamp: day1, value: 100),
                    NextMarketPoint(timestamp: day1.addingTimeInterval(5 * 3600), value: 102)]
        let follow = [NextMarketPoint(timestamp: day1, value: 2.0),
                      NextMarketPoint(timestamp: day1.addingTimeInterval(5 * 3600), value: 1.98)]
        let record = replication(registered: ["2026-10-21"])
        let settled = NextSignalReplicationEngine.settle([record], market: .japan,
                                                         leadSeries: lead, followSeries: follow, at: today)
        XCTAssertEqual(settled[0].confirmedCount, 0)
        XCTAssertEqual(settled[0].refutedCount, 1, "海外涨、本地跌，关系没兑现")
    }

    func test_settleIgnoresTodayAndIsIdempotent() {
        let today = shanghai(2026, 10, 23, 9, 30)
        let lead = [NextMarketPoint(timestamp: today, value: 100),
                    NextMarketPoint(timestamp: today.addingTimeInterval(3600), value: 103)]
        let follow = [NextMarketPoint(timestamp: today, value: 2.0),
                      NextMarketPoint(timestamp: today.addingTimeInterval(3600), value: 2.05)]
        let record = replication(registered: ["2026-10-23"])
        let first = NextSignalReplicationEngine.settle([record], market: .japan,
                                                       leadSeries: lead, followSeries: follow, at: today)
        XCTAssertEqual(first[0].decidedCount, 0, "当天还没收盘，不能自己给自己判定")
        // 反复结算不应该重复计数
        let again = NextSignalReplicationEngine.settle(first, market: .japan,
                                                       leadSeries: lead, followSeries: follow, at: today)
        XCTAssertEqual(again[0].decidedCount, 0)
    }

    func test_settleDoesNotTouchOtherMarkets() {
        let day1 = shanghai(2026, 10, 21, 9, 30)
        let today = shanghai(2026, 10, 23, 9, 30)
        let lead = [NextMarketPoint(timestamp: day1, value: 100),
                    NextMarketPoint(timestamp: day1.addingTimeInterval(5 * 3600), value: 102)]
        let follow = [NextMarketPoint(timestamp: day1, value: 2.0),
                      NextMarketPoint(timestamp: day1.addingTimeInterval(5 * 3600), value: 2.04)]
        let korea = NextSignalReplication(lead: NextCrossMarket.korea.rawValue, followCode: "513520",
                                          minutes: 15, windowDays: nil,
                                          registeredDays: ["2026-10-21"])
        let settled = NextSignalReplicationEngine.settle([korea], market: .japan,
                                                         leadSeries: lead, followSeries: follow, at: today)
        XCTAssertEqual(settled[0].decidedCount, 0, "拿日本的序列去判韩国的关系是错配")
    }

    // MARK: - 复盘映射

    func test_predictionCreditIsSeparateFromProfit() {
        // 做了但亏了：预测兑现了，只是策略结果不好。
        XCTAssertEqual(NextSignalReplicationEngine.predictsFollowThrough(.failedFollowThrough), true)
        // 取消后躲过下跌：这次决定对，但预测没兑现。
        XCTAssertEqual(NextSignalReplicationEngine.predictsFollowThrough(.avoidedLoss), false)
        XCTAssertNil(NextSignalReplicationEngine.predictsFollowThrough(.noSignal),
                     "没有信号时不计数，不能算兑现也不能算否认")
    }
}
