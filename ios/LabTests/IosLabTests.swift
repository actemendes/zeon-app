import XCTest
import Foundation

// Runs in the independent .xctrunner application, never in Runner or PacketTunnel.
// Fixture contains only test selectors and public control targets, not VPN secrets.
final class IosLabTests: XCTestCase {
    struct Target: Decodable { let url: String; let marker: String }
    struct Fixture: Decodable {
        let appBundleId: String
        let mode: String
        let targets: [Target]
        let directEgress: String
        let serverAEgress: String
        let serverBEgress: String
        let serverPicker: String
        let homeTab: String
        let serverA: String
        let serverB: String
        let unavailableURL: String
    }
    private var fixture: Fixture!
    private var app: XCUIApplication!
    private var ownsConnection = false
    private var changedServer = false
    private var deadline: Date!
    private var steps = [[String: Any]]()
    private var scenarioCompleted = false
    private var directEgress: String?
    private var trafficFailure: [String: Any]?
    private var uiFailures = [[String: Any]]()
    private var navigationFailure: String?

    private func journal(_ status: String) -> [String: Any] {
        var value: [String: Any] = ["schema": 1, "test": name, "status": status, "steps": steps]
        value["run_id"] = ProcessInfo.processInfo.environment["ZEON_IOS_LAB_RUN_ID"] ?? "missing"
        value["source_sha"] = ProcessInfo.processInfo.environment["ZEON_IOS_LAB_SOURCE_SHA"] ?? "missing"
        if let deadline = deadline { value["lease_deadline"] = deadline.timeIntervalSince1970 }
        if let failure = trafficFailure { value["failure"] = failure }
        if !uiFailures.isEmpty { value["ui_failures"] = uiFailures }
        if let failure = navigationFailure { value["navigation_failure"] = failure }
        return value
    }

