import Foundation

// MARK: - 148 预注册前瞻复现（pre-registered forward replication）
//
// 统计显著 ≠ 可以拿它做交易。
//   前者回答「这条关系在过去的数据里像不像随机」，
//   后者要回答「这条关系在没被拿来拟合的数据上还成不成立」。
// 后者在本地无法证明，只能等它自己兑现——所以唯一诚实的做法是**先把假设写下来**，
// 再等未来的行情来判。这就是预注册。规则写死在代码里，不靠自觉：
//
//   1. 只有统计门槛全部通过的 study 才允许登记（登记入口只被统计层调用）；
//   2. 登记发生在当天第一次看到该信号时，事后补登记一律不算（`record` 只认已登记的那一天）；
//   3. 复盘结果只按「预测有没有兑现」记，**不按赚没赚钱记**——
//      做了但亏了，预测仍然是兑现的；取消后躲过下跌，那是策略对、预测错。
//      两者混在一起，这套检验立刻退化成自我表扬；
//   4. 确认次数不到 `minimumConfirmed`，`eligibleForTradingSignal` 恒为 False。

struct NextSignalReplication: Equatable, Codable {
    /// 领先市场，存 `NextCrossMarket.rawValue` 而不是枚举本身：
    /// 枚举以后加成员时旧存档不会解码失败。
    let lead: String
    let followCode: String
    let minutes: Int
    /// 滚动窗口天数；nil 表示「用全部归档，不分窗口」。
    let windowDays: Int?

    /// 预注册日（Asia/Shanghai, yyyy-MM-dd）。同一天重复登记会被忽略。
    var registeredDays: [String]
    var confirmedDays: [String]
    var refutedDays: [String]

    init(lead: String, followCode: String, minutes: Int, windowDays: Int?,
         registeredDays: [String] = [], confirmedDays: [String] = [], refutedDays: [String] = []) {
        self.lead = lead
        self.followCode = followCode
        self.minutes = minutes
        self.windowDays = windowDays
        self.registeredDays = registeredDays
        self.confirmedDays = confirmedDays
        self.refutedDays = refutedDays
    }

    /// 没有任何登记记录的空壳。`eligibleForTradingSignal` 对它是 False。
    static let none = NextSignalReplication(lead: "", followCode: "", minutes: 0, windowDays: nil)

    var market: NextCrossMarket? { NextCrossMarket(rawValue: lead) }

    var registeredCount: Int { Set(registeredDays).count }
    /// 确认与否认各按「天」去重：一天只算一次，避免同日多次刷新刷出计数。
    var confirmedCount: Int { Set(confirmedDays).count }
    var refutedCount: Int { Set(refutedDays).count }
    var decidedCount: Int { Set(confirmedDays).union(Set(refutedDays)).count }

    /// 兑现率。没有判定过时是 nil——不能把「还没开始」写成 0%。
    var hitRate: Double? {
        guard decidedCount > 0 else { return nil }
        return Double(confirmedCount) / Double(decidedCount)
    }

    /// 暂停：至少被否认 2 次，且否认多于确认。暂停的组合不再累计，也不再授权。
    var isSuspended: Bool {
        refutedCount >= 2 && refutedCount > confirmedCount
    }

    var label: String {
        let marketName = market?.displayName ?? lead
        let window = windowDays.map { "\($0) 日" } ?? "全量"
        return "\(marketName) → \(followCode) · \(minutes) 分钟 · \(window)"
    }

    /// 给用户看的一句话状态。数字全部来自真实计数，没有就写没有。
    var note: String {
        let rate = hitRate.map { NextLeadLagStudy.percent($0, digits: 0) } ?? "—"
        var text = "预注册 \(registeredCount) 次 · 兑现 \(confirmedCount) 次 · 未兑现 \(refutedCount) 次 · 兑现率 \(rate)"
        if isSuspended { text += " · 已暂停（未兑现次数过多）" }
        let progress = min(confirmedCount, NextSignalReplicationEngine.minimumConfirmed)
        text += " · 自动授权进度 \(progress)/\(NextSignalReplicationEngine.minimumConfirmed)"
        return text
    }
}

