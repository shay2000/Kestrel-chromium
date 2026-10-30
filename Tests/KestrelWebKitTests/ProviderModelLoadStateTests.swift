#if canImport(SwiftUI)
import XCTest
@testable import KestrelWebKit

final class ProviderModelLoadStateTests: XCTestCase {
    @MainActor func testSlowPreviousProviderCannotOverwriteTheNewCatalogue() async {
        let state = ProviderModelLoadState()
        let started = expectation(description: "Old fetch started")
        var resume: CheckedContinuation<[ProviderModel], Error>?
        let old = Task {
            await state.load {
                try await withCheckedThrowingContinuation { resume = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let current = ProviderModel(id: "new", name: "New model")
        await state.load { [current] }
        resume?.resume(returning: [ProviderModel(id: "old", name: "Old model")])
        let stale = await old.value
        XCTAssertNil(stale, "A stale catalogue must not be cached")
        XCTAssertEqual(state.models.map(\.id), ["new"])
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.errorText)
    }

    @MainActor func testStaleFailureCannotReplaceACachedProvider() async {
        let state = ProviderModelLoadState()
        let started = expectation(description: "Old fetch started")
        var resume: CheckedContinuation<[ProviderModel], Error>?
        let old = Task {
            await state.load {
                try await withCheckedThrowingContinuation { resume = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        state.useCached([ProviderModel(id: "cached", name: "Cached model")])
        resume?.resume(throwing: AIProviderError.notConfigured("Previous provider failed"))
        _ = await old.value
        XCTAssertEqual(state.models.map(\.id), ["cached"])
        XCTAssertNil(state.errorText)
        XCTAssertFalse(state.isLoading)
    }

    @MainActor func testFailureEndsLoadingAndAllowsRetry() async {
        let state = ProviderModelLoadState()
        await state.load { throw AIProviderError.notConfigured("Connection unavailable") }
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.errorText?.contains("Connection unavailable") == true)
        XCTAssertTrue(state.models.isEmpty)
        await state.load { [ProviderModel(id: "retry", name: "Retry model")] }
        XCTAssertNil(state.errorText)
        XCTAssertEqual(state.models.map(\.id), ["retry"])
    }
}
#endif