    private func record(_ id: String) {
        steps.append(["id": id, "time": Date().timeIntervalSince1970])
        let value = journal("INTERRUPTED")
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: directory.appendingPathComponent("ios-lab-current.json"), options: .atomic)
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 540
        guard let json = ProcessInfo.processInfo.environment["ZEON_IOS_LAB_FIXTURE"] else {
            throw XCTSkip("BLOCKED: isolated test fixture is required")
        }
        fixture = try JSONDecoder().decode(Fixture.self, from: Data(json.utf8))
        directEgress = fixture.directEgress == "discover" ? nil : fixture.directEgress
        guard fixture.targets.count == 2,
              Set(fixture.targets.compactMap { URL(string: $0.url)?.host }).count == 2,
              IosLabEvidence.distinctAddresses([fixture.serverAEgress, fixture.serverBEgress] +
                  (directEgress.map { [$0] } ?? [])) else {
            throw XCTSkip("BLOCKED: two independent targets and distinct egress identities required")
        }
        // Ordinary builds have no autonomous PacketTunnel lease. They must not
        // be labelled safe for unattended controller-loss runs.
        guard fixture.mode == "diagnostic" else {
            throw XCTSkip("BLOCKED: ordinary-build autonomous recovery has not been commissioned")
        }
        let lease = Double(ProcessInfo.processInfo.environment["ZEON_IOS_LAB_LEASE_SECONDS"] ?? "300") ?? 300
        guard lease >= 120 && lease <= 480 else { throw XCTSkip("BLOCKED: invalid run deadline") }
        deadline = Date().addingTimeInterval(lease)
        app = XCUIApplication(bundleIdentifier: fixture.appBundleId)
        app.activate()
        // Preserve a pre-existing user connection; cleanup owns only our Start.
        guard element("disconnected").waitForExistence(timeout: 30) else {
            throw XCTSkip("BLOCKED: target does not have a disconnected baseline")
        }
        app.launchEnvironment["ZEON_IOS_LAB_DEADLINE"] = String(deadline.timeIntervalSince1970)
        app.launch()
        let source = ProcessInfo.processInfo.environment["ZEON_IOS_LAB_SOURCE_SHA"] ?? "missing"
        guard app.windows["zeon.lab.lease." + source].waitForExistence(timeout: 15) else {
            throw XCTSkip("BLOCKED: diagnostic app did not arm the autonomous tunnel lease")
        }
        record("lease_armed")
        try waitState("disconnected", seconds: 45)
        try traffic(egress: directEgress, discoverBaseline: directEgress == nil)
    }

    override func tearDownWithError() throws {
        guard !steps.isEmpty else { return }
        let cleaned = IosLabEvidence.attemptCleanup {
            if ownsConnection, app != nil {
                if changedServer {
                    app.activate()
                    try chooseServer(fixture.serverA)
                    try traffic(egress: fixture.serverAEgress)
                    changedServer = false
                }
                try stop()
                try traffic(egress: directEgress)
            }
        }
        // Cleanup failure must survive in the receipt, not bypass its creation.
        record(cleaned ? "cleanup_verified" : "cleanup_failed")
        let value = journal(IosLabEvidence.receiptStatus(
            completed: scenarioCompleted, cleanup: cleaned, failures: testRun?.failureCount ?? 1))
        let data = try JSONSerialization.data(withJSONObject: value)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "zeon-ios-lab"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try data.write(to: directory.appendingPathComponent("ios-lab-current.json"), options: .atomic)
        }
    }

    private func element(_ state: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "zeon.vpn." + state).firstMatch
    }

    private func waitState(_ state: String, seconds: TimeInterval) throws {
        let limit = Date().addingTimeInterval(seconds)
        while Date() < limit {
            if element(state).exists { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let states = ["idle", "disconnected", "permissionRequired", "startRequested", "startingPlatform",
                      "startingCore", "waitingTun", "verifying", "connected", "stopRequested", "stopping", "failed"]
        uiFailures.append(["expected": state, "observed": states.filter { element($0).exists },
                           "app_alert": app.alerts.firstMatch.exists,
                           "system_alert": XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists])
        record("state_timeout")
        throw NSError(domain: "ZEON.IosLab.State", code: 1)
    }

    private func connect() throws {
        ownsConnection = true
        record("start_requested")
        element("disconnected").tap()
        record("start_tapped")
        try waitState("connected", seconds: 45)
        record("connected")
        try chooseServer(fixture.serverA)
        record("server_a_selected")
        // Keep an observable active window for the host's independent USB probe.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
    }

    private func stop() throws {
        app.activate()
        try returnHome()
        record("stop_requested")
        if element("connected").exists {
            element("connected").tap()
            record("stop_tapped")
        } else if element("startingCore").exists {
            element("startingCore").tap()
            record("stop_tapped")
        }
        try waitState("disconnected", seconds: 15)
        ownsConnection = false
        record("disconnected")
    }

    private func returnHome() throws {
        if element("connected").exists || element("disconnected").exists || element("startingCore").exists {
            return
        }
        let home = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", fixture.homeTab)).firstMatch
        guard home.waitForExistence(timeout: 10) else {
            throw navigationError("home_missing")
        }
        home.tap()
    }

    private func navigationError(_ reason: String) -> NSError {
        navigationFailure = reason
        record("navigation_failed")
        return NSError(domain: "ZEON.IosLab.Navigation", code: 1)
    }

    private func chooseServer(_ tag: String) throws {
        try returnHome()
        let picker = app.descendants(matching: .any).matching(identifier: fixture.serverPicker).firstMatch
        guard picker.waitForExistence(timeout: 10), picker.isHittable else {
            throw navigationError("picker_missing")
        }
        picker.tap()
        record("server_picker_opened")
        let server = app.descendants(matching: .any).matching(identifier: IosLabEvidence.proxyIdentifier(tag)).firstMatch
        _ = server.waitForExistence(timeout: 5)
        for _ in 0..<10 {
            if server.exists && server.isHittable { break }
            app.swipeUp()
        }
        for _ in 0..<20 {
            if server.exists && server.isHittable { break }
            app.swipeDown()
        }
        guard server.exists && server.isHittable else {
            throw navigationError("server_missing")
        }
        record("server_row_found")
        if !server.isSelected {
            server.tap()
            record("server_row_tapped")
        }
        let selected = Date().addingTimeInterval(45)
        while !server.isSelected && Date() < selected {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard server.isSelected else { throw navigationError("selection_timeout") }
        record("server_row_selected")
        try returnHome()
        try waitState("connected", seconds: 45)
    }

    private func traffic(egress: String?, discoverBaseline: Bool = false) throws {
        guard egress != nil || discoverBaseline else {
            throw NSError(domain: "ZEON.IosLab.Fixture", code: 2)
        }
        var discovered: String?
        for (index, target) in fixture.targets.enumerated() {
            let nonce = UUID().uuidString
            var components = URLComponents(string: target.url)!
            guard components.scheme == "https", components.user == nil, components.password == nil else {
                throw NSError(domain: "ZEON.IosLab.Fixture", code: 1)
            }
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "nonce", value: nonce)]
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 12
            let session = URLSession(configuration: configuration)
            let finished = expectation(description: "independent HTTPS response")
            var check = IosLabEvidence.TrafficCheck(egress: nil, failure: "network_timeout")
            let task = session.dataTask(with: components.url!) { data, response, error in
                defer { finished.fulfill() }
                check = IosLabEvidence.traffic(data: data, response: response, error: error,
                    host: components.host, marker: target.marker, nonce: nonce, expectedEgress: egress)
            }
            task.resume()
            let result = XCTWaiter.wait(for: [finished], timeout: 13)
            session.invalidateAndCancel()
            var failure = result == .completed ? check.failure : "network_timeout"
            if failure == nil, discoverBaseline, let actual = check.egress {
                failure = IosLabEvidence.baselineFailure(egress: actual, first: discovered,
                    vpnExits: [fixture.serverAEgress, fixture.serverBEgress])
                discovered = actual
            }
            if let reason = failure {
                trafficFailure = ["reason": reason, "target_index": index + 1]
                if reason == "egress_mismatch", let actual = check.egress {
                    trafficFailure?["observed_exit"] = IosLabEvidence.exitClass(actual, direct: directEgress,
                        a: fixture.serverAEgress, b: fixture.serverBEgress)
                }
                record("traffic_failed")
                throw NSError(domain: "ZEON.IosLab.Traffic", code: 1)
            }
        }
        if discoverBaseline { directEgress = discovered }
        record(discoverBaseline || egress == directEgress ? "direct_traffic_verified" : "tunnel_traffic_verified")
    }

    func testConnectTrafficDisconnect() throws {
        try connect()
        try traffic(egress: fixture.serverAEgress)
        // UI commands while the tunnel is active exercise the XCTest transport.
        XCUIDevice.shared.press(.home)
        app.activate()
        try waitState("connected", seconds: 10)
        try stop()
        try traffic(egress: directEgress)
        scenarioCompleted = true
    }

    func testCancelObserveRetry() throws {
        ownsConnection = true
        element("disconnected").tap()
        guard element("startingCore").waitForExistence(timeout: 10) else {
            throw XCTSkip("BLOCKED: cancellation phase was not observable")
        }
        element("startingCore").tap()
        try waitState("disconnected", seconds: 15)
        let end = Date().addingTimeInterval(150)
        while Date() < end {
            XCTAssertFalse(element("connected").exists, "Late connection after cancel")
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        try traffic(egress: directEgress)
        try connect()
        try traffic(egress: fixture.serverAEgress)
        scenarioCompleted = true
    }

    func testServerAB() throws {
        try connect()
        try traffic(egress: fixture.serverAEgress)
        changedServer = true
        try chooseServer(fixture.serverB)
        try traffic(egress: fixture.serverBEgress)
        try chooseServer(fixture.serverA)
        try traffic(egress: fixture.serverAEgress)
        changedServer = false
        scenarioCompleted = true
    }

    func testUnavailableEndpoint() throws {
        try connect()
        try traffic(egress: fixture.serverAEgress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        let finished = expectation(description: "isolated unavailable endpoint")
        var failed = false
        let url = try XCTUnwrap(URL(string: fixture.unavailableURL))
        XCTAssertEqual(url.scheme, "https")
        session.dataTask(with: url) { _, response, error in
            failed = error != nil || (response as? HTTPURLResponse)?.statusCode == 503
            finished.fulfill()
        }.resume()
        let result = XCTWaiter.wait(for: [finished], timeout: 10)
        session.invalidateAndCancel()
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(failed)
        try traffic(egress: fixture.serverAEgress)
        scenarioCompleted = true
    }

    func testCloseReturn() throws {
        try connect()
        try traffic(egress: fixture.serverAEgress)
        record("app_terminate_requested")
        app.terminate()
        record("app_terminated")
        try traffic(egress: fixture.serverAEgress)
        app.launchEnvironment.removeValue(forKey: "ZEON_IOS_LAB_DEADLINE")
        app.launch()
        record("app_relaunched")
        try waitState("connected", seconds: 45)
        try traffic(egress: fixture.serverAEgress)
        scenarioCompleted = true
    }

    func testLeaseExpiry() throws {
        // This is diagnostic evidence, never ordinary-build functional PASS.
        try connect()
        try traffic(egress: fixture.serverAEgress)
        // Keep the host backgrounded, not force-terminated by XCTest. A tunnel
        // that stops early must not pass merely because it is down at expiry.
        XCUIDevice.shared.press(.home)
        record("app_backgrounded")
        while Date() < deadline.addingTimeInterval(-35) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        try traffic(egress: fixture.serverAEgress)
        record("lease_preexpiry_verified")
        while Date() < deadline.addingTimeInterval(5) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        try traffic(egress: directEgress)
        app.launchEnvironment.removeValue(forKey: "ZEON_IOS_LAB_DEADLINE")
        app.launch()
        record("app_relaunched")
        try waitState("disconnected", seconds: 15)
        ownsConnection = false
        scenarioCompleted = true
    }
}
