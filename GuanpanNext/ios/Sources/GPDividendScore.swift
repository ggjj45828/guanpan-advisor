import SwiftUI

/// 红利买入时机打分（满分 100）。
///
/// 口径（全部本机可复算，不预测价格、不预测分红）：
/// - 股息率 40 分：近 12 个月每份**已核实**派息 ÷ 分母（ETF 有 IOPV 按净值，否则按现价），
///   达到用户设定的目标股息率即拿满，按比例给分。
/// - 价格位置 35 分：现价在近 180 个交易日高低区间中的位置，越靠下分越高。
/// - 高点回撤 15 分：相对近 180 个交易日高点回撤越深分越高（回撤 20% 拿满）。
/// - 分红稳定性 10 分：近三个自然年里有已核实分红的年份数（3 年 10 分 / 2 年 7 分 / 1 年 4 分）。
///
/// 哪项数据缺失，哪项计 0 分并记入 `missing`，界面明示，不拿中性分冒充。
struct DividendBuyScore: Equatable, Identifiable {
    var id: String { code }
    enum Tier: String, Equatable {
        case attention = "值得关注"
        case batch = "可分批"
        case observe = "观望"
        case wait = "等待"
    }
    let code: String
    let price: Decimal
    let perShare: Decimal
    /// 股息率分母：ETF 有 IOPV 时为净值，否则为现价。
    let yieldBase: Decimal
    let yieldPercent: Double
    let targetYieldPercent: Decimal
    let yieldPoints: Int
    let positionPoints: Int
    let drawdownPoints: Int
    let stabilityPoints: Int
    let windowLow: Decimal?
    let windowHigh: Decimal?
    let missing: [String]
    var total: Int { yieldPoints + positionPoints + drawdownPoints + stabilityPoints }
    var tier: Tier {
        switch total {
        case 80...: return .attention
        case 60..<80: return .batch
        case 40..<60: return .observe
        default: return .wait
        }
    }
}

/// 打分的唯一实现。纯函数：同样的输入必然得到同样的分数，用户可以逐项核对。
enum DividendBuyScoreEngine {
    /// 近 180 个交易日（约半年）的日 K 窗口。
    static let windowBars = 180
    /// 回撤满分线：相对窗口高点回撤 20% 即拿满回撤分。
    static let drawdownFullScale = 0.20

    /// - Parameters:
    ///   - perShare: 近 12 个月每份已核实派息（0 表示不打分）。
    ///   - price: 现价（nil 或 ≤0 表示不打分）。
    ///   - dividendEvents: 已合并的去重派息事件（调用方负责 merged）。
    ///   - today: `yyyy-MM-dd`，注入以便测试固定时间。
    static func evaluate(code: String, perShare: Decimal, price: Decimal?, iopv: Decimal?,
                         samples: [NextChartSample], dividendEvents: [NextETFDividendEvent],
                         today: String, targetYieldPercent: Decimal) -> DividendBuyScore? {
        guard perShare > 0, let price, price > 0 else { return nil }
        var missing: [String] = []
        var base = price
        if NextDividendRules.isOnExchangeETF(code), let net = iopv, net > 0 { base = net }

        // 1) 股息率 40 分：达到目标股息率拿满，按比例。
        let yieldPercent = NextNum.double(perShare) / NextNum.double(base) * 100
        var yieldPoints = 0
        if targetYieldPercent > 0 {
            let target = NextNum.double(targetYieldPercent)
            yieldPoints = Int((40 * min(yieldPercent / target, 1)).rounded())
        } else {
            missing.append("目标股息率")
        }

        // 2) 3) 位置与回撤共用同一个日 K 窗口；没有日 K 就都记缺失。
        let window = Array(samples.filter { $0.close > 0 }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(windowBars))
        var positionPoints = 0
        var drawdownPoints = 0
        var windowLow: Decimal?
        var windowHigh: Decimal?
        if !window.isEmpty {
            let lows = window.map { $0.low ?? $0.close }
            let highs = window.map { $0.high ?? $0.close }
            windowLow = lows.min()
            windowHigh = highs.max()
            if let low = windowLow, let high = windowHigh, high > low {
                let position = min(max(NextNum.double((price - low) / (high - low)), 0), 1)
                positionPoints = Int((35 * (1 - position)).rounded())
            } else {
                missing.append("日K区间")
            }
            if let high = windowHigh, high > 0 {
                let drawdown = min(max(NextNum.double((high - price) / high), 0), 1)
                drawdownPoints = Int((15 * min(drawdown / drawdownFullScale, 1)).rounded())
            } else {
                missing.append("日K高点")
            }
        } else {
            missing.append("日K")
        }

        // 4) 分红稳定性 10 分：近三个自然年（含今年）有已核实派息的年份数。
        let currentYear = Int(today.prefix(4)) ?? 0
        let years = Set(dividendEvents
            .filter { $0.isEstimated != true && $0.date <= today }
            .compactMap { Int($0.date.prefix(4)) }
            .filter { $0 >= currentYear - 2 && $0 <= currentYear })
        let stabilityPoints: Int
        switch years.count {
        case 3...: stabilityPoints = 10
        case 2: stabilityPoints = 7
        case 1: stabilityPoints = 4
        default: stabilityPoints = 0
        }

        return DividendBuyScore(code: code, price: price, perShare: perShare, yieldBase: base,
            yieldPercent: yieldPercent, targetYieldPercent: targetYieldPercent,
            yieldPoints: yieldPoints, positionPoints: positionPoints, drawdownPoints: drawdownPoints,
            stabilityPoints: stabilityPoints, windowLow: windowLow, windowHigh: windowHigh, missing: missing)
    }
}

