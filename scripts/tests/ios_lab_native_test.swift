import Foundation

@main
struct IosLabEvidenceTests {
    static func main() throws {
        var count = 0
        func expect(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
        }
        expect(IosLabEvidence.receiptStatus(completed: false, cleanup: true, failures: 0) == "FAIL", "setup failure")
        expect(IosLabEvidence.receiptStatus(completed: true, cleanup: false, failures: 0) == "FAIL", "cleanup missing")
        expect(IosLabEvidence.receiptStatus(completed: true, cleanup: true, failures: 1) == "FAIL", "XCTest failure")
        expect(IosLabEvidence.receiptStatus(completed: true, cleanup: true, failures: 0) == "PASS", "completed")
        expect(IosLabEvidence.attemptCleanup({}), "successful cleanup")
        expect(!IosLabEvidence.attemptCleanup { throw NSError(domain: "synthetic", code: 1) }, "cleanup throw retained")
        let url = URL(string: "https://control.example.invalid/echo")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let valid = ["nonce": "fresh-nonce", "marker": "control", "egress": "192.0.2.1"]
        func check(_ body: [String: String], expected: String? = "192.0.2.1",
                   response: URLResponse? = response, error: Error? = nil) throws -> IosLabEvidence.TrafficCheck {
            IosLabEvidence.traffic(data: try JSONSerialization.data(withJSONObject: body), response: response,
                error: error, host: url.host, marker: "control", nonce: "fresh-nonce", expectedEgress: expected)
        }
        expect(try check(valid).failure == nil, "matching response")
        expect(try check(valid, expected: nil).egress == "192.0.2.1", "discovery retains peer only in memory")
        expect(try check(valid, expected: "192.0.2.2").failure == "egress_mismatch", "wrong exit")
        for key in ["nonce", "marker", "egress"] {
            var body = valid
            body[key] = "invalid"
            expect(try check(body).failure == (key == "egress" ? "payload" : key), "invalid " + key)
        }
        var ipv6 = valid
        ipv6["egress"] = "2001:db8::1"
        expect(try check(ipv6, expected: nil).failure == nil, "valid IPv6")
        expect(try check(ipv6, expected: "2001:db8:0:0:0:0:0:1").failure == nil, "IPv6 identity")
        expect(try check(valid, expected: "::ffff:192.0.2.1").failure == nil, "mapped IPv4 identity")
        expect(IosLabEvidence.baselineFailure(egress: "2001:db8::1", first: nil,
            vpnExits: ["2001:db8:0:0:0:0:0:1"]) == "baseline_is_vpn_exit", "equivalent IPv6 VPN exit")
        expect(IosLabEvidence.baselineFailure(egress: "::ffff:192.0.2.1", first: nil,
            vpnExits: ["192.0.2.1"]) == "baseline_is_vpn_exit", "mapped IPv4 VPN exit")
        expect(IosLabEvidence.baselineFailure(egress: "2001:db8::1", first: "2001:db8:0:0:0:0:0:1",
            vpnExits: ["192.0.2.1"]) == nil, "equivalent baseline replies")
        expect(!IosLabEvidence.distinctAddresses(["2001:db8::1", "2001:db8:0:0:0:0:0:1"]), "duplicate IPv6 exit")
        expect(!IosLabEvidence.distinctAddresses(["192.0.2.1", "::ffff:192.0.2.1"]), "duplicate mapped exit")
        expect(!IosLabEvidence.distinctAddresses(["not-an-address", "192.0.2.1"]), "invalid fixture address")
        expect(IosLabEvidence.distinctAddresses(["192.0.2.1", "192.0.2.2", "2001:db8::1"]), "distinct exits")
        let wrongOrigin = HTTPURLResponse(url: URL(string: "https://other.example.invalid/echo")!,
                                         statusCode: 200, httpVersion: nil, headerFields: nil)!
        expect(try check(valid, response: wrongOrigin).failure == "origin", "redirect origin")
        let unavailable = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
        expect(try check(valid, response: unavailable).failure == "http_status", "HTTP error")
        for (code, reason) in [(URLError.notConnectedToInternet, "network_offline"),
                               (.cannotFindHost, "network_dns"), (.timedOut, "network_timeout"),
                               (.cannotConnectToHost, "network_refused"), (.cancelled, "network_cancelled"),
                               (.serverCertificateUntrusted, "network_tls")] {
            let error = NSError(domain: NSURLErrorDomain, code: code.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "must-not-be-reported"])
            expect(try check(valid, error: error).failure == reason, "bounded network category")
        }
        expect(IosLabEvidence.baselineFailure(egress: "192.0.2.1", first: nil,
                                             vpnExits: ["192.0.2.2", "192.0.2.3"]) == nil, "first direct target")
        expect(IosLabEvidence.baselineFailure(egress: "192.0.2.1", first: "192.0.2.1",
                                             vpnExits: ["192.0.2.2", "192.0.2.3"]) == nil, "targets agree")
        expect(IosLabEvidence.baselineFailure(egress: "192.0.2.4", first: "192.0.2.1",
                                             vpnExits: ["192.0.2.2", "192.0.2.3"]) == "baseline_disagreement", "targets disagree")
        expect(IosLabEvidence.baselineFailure(egress: "192.0.2.2", first: nil,
                                             vpnExits: ["192.0.2.2", "192.0.2.3"]) == "baseline_is_vpn_exit", "baseline cannot be VPN exit")
        print("PASS: \(count) native evidence checks; no device or network used")
    }
}
