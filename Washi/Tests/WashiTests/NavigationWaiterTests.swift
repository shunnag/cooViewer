import WebKit
import XCTest
@testable import Washi

/// NavigationWaiter のキャンセル即応・タイムアウト・単発 resume の検証
/// (WebKit のナビゲーションは起こさず、待機ロジックだけを直接叩く)。
@MainActor
final class NavigationWaiterTests: XCTestCase {
    func testCancellationResolvesPromptly() async throws {
        let waiter = NavigationWaiter()
        let start = ContinuousClock.now
        let task = Task { try await waiter.wait(timeout: .seconds(30)) }
        // 設置される猶予を与えてからキャンセル
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            try await task.value
            XCTFail("キャンセルで throw するはず")
        } catch {
            // 30 秒のタイムアウトを待たず即座に抜けること
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        }
    }

    func testTimeoutFires() async throws {
        let waiter = NavigationWaiter()
        do {
            try await waiter.wait(timeout: .milliseconds(30))
            XCTFail("タイムアウトで throw するはず")
        } catch let error as NavigationWaiter.WaitError {
            guard case .timeout = error else {
                return XCTFail("タイムアウト種別のエラー")
            }
        }
    }

    func testDelegateFinishResolves() async throws {
        let waiter = NavigationWaiter()
        let webView = WKWebView(frame: .zero)
        let task = Task { try await waiter.wait(timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(20))
        waiter.webView(webView, didFinish: nil)  // ナビゲーション完了通知
        try await task.value  // 正常完了(throw しない)
    }

    func testDoubleResumeIsSafe() async throws {
        // タイムアウト後に didFinish が来てもクラッシュしない(単発ガード)
        let waiter = NavigationWaiter()
        do {
            try await waiter.wait(timeout: .milliseconds(20))
        } catch {}
        let webView = WKWebView(frame: .zero)
        waiter.webView(webView, didFinish: nil)  // 二重 resume → no-op
    }
}
