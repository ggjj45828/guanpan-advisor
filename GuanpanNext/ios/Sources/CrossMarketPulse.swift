import Foundation

// MARK: - 140 跨市场脉搏
//
// 首页要回答的是「现在外面在发生什么、那些数据还能不能用」，不是「该买什么」。
// 所以这里只做三件事：谁在开、最新一个观测是几点、相对昨天动了多少。
//
// 三条不许越界的规矩：
// 1. 数据过期或市场休市 → 明确写「已收盘 / 午休 / 周末休市」，并把这条从「可用」里踢出去；
// 2. 没有归档就显示「—」，不拿昨天的收盘价冒充今天的实时价；
// 3. 不在这一层给方向性结论。归档天数不够时，标题下面直接写「暂无稳定领先关系」。

struct NextCrossMarketPulseRow: Equatable {
    enum Tone: Equatable { case ok, warn, idle }

    let market: NextCrossMarket
    let status: NextMarketStatus
    let price: Double?
    let changePercent: Double?
    let observedAt: Date?
    let ageMinutes: Int?
    /// 这条数据能不能当「今天的信息」用。休市 / 过期 / 无数据一律 false。
    let usable: Bool

    var stateText: String {
        switch status {
        case .open: return "交易中"
        case .lunchBreak: return "午休"
        case .preOpen: return "未开盘"
        case .closed: return "已收盘"
        case .weekend: return "周末休市"
        case .holiday: return "休市"
        }
    }

    var priceText: String {
        guard let price else { return "—" }
        return price >= 1000 ? String(format: "%.0f", price) : String(format: "%.2f", price)
    }

    var changeText: String {
        guard let changePercent else { return "—" }
        return String(format: "%+.2f%%", changePercent)
    }

    /// 「几点看到的」。休市时说「最后观测 HH:mm」，不假装是现在。
    var ageText: String {
        guard let observedAt else { return "无归档" }
        let stamp = NextCrossMarketPulseRow.clock(observedAt, in: market)
        guard let ageMinutes else { return stamp }
        guard status.providesLiveInformation else { return "最后 \(stamp)" }
        return ageMinutes <= 1 ? "\(stamp) · 刚刚" : "\(stamp) · \(ageMinutes) 分钟前"
    }

    var tone: Tone {
        guard price != nil else { return .idle }
        if !usable { return .warn }
        guard let changePercent else { return .ok }
        return abs(changePercent) < 0.05 ? .idle : .ok
    }

    static func clock(_ date: Date, in market: NextCrossMarket) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = market.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct NextCrossMarketPulse: Equatable {
    let generatedAt: Date
    let rows: [NextCrossMarketPulseRow]
    /// 每个市场归档了多少个交易日。
    let archivedDays: [NextCrossMarket: Int]
    let minimumDays: Int
    /// A股午休期间的可观察变化（119）。没有午休或数据不足就是 nil。
    let lunchNote: String?

    var hasAnyData: Bool { rows.contains { $0.price != nil } }
    var usableCount: Int { rows.filter(\.usable).count }

    /// 标题：「日经 +0.82% · 韩国 -0.31%」；没数据就直说没数据。
    var headline: String {
        let parts = rows.compactMap { row -> String? in
            guard row.price != nil else { return nil }
            return "\(NextCrossMarketPulse.shortName(row.market)) \(row.changeText)"
        }
        return parts.isEmpty ? "暂无跨市场数据" : parts.joined(separator: " · ")
    }

    /// 副标题：先把「为什么不能据此交易」写在最显眼的位置。
    var subtitle: String {
        let verified = rows.filter { (archivedDays[$0.market] ?? 0) >= minimumDays }
        if verified.isEmpty {
            let days = rows.map { archivedDays[$0.market] ?? 0 }.max() ?? 0
            return "归档 \(days) 天 · 不足 \(minimumDays) 天，暂无稳定领先关系，仅作背景"
        }
        return "已归档 \(verified.count) 个市场达 \(minimumDays) 天，可回放验证"
    }

    var footnote: String {
        let live = rows.filter(\.usable)
        if live.isEmpty { return "当前没有可用实时数据：休市或归档未更新，不参与今日判断" }
        return "每分钟采自 NAS 归档 · 休市或过期的数据不参与判断"
    }

    static func shortName(_ market: NextCrossMarket) -> String {
        switch market {
        case .china: return "A股"
        case .hongKong: return "港股"
        case .japan: return "日经"
        case .korea: return "韩国"
        case .unitedStates: return "纳指"
        }
    }
}

enum NextCrossMarketPulseBuilder {
    /// A股以外的 4 个市场。A股 自己不是「外部市场」，放在这里会让人误以为它是先行方。
    static let overseas: [NextCrossMarket] = [.japan, .korea, .hongKong, .unitedStates]

