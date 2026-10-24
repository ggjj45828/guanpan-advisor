import Foundation

// MARK: - 跨市场归档数据接入（117 / 146 的数据入口）
//
// 这一层只做一件事：把 NAS 归档的「每分钟快照」变成回放器能吃的分钟序列。
// 它**不做任何统计**，也不生成假设——统计在 `NextLeadLagEngine` / `NextReplayEngine`，
// 假设在 `NextHypothesisJudge`。分开的原因很实际：数据接入最容易出错（时区、
// 前收、缺日），把它单独隔出来才能单独测，出问题也第一时间知道是数据错还是引擎错。

/// NAS `/v1/cross/series` 的解析结果。
struct NextCrossMarketArchive: Equatable {
    /// 市场 → 该市场本地日期（"yyyy-MM-dd"）→ 升序点。
    let byMarket: [NextCrossMarket: [String: [NextMarketPoint]]]
    /// 市场 → 该日最后一个源涨跌幅。首页要显示「今天涨多少」必须用源的这个数，
    /// 用我们自己算的相邻点差会把隔夜跳空算进日内。
    var dayChange: [NextCrossMarket: [String: Double]] = [:]
    /// 服务端报告的行数。用来交叉校验解析有没有漏行。
    let reportedRows: Int

    var totalPoints: Int {
        byMarket.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
    }

    /// 最新一天源给的涨跌幅。
    func latestChangePercent(_ market: NextCrossMarket) -> Double? {
        guard let days = dayChange[market], let latest = days.keys.sorted().last else { return nil }
        return days[latest]
    }

    /// 某市场全部点（跨日、升序）。
    func points(_ market: NextCrossMarket) -> [NextMarketPoint] {
        (byMarket[market] ?? [:]).keys.sorted().flatMap { (byMarket[market] ?? [:])[$0] ?? [] }
    }

    func dayCount(_ market: NextCrossMarket) -> Int {
        (byMarket[market] ?? [:]).count
    }

    /// 「这个市场能不能支撑回放验证」。不够就直说不够，不假装在跑。
    func availabilityNote(_ market: NextCrossMarket, minimumDays: Int = NextCrossMarketFeed.minimumReplayDays) -> String {
        let days = dayCount(market)
        if days == 0 { return "\(market.displayName)：还没有归档数据" }
        if days < minimumDays { return "\(market.displayName)：只有 \(days) 个交易日（需 ≥\(minimumDays) 天），暂无稳定领先关系" }
        return "\(market.displayName)：已归档 \(days) 个交易日"
    }

    /// 进决策上下文的说明行。
    ///
    /// 最后一行是关键：日韩不够 30 天时必须**明确**写「暂无稳定领先关系」。
    /// 少了这句，模型会拿「日经上午涨了 1%」这种单点事实编出一个午后机会——
    /// 而这条规律从来没被任何数据验证过。宁可显得没本事，也不能让它编。
    func decisionContextNotes(minimumDays: Int = NextCrossMarketFeed.minimumReplayDays) -> [String] {
        var lines = [NextCrossMarket.japan, .korea, .hongKong, .unitedStates].map {
            availabilityNote($0, minimumDays: minimumDays)
        }
        let shortfall = [NextCrossMarket.japan, .korea].filter { dayCount($0) < minimumDays }
        if !shortfall.isEmpty {
            let names = shortfall.map(\.displayName).joined(separator: "、")
            lines.append("\(names) 归档不足 \(minimumDays) 个交易日：暂无稳定领先关系，不得据此产生午后假设或交易建议")
        }
        return lines
    }
}

enum NextCrossMarketFeed {
    /// 回放器要求「提出假设的样本 ≥30 天」。低于这个数一律不下结论。
    static let minimumReplayDays = 30

    enum FeedError: Error, Equatable { case malformed(String) }

