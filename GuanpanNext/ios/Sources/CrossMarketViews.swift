import SwiftUI

// MARK: - 140 首页「跨市场脉搏」
//
// 五套主题共用这一张卡（不是每套各写一遍）。原因很简单：这个卡上的每一句话都是
// 「事实 + 数据年龄」，颜色只换外观。各主题各写一份，最后一定会有某一套把
// 「已收盘」写成「在线」，就像之前 NAS 那三处硬编码一样。

struct GPCrossMarketPulseCard: View {
    @Environment(\.gp) private var p
    let pulse: NextCrossMarketPulse

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if pulse.hasAnyData {
                ForEach(pulse.rows, id: \.market) { row in
                    rowView(row)
                }
            } else {
                // 没有归档时只留一句，不再下面再补一句「当前没有可用实时数据」——
                // 空状态本来就该短，三行都在说「没有」只会把首屏挤满。
                Text("NAS 还没攒到跨市场快照：每分钟采一次，攒够 \(pulse.minimumDays) 个交易日才谈得上领先关系")
                    .font(.system(size: 11)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lunch = pulse.lunchNote {
                Text(lunch)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(p.primaryDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pulse.hasAnyData {
                Text(pulse.footnote)
                    .font(.system(size: 9.5)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paperAlt, in: RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous)
            .stroke(p.line.opacity(0.5), lineWidth: 0.8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("跨市场脉搏")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 4)
                // 没有数据时不显示「暂无跨市场数据」——下面那句已经说明了，不必重复。
                if pulse.hasAnyData {
                    Text(pulse.headline)
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(p.muted)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            Text(pulse.subtitle)
                .font(.system(size: 10)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rowView(_ row: NextCrossMarketPulseRow) -> some View {
        HStack(spacing: 8) {
            Text(NextCrossMarketPulse.shortName(row.market))
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(p.ink)
                .frame(width: 34, alignment: .leading)
            Text(row.stateText)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(toneColor(row.tone).opacity(row.usable ? 1 : 0.75))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(toneColor(row.tone).opacity(0.12), in: Capsule())
            Spacer(minLength: 4)
            Text(row.priceText)
                .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(p.ink)
                .monospacedDigit()
            Text(row.changeText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(changeColor(row))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
            Text(row.ageText)
                .font(.system(size: 9.5)).foregroundStyle(p.muted)
                .frame(width: 86, alignment: .trailing)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func changeColor(_ row: NextCrossMarketPulseRow) -> Color {
        guard let change = row.changePercent, row.usable else { return p.muted }
        if abs(change) < 0.05 { return p.muted }
        // 涨红跌绿（A股习惯），与全 App 一致
        return change > 0 ? p.risk : p.jade
    }

    private func toneColor(_ tone: NextCrossMarketPulseRow.Tone) -> Color {
        switch tone {
        case .ok: return p.primary
        case .warn: return p.terracotta
        case .idle: return p.muted
        }
    }

    private var accessibilityText: String {
        let rows = pulse.rows.map { "\(NextCrossMarketPulse.shortName($0.market)) \($0.stateText) \($0.changeText) \($0.ageText)" }
        return (["跨市场脉搏", pulse.headline, pulse.subtitle] + rows + [pulse.footnote]).joined(separator: "，")
    }
}

// MARK: - 141 持仓详情「外部市场影响」

struct GPAbroadImpactSection: View {
    @Environment(\.gp) private var p
    let impact: NextHoldingAbroadImpact

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("外部市场影响")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 4)
                Text(impact.hasStableLead ? "已验证" : "暂无稳定关系")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(impact.hasStableLead ? p.primary : p.muted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((impact.hasStableLead ? p.primary : p.muted).opacity(0.12), in: Capsule())
            }
            ForEach(Array(impact.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paperAlt, in: RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous)
            .stroke(p.line.opacity(0.5), lineWidth: 0.8))
    }
}

// MARK: - 145 完整推理链
//
// 这一块不产生任何新数字，只把「结论是怎么一步步走到这里的」摊开：
// 每一步给出「通过 / 仅背景 / 断开」，断在哪一步就停在哪一步。
// 排序即优先级：前面断了，后面的好看数据都不作数。

struct GPReasoningChainCard: View {
    @Environment(\.gp) private var p
    let chain: NextReasoningChain

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("推理链")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 4)
                Text(chain.allowsAction ? "链条完整" : "链条断开")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(chain.allowsAction ? p.risk : p.muted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((chain.allowsAction ? p.risk : p.muted).opacity(0.12), in: Capsule())
            }
            ForEach(Array(chain.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: Self.symbol(step.gate))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Self.color(step.gate, p))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.stage)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Self.color(step.gate, p))
                        Text(step.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(p.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(chain.verdict)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(chain.allowsAction ? p.risk : p.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paperAlt, in: RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous)
            .stroke(p.line.opacity(0.5), lineWidth: 0.8))
        .accessibilityIdentifier("crossmarket.reasoningchain")
    }

    static func symbol(_ gate: NextReasoningStep.Gate) -> String {
        switch gate {
        case .pass: return "checkmark.circle"
        case .background: return "circle.dashed"
        case .blocked: return "xmark.circle"
        }
    }

    static func color(_ gate: NextReasoningStep.Gate, _ p: GPPalette) -> Color {
        switch gate {
        case .pass: return p.jade
        case .background: return p.muted
        case .blocked: return p.terracotta
        }
    }
}

// MARK: - 闭环（129/139）
//
// 一张卡回答「今天这条链走到了哪、最后决定做什么」。
// 「不交易」是正式结论，和「做T」一样占一个位置，不用灰字当免责声明。

struct GPLoopCard: View {
    @Environment(\.gp) private var p
    let outcome: NextLoopOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("跨市场闭环")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 4)
                Text(outcome.gate.label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(gateColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(gateColor.opacity(0.12), in: Capsule())
            }
            Text(outcome.gate.reason)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(p.ink)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(outcome.explanation.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10.5)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paperAlt, in: RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous)
            .stroke(p.line.opacity(0.5), lineWidth: 0.8))
        .accessibilityIdentifier("crossmarket.loop")
    }

    private var gateColor: Color {
        switch outcome.gate {
        case .doT: return p.risk
        case .grid: return p.primary
        case .noTrade: return p.muted
        }
    }
}

// MARK: - 146 历史回放验证器（研究工具，不是模拟账户）
//
// 这个页面只说一件事：把某一天 12:50 之前能看到的证据交给规则，等 13:00 之后的真实行情出来，
// 看那条假设有没有被证实。所以它没有份额、没有成本、没有盈亏——**它不是一个账户**。
// 结论由 `NextReplayEngine` 给，页面照抄：数据不够时就显示「没有稳定领先关系」。

struct GPReplayLabView: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @Environment(\.dismiss) private var dismiss
    let code: String
    @State private var days = 60

    private var report: NextReplayReport? { model.replayReports[code] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    intro
                    controls
                    if let report {
                        verdictCard(report)
                        dayList(report)
                    } else {
                        emptyHint
                    }
                }
                .padding(14)
            }
            .background(p.canvas)
            .navigationTitle("历史回放验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }.foregroundStyle(p.primary)
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("这条规矩会被这样检验")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
            Text("每个交易日只允许看到 12:50 之前的行情：若海外午休期间在修复、且 A股 上午已经下跌，就提出「午后修复」的假设；再把 13:00 之后的真实行情放出来，看 A股 有没有站回上午收盘价。")
                .font(.system(size: 11)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("它不会产生任何订单、份额或盈亏；样本不足 30 天一律写「没有稳定领先关系」。")
                .font(.system(size: 10.5)).foregroundStyle(p.terracotta)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paperAlt, in: RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("区间", selection: $days) {
                Text("30 天").tag(30)
                Text("60 天").tag(60)
                Text("120 天").tag(120)
            }
            .pickerStyle(.segmented)
            Button {
                Task { await model.runReplayLab(for: code, days: days) }
            } label: {
                HStack(spacing: 4) {
                    if model.replayRunning { ProgressView().controlSize(.mini) }
                    Text(model.replayRunning ? "回放中" : "开始回放")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(p.paper)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(p.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.replayRunning)
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("还没跑过").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink)
            Text("回放要先从 NAS 取这只标的多日分钟线。有持仓但归档不足时，结论会直接写「没有稳定领先关系」——那也是有用的答案。")
                .font(.system(size: 11)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paperAlt, in: RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous))
    }

    private func verdictCard(_ report: NextReplayReport) -> some View {
        let isEvidence: Bool = {
            if case .evidence = report.verdict { return true }
            return false
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text(isEvidence ? "这段历史的结论" : "这段历史的结论：不成立")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink)
            Text(report.verdict.headline)
                .font(.system(size: 12)).foregroundStyle(isEvidence ? p.primaryDeep : p.terracotta)
                .fixedSize(horizontal: false, vertical: true)
            Text("共 \(report.results.count) 个交易日 · 提出假设 \(report.hypothesisCount) 次 · 确认 \(report.confirmedCount) 次")
                .font(.system(size: 10)).foregroundStyle(p.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paperAlt, in: RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous)
            .stroke((isEvidence ? p.primary : p.terracotta).opacity(0.35), lineWidth: 0.8))
    }

    private func dayList(_ report: NextReplayReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("逐日结果").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink)
            ForEach(Array(report.results.suffix(20).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(GPReplayLabView.dayText(item.date))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                        .frame(width: 52, alignment: .leading)
                    Text(item.outcome.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(GPReplayLabView.color(item.outcome, p))
                        .frame(width: 68, alignment: .leading)
                    Text(item.note)
                        .font(.system(size: 10)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paperAlt, in: RoundedRectangle(cornerRadius: p.tokens.cardRadius, style: .continuous))
    }

    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }

    static func color(_ outcome: NextReplayOutcome, _ p: GPPalette) -> Color {
        switch outcome {
        case .confirmedFollowThrough: return p.risk      // 涨用红
        case .confirmedFailed: return p.jade             // 跌用绿
        case .rejectedNoConfirmation: return p.terracotta
        case .noHypothesis: return p.muted
        }
    }
}
