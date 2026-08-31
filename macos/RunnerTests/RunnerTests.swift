import Cocoa
import FlutterMacOS
import XCTest

@testable import ZEON

class RunnerTests: XCTestCase {

  func testSessionGenerationIsMonotonic() {
    let fence = MacVPNLifecycleFence()

    XCTAssertEqual(fence.setSessionGeneration(42, requestedAction: .connect), 42)
    XCTAssertEqual(fence.setSessionGeneration(41, requestedAction: .connect), 42)
    XCTAssertTrue(fence.isCurrentGeneration(42))
    XCTAssertFalse(fence.isCurrentGeneration(41))
  }

  func testSameGenerationStopCancelsPendingStartPermitAtPostAwaitCheckpoint() {
    let fence = MacVPNLifecycleFence()
    XCTAssertEqual(fence.setSessionGeneration(42, requestedAction: .connect), 42)
    let pendingStart = try! XCTUnwrap(fence.startPermit(for: 42))

    XCTAssertTrue(fence.markStop(generation: 42, replacement: false))

    var invokedStartTunnel = false
    let started = fence.performIfStartAuthorized(pendingStart) {
      invokedStartTunnel = true
    }
    let stopped = fence.snapshot()
    XCTAssertFalse(started)
    XCTAssertFalse(invokedStartTunnel)
    XCTAssertFalse(fence.isStartAuthorized(pendingStart))
    XCTAssertEqual(stopped.requestedAction, .stop)
    XCTAssertEqual(stopped.stopTombstoneGeneration, 42)
    XCTAssertEqual(stopped.stopSource, .terminal)
    XCTAssertGreaterThan(stopped.actionRevision, pendingStart.actionRevision)
  }

  func testSameGenerationConnectCannotClearAcceptedStopTombstone() {
    let fence = MacVPNLifecycleFence()
    XCTAssertEqual(fence.setSessionGeneration(42, requestedAction: .connect), 42)
    XCTAssertTrue(fence.markStop(generation: 42, replacement: false))

    XCTAssertEqual(fence.setSessionGeneration(42, requestedAction: .connect), 42)

    XCTAssertNil(fence.startPermit(for: 42))
    XCTAssertEqual(fence.snapshot().requestedAction, .stop)
    XCTAssertEqual(fence.snapshot().stopTombstoneGeneration, 42)
  }

  func testReplacementStopInvalidatesOlderPermitAndAllowsSubsequentStart() {
    let fence = MacVPNLifecycleFence()
    XCTAssertEqual(fence.setSessionGeneration(42, requestedAction: .connect), 42)
    let olderPendingStart = try! XCTUnwrap(fence.startPermit(for: 42))

    XCTAssertTrue(fence.markStop(generation: 42, replacement: true))

    XCTAssertFalse(fence.isStartAuthorized(olderPendingStart))
    XCTAssertEqual(fence.snapshot().requestedAction, .stop)
    XCTAssertEqual(fence.snapshot().stopSource, .replacement)
    let replacementStart = try! XCTUnwrap(fence.startPermit(for: 42))
    XCTAssertTrue(fence.isStartAuthorized(replacementStart))
    XCTAssertGreaterThan(replacementStart.actionRevision, olderPendingStart.actionRevision)
    XCTAssertEqual(fence.snapshot().requestedAction, .connect)
    XCTAssertNil(fence.snapshot().stopTombstoneGeneration)
    XCTAssertEqual(fence.snapshot().stopSource, .none)
  }

  func testReplacementCannotDowngradeTerminalStopTombstone() {
    let fence = MacVPNLifecycleFence()
    XCTAssertEqual(fence.setSessionGeneration(42, requestedAction: .connect), 42)
    XCTAssertTrue(fence.markStop(generation: 42, replacement: false))

    XCTAssertTrue(fence.markStop(generation: 42, replacement: true))

    XCTAssertNil(fence.startPermit(for: 42))
    XCTAssertEqual(fence.snapshot().stopSource, .terminal)
  }

  func testNewerGenerationClearsOlderStopTombstone() {
    let fence = MacVPNLifecycleFence()
    XCTAssertEqual(fence.setSessionGeneration(42, requestedAction: .connect), 42)
    XCTAssertTrue(fence.markStop(generation: 42, replacement: false))

    XCTAssertEqual(fence.setSessionGeneration(43, requestedAction: .connect), 43)

    XCTAssertNotNil(fence.startPermit(for: 43))
    XCTAssertNil(fence.snapshot().stopTombstoneGeneration)
  }

  func testPreparationCanOnlyPromoteToConnectBeforeStop() {
    let fence = MacVPNLifecycleFence()
    XCTAssertEqual(fence.setSessionGeneration(42, requestedAction: .prepare), 42)
    XCTAssertNil(fence.startPermit(for: 42))

    XCTAssertEqual(fence.setSessionGeneration(42, requestedAction: .connect), 42)
    XCTAssertNotNil(fence.startPermit(for: 42))

    XCTAssertTrue(fence.markStop(generation: 42, replacement: false))
    XCTAssertEqual(fence.setSessionGeneration(42, requestedAction: .connect), 42)
    XCTAssertNil(fence.startPermit(for: 42))
  }

}
