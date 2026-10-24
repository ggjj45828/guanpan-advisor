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
                Text("还没有跨市场数据：NAS 归档要先攒起来（每分钟采一次，需要时间）")
                    .font(.system(size: 11)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lunch = pulse.lunchNote {
                Text(lunch)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(p.primaryDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(pulse.footnote)
                .font(.system(size: 9.5)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
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
                Text(pulse.headline)
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(p.muted)
                    .lineLimit(1).minimumScaleFactor(0.75)
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
