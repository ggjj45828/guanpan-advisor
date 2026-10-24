import XCTest
@testable import GuanpanAdvisorCore

/// 117 / 120 / 146 的数据入口验收。
///
/// 这组用例只关心「把自己骗过去的那几种情形」：
/// - 前收取错 → 跳空被当成日内涨跌 → 回放结论全歪；
/// - 海外点取用区间错 → 当天晚上（A股收盘后）的美股走势被提前用上，等于未来数据；
/// - 归档空/结构坏 → 界面显示「暂无稳定领先关系」，而真相是数据源坏了，这两件事必须能分开。
final class NextCrossMarketFeedTests: XCTestCase {

    private func shanghai(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    private func minuteSeries(_ day: String, prices: [Double], start: String = "09:30") -> [NextMarketPoint] {
        let base = shanghai("\(day)T\(start):00+08:00")
        return prices.enumerated().map { index, price in
            NextMarketPoint(timestamp: base.addingTimeInterval(Double(index) * 60), value: price)
        }
    }

    private func archiveJSON(_ body: String) -> Data { Data(body.utf8) }

    // MARK: 归档解析

    func test_parseGroupsPointsByMarketDayAndRejectsBadRows() throws {
        let json = """
        {"source":"NAS cross-market snapshot archive","rows":4,
         "markets":{"japan":{"2026-10-23":[
            {"timestamp":"2026-10-23T05:12:00+00:00","price":62692.94,"changePercent":-0.34},
            {"timestamp":"2026-10-23T05:13:00+00:00","price":"0","changePercent":null},
            {"timestamp":"not-a-time","price":1,"changePercent":null}]}}}
        """
        let archive = try NextCrossMarketFeed.parse(archiveJSON(json))
        XCTAssertEqual(archive.dayCount(.japan), 1)
        // 价格为 0 与时间不可解析的行都必须丢掉，不能变成 0 值点位
        XCTAssertEqual(archive.points(.japan).count, 1)
        XCTAssertEqual(archive.points(.japan).first?.value ?? 0, 62692.94, accuracy: 0.001)
    }

    func test_parseThrowsWhenServerReportsRowsButNothingParsed() {
        let json = #"{"rows":12,"markets":{"unknownMarket":{"2026-10-23":[]}}}"#
        XCTAssertThrowsError(try NextCrossMarketFeed.parse(archiveJSON(json)))
    }

    func test_dayKeyUsesMarketOwnTimeZone() {
        let stamp = shanghai("2026-10-24T06:00:00+08:00")  // 纽约 10-23 18:00
        XCTAssertEqual(NextCrossMarketFeed.dayKey(stamp, market: .unitedStates), "2026-10-23")
        XCTAssertEqual(NextCrossMarketFeed.dayKey(stamp, market: .china), "2026-10-24")
    }

    func test_availabilitySpeaksUpWhenDaysAreInsufficient() {
        let json = """
        {"rows":2,"markets":{"korea":{"2026-10-23":[
            {"timestamp":"2026-10-23T05:12:00+00:00","price":5550.3},
            {"timestamp":"2026-10-23T05:13:00+00:00","price":5551.1}]}}}
        """
        let archive = (try? NextCrossMarketFeed.parse(archiveJSON(json)))!
        XCTAssertTrue(archive.availabilityNote(.korea).contains("暂无稳定领先关系"))
        XCTAssertTrue(archive.availabilityNote(.japan).contains("还没有归档数据"))
    }

    // MARK: 回放装配

    func test_assemblerUsesPreviousSessionCloseNotSameDayOpen() {
        // 第一天收 1.00，第二天 1.10 开盘（跳空 10%）。前收必须是 1.00。
        let local = minuteSeries("2026-10-22", prices: [1.00, 1.00, 1.00])
            + minuteSeries("2026-10-23", prices: [1.10, 1.12])
        let days = NextReplayAssembler.days(code: "510300", name: "沪深300ETF",
                                           localMinutes: local,
                                           archive: NextCrossMarketArchive(byMarket: [:], reportedRows: 0))
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].local.previousClose, 1.00, accuracy: 0.0001)
        XCTAssertEqual(days[0].local.points.count, 2)
    }

    func test_assemblerKeepsOverseasPointsInsideLeadInWindowOnly() {
        // 日经：本地日 00:00 前 18 小时内（前一日 06:00 之后）到当日 15:00 之间的点才收。
        let local = minuteSeries("2026-10-22", prices: [1.00]) + minuteSeries("2026-10-23", prices: [1.00, 1.01])
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        func tokyoStamp(_ text: String) -> Date {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = tokyo
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)!
        }
        let japanPoints = [
            NextMarketPoint(timestamp: tokyoStamp("2026-10-22T12:00:00+09:00"), value: 100),  // 窗口内（前一日）
            NextMarketPoint(timestamp: tokyoStamp("2026-10-23T14:00:00+09:00"), value: 101),  // 窗口内（当日）
            NextMarketPoint(timestamp: tokyoStamp("2026-10-23T20:00:00+09:00"), value: 105),  // A股收盘后，必须排除
        ]
        let archive = NextCrossMarketArchive(byMarket: [.japan: ["x": japanPoints]], reportedRows: 3)
        let days = NextReplayAssembler.days(code: "510300", name: "沪深300ETF",
                                           localMinutes: local, archive: archive)
        XCTAssertEqual(days.count, 1)
        let overseas = days[0].overseas.first { $0.market == .japan }
        XCTAssertNotNil(overseas)
        XCTAssertEqual(overseas?.points.count, 2, "A股收盘之后的日经点位不能进入当天回放，那是未来数据")
        XCTAssertEqual(overseas?.previousClose ?? 0, 100, accuracy: 0.0001)
    }

    func test_assemblerSkipsFirstDayAndDaysWithoutPreviousClose() {
        let local = minuteSeries("2026-10-23", prices: [1.00, 1.01])
        let days = NextReplayAssembler.days(code: "510300", name: "沪深300ETF",
                                           localMinutes: local,
                                           archive: NextCrossMarketArchive(byMarket: [:], reportedRows: 0))
        XCTAssertTrue(days.isEmpty, "只有一天数据时没有前收，不能凑出一天回放素材")
    }

    // MARK: 129 / 130 进统一决策上下文

    func test_decisionContextNotesWarnWhenJapanKoreaAreInsufficient() {
        let json = """
        {"rows":2,"markets":{"japan":{"2026-10-23":[
            {"timestamp":"2026-10-23T05:12:00+00:00","price":62692.94}]}}}
        """
        let archive = try! NextCrossMarketFeed.parse(archiveJSON(json))
        let notes = archive.decisionContextNotes()
        XCTAssertTrue(notes.contains { $0.contains("日本") && $0.contains("暂无稳定领先关系") })
        XCTAssertTrue(notes.contains { $0.contains("韩国") && $0.contains("暂无稳定领先关系") })
        XCTAssertTrue(notes.last?.contains("不得据此产生午后假设") ?? false,
                      "日韩不够 30 天时必须明确禁止据此产生交易建议")
    }

    func test_decisionContextNotesStayQuietWhenBothMarketsHaveEnoughDays() {
        var japan: [String: [NextMarketPoint]] = [:]
        var korea: [String: [NextMarketPoint]] = [:]
        for index in 0..<30 {
            let day = String(format: "2026-09-%02d", index + 1)
            let stamp = shanghai("\(day)T10:00:00+08:00")
            japan[day] = [NextMarketPoint(timestamp: stamp, value: 62000 + Double(index))]
            korea[day] = [NextMarketPoint(timestamp: stamp, value: 5500 + Double(index))]
        }
        let archive = NextCrossMarketArchive(byMarket: [.japan: japan, .korea: korea], reportedRows: 60)
        let notes = archive.decisionContextNotes()
        XCTAssertFalse(notes.contains { $0.contains("不得据此产生午后假设") })
        XCTAssertTrue(notes.contains { $0.contains("已归档 30 个交易日") })
    }

    // MARK: 120 午后反应统计

    private func afternoonSession(_ day: String, conditionMet: Bool, returns: [Double],
                                  lunchEnd: String = "13:00") -> NextAfternoonSession {
        let base = shanghai("\(day)T\(lunchEnd):00+08:00")
        var price = 1.0
        var points = [NextMarketPoint(timestamp: base, value: price)]
        for (index, change) in returns.enumerated() {
            price *= (1 + change / 100)
            points.append(NextMarketPoint(timestamp: base.addingTimeInterval(Double(index + 1) * 60), value: price))
        }
        return NextAfternoonSession(date: base, lunchEnd: base, conditionMet: conditionMet, points: points)
    }

    func test_afternoonReactionSaysNoPatternWhenSampleIsTooSmall() {
        let sessions = (0..<5).map { index in
            afternoonSession("2026-09-0\(index + 1)", conditionMet: true,
                             returns: [0.2, 0.3, 0.4, 0.5, 0.6, 0.7])
        }
        let study = NextAfternoonReactionEngine.study(code: "510300", conditionText: "海外午休修复", sessions: sessions)
        XCTAssertFalse(study.hasStablePattern)
        XCTAssertTrue(study.summary.contains("暂无稳定规律"))
        XCTAssertEqual(study.conditionedDays, 5)
    }

    func test_afternoonReactionDetectsConsistentPositivePattern() {
        var sessions: [NextAfternoonSession] = []
        for index in 0..<25 {
            let day = String(format: "2026-09-%02d", index + 1)
            sessions.append(afternoonSession(day, conditionMet: true, returns: [0.1, 0.2, 0.3]))
        }
        let study = NextAfternoonReactionEngine.study(code: "510300", conditionText: "海外午休修复", sessions: sessions)
        XCTAssertTrue(study.hasStablePattern)
        XCTAssertEqual(study.conditionedDays, 25)
        XCTAssertEqual(study.conditioned.last?.positiveRate ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(study.conditioned.last?.medianReturn ?? 0, 0)
    }

    func test_afternoonReactionDoesNotClaimPatternForCoinFlip() {
        // 一半涨一半跌、样本充足：偏离不足 10 个百分点，必须判「暂无稳定规律」
        var sessions: [NextAfternoonSession] = []
        for index in 0..<24 {
            let day = String(format: "2026-09-%02d", index + 1)
            sessions.append(afternoonSession(day, conditionMet: true,
                                             returns: index % 2 == 0 ? [0.2, 0.4] : [-0.2, -0.4]))
        }
        let study = NextAfternoonReactionEngine.study(code: "510300", conditionText: "海外午休修复", sessions: sessions)
        XCTAssertFalse(study.hasStablePattern)
        XCTAssertTrue(study.summary.contains("与随机无异"))
    }
}
