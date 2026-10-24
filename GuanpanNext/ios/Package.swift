// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GuanpanAdvisorCore", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "GuanpanAdvisorCore", targets: ["GuanpanAdvisorCore"])], targets: [
    .target(name: "GuanpanAdvisorCore", path: "Sources", sources: ["NextCore.swift", "LocalRules.swift", "GlobalIndices.swift", "PortfolioSummary.swift", "InstrumentCatalog.swift", "NextAIGuide.swift", "NextCandidatePlans.swift", "NextDecisionMemory.swift", "NextNewsImpact.swift", "InvestorProfile.swift", "AppThemeCore.swift", "CrossMarket.swift", "CrossMarketReplay.swift", "CrossMarketFeed.swift", "CrossMarketPulse.swift", "CrossMarketReasoning.swift", "CrossMarketLoop.swift", "SignalReplication.swift", "SampleFreshness.swift", "MarketSourceChain.swift"]),
    .testTarget(name: "GuanpanAdvisorCoreTests", dependencies: ["GuanpanAdvisorCore"], path: "Tests")
])