    static func build(archive: NextCrossMarketArchive?, now: Date,
                      calendar: NextMarketCalendar = NextMarketCalendar(),
                      minimumDays: Int = NextCrossMarketFeed.minimumReplayDays) -> NextCrossMarketPulse {
        var rows: [NextCrossMarketPulseRow] = []
        var days: [NextCrossMarket: Int] = [:]
        for market in overseas {
            let points = archive?.points(market) ?? []
            days[market] = archive?.dayCount(market) ?? 0
            let status = calendar.status(market, at: now)
            guard let latest = points.last else {
                rows.append(NextCrossMarketPulseRow(market: market, status: status, price: nil,
                                                    changePercent: nil, observedAt: nil, ageMinutes: nil,
                                                    usable: false))
                continue
            }
            let age = max(0, Int(now.timeIntervalSince(latest.timestamp) / 60))
            // 涨跌幅优先用源自己给的当日涨跌幅；没有就用「上一个交易日的最后一点」当基准。
            let change = archive?.latestChangePercent(market)
                ?? previousSessionChange(points: points, latest: latest, market: market)
            rows.append(NextCrossMarketPulseRow(
                market: market, status: status, price: latest.value, changePercent: change,
                observedAt: latest.timestamp, ageMinutes: age,
                usable: status.providesLiveInformation && age <= 30))
        }
        return NextCrossMarketPulse(generatedAt: now, rows: rows, archivedDays: days,
                                    minimumDays: minimumDays,
                                    lunchNote: lunchNote(archive: archive, now: now, calendar: calendar))
    }

    /// 当日涨跌幅：最新一点相对「该市场本地日的前一日最后一点」。
    static func previousSessionChange(points: [NextMarketPoint], latest: NextMarketPoint,
                                      market: NextCrossMarket) -> Double? {
        let key = NextCrossMarketFeed.dayKey(latest.timestamp, market: market)
        guard let index = points.lastIndex(where: { NextCrossMarketFeed.dayKey($0.timestamp, market: market) == key }),
              index > 0 else { return nil }
        let base = points[index - 1].value
        return NextCrossMarketAlignment.changePercent(from: base, to: latest.value)
    }

    /// 119 的显示版本：A股 正在午休时，说说日韩/港股这段时间动了多少。
    ///
    /// 直接算「11:30 那一点 → 12:50 那一点」的涨跌幅，不借「昨收」当基准：
    /// 借昨收会把上午的涨跌混进来，显示出来的就不是「午休期间的变化」了。
    static func lunchNote(archive: NextCrossMarketArchive?, now: Date,
                          calendar: NextMarketCalendar) -> String? {
        guard let archive, calendar.status(.china, at: now) == .lunchBreak,
              let lunch = calendar.lunchBreak(.china, at: now) else { return nil }
        let cutoff = lunch.end.addingTimeInterval(-10 * 60)
        var notes: [String] = []
        for market in [NextCrossMarket.japan, .korea, .hongKong] {
            let points = archive.points(market)
            guard let pre = NextCrossMarketAlignment.lastPoint(atOrBefore: lunch.start, in: points),
                  let late = NextCrossMarketAlignment.lastPoint(atOrBefore: cutoff, in: points),
                  pre.timestamp < late.timestamp,
                  let shock = NextCrossMarketAlignment.changePercent(from: pre.value, to: late.value) else { continue }
            notes.append("\(market.displayName) \(String(format: "%+.2f", shock))pp")
        }
        guard !notes.isEmpty else { return nil }
        return "A股午休期间：" + notes.joined(separator: " · ")
    }
}

// MARK: - 141 持仓详情里的「外部市场影响」
//
// 只回答一个问题：这只标的，外面有没有**验证过**的领先关系？
// 没验证过就写「暂无稳定领先关系」，不许把「日经今天涨了」当成买入理由。

struct NextHoldingAbroadImpact: Equatable {
    let code: String
    let hasStableLead: Bool
    let lines: [String]

    var summary: String {
        if hasStableLead, let first = lines.first { return first }
        return lines.last ?? "暂无稳定领先关系"
    }
}

enum NextHoldingAbroadImpactBuilder {
    static func impact(code: String, studies: [NextLeadLagStudy],
                       pulse: NextCrossMarketPulse) -> NextHoldingAbroadImpact {
        let usable = studies.filter { $0.followCode == code && $0.best != nil }
        var lines: [String] = []
        for study in usable.prefix(2) {
            guard let best = study.best else { continue }
            lines.append("\(study.lead.displayName) 领先约 \(best.minutes) 分钟（样本 \(best.sampleCount)，相关 \(NextLeadLagStudy.percent(best.correlation, digits: 2))）")
        }
        lines.append(contentsOf: pulse.rows.compactMap { row -> String? in
            guard row.price != nil else { return nil }
            return "\(row.market.displayName) \(row.stateText) \(row.changeText) · \(row.ageText)"
        })
        if usable.isEmpty {
            lines.append("暂无稳定领先关系：\(pulse.subtitle)")
            return NextHoldingAbroadImpact(code: code, hasStableLead: false, lines: lines)
        }
        return NextHoldingAbroadImpact(code: code, hasStableLead: true, lines: lines)
    }
}
