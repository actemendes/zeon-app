import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testStaleStopReturnsIntegerGenerationWithoutStoppingUserTunnel() {
    let manager = VPNManager.shared
    let current = manager.currentSessionGeneration() + 10
    XCTAssertEqual(manager.setSessionGeneration(current), current)
    let finished = expectation(description: "typed stop reply")
    MethodHandler().handle(FlutterMethodCall(methodName: "stop", arguments: ["generation": current - 1])) { value in
      guard let reply = value as? NSNumber else {
        XCTFail("Stop must return an integer generation")
        finished.fulfill()
        return
      }
      XCTAssertNotEqual(CFGetTypeID(reply), CFBooleanGetTypeID())
      XCTAssertEqual(reply.int64Value, current)
      finished.fulfill()
    }
    wait(for: [finished], timeout: 2)
  }

  func testSessionGenerationIsMonotonic() {
    let manager = VPNManager.shared
    let next = manager.currentSessionGeneration() + 10

    XCTAssertEqual(manager.setSessionGeneration(next), next)
    XCTAssertTrue(manager.isCurrentGeneration(next))
    XCTAssertEqual(manager.setSessionGeneration(next - 1), next)
    XCTAssertFalse(manager.isCurrentGeneration(next - 1))
  }

  func testNewGenerationCannotInheritCoreReadiness() {
    let manager = VPNManager.shared
    let next = manager.currentSessionGeneration() + 10

    XCTAssertEqual(manager.setSessionGeneration(next), next)
    XCTAssertFalse(manager.isCoreReadyForCurrentGeneration())
  }

}
