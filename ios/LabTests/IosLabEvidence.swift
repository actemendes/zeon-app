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

    static func attemptCleanup(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return true } catch { return false }
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
        guard let egress = value["egress"], let address = addressBytes(egress) else { return failed("payload") }
        if let expected = expectedEgress, address != addressBytes(expected) { return failed("egress_mismatch") }
        return TrafficCheck(egress: egress, failure: nil)
    }

    static func baselineFailure(egress: String, first: String?, vpnExits: [String]) -> String? {
        guard let address = addressBytes(egress) else { return "payload" }
        if vpnExits.contains(where: { addressBytes($0) == address }) { return "baseline_is_vpn_exit" }
        if let first = first, addressBytes(first) != address { return "baseline_disagreement" }
        return nil
    }

    static func distinctAddresses(_ values: [String]) -> Bool {
        let addresses = values.compactMap(addressBytes)
        return addresses.count == values.count && Set(addresses).count == values.count
    }

    private static func addressBytes(_ value: String) -> Data? {
        var address4 = in_addr()
        var address6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &address4) == 1 }) {
            return Data([4]) + Data(bytes: &address4, count: MemoryLayout<in_addr>.size)
        }
        guard value.withCString({ inet_pton(AF_INET6, $0, &address6) == 1 }) else { return nil }
        let bytes = Data(bytes: &address6, count: MemoryLayout<in6_addr>.size)
        // IPv4-mapped IPv6 denotes the same peer as the plain IPv4 address.
        if bytes.prefix(12) == Data(repeating: 0, count: 10) + Data([255, 255]) {
            return Data([4]) + bytes.suffix(4)
        }
        return Data([6]) + bytes
    }
}