    /// 解析 `/v1/cross/series`。结构不认识就抛错，绝不返回「空但看起来正常」的结果——
    /// 空结果会让界面上显示「暂无稳定领先关系」，而这跟数据源坏了是两件完全不同的事。
    static func parse(_ data: Data) throws -> NextCrossMarketArchive {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeedError.malformed("不是 JSON 对象")
        }
        guard let markets = root["markets"] as? [String: Any] else {
            throw FeedError.malformed("缺少 markets 字段")
        }
        var byMarket: [NextCrossMarket: [String: [NextMarketPoint]]] = [:]
        var dayChange: [NextCrossMarket: [String: Double]] = [:]
        for (key, value) in markets {
            guard let market = NextCrossMarket(rawValue: key) else { continue }
            guard let days = value as? [String: Any] else { continue }
            var grouped: [String: [NextMarketPoint]] = [:]
            for (day, rawPoints) in days {
                guard let rows = rawPoints as? [[String: Any]] else { continue }
                var points: [NextMarketPoint] = []
                var lastChange: Double?
                for row in rows {
                    guard let stampText = row["timestamp"] as? String,
                          let stamp = NextCrossMarketFeed.date(from: stampText),
                          let price = NextCrossMarketFeed.double(row["price"]),
                          price > 0 else { continue }
                    points.append(NextMarketPoint(timestamp: stamp, value: price))
                    if let change = NextCrossMarketFeed.double(row["changePercent"]) { lastChange = change }
                }
                if !points.isEmpty {
                    let sorted = points.sorted { $0.timestamp < $1.timestamp }
                    grouped[day] = sorted
                    if let lastChange { dayChange[market, default: [:]][day] = lastChange }
                }
            }
            if !grouped.isEmpty { byMarket[market] = grouped }
        }
        let reported = (root["rows"] as? Int) ?? (root["rows"] as? NSNumber)?.intValue ?? 0
        if byMarket.isEmpty, reported > 0 {
            throw FeedError.malformed("服务端有 \(reported) 行，但一行都没解析出来")
        }
        return NextCrossMarketArchive(byMarket: byMarket, dayChange: dayChange, reportedRows: reported)
    }

    /// 该市场本地日期键。日期必须按各市场自己的时区切：
    /// 用上海时区切美股，会把美股一个交易日劈成两天，隔夜变化直接算错。
    static func dayKey(_ date: Date, market: NextCrossMarket) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(from text: String) -> Date? {
        // 归档里是带偏移的 ISO 时间（服务端统一写 UTC）。两种写法都接受。
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

// MARK: - 回放素材装配

/// 把「A股 ETF 分钟线 + 海外归档」装成逐日回放素材。
///
/// 两个容易搞错的口径，都在这里钉死：
/// 1. **前收**取本地上一交易日的最后一点。取不到就跳过这一天，不拿当天开盘价凑数
///    （拿开盘价当昨收，会把跳空当成日内涨跌，回放结论全歪）。
/// 2. **海外点的取用区间**是「本地日 00:00（北京时间）往前 18 小时 → 本地日 15:00」。
///    这样美股前一天夜里到当天凌晨的走势会正确进入当天 A股 的视野，
///    而不会把当天晚上（A股收盘之后）的美股走势提前算进来——那就是未来数据。
enum NextReplayAssembler {
    static let overseasLeadInHours: Double = 18
    static let sessionEndHour: Double = 15

    static func days(code: String, name: String,
                     localMinutes: [NextMarketPoint],
                     archive: NextCrossMarketArchive,
                     localMarket: NextCrossMarket = .china,
                     overseasMarkets: [NextCrossMarket] = [.japan, .korea, .hongKong, .unitedStates]) -> [NextReplayDay] {
        let grouped = groupByLocalDay(localMinutes, market: localMarket)
        let dayKeys = grouped.keys.sorted()
        guard dayKeys.count >= 2 else { return [] }
        var result: [NextReplayDay] = []
        for index in 1..<dayKeys.count {
            let key = dayKeys[index]
            guard let points = grouped[key], let previousPoints = grouped[dayKeys[index - 1]],
                  let previousClose = previousPoints.last?.value, previousClose > 0 else { continue }
            guard let dayStart = startOfDay(key, market: localMarket) else { continue }
            let windowStart = dayStart.addingTimeInterval(-overseasLeadInHours * 3600)
            let windowEnd = dayStart.addingTimeInterval(sessionEndHour * 3600)
            var overseas: [NextCrossMarketDaySeries] = []
            for market in overseasMarkets {
                let all = archive.points(market)
                let window = all.filter { $0.timestamp >= windowStart && $0.timestamp <= windowEnd }
                guard !window.isEmpty else { continue }
                // 前收：窗口开始前最后一点；没有就用窗口内第一点（当日首次观测）。
                let base = NextCrossMarketAlignment.lastPoint(atOrBefore: windowStart, in: all)?.value
                    ?? window.first?.value ?? 0
                guard base > 0 else { continue }
                overseas.append(NextCrossMarketDaySeries(market: market, previousClose: base, points: window))
            }
            result.append(NextReplayDay(date: dayStart, code: code, name: name,
                                        local: NextCrossMarketDaySeries(market: localMarket,
                                                                        previousClose: previousClose,
                                                                        points: points),
                                        overseas: overseas))
        }
        return result
    }

    static func groupByLocalDay(_ points: [NextMarketPoint], market: NextCrossMarket) -> [String: [NextMarketPoint]] {
        var grouped: [String: [NextMarketPoint]] = [:]
        for point in points where point.value > 0 {
            grouped[NextCrossMarketFeed.dayKey(point.timestamp, market: market), default: []].append(point)
        }
        for key in Array(grouped.keys) {
            grouped[key]?.sort { $0.timestamp < $1.timestamp }
        }
        return grouped
    }

    static func startOfDay(_ key: String, market: NextCrossMarket) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        var components = DateComponents()
        components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        return calendar.date(from: components)
    }
}
