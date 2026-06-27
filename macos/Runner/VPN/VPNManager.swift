import Combine
import Foundation
import NetworkExtension

enum VPNManagerAlertType: String {
  case RequestVPNPermission
  case EmptyConfiguration
  case CreateService
  case StartService
}

struct VPNManagerAlert {
  let alert: VPNManagerAlertType?
  let message: String?
}

class VPNManager: ObservableObject {
  static let shared = VPNManager()

  private var cancelBag: Set<AnyCancellable> = []
  private var observer: NSObjectProtocol?
  private var manager = NETunnelProviderManager()

  @Published private(set) var state: NEVPNStatus = .invalid
  @Published private(set) var alert: VPNManagerAlert = .init(alert: nil, message: nil)

  init() {
    observer = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      guard let connection = notification.object as? NEVPNConnection else { return }
      self?.state = connection.status
    }
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func setup() async throws {
    try await loadVPNPreference()
  }

  private func loadVPNPreference() async throws {
    let providerBundleIdentifier = Bundle.main.baseBundleIdentifier + ".HiddifyPacketTunnel"
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    let matchingManagers = managers.filter {
      ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
    }

    if let existing = matchingManagers.first {
      if matchingManagers.count > 1 {
        NSLog("VPNManager: found \(matchingManagers.count) Packet Tunnel preferences; using the first matching manager")
      }
      manager = existing
      state = existing.connection.status
      return
    }

    let newManager = NETunnelProviderManager()
    let providerProtocol = NETunnelProviderProtocol()
    providerProtocol.providerBundleIdentifier = providerBundleIdentifier
    providerProtocol.serverAddress = "Zeon"
    newManager.protocolConfiguration = providerProtocol
    newManager.localizedDescription = "Zeon"
    newManager.isEnabled = true
    try await newManager.saveToPreferences()
    try await newManager.loadFromPreferences()
    manager = newManager
    state = newManager.connection.status
  }

  private func enableVPNManager() async throws {
    manager.isEnabled = true
    manager.isOnDemandEnabled = false
    manager.onDemandRules = []
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
  }

  func connect(with configPath: String, grpcServiceModePort: Int, disableMemoryLimit: Bool = false) async throws {
    guard !configPath.isEmpty else {
      alert = .init(alert: .EmptyConfiguration, message: "empty VPN configuration path")
      throw NSError(domain: "VPNManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty VPN configuration path"])
    }
    do {
      try await setup()
      try await enableVPNManager()
      try manager.connection.startVPNTunnel(options: [
        "Config": configPath as NSString,
        "GrpcServiceModePort": NSNumber(value: grpcServiceModePort),
        "DisableMemoryLimit": (disableMemoryLimit ? "YES" : "NO") as NSString,
      ])
    } catch {
      alert = .init(alert: .StartService, message: error.localizedDescription)
      throw error
    }
  }

  func disconnect() {
    if manager.isOnDemandEnabled {
      manager.isOnDemandEnabled = false
      manager.onDemandRules = []
      manager.saveToPreferences { error in
        if let error {
          NSLog("VPN save error: \(error.localizedDescription)")
        }
      }
    }
    manager.connection.stopVPNTunnel()
  }

  func reset() {
    disconnect()
    Task {
      let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
      for manager in managers ?? [] {
        try? await manager.removeFromPreferences()
      }
      try? await setup()
    }
  }
}