enum NextSignalReplicationEngine {
    /// 需要多少次**前瞻**兑现才允许把领先关系变成交易信号。
    /// 3 次是刻意压低的下限：本地拿到的分时数据量撑不起更高次数，
    /// 但这 3 次必须是在登记之后发生的，不能从历史里挑。
    static let minimumConfirmed = 3
    static let minimumHitRate = 0.5
    static let maximumRefuted = 2

    static func key(lead: NextCrossMarket, followCode: String, minutes: Int, windowDays: Int?) -> String {
        "\(lead.rawValue)|\(followCode)|\(minutes)|\(windowDays.map(String.init) ?? "all")"
    }

    static func key(of replication: NextSignalReplication) -> String {
        "\(replication.lead)|\(replication.followCode)|\(replication.minutes)|\(replication.windowDays.map(String.init) ?? "all")"
    }

    static var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 预注册/兑现的记账日。用北京时间的自然日，和交易日的直觉一致。
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func find(_ list: [NextSignalReplication], lead: NextCrossMarket,
                     followCode: String, minutes: Int, windowDays: Int?) -> NextSignalReplication? {
        let target = key(lead: lead, followCode: followCode, minutes: minutes, windowDays: windowDays)
        return list.first { key(of: $0) == target }
    }

    /// 登记今天的预注册。只由「统计门槛已通过」的调用方触发，且同一天只登记一次。
    /// 返回值可直接写回存储；重复登记会原样返回，不会修改任何计数。
    @discardableResult
    static func register(_ list: [NextSignalReplication], lead: NextCrossMarket,
                         followCode: String, minutes: Int, windowDays: Int?,
                         at date: Date = Date()) -> [NextSignalReplication] {
        let today = day(date)
        let target = key(lead: lead, followCode: followCode, minutes: minutes, windowDays: windowDays)
        var result = list
        if let index = result.firstIndex(where: { key(of: $0) == target }) {
            guard !result[index].registeredDays.contains(today) else { return result }
            result[index].registeredDays.append(today)
            // 登记只增不改历史：已确认过的组合继续累积，不会被重置。
            return result.sorted { key(of: $0) < key(of: $1) }
        }
        result.append(NextSignalReplication(lead: lead.rawValue, followCode: followCode,
                                            minutes: minutes, windowDays: windowDays,
                                            registeredDays: [today]))
        return result.sorted { key(of: $0) < key(of: $1) }
    }

    /// 复盘结果写回。**只对当天已登记的记录生效**——这是预注册的全部意义：
    /// 没登记就发生的行情不能拿来当验证。返回 (新列表, 本次被计入的条数)。
    static func record(_ list: [NextSignalReplication], code: String, at date: Date,
                       outcome: NextLoopReviewOutcome) -> (records: [NextSignalReplication], applied: Int) {
        guard let predicts = predictsFollowThrough(outcome) else { return (list, 0) }
        let today = day(date)
        var result = list
        var applied = 0
        for index in result.indices {
            guard result[index].followCode == code else { continue }
            guard result[index].registeredDays.contains(today) else { continue }
            if predicts {
                guard !result[index].confirmedDays.contains(today) else { continue }
                result[index].confirmedDays.append(today)
            } else {
                guard !result[index].refutedDays.contains(today) else { continue }
                result[index].refutedDays.append(today)
            }
            applied += 1
        }
        return (result, applied)
    }

    /// 复盘结果 → 「预测是否兑现」。
    /// 注意这里刻意**不看赚没赚钱**：
    /// - 做了但亏了（failedFollowThrough）：跟随确实发生了，预测兑现；
    /// - 取消后躲过下跌（avoidedLoss）：跟随没发生，预测没兑现，即便这次决定是对的。
    /// 把两件事混起来，这套检验就变成自己给自己发奖。
    static func predictsFollowThrough(_ outcome: NextLoopReviewOutcome) -> Bool? {
        switch outcome {
        case .followThrough: return true
        case .missedGain: return true
        case .failedFollowThrough: return true
        case .avoidedLoss: return false
        case .noSignal: return nil
        }
    }

