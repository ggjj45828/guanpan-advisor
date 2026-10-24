import XCTest
@testable import GuanpanAdvisorCore

/// 源链：优先源优先，但「成功」不等于「够用」。
///
/// 旧行为是第一个不抛错的就返回。问题是只返回两根 K 线的响应在解析层完全合法，
/// 于是能给出几百天历史的备用源根本没机会被调用，而日志里一切正常。
final class NextMarketChainTests: XCTestCase {

    private struct Stub: Error {}

    /// 调用次数计数器：用来证明「优先源够用就不要往后试」。
    private final class Counter: @unchecked Sendable {
        private(set) var hits: [String] = []
        func record(_ name: String) { hits.append(name) }
    }

    func test_preferredSourceThatIsRichEnoughIsUsedImmediately() async throws {
        let counter = Counter()
        let result = try await NextMarketChain.best([
            ("甲", { counter.record("甲"); return 640 }),
            ("乙", { counter.record("乙"); return 900 })
        ], minimum: 60, sampleCount: { $0 })
        XCTAssertEqual(result.value, 640)
        XCTAssertEqual(result.source, "甲", "优先源够用就必须用它，不能被「样本更多」颠倒优先级")
        XCTAssertTrue(result.metMinimum)
        XCTAssertEqual(counter.hits, ["甲"], "够用就该停，不要多发一次请求")
    }

    func test_thinPreferredSourceDoesNotEmptyBlockRicherBackup() async throws {
        let counter = Counter()
        let result = try await NextMarketChain.best([
            ("甲", { counter.record("甲"); return 2 }),
            ("乙", { counter.record("乙"); return 640 })
        ], minimum: 60, sampleCount: { $0 })
        XCTAssertEqual(result.value, 640, "两根 K 线不能挡住 640 根历史")
        XCTAssertEqual(result.source, "乙")
        XCTAssertTrue(result.metMinimum)
        XCTAssertEqual(counter.hits, ["甲", "乙"])
        XCTAssertEqual(result.attempted, ["甲", "乙"])
    }

    func test_failedPreferredSourceFallsThrough() async throws {
        let result = try await NextMarketChain.best([
            ("甲", { throw Stub() }),
            ("乙", { return 300 })
        ], minimum: 60, sampleCount: { $0 })
        XCTAssertEqual(result.source, "乙")
        XCTAssertTrue(result.metMinimum)
    }

    func test_allThinUsesTheRichestAndSaysSo() async throws {
        let result = try await NextMarketChain.best([
            ("甲", { return 3 }),
            ("乙", { return 12 }),
            ("丙", { return 7 })
        ], minimum: 60, sampleCount: { $0 })
        XCTAssertEqual(result.value, 12, "全都不够用时取最完整的，而不是最后一个或第一个")
        XCTAssertEqual(result.source, "乙")
        XCTAssertFalse(result.metMinimum, "必须如实标明没达到最低样本")
        XCTAssertTrue(result.shortfallNote.contains("乙"))
        XCTAssertTrue(result.shortfallNote.contains("低于最低要求"))
    }

    func test_allFailThrowsWithTrail() async {
        do {
            _ = try await NextMarketChain.best([
                ("甲", { throw Stub() }),
                ("乙", { throw Stub() })
            ], minimum: 60, sampleCount: { (value: Int) -> Int in value })
            XCTFail("全部失败必须抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("行情源全部不可用"), error.localizedDescription)
        }
    }

    func test_firstResultKeepsWorkingForQuotes() async throws {
        // 报价没有「样本量」概念，仍然用原来的 first，行为不能被这次改动影响。
        let result = try await NextMarketChain.first([
            ("甲", { return "quote-a" }),
            ("乙", { return "quote-b" })
        ])
        XCTAssertEqual(result.value, "quote-a")
        XCTAssertEqual(result.source, "甲")
    }

    func test_minimumThresholdsAreNotZero() {
        // 门槛设成 0 就等于退回旧的 first 行为，这里钉死它。
        XCTAssertGreaterThan(NextMarketChain.minimumDailyBars, 0)
        XCTAssertGreaterThan(NextMarketChain.minimumIntradayPoints, 0)
        XCTAssertGreaterThanOrEqual(NextMarketChain.minimumDailyBars, 60,
                                    "日 K 少于 60 根算不出可用的长期统计")
    }
}
