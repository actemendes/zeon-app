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

enum MacVPNLifecycleAction: String {
  case none = ""
  case prepare
  case connect
  case stop
}

enum MacVPNStopSource: String {
  case none = ""
  case replacement
  case terminal
}

struct MacVPNStartPermit: Equatable {
  let generation: Int64
  let actionRevision: UInt64
}

struct MacVPNLifecycleSnapshot: Equatable {
  let generation: Int64
  let requestedAction: MacVPNLifecycleAction
  let actionRevision: UInt64
  let stopTombstoneGeneration: Int64?
  let stopSource: MacVPNStopSource
}

/// Serializes lifecycle ownership independently from NetworkExtension I/O.
///
/// A generation alone cannot fence a delayed Start because failure cleanup can
/// issue Stop with the same generation. Each Start therefore captures the
/// current action revision and must still own that exact permit after every
/// suspension point and while `startVPNTunnel` is invoked. Replacement Stop is
/// a consumable tombstone: it invalidates older permits but lets the next Start
/// at that generation create a fresh permit. An ordinary Stop is terminal.
final class MacVPNLifecycleFence {
  private let lock = NSLock()
  private var generation: Int64 = 0
  private var requestedAction: MacVPNLifecycleAction = .none
  private var actionRevision: UInt64 = 0
  private var stopTombstoneGeneration: Int64?
  private var stopSource: MacVPNStopSource = .none

  @discardableResult
  func setSessionGeneration(
    _ nextGeneration: Int64,
    requestedAction nextAction: MacVPNLifecycleAction
  ) -> Int64 {
    lock.lock()
    defer { lock.unlock() }

    guard nextGeneration > 0 else { return generation }
    if nextGeneration > generation {
      generation = nextGeneration
      requestedAction = nextAction
      stopTombstoneGeneration = nil
      stopSource = .none
      actionRevision &+= 1
    } else if nextGeneration == generation,
      nextAction == .connect,
      requestedAction == .prepare,
      stopTombstoneGeneration != nextGeneration
    {
      // Preparation and its subsequent user Start share one generation. This
      // is the only legal same-generation action promotion.
      requestedAction = .connect
      actionRevision &+= 1
    }
    return generation
  }

  func currentGeneration() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }

  func isCurrentGeneration(_ candidate: Int64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return candidate > 0 && candidate == generation
  }

  func isCurrentConnectGeneration(_ candidate: Int64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return isConnectAuthorizedLocked(generation: candidate)
  }

  func startPermit(for candidate: Int64) -> MacVPNStartPermit? {
    lock.lock()
    defer { lock.unlock() }
    if candidate > 0,
      candidate == generation,
      requestedAction == .stop,
      stopTombstoneGeneration == candidate,
      stopSource == .replacement
    {
      // A replacement Stop belongs to the Start that follows it. Consume that
      // tombstone atomically so only a newly-entering Start can continue; any
      // permit captured before the replacement remains invalidated.
      requestedAction = .connect
      stopTombstoneGeneration = nil
      stopSource = .none
      actionRevision &+= 1
    }
    guard isConnectAuthorizedLocked(generation: candidate) else { return nil }
    return MacVPNStartPermit(generation: candidate, actionRevision: actionRevision)
  }

  func isStartAuthorized(_ permit: MacVPNStartPermit) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return isStartAuthorizedLocked(permit)
  }

  /// Holds the lifecycle lock through the synchronous NetworkExtension start
  /// handoff. Therefore either Start wins first and a following Stop tears it
  /// down, or Stop installs its tombstone first and the handoff is skipped.
  @discardableResult
  func performIfStartAuthorized(
    _ permit: MacVPNStartPermit,
    operation: () throws -> Void
  ) rethrows -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard isStartAuthorizedLocked(permit) else { return false }
    try operation()
    return true
  }

  @discardableResult
  func markStop(generation candidate: Int64, replacement: Bool) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard candidate > 0, candidate == generation else { return false }

    let nextStopSource: MacVPNStopSource = replacement ? .replacement : .terminal
    let terminalStopAlreadyOwnsGeneration =
      requestedAction == .stop && stopTombstoneGeneration == candidate && stopSource == .terminal
    if !terminalStopAlreadyOwnsGeneration
      && (requestedAction != .stop || stopTombstoneGeneration != candidate
        || stopSource != nextStopSource)
    {
      requestedAction = .stop
      stopTombstoneGeneration = candidate
      stopSource = nextStopSource
      actionRevision &+= 1
    }
    return true
  }

  func snapshot() -> MacVPNLifecycleSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return MacVPNLifecycleSnapshot(
      generation: generation,
      requestedAction: requestedAction,
      actionRevision: actionRevision,
      stopTombstoneGeneration: stopTombstoneGeneration,
      stopSource: stopSource
    )
  }

  private func isConnectAuthorizedLocked(generation candidate: Int64) -> Bool {
    candidate > 0 && candidate == generation && requestedAction == .connect
      && stopTombstoneGeneration != candidate
  }

  private func isStartAuthorizedLocked(_ permit: MacVPNStartPermit) -> Bool {
    isConnectAuthorizedLocked(generation: permit.generation)
      && permit.actionRevision == actionRevision
  }
}