/// 收息页「红利买入时机 · 自选打分」卡。对自选与持仓逐只打分，点击进行情详情。
private struct DividendBuyScoreCard: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var targetYieldText: String = UserDefaults.standard.string(forKey: "guanpan.targetYield") ?? "4"
    @State private var methodExpanded = false
    @State private var refreshing = false

    private var targetYield: Decimal { Decimal(string: targetYieldText.trimmingCharacters(in: .whitespaces)) ?? 0 }
    private var today: String { dividendTodayString() }
    private var codes: [String] { Array(Set(model.watch + model.book.positions.map(\.code))).sorted() }
    private var rows: [DividendBuyScore] {
        let target = targetYield
        return codes.compactMap { code -> DividendBuyScore? in
            let events = NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[code] ?? [])).filter { $0.code == code }
            let perShare = NextDividendAnalytics.recentVerifiedPerShare(code: code, events: events, today: today)
            let quote = model.quotes[code]?.quote
            let samples = model.chartData["\(code):day"]?.orderedSamples ?? []
            return DividendBuyScoreEngine.evaluate(code: code, perShare: perShare, price: quote?.price,
                iopv: quote?.iopv, samples: samples, dividendEvents: events,
                today: today, targetYieldPercent: target)
        }.sorted { $0.total > $1.total }
    }
    private var unscoredCount: Int { codes.count - rows.count }
    private var scoredCount: Int { rows.count }
    private var sectionTrailing: String { "\(scoredCount) 只打分" }

    var body: some View {
        EditorialSection(title: "红利买入时机 · 自选打分", trailing: sectionTrailing, accent: p.chartGold) {
            intro
            DisclosureGroup(isExpanded: $methodExpanded) {
                methodPanel
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Capsule().fill(p.chartGold.opacity(0.85)).frame(width: 3, height: 14).offset(y: 1)
                    Text("打分方法").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                    Spacer(minLength: 8)
                    Text("40/35/15/10").font(.caption).foregroundStyle(p.chartGold.opacity(0.85))
                }
            }
            .accentColor(p.forest)
            targetYieldEditor
            if rows.isEmpty {
                GPStatus(title: "暂时没有可打分的标的",
                         detail: "需要近 12 个月有已核实派息、且能取到行情。点「刷新打分数据」拉取派息历史与行情；只用已核实数据，不用推算值冒充。",
                         symbol: "star.slash")
            } else {
                ForEach(rows) { score in
                    DividendBuyScoreRow(score: score, targetYield: targetYield)
                    if score.code != rows.last?.code { Divider().overlay(p.line) }
                }
                if unscoredCount > 0 {
                    Text("另有 \(unscoredCount) 只未打分：近 12 个月没有已核实派息，或暂无行情。")
                        .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            GPActionButton(title: refreshing ? "刷新中…" : "刷新打分数据", secondary: true, systemImage: "arrow.clockwise", action: refresh).disabled(refreshing)
        }
    }

    private var intro: some View {
        Text("价格越跌、股息率越高，分数越高。全部用本机已核实数据现算：近 12 个月每份派息、现价/IOPV、近半年日 K 高低点、近三年分红年份。不预测价格，也不预测分红；只是把「现在适不适合开始关注」拆成可核对的分数。")
            .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
    }

    private var methodPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            GPDataRow(title: "股息率 · 40 分", value: "达到目标股息率拿满", note: "近12个月每份已核实派息 ÷ 现价（ETF 有 IOPV 按净值）；按比例给分")
            GPDataRow(title: "价格位置 · 35 分", value: "越靠区间下沿分越高", note: "现价在近 180 个交易日高低区间中的位置")
            GPDataRow(title: "高点回撤 · 15 分", value: "回撤 20% 拿满", note: "相对近 180 个交易日高点；跌得越深分越高")
            GPDataRow(title: "分红稳定性 · 10 分", value: "3 年 10 / 2 年 7 / 1 年 4", note: "近三个自然年有已核实派息的年份数")
            Text("档位：≥80 值得关注 · 60–79 可分批 · 40–59 观望 · <40 等待。缺数据的项按 0 分计并在行内标注，不拿中性分冒充。")
                .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var targetYieldEditor: some View {
        HStack(spacing: 6) {
            Text("目标股息率 %").font(.caption).foregroundStyle(p.muted)
            TextField("4", text: $targetYieldText).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 64)
                .onChange(of: targetYieldText) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    if let v = Decimal(string: trimmed), v > 0 { UserDefaults.standard.set(NextMoney.text(v, digits: 3), forKey: "guanpan.targetYield") }
                }
            Spacer(minLength: 4)
            Text("改后分数立即重算").font(.caption2).foregroundStyle(p.muted)
        }
    }

    private func refresh() {
        refreshing = true
        Task {
            for security in codes {
                await model.refreshInstrument(security)
                await model.refreshDividendHistory(security)
            }
            refreshing = false
        }
    }
}

