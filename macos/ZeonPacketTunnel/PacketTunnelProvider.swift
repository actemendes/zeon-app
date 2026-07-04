import Foundation
import NetworkExtension

class PacketTunnelProvider: ExtensionProvider {
  private var upload: Int64 = 0
  private var download: Int64 = 0

  override func startTunnel(options: [String: NSObject]?) async throws {
    try await super.startTunnel(options: options)
    writeMessage("(packet-tunnel) principal provider startTunnel completed")
  }

  override func handleAppMessage(_ messageData: Data) async -> Data? {
    let message = String(data: messageData, encoding: .utf8)
    switch message {
    case "stats":
      return "\(upload),\(download)".data(using: .utf8)
    default:
      return nil
    }
  }
}
