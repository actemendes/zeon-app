import Foundation
import HiddifyCore
import NetworkExtension

open class ExtensionProvider: NEPacketTunnelProvider {
  public static let errorFile = FilePath.workingDirectory.appendingPathComponent("network_extension_error.log")
  private var platformInterface: ExtensionPlatformInterface!

  override open func startTunnel(options: [String: NSObject]?) async throws {
    try? FileManager.default.removeItem(at: ExtensionProvider.errorFile)
    writeMessage("(packet-tunnel) starting")

    do {
      try createRequiredDirectories()

      if platformInterface == nil {
        platformInterface = ExtensionPlatformInterface(self)
      }

      let disableMemoryLimit = (options?["DisableMemoryLimit"] as? NSString as? String ?? "NO") == "YES"
      let grpcServiceModePort = (options?["GrpcServiceModePort"] as? NSNumber)?.intValue ?? 17179
      let configPath = options?["Config"] as? NSString as? String ?? ""
      guard !configPath.isEmpty else {
        writeFatalError("(packet-tunnel) error: config path is empty")
        return
      }
      let providerConfigPath = try prepareProviderConfig(configPath)

      let opts = MobileSetupOptions()
      opts.basePath = FilePath.sharedDirectory.path
      opts.workingDir = FilePath.workingDirectory.path
      opts.tempDir = FilePath.cacheDirectory.path
      opts.listen = "127.0.0.1:\(grpcServiceModePort)"
      opts.secret = ""
      opts.debug = false
      opts.mode = 4
      opts.fixAndroidStack = false

      var setupError: NSError?
      MobileSetup(opts, platformInterface, &setupError)
      if let setupError {
        throw setupError
      }

      LibboxSetMemoryLimit(!disableMemoryLimit)
      writeMessage("(packet-tunnel) setup completed")

      var startError: NSError?
      MobileStart(providerConfigPath, "", &startError)
      if let startError {
        throw startError
      }
      writeMessage("(packet-tunnel) service started")
    } catch {
      NSLog("Tunnel setup failed: \(error.localizedDescription)")
      writeFatalError("(packet-tunnel) setup failed: \(error.localizedDescription)")
      throw error
    }
  }

  override open func stopTunnel(with reason: NEProviderStopReason) async {
    writeMessage("(packet-tunnel) stopping, reason: \(reason.rawValue)")
    MobileClose(4)
  }

  override open func handleAppMessage(_ messageData: Data) async -> Data? {
    messageData
  }

  override open func wake() {
    MobileWake()
  }

  func reloadService() async throws {
    guard let config = try? String(contentsOf: FilePath.sharedDirectory.appendingPathComponent("config.json")) else {
      return
    }
    var error: NSError?
    MobileStart("", config, &error)
    if let error {
      throw error
    }
  }

  func writeMessage(_ message: String) {
    NSLog("%@", message)
    writeError(message)
  }

  func writeError(_ message: String) {
    let messageWithNewline = "[\(Date())] \(message)\n"
    do {
      try FileManager.default.createDirectory(at: FilePath.workingDirectory, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: ExtensionProvider.errorFile.path) {
        let handle = try FileHandle(forWritingTo: ExtensionProvider.errorFile)
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        if let data = messageWithNewline.data(using: .utf8) {
          handle.write(data)
        }
      } else {
        try messageWithNewline.write(to: ExtensionProvider.errorFile, atomically: true, encoding: .utf8)
      }
    } catch {
      NSLog("Failed to write extension log: \(error.localizedDescription)")
    }
  }

  public func writeFatalError(_ message: String) {
    NSLog("Fatal error: \(message)")
    writeError("FATAL: \(message)")
    cancelTunnelWithError(NSError(domain: "ExtensionProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
  }

  private func createRequiredDirectories() throws {
    for directory in [FilePath.sharedDirectory, FilePath.cacheDirectory, FilePath.workingDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  private func prepareProviderConfig(_ configPath: String) throws -> String {
    guard let defaultInterface = platformInterface.preferredPhysicalInterfaceName() else {
      writeMessage("(packet-tunnel) no physical default interface found; using original config")
      return configPath
    }

    let configURL = URL(fileURLWithPath: configPath)
    let data = try Data(contentsOf: configURL)
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      writeMessage("(packet-tunnel) config is not a JSON object; using original config")
      return configPath
    }

    var route = root["route"] as? [String: Any] ?? [:]
    route["default_interface"] = defaultInterface
    route["auto_detect_interface"] = false
    route.removeValue(forKey: "default_network_strategy")
    route.removeValue(forKey: "default_network_type")
    route.removeValue(forKey: "default_fallback_network_type")
    root["route"] = route

    let preparedData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    let preparedURL = FilePath.workingDirectory.appendingPathComponent("packet-tunnel-config.json")
    try preparedData.write(to: preparedURL, options: .atomic)
    writeMessage("(packet-tunnel) prepared config with default_interface=\(defaultInterface), auto_detect_interface=false")
    return preparedURL.path
  }
}