    /// 某一天的净方向（收盘价 - 开盘价）。数据不足或价格非正时返回 nil。
    static func dayNetChange(_ points: [NextMarketPoint], on day: Date) -> Double? {
        let calendar = shanghai
        let sameDay = points.filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
            .sorted { $0.timestamp < $1.timestamp }
        guard sameDay.count > 1, let first = sameDay.first, let last = sameDay.last,
              first.value > 0, last.value > 0 else { return nil }
        return last.value - first.value
    }

    /// 结算**已登记过的那几天**：登记日当天，领先市场与跟随标的的净方向是否同号。
    ///
    /// 两条硬规矩：
    /// 1. 只判登记日当天，今天的登记要等收盘后才可能被判定；
    /// 2. 已经判定过的日子不会重复计数。
    /// 因此这个函数可以反复调用：同样的输入不会把 confirmedCount 越加越大。
    static func settle(_ list: [NextSignalReplication], market: NextCrossMarket,
                       leadSeries: [NextMarketPoint], followSeries: [NextMarketPoint],
                       at today: Date = Date()) -> [NextSignalReplication] {
        let calendar = shanghai
        let todayStart = calendar.startOfDay(for: today)
        var result = list
        for index in result.indices {
            let record = result[index]
            // 只结算属于这个领先市场的记录：拿日本的序列去判韩国的关系是纯粹的错配。
            guard record.lead == market.rawValue else { continue }
            for dayText in Set(record.registeredDays) {
                guard let day = parse(dayText) else { continue }
                // 只有已经过完的日子才能判定。
                guard calendar.startOfDay(for: day) < todayStart else { continue }
                if result[index].confirmedDays.contains(dayText) { continue }
                if result[index].refutedDays.contains(dayText) { continue }
                guard let leadNet = dayNetChange(leadSeries, on: day),
                      let followNet = dayNetChange(followSeries, on: day),
                      leadNet != 0, followNet != 0 else { continue }
                if (leadNet > 0) == (followNet > 0) {
                    result[index].confirmedDays.append(dayText)
                } else {
                    result[index].refutedDays.append(dayText)
                }
            }
        }
        return result
    }

    static func parse(_ dayText: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dayText)
    }

    /// 唯一允许「跨市场信号 → 方向性动作」的开关。
    /// 没有登记、登记过但没兑现够、兑现率不够、或被暂停，一律 False。
    static func allowsTradingSignal(_ replication: NextSignalReplication?) -> Bool {
        guard let replication else { return false }
        guard replication.confirmedCount >= minimumConfirmed else { return false }
        guard let rate = replication.hitRate, rate >= minimumHitRate else { return false }
        guard replication.refutedCount <= maximumRefuted else { return false }
        guard !replication.isSuspended else { return false }
        return true
    }

    /// 没达标时要说清差在哪一项，不能只写「不够」。
    static func blockReason(_ replication: NextSignalReplication?) -> String {
        guard let replication, replication.registeredCount > 0 else {
            return "还没有对这条关系做过前瞻预注册，历史回测不构成授权"
        }
        if replication.isSuspended {
            return "预注册兑现率过低（\(replication.confirmedCount)/\(replication.decidedCount)），已暂停该关系"
        }
        if replication.confirmedCount < minimumConfirmed {
            return "前瞻兑现 \(replication.confirmedCount)/\(minimumConfirmed) 次，未达到自动授权门槛"
        }
        if let rate = replication.hitRate, rate < minimumHitRate {
            return "前瞻兑现率 \(NextLeadLagStudy.percent(rate, digits: 0)) 低于 \(NextLeadLagStudy.percent(minimumHitRate, digits: 0))"
        }
        return "未达到自动授权门槛"
    }
}
