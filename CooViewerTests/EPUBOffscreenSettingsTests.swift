import Washi
import XCTest

@testable import cooViewer

/// 電力方針から Washi の画面外方針への写像と、生成ファクトリがいまの方針に従うこと(設計書 §5)
@MainActor
final class EPUBOffscreenSettingsTests: XCTestCase {
    private var originalPolicy = PowerPolicy.default

    override func setUp() async throws {
        await MainActor.run { originalPolicy = PowerStateMonitor.shared.powerPolicy }
    }

    override func tearDown() async throws {
        await MainActor.run { PowerStateMonitor.shared.powerPolicy = originalPolicy }
    }

    /// Washi に「低電力モードだけ」は無いので、全速以外はシステム追従に写す
    func testPowerPolicyMapsToWashiOffscreenEnergyPolicy() {
        let expected: [PowerPolicy: EPUBOffscreenEnergyPolicy] = [
            .lowPowerModeOrThermal: .followSystem,
            .lowPowerModeOnly: .followSystem,
            .alwaysFullSpeed: .unrestricted,
        ]
        XCTAssertEqual(Set(expected.keys), Set(PowerPolicy.allCases))
        for (policy, offscreen) in expected {
            XCTAssertEqual(policy.offscreenEnergyPolicy, offscreen, "\(policy)")
        }
    }

    /// 生成時の値はいまの方針から取り、新しいビューとアトラスに反映される
    func testFactoriesFollowCurrentPowerPolicy() throws {
        let publication = try EPUBPublication(
            data: EPUBAtlasStoreTests.epubData(identifier: "offscreen-policy", body: "本文"),
            displayURL: URL(fileURLWithPath: "/test/offscreen-policy.epub"))
        for policy in PowerPolicy.allCases {
            PowerStateMonitor.shared.powerPolicy = policy
            XCTAssertEqual(EPUBOffscreenSettings.energyPolicy, policy.offscreenEnergyPolicy)

            let view = EPUBOffscreenSettings.makeReaderView()
            defer { view.cancelPageCensus() }
            XCTAssertEqual(view.offscreenEnergyPolicy, policy.offscreenEnergyPolicy, "\(policy)")

            let atlas = EPUBOffscreenSettings.makeAtlas(publication: publication)
            defer { atlas.invalidate() }
            XCTAssertEqual(atlas.offscreenEnergyPolicy, policy.offscreenEnergyPolicy, "\(policy)")
        }
    }
}
