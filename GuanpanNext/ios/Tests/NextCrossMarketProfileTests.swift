import XCTest
@testable import GuanpanAdvisorCore

/// 121 条件化领先 + 132 分时段画像。
///
/// 两者共用同一个机制：**先按条件过滤配对，再重跑统计**。
/// 这组用例盯三件事：条件判定不许用未来数据、分组后不借样本、样本不足要明说。
final class NextCrossMarketProfileTests: XCTestCase {

    private func shanghai(_ y: Int, _ m: Int, _ d: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    // MARK: - 121 市场状态分类

    func test_choppyDayIsNotCalledTrendEvenWithBigMove() {
        // 净涨 1.2% 但振幅 2.6%：来回拉出来的，不是单边走出来的。
        let day = shanghai(2026, 10, 23, 0, 0)
        let points = [NextMarketPoint(timestamp: day.addingTimeInterval(9 * 3600), value: 100),
                      NextMarketPoint(timestamp: day.addingTimeInterval(9.5 * 3600), value: 102.6),
                      NextMarketPoint(timestamp: day.addingTimeInterval(10 * 3600), value: 101.2)]
        guard let result = NextRegimeClassifier.classify(day: day, points: points) else {
            return XCTFail("应能分类")
        }
        XCTAssertEqual(result.kind, .highVolatility, "振幅远大于净涨跌幅，是来回拉不是单边")
    }

    func test_cleanUptrendIsClassifiedAsTrendingUp() {
        let day = shanghai(2026, 10, 23, 0, 0)
        // 从 100 稳涨到 101，中间只回踩到 99.98 → 净 +1.0%，振幅 1.02%
        let points = [NextMarketPoint(timestamp: day.addingTimeInterval(9 * 3600), value: 100),
                      NextMarketPoint(timestamp: day.addingTimeInterval(10 * 3600), value: 99.98),
                      NextMarketPoint(timestamp: day.addingTimeInterval(11 * 3600), value: 101)]
        guard let result = NextRegimeClassifier.classify(day: day, points: points) else {
            return XCTFail("应能分类")
        }
        XCTAssertEqual(result.kind, .trendingUp)
        XCTAssertTrue(result.note.contains("单边上行"), result.note)
    }

    func test_cleanDowntrendIsClassifiedAsTrendingDown() {
        let day = shanghai(2026, 10, 23, 0, 0)
        let points = [NextMarketPoint(timestamp: day.addingTimeInterval(9 * 3600), value: 100),
                      NextMarketPoint(timestamp: day.addingTimeInterval(11 * 3600), value: 98.8)]
        guard let result = NextRegimeClassifier.classify(day: day, points: points) else {
            return XCTFail("应能分类")
        }
        XCTAssertEqual(result.kind, .trendingDown)
    }

    func test_flatDayIsRange() {
        let day = shanghai(2026, 10, 23, 0, 0)
        let points = [NextMarketPoint(timestamp: day.addingTimeInterval(9 * 3600), value: 100),
                      NextMarketPoint(timestamp: day.addingTimeInterval(11 * 3600), value: 100.05)]
        XCTAssertEqual(NextRegimeClassifier.classify(day: day, points: points)?.kind, .range)
    }

    func test_singlePointDayCannotBeClassified() {
        let day = shanghai(2026, 10, 23, 0, 0)
        let points = [NextMarketPoint(timestamp: day.addingTimeInterval(9 * 3600), value: 100)]
        XCTAssertNil(NextRegimeClassifier.classify(day: day, points: points),
                     "一个点算不出状态，不能猜")
    }

    func test_classificationUsesOnlyThatDay() {
        // 两天截然不同：第一天单边大涨，第二天横盘。各日结论必须互不影响。
        let day1 = shanghai(2026, 10, 22, 0, 0)
        let day2 = shanghai(2026, 10, 23, 0, 0)
        let series = [NextMarketPoint(timestamp: day1.addingTimeInterval(9 * 3600), value: 100),
                      NextMarketPoint(timestamp: day1.addingTimeInterval(11 * 3600), value: 102),
                      NextMarketPoint(timestamp: day2.addingTimeInterval(9 * 3600), value: 102),
                      NextMarketPoint(timestamp: day2.addingTimeInterval(11 * 3600), value: 102.02)]
        let days = NextRegimeClassifier.days(series: series)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].kind, .trendingUp)
        XCTAssertEqual(days[1].kind, .range)
    }

    // MARK: - 132 时段划分

    func test_sessionBucketBoundaries() {
        XCTAssertEqual(NextSessionBucket.bucket(forMinute: 9 * 60 + 29), nil, "开盘前不属于任何可交易时段")
        XCTAssertEqual(NextSessionBucket.bucket(forMinute: 9 * 60 + 30), .open30)
        XCTAssertEqual(NextSessionBucket.bucket(forMinute: 9 * 60 + 59), .open30)
        XCTAssertEqual(NextSessionBucket.bucket(forMinute: 10 * 60), .morning)
        XCTAssertEqual(NextSessionBucket.bucket(forMinute: 11 * 60 + 29), .morning)
        XCTAssertEqual(NextSessionBucket.bucket(forMinute: 12 * 60), nil, "A股午休不属于任何时段")
        XCTAssertEqual(NextSessionBucket.bucket(forMinute: 13 * 60), .afternoon)
        XCTAssertEqual(NextSessionBucket.bucket(forMinute: 14 * 60 + 30), .close30)
        XCTAssertEqual(NextSessionBucket.bucket(forMinute: 15 * 60), nil, "收盘后不再计入")
    }

    // MARK: - 过滤发生在配对之前

    /// 24 个交易日、每天 4 根 5 分钟点，跟随滞后一根。
    private func twoWaySeries(days: Int = 24) -> ([NextMarketPoint], [NextMarketPoint]) {
        var lead: [NextMarketPoint] = []
        var follow: [NextMarketPoint] = []
        var leadValue = 100.0
        var followValue = 100.0
        var previousChange = 0.0
        var index = 0
        var cursor = shanghai(2026, 9, 21, 9, 30)
        var produced = 0
        while produced < days {
            let weekday = Calendar(identifier: .gregorian).component(
                .weekday, from: cursor)
            if weekday != 1 && weekday != 7 {
                for step in 0..<4 {
                    let stamp = cursor.addingTimeInterval(Double(step) * 300)
                    let change = sin(Double(index) * 0.35) * 0.4
                    leadValue *= (1 + change / 100)
                    lead.append(NextMarketPoint(timestamp: stamp, value: leadValue))
                    follow.append(NextMarketPoint(timestamp: stamp, value: followValue))
                    followValue *= (1 + previousChange / 100)
                    previousChange = change
                    index += 1
                }
                produced += 1
            }
            cursor = cursor.addingTimeInterval(86_400)
        }
        return (lead, follow)
    }

    func test_includePairFiltersBeforePairing() {
        let (lead, follow) = twoWaySeries()
        let end = lead.last!.timestamp
        let open = NextLeadLagEngine.study(lead: .japan, leadSeries: lead, followCode: "513520",
                                           followSeries: follow, lastValidated: end)
        XCTAssertNotNil(open.best, "不过滤时应能找到关系")

        let none = NextLeadLagEngine.study(lead: .japan, leadSeries: lead, followCode: "513520",
                                           followSeries: follow, lastValidated: end,
                                           includePair: { _ in false })
        XCTAssertNil(none.best, "全过滤掉之后不该还有结论")
        XCTAssertTrue(none.summary.contains("暂无稳定领先关系"), none.summary)
    }

    func test_sessionProfilesOnlyKeepPointsInsideTheirBucket() {
        // 所有点都在 9:30–9:45 之间 → 只有 open30 有样本，其余时段必须明说没有。
        let (lead, follow) = twoWaySeries()
        let profiles = NextSessionProfileEngine.studies(
            lead: .japan, leadSeries: lead, followCode: "513520",
            followSeries: follow, lastValidated: lead.last!.timestamp)
        let open = profiles.first { $0.bucket == .open30 }
        let close = profiles.first { $0.bucket == .close30 }
        XCTAssertNotNil(open?.study.best, "开盘时段的点都在，应能出结论")
        XCTAssertNil(close?.study.best, "尾盘没有任何点，不能凭空有结论")
        XCTAssertTrue(close?.summary.contains("暂无结论") ?? false, close?.summary ?? "")
    }

    func test_conditionalLeadsDoNotBorrowSamplesAcrossRegimes() {
        let (lead, follow) = twoWaySeries()
        let leads = NextConditionalLeadEngine.studies(
            lead: .japan, leadSeries: lead, followCode: "513520",
            followSeries: follow, lastValidated: lead.last!.timestamp)
        XCTAssertEqual(leads.count, NextRegimeKind.allCases.count)
        // 分组是互斥的：各状态的独立交易日之和不可能超过总交易日数。
        // 借样本的写法（例如每组都用全样本）会立刻把这条断言撑爆。
        let summed = leads.reduce(0) { $0 + $1.independentDays }
        XCTAssertLessThanOrEqual(summed, 24, "分组互斥，样本量之和不能超过总交易日")
        for item in leads where item.study.best == nil {
            XCTAssertTrue(item.summary.contains("暂无结论"), "该状态下样本不足必须明说：\(item.summary)")
        }
    }

    func test_strongestOnlyPicksFromQualifiedLeads() {
        // 没有任何分组通过门槛时，不能硬挑一个「最像」的当结论。
        let (lead, follow) = twoWaySeries(days: 6)
        let leads = NextConditionalLeadEngine.studies(
            lead: .japan, leadSeries: lead, followCode: "513520",
            followSeries: follow, lastValidated: lead.last!.timestamp)
        if leads.contains(where: { $0.study.passesStatisticalBar }) {
            XCTAssertNotNil(NextConditionalLeadEngine.strongest(leads))
        } else {
            XCTAssertNil(NextConditionalLeadEngine.strongest(leads),
                         "全部不达标时不许挑一个最像的")
        }
    }
}
