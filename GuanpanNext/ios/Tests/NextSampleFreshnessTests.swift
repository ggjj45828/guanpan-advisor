import XCTest
@testable import GuanpanAdvisorCore

/// 149 分时样本时效与「不倒退」。
///
/// 要堵的洞很具体：上游可以返回「接收时间很新、样本却是上一个交易日」的分时。
/// 旧逻辑只看接收时间，于是界面显示「刚刚更新」，图表和下游分析读到的却是昨天的价格；
/// 刷新流程还会直接用这份数据覆盖当天缓存，覆盖完就再也看不出异常。
final class NextSampleFreshnessTests: XCTestCase {

    private func shanghai(_ y: Int, _ m: Int, _ d: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    private func sample(_ date: Date, _ price: Decimal = 2.0) -> NextChartSample {
        NextChartSample(timestamp: date, open: price, high: price, low: price,
                        close: price, iopv: nil, volume: 100)
    }

    private func dataset(code: String = "513520", samples: [NextChartSample],
                         receivedAt: Date) -> NextChartDataset {
        NextChartDataset(code: code, interval: .intraday, samples: samples,
                         costPerUnit: nil, costObservedAt: nil,
                         priceSource: "测试", iopvSource: nil, observedAt: receivedAt)
    }

    // MARK: - 样本时效

    func test_newlyReceivedButYesterdaySamplesIsRejected() {
        // 这正是要修的场景：接收时间是今天 09:20，样本全是昨天的。
        let now = shanghai(2026, 10, 23, 9, 20)
        let samples = [sample(shanghai(2026, 10, 22, 9, 35)),
                       sample(shanghai(2026, 10, 22, 14, 55))]
        let verdict = NextSampleAudit.freshness(samples: samples, now: now, marketOpen: false)
        guard case let .previousSession(days) = verdict else {
            return XCTFail("接收时间新不代表样本新，应判为上一交易日：\(verdict)")
        }
        XCTAssertEqual(days, 1)
        XCTAssertFalse(verdict.usableForIntraday, "昨天的样本不能当今天用")
        XCTAssertTrue(verdict.note.contains("不能当作今天"), verdict.note)
        XCTAssertTrue(verdict.note.contains("接收时间很新"), "必须点出这个矛盾，否则用户会以为数据没问题")
    }

    func test_todaySamplesDuringSessionAreLive() {
        let now = shanghai(2026, 10, 23, 10, 30)
        let samples = [sample(shanghai(2026, 10, 23, 9, 35)),
                       sample(shanghai(2026, 10, 23, 10, 25))]
        let verdict = NextSampleAudit.freshness(samples: samples, now: now, marketOpen: true)
        XCTAssertEqual(verdict, .live(ageMinutes: 5))
        XCTAssertTrue(verdict.usableForIntraday)
        XCTAssertEqual(verdict.label, "实时")
    }

    func test_todaySamplesAfterCloseAreUsableForReview() {
        let now = shanghai(2026, 10, 23, 16, 0)
        let samples = [sample(shanghai(2026, 10, 23, 9, 35)),
                       sample(shanghai(2026, 10, 23, 15, 0))]
        let verdict = NextSampleAudit.freshness(samples: samples, now: now, marketOpen: false)
        XCTAssertEqual(verdict, .closedToday)
        XCTAssertTrue(verdict.usableForIntraday, "收盘序列可以用来看今天的复盘")
    }

    func test_futureSamplesAreRefused() {
        let now = shanghai(2026, 10, 23, 10, 0)
        let samples = [sample(shanghai(2026, 10, 23, 10, 30))]
        XCTAssertEqual(NextSampleAudit.freshness(samples: samples, now: now, marketOpen: true), .future)
        XCTAssertFalse(NextSampleFreshness.future.usableForIntraday)
    }

    func test_emptySamplesAreNotEmptySuccess() {
        XCTAssertEqual(NextSampleAudit.freshness(samples: [], now: Date(), marketOpen: true), .empty)
        XCTAssertFalse(NextSampleFreshness.empty.usableForIntraday)
    }

    func test_sampleDayComesFromLastSampleNotFirst() {
        // 跨日残段：第一根还是昨天的，最后一根是今天的 → 样本日必须按今天算。
        let samples = [sample(shanghai(2026, 10, 22, 14, 55)),
                       sample(shanghai(2026, 10, 23, 9, 35))]
        let day = NextSampleAudit.sampleDay(of: samples)
        XCTAssertEqual(day, shanghai(2026, 10, 23, 0, 0))
    }

    // MARK: - 覆盖必须单调前进

    func test_olderSamplesNeverOverwriteNewerCache() {
        let cached = dataset(samples: [sample(shanghai(2026, 10, 23, 9, 35)),
                                       sample(shanghai(2026, 10, 23, 10, 30))],
                             receivedAt: shanghai(2026, 10, 23, 10, 30))
        let incoming = dataset(samples: [sample(shanghai(2026, 10, 22, 9, 35)),
                                         sample(shanghai(2026, 10, 22, 14, 55))],
                               receivedAt: shanghai(2026, 10, 23, 10, 31))
        XCTAssertFalse(NextSampleAudit.shouldReplace(existing: cached, incoming: incoming),
                       "接收时间更新，但样本更旧 —— 必须拒绝，否则今天的曲线被换成昨天的")
    }

    func test_sameDayWithFewerSamplesDoesNotOverwrite() {
        let cached = dataset(samples: [sample(shanghai(2026, 10, 23, 9, 35)),
                                       sample(shanghai(2026, 10, 23, 10, 30)),
                                       sample(shanghai(2026, 10, 23, 11, 20))],
                             receivedAt: shanghai(2026, 10, 23, 11, 20))
        let incoming = dataset(samples: [sample(shanghai(2026, 10, 23, 9, 35))],
                               receivedAt: shanghai(2026, 10, 23, 11, 21))
        XCTAssertFalse(NextSampleAudit.shouldReplace(existing: cached, incoming: incoming),
                       "同一天样本变少说明被截断，宁可保留完整曲线")
    }

    func test_sameDayGrowingSamplesReplace() {
        let cached = dataset(samples: [sample(shanghai(2026, 10, 23, 9, 35))],
                             receivedAt: shanghai(2026, 10, 23, 9, 36))
        let incoming = dataset(samples: [sample(shanghai(2026, 10, 23, 9, 35)),
                                         sample(shanghai(2026, 10, 23, 9, 40))],
                               receivedAt: shanghai(2026, 10, 23, 9, 41))
        XCTAssertTrue(NextSampleAudit.shouldReplace(existing: cached, incoming: incoming))
    }

    func test_nextSessionReplaces() {
        let cached = dataset(samples: [sample(shanghai(2026, 10, 22, 14, 55))],
                             receivedAt: shanghai(2026, 10, 22, 15, 0))
        let incoming = dataset(samples: [sample(shanghai(2026, 10, 23, 9, 35))],
                               receivedAt: shanghai(2026, 10, 23, 9, 36))
        XCTAssertTrue(NextSampleAudit.shouldReplace(existing: cached, incoming: incoming))
    }

    func test_emptyIncomingNeverReplaces() {
        let cached = dataset(samples: [sample(shanghai(2026, 10, 23, 9, 35))],
                             receivedAt: shanghai(2026, 10, 23, 9, 36))
        let incoming = dataset(samples: [], receivedAt: shanghai(2026, 10, 23, 9, 37))
        XCTAssertFalse(NextSampleAudit.shouldReplace(existing: cached, incoming: incoming),
                       "空响应不能把现有曲线清掉")
    }
}
