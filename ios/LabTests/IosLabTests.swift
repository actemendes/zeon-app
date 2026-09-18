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

    private func record(_ id: String) {
        steps.append(["id": id, "time": Date().timeIntervalSince1970])
        let value: [String: Any] = ["schema": 1, "test": name, "status": "INTERRUPTED", "steps": steps]
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
        guard fixture.targets.count == 2,
              Set(fixture.targets.compactMap { URL(string: $0.url)?.host }).count == 2,
              Set([fixture.directEgress, fixture.serverAEgress, fixture.serverBEgress]).count == 3 else {
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
        try traffic(egress: fixture.directEgress)
    }

    override func tearDownWithError() throws {
        guard !steps.isEmpty else { return }
        if ownsConnection, app != nil {
            if changedServer {
                app.activate()
                app.descendants(matching: .any).matching(identifier: fixture.serverPicker).firstMatch.tap()
                app.staticTexts[fixture.serverA].firstMatch.tap()
                try waitState("connected", seconds: 45)
                try traffic(egress: fixture.serverAEgress)
                changedServer = false
            }
            try stop()
            try traffic(egress: fixture.directEgress)
        }
        record("cleanup_verified")
        let value: [String: Any] = ["schema": 1, "test": name,
            "status": testRun?.failureCount == 0 ? "PASS" : "FAIL", "steps": steps]
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
        throw NSError(domain: "ZEON.IosLab.State", code: 1)
    }

    private func connect() throws {
        ownsConnection = true
        element("disconnected").tap()
        try waitState("connected", seconds: 45)
        record("connected")
        // Keep an observable active window for the host's independent USB probe.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
    }

    private func stop() throws {
        app.activate()
        if element("connected").exists { element("connected").tap() }
        else if element("startingCore").exists { element("startingCore").tap() }
        try waitState("disconnected", seconds: 15)
        ownsConnection = false
        record("disconnected")
    }

    private func traffic(egress: String) throws {
        for target in fixture.targets {
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
            var valid = false
            let task = session.dataTask(with: components.url!) { data, response, error in
                defer { finished.fulfill() }
                guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.host == components.host, let data = data, data.count <= 16384,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
                valid = object["nonce"] == nonce && object["marker"] == target.marker && object["egress"] == egress
            }
            task.resume()
            let result = XCTWaiter.wait(for: [finished], timeout: 13)
            session.invalidateAndCancel()
            guard result == .completed && valid else {
                // Never include response bodies, IPs, URLs or profile names in reports.
                throw NSError(domain: "ZEON.IosLab.Traffic", code: 1)
            }
        }
        record(egress == fixture.directEgress ? "direct_traffic_verified" : "tunnel_traffic_verified")
    }

    func testConnectTrafficDisconnect() throws {
        try connect()
        try traffic(egress: fixture.serverAEgress)
        // UI commands while the tunnel is active exercise the XCTest transport.
        XCUIDevice.shared.press(.home)
        app.activate()
        try waitState("connected", seconds: 10)
        try stop()
        try traffic(egress: fixture.directEgress)
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
        try traffic(egress: fixture.directEgress)
        try connect()
        try traffic(egress: fixture.serverAEgress)
    }

    func testServerAB() throws {
        try connect()
        try traffic(egress: fixture.serverAEgress)
        changedServer = true
        app.descendants(matching: .any).matching(identifier: fixture.serverPicker).firstMatch.tap()
        app.staticTexts[fixture.serverB].firstMatch.tap()
        try waitState("connected", seconds: 45)
        try traffic(egress: fixture.serverBEgress)
        app.descendants(matching: .any).matching(identifier: fixture.serverPicker).firstMatch.tap()
        app.staticTexts[fixture.serverA].firstMatch.tap()
        try waitState("connected", seconds: 45)
        try traffic(egress: fixture.serverAEgress)
        changedServer = false
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
    }

    func testCloseReturn() throws {
        try connect()
        app.terminate()
        try traffic(egress: fixture.serverAEgress)
        app.launchEnvironment.removeValue(forKey: "ZEON_IOS_LAB_DEADLINE")
        app.launch()
        try waitState("connected", seconds: 45)
        try traffic(egress: fixture.serverAEgress)
    }

    func testLeaseExpiry() throws {
        // This is diagnostic evidence, never ordinary-build functional PASS.
        try connect()
        try traffic(egress: fixture.serverAEgress)
        app.terminate()
        while Date() < deadline.addingTimeInterval(5) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        try traffic(egress: fixture.directEgress)
        app.launchEnvironment.removeValue(forKey: "ZEON_IOS_LAB_DEADLINE")
        app.launch()
        try waitState("disconnected", seconds: 15)
        ownsConnection = false
    }
}
