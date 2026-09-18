//
//  PacketTunnelProvider.swift
//  SingBoxPacketTunnel
//
//  Created by GFWFighter on 7/24/1402 AP.
//

import NetworkExtension

class PacketTunnelProvider: ExtensionProvider {
#if ZEON_IOS_LAB
    private var labDeadlineTimer: DispatchSourceTimer?

    private func armLabDeadline() throws {
        let path = FilePath.sharedDirectory.appendingPathComponent("ios-lab-deadline")
        guard let raw = try? String(contentsOf: path, encoding: .utf8),
              let deadline = Double(raw), deadline > Date().timeIntervalSince1970,
              deadline <= Date().timeIntervalSince1970 + 600 else {
            throw NSError(domain: "ZEON.IosLab", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Diagnostic run lease missing or expired"])
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0, deadline - Date().timeIntervalSince1970))
        timer.setEventHandler { [weak self] in
            self?.cancelTunnelWithError(NSError(domain: "ZEON.IosLab", code: 2))
        }
        labDeadlineTimer?.cancel()
        labDeadlineTimer = timer
        timer.resume()
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        labDeadlineTimer?.cancel()
        labDeadlineTimer = nil
        await super.stopTunnel(with: reason)
    }
#endif

    private var upload: Int64 = 0
    private var download: Int64 = 0
    // private var trafficLock: NSLock = NSLock()
    
    // var trafficReader: TrafficReader!
    
    override func startTunnel(options: [String : NSObject]?) async throws {
#if ZEON_IOS_LAB
        try armLabDeadline()
#endif
//    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {

        NSLog("H?C1")
        try await super.startTunnel(options: options)
        /*trafficReader = TrafficReader { [unowned self] traffic in
            trafficLock.lock()
            upload += traffic.up
            download += traffic.down
            trafficLock.unlock()
        }*/
    }
    
    override func handleAppMessage(_ messageData: Data) async -> Data? {
        
        let message = String(data: messageData, encoding: .utf8)
//        NSLog("H?C2"+message??"")
        switch message {
        case "stats":
            return "\(upload),\(download)".data(using: .utf8)!
        default:
            return nil
        }
    }
}
