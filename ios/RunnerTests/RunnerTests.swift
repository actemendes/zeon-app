import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

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
