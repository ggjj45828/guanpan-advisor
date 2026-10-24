import Foundation

// MARK: - 150 源链：优先源优先，但「成功」不等于「够用」
//
// 放在 Core 而不是网络层，是为了让「选源规则」本身可以被单元测试覆盖：
// 选源逻辑出错的代价是长期缺数据，而且日志里看不出异常。
//
// 旧行为是第一个不抛错的就返回。问题是：只返回两根 K 线的响应在解析层完全合法，
// 于是能给出几百天历史的备用源根本没机会被调用。

enum NextMarketChain {
    /// 日 K 最低样本 60 根。少于这个数，均线、振幅分位、网格区间全都算不准。
    static let minimumDailyBars = 60
    /// 分时最低样本 30 个点。
    /// 刻意不设成「一整天 240 点」：盘中刚开始时本来就没那么多，
    /// 按全天算会导致每次刷新都白跑一遍备用源。30 点足以识别「只返回两个点」的降级响应。
    static let minimumIntradayPoints = 30

    /// 顺序尝试，第一个成功就返回。用于没有「样本量」概念的接口，例如报价。
    static func first<T>(_ attempts: [(source: String, run: () async throws -> T)]) async throws -> (value: T, source: String) {
        var failures: [(source: String, reason: String)] = []
        for attempt in attempts {
            do { return (try await attempt.run(), attempt.source) }
            catch { failures.append((attempt.source, error.localizedDescription)) }
        }
        let trail = failures.map { "\($0.source)（\($0.reason)）" }.joined(separator: " → ")
        throw NextError.invalid("行情源全部不可用：\(trail)")
    }

    /// 顺序尝试，但**成功不等于够用**。
    ///
    /// 规则：
    /// 1. 仍然按来源优先级顺序试；
    /// 2. 优先源样本够（≥ minimum）→ 立刻用，不多发请求；
    /// 3. 优先源成功但不够 → 继续往后试，第一个够用的胜出；
    /// 4. 全都不够 → 取样本最多的那个，并如实标明「没达到最低样本」。
    ///
    /// 既保住来源优先级，也不让残缺响应挡住更完整的历史。
    static func best<T>(_ attempts: [(source: String, run: () async throws -> T)],
                        minimum: Int,
                        sampleCount: (T) -> Int) async throws -> NextChainResult<T> {
        var champion: (value: T, source: String, count: Int)?
        var failures: [(source: String, reason: String)] = []
        var attempted: [String] = []
        for attempt in attempts {
            attempted.append(attempt.source)
            do {
                let value = try await attempt.run()
                let count = sampleCount(value)
                if champion == nil || count > champion!.count {
                    champion = (value, attempt.source, count)
                }
                // 第一个够用的就停：优先源够用时不浪费一次网络请求。
                if count >= minimum {
                    return NextChainResult(value: value, source: attempt.source, sampleCount: count,
                                           metMinimum: true, attempted: attempted)
                }
            } catch {
                failures.append((attempt.source, error.localizedDescription))
            }
        }
        if let champion {
            return NextChainResult(value: champion.value, source: champion.source,
                                   sampleCount: champion.count, metMinimum: false, attempted: attempted)
        }
        let trail = failures.map { "\($0.source)（\($0.reason)）" }.joined(separator: " → ")
        throw NextError.invalid("行情源全部不可用：\(trail)")
    }
}

/// 源链结果。除了「拿到什么」，还要说清「够不够」——
/// 调用方需要能区分「拿到了 3 根日 K」和「拿到了 640 根日 K」。
struct NextChainResult<T> {
    let value: T
    let source: String
    let sampleCount: Int
    /// 是否达到调用方要求的最低样本量。false 时数据可以用，但不能当长期统计的依据。
    let metMinimum: Bool
    /// 实际尝试过的来源，按顺序。用来解释「为什么最后用的是备用源」。
    let attempted: [String]

    /// 没达最低样本时给用户的一句话。达标时为空。
    var shortfallNote: String {
        guard !metMinimum else { return "" }
        return "\(source) 只返回 \(sampleCount) 个样本，低于最低要求；已尝试 \(attempted.joined(separator: " → "))"
    }
}