class VPNManager: ObservableObject {
  static let shared = VPNManager()

  private var cancelBag: Set<AnyCancellable> = []
  private let lifecycleFence = MacVPNLifecycleFence()
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

  /// Accepts monotonically increasing lifecycle generations from Flutter.
  /// macOS still publishes legacy status events, but it must fence start/stop
  /// method calls with the same generation contract as the other platforms.
  @discardableResult
  func setSessionGeneration(
    _ generation: Int64,
    requestedAction: MacVPNLifecycleAction = .connect
  ) -> Int64 {
    lifecycleFence.setSessionGeneration(generation, requestedAction: requestedAction)
  }

  func currentSessionGeneration() -> Int64 {
    lifecycleFence.currentGeneration()
  }

  func isCurrentSessionGeneration(_ generation: Int64) -> Bool {
    lifecycleFence.isCurrentGeneration(generation)
  }

  func isCurrentConnectSessionGeneration(_ generation: Int64) -> Bool {
    lifecycleFence.isCurrentConnectGeneration(generation)
  }

  private func loadVPNPreference() async throws {
    let providerBundleIdentifier = Bundle.main.baseBundleIdentifier + ".ZeonPacketTunnel"
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

  private func enableVPNManager(
    configPath: String,
    grpcServiceModePort: Int,
    disableMemoryLimit: Bool,
    generation: Int64,
    startPermit: MacVPNStartPermit
  ) async throws {
    manager.isEnabled = true
    manager.isOnDemandEnabled = false
    manager.onDemandRules = []
    if let providerProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol {
      providerProtocol.providerConfiguration = [
        "Config": configPath,
        "GrpcServiceModePort": grpcServiceModePort,
        "DisableMemoryLimit": disableMemoryLimit ? "YES" : "NO",
        "Generation": generation,
      ]
      manager.protocolConfiguration = providerProtocol
    }
    try await manager.saveToPreferences()
    guard lifecycleFence.isStartAuthorized(startPermit) else { throw staleGenerationError() }
    try await manager.loadFromPreferences()
    guard lifecycleFence.isStartAuthorized(startPermit) else { throw staleGenerationError() }
  }

  func connect(
    with configPath: String,
    grpcServiceModePort: Int,
    disableMemoryLimit: Bool = false,
    generation: Int64
  ) async throws {
    guard !configPath.isEmpty else {
      alert = .init(alert: .EmptyConfiguration, message: "empty VPN configuration path")
      throw NSError(domain: "VPNManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty VPN configuration path"])
    }
    do {
      guard let startPermit = lifecycleFence.startPermit(for: generation) else {
        throw staleGenerationError()
      }
      try await setup()
      guard lifecycleFence.isStartAuthorized(startPermit) else { throw staleGenerationError() }
      try await enableVPNManager(
        configPath: configPath,
        grpcServiceModePort: grpcServiceModePort,
        disableMemoryLimit: disableMemoryLimit,
        generation: generation,
        startPermit: startPermit
      )
      guard lifecycleFence.isStartAuthorized(startPermit) else { throw staleGenerationError() }
      let started = try lifecycleFence.performIfStartAuthorized(startPermit) {
        try manager.connection.startVPNTunnel(options: [
          "Config": configPath as NSString,
          "GrpcServiceModePort": NSNumber(value: grpcServiceModePort),
          "DisableMemoryLimit": (disableMemoryLimit ? "YES" : "NO") as NSString,
          "Generation": NSNumber(value: generation),
        ])
      }
      guard started else { throw staleGenerationError() }
    } catch {
      if !isStaleGenerationError(error) {
        alert = .init(alert: .StartService, message: error.localizedDescription)
      }
      throw error
    }
  }

  @discardableResult
  func disconnect(generation: Int64, replacement: Bool = false) -> Bool {
    guard lifecycleFence.markStop(generation: generation, replacement: replacement) else {
      return false
    }
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
    return true
  }

  func reset() {
    let generation = currentSessionGeneration()
    if generation > 0 {
      _ = disconnect(generation: generation)
    } else {
      manager.connection.stopVPNTunnel()
    }
    Task {
      let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
      for manager in managers ?? [] {
        try? await manager.removeFromPreferences()
      }
      try? await setup()
    }
  }

  func isStaleGenerationError(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == "VPNManager" && error.code == 2
  }

  private func staleGenerationError() -> NSError {
    NSError(
      domain: "VPNManager",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "stale VPN session operation"]
    )
  }
}
