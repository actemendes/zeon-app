import Foundation
import Darwin

enum IosLabEvidence {
    struct TrafficCheck {
        let egress: String?
        let failure: String?
    }

    static func receiptStatus(completed: Bool, cleanup: Bool, failures: Int) -> String {
        completed && cleanup && failures == 0 ? "PASS" : "FAIL"
    }

    static func traffic(data: Data?, response: URLResponse?, error: Error?,
                        host: String?, marker: String, nonce: String,
                        expectedEgress: String?) -> TrafficCheck {
        func failed(_ reason: String) -> TrafficCheck { TrafficCheck(egress: nil, failure: reason) }
        if let error = error as NSError? {
            guard error.domain == NSURLErrorDomain else { return failed("network_other") }
            switch URLError.Code(rawValue: error.code) {
            case .notConnectedToInternet: return failed("network_offline")
            case .cannotFindHost, .dnsLookupFailed: return failed("network_dns")
            case .timedOut: return failed("network_timeout")
            case .cannotConnectToHost: return failed("network_refused")
            case .cancelled: return failed("network_cancelled")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return failed("network_tls")
            default: return failed("network_other")
            }
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return failed("http_status") }
        guard http.url?.scheme == "https", http.url?.host == host else { return failed("origin") }
        guard let data = data, data.count <= 16384,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return failed("payload")
        }
        guard value["nonce"] == nonce else { return failed("nonce") }
        guard value["marker"] == marker else { return failed("marker") }
        guard let egress = value["egress"], isIPAddress(egress) else { return failed("payload") }
        if let expected = expectedEgress, egress != expected { return failed("egress_mismatch") }
        return TrafficCheck(egress: egress, failure: nil)
    }

    static func baselineFailure(egress: String, first: String?, vpnExits: [String]) -> String? {
        if vpnExits.contains(egress) { return "baseline_is_vpn_exit" }
        if let first = first, first != egress { return "baseline_disagreement" }
        return nil
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var address4 = in_addr()
        var address6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address4) == 1 || inet_pton(AF_INET6, $0, &address6) == 1 }
    }
}