private struct DividendBuyScoreRow: View {
    @Environment(\.gp) private var p
    @EnvironmentObject private var model: NextAppModel
    let score: DividendBuyScore
    let targetYield: Decimal

    private var tone: Color {
        switch score.tier {
        case .attention: return p.jade
        case .batch: return p.chartGold
        case .observe: return p.chartBlue
        case .wait: return p.muted
        }
    }
    private var isETF: Bool { NextDividendRules.isOnExchangeETF(score.code) }
    private var name: String {
        let quoted = model.quotes[score.code]?.quote.name ?? ""
        if !quoted.isEmpty, quoted != score.code { return quoted }
        return model.book.positions.first(where: { $0.code == score.code })?.name ?? NextNameBook.resolve(score.code)
    }
    private var yieldBasisText: String { isETF && score.yieldBase != score.price ? "按净值" : "按现价" }
    private var targetPriceText: String {
        guard targetYield > 0 else { return "—" }
        return "¥\(NextMoney.text(score.perShare / (targetYield / 100), digits: 3))"
    }
    private var priceLine: String {
        "现价 ¥\(NextMoney.text(score.price, digits: 3)) · 股息率 \(NextNum.text(score.yieldPercent, digits: 3))%（\(yieldBasisText)）· 目标买入价 \(targetPriceText)"
    }
    private var componentsLine: String {
        "股息率 \(score.yieldPoints)/40 · 位置 \(score.positionPoints)/35 · 回撤 \(score.drawdownPoints)/15 · 稳定 \(score.stabilityPoints)/10"
    }

    var body: some View {
        NavigationLink(value: GPRoute.instrument(score.code)) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink).lineLimit(1)
                    GPPillBadge(text: isETF ? "ETF" : "股票", color: isETF ? p.jade : p.chartBlue)
                    Spacer(minLength: 4)
                    Text("\(score.total) 分").font(.system(.subheadline, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(tone)
                    Text(score.tier.rawValue).font(.caption.weight(.semibold)).foregroundStyle(tone)
                }
                Text(priceLine).font(.caption).foregroundStyle(p.ink).lineLimit(1).minimumScaleFactor(0.8)
                Text(componentsLine).font(.caption2).foregroundStyle(p.muted).lineLimit(1).minimumScaleFactor(0.8)
                if !score.missing.isEmpty {
                    Text("缺 \(score.missing.joined(separator: "、"))，该项按 0 分计")
                        .font(.caption2).foregroundStyle(p.terracotta).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
