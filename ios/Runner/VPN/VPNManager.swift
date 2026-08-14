//
//  VPNManager.swift
//  Runner
//
//  Created by GFWFighter on 7/25/1402 AP.
//

import Foundation
import Combine
import NetworkExtension

enum VPNManagerAlertType: String {
    case RequestVPNPermission
    case RequestNotificationPermission
    case EmptyConfiguration
    case StartCommandServer
    case CreateService
    case StartService
}

struct VPNManagerAlert {
    let alert: VPNManagerAlertType?
    let message: String?
}

class VPNManager: ObservableObject {
    private var cancelBag: Set<AnyCancellable> = []
    private let generationLock = NSLock()
    private var sessionGeneration: Int64 = 0
    private var coreReadyGeneration: Int64 = 0
    private var requestedAction = ""
    private var stopSource = ""
    private var lastObservedStatus: NEVPNStatus = .invalid
    private var providerStatusRequestInFlight = false
    private let runtimeEpoch = UUID().uuidString
    private var snapshotSequence: Int64 = 1
    
    private var observer: NSObjectProtocol?
    private var manager = NEVPNManager.shared()
    private var loaded: Bool = false
    private var timer: Timer?
            
    static let shared: VPNManager = VPNManager()
        
    @Published private(set) var state: NEVPNStatus = .invalid
    @Published private(set) var alert: VPNManagerAlert = .init(alert: nil, message: nil)
    
    @Published private(set) var upload: Int64 = 0
    @Published private(set) var download: Int64 = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    
    private var _connectTime: Date?
    private var connectTime: Date? {
        set {
            UserDefaults(suiteName: FilePath.groupName)?.set(newValue?.timeIntervalSince1970, forKey: "SingBoxConnectTime")
            _connectTime = newValue
        }
        get {
            if let _connectTime {
                return _connectTime
            }
            guard let interval = UserDefaults(suiteName: FilePath.groupName)?.value(forKey: "SingBoxConnectTime") as? TimeInterval else {
                return nil
            }
            return Date(timeIntervalSince1970: interval)
        }
    }
    private var readingWS: Bool = false
    
    @Published var isConnectedToAnyVPN: Bool = false
    
    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: nil) { [weak self] notification in
            guard let self,
                  let connection = notification.object as? NEVPNConnection,
                  connection === self.manager.connection
            else { return }
            self.setState(connection.status)
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            updateStats()
            refreshProviderReadinessIfNeeded()
            elapsedTime = -1 * (connectTime?.timeIntervalSinceNow ?? 0)
        }
    }
                
    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        timer?.invalidate()
    }
    
    func setup() async throws {
        // guard !loaded else { return }
        loaded = true
        do {
            try await loadVPNPreference()
            try await migrateStoredProviderConfigurationIfNeeded()
        } catch {
            print(error.localizedDescription)
        }
    }
    
    private func loadVPNPreference() async throws {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let manager = managers.first {
                self.manager = manager
                setState(manager.connection.status)
                return
            }
            let newManager = NETunnelProviderManager()
            let `protocol` = NETunnelProviderProtocol()
            `protocol`.providerBundleIdentifier = Bundle.main.baseBundleIdentifier + ".ZeonPacketTunnel"
            `protocol`.serverAddress = "localhost"
            newManager.protocolConfiguration = `protocol`
            newManager.localizedDescription = "ZEON"
            try await newManager.saveToPreferences()
            try await newManager.loadFromPreferences()
            self.manager = newManager
            setState(newManager.connection.status)
        } catch {
            print(error.localizedDescription)	
        }
    }
    
    private func enableVPNManager(
        config: String,
        grpcServiceModePort: Int,
        disableMemoryLimit: Bool,
        generation: Int64 = 0
    ) async throws {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                try? await manager.loadFromPreferences()
                manager.isEnabled = true
                manager.isOnDemandEnabled = false
                manager.onDemandRules = []

                if let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol {
                    tunnelProtocol.providerConfiguration = providerConfiguration(
                        config: config,
                        grpcServiceModePort: grpcServiceModePort,
                        disableMemoryLimit: disableMemoryLimit,
                        generation: generation
                    )
                    manager.protocolConfiguration = tunnelProtocol
                }

                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                setState(manager.connection.status)
                return
            } catch {
                lastError = error
                print(error.localizedDescription)
                if attempt == 0 && error.localizedDescription.lowercased().contains("stale") {
                    try? await loadVPNPreference()
                    continue
                }
                throw error
            }
        }
        if let lastError = lastError {
            throw lastError
        }
    }

    private func setState(_ status: NEVPNStatus) {
        generationLock.lock()
        let previousStatus = lastObservedStatus
        lastObservedStatus = status
        switch status {
        case .connected, .connecting, .reasserting:
            requestedAction = "connect"
            stopSource = ""
        case .disconnecting:
            if requestedAction != "stop" {
                requestedAction = "stop"
                stopSource = "system"
            }
        case .disconnected, .invalid:
            if isActiveTunnelStatus(previousStatus), requestedAction != "stop" {
                requestedAction = "stop"
                stopSource = "system"
            }
        @unknown default:
            break
        }
        snapshotSequence += 1
        generationLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.state = status
        }
        if status == .connected {
            refreshProviderReadinessIfNeeded()
        }
    }

    @discardableResult
    func setSessionGeneration(_ generation: Int64) -> Int64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        if generation > sessionGeneration {
            sessionGeneration = generation
            coreReadyGeneration = 0
            requestedAction = "connect"
            stopSource = ""
            snapshotSequence += 1
        }
        return sessionGeneration
    }

    func currentSessionGeneration() -> Int64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return sessionGeneration
    }

    func isCurrentGeneration(_ generation: Int64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation > 0 && generation == sessionGeneration
    }

    func isCoreReadyForCurrentGeneration() -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return sessionGeneration > 0 && coreReadyGeneration == sessionGeneration
    }

    func markCoreStarted(_ generation: Int64) async throws {
        guard isCurrentGeneration(generation) else {
            throw staleGenerationError()
        }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            guard isCurrentGeneration(generation) else {
                throw staleGenerationError()
            }
            if manager.connection.status == .connected {
                guard markReadyIfCurrent(generation) else { throw staleGenerationError() }
                // Republish only after both the packet tunnel and core are ready.
                setState(manager.connection.status)
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(
            domain: "VPNManager",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "packet tunnel was not ready after core start"]
        )
    }

    private func staleGenerationError() -> NSError {
        NSError(
            domain: "VPNManager",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "stale VPN session operation"]
        )
    }

    private func markReadyIfCurrent(_ generation: Int64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == sessionGeneration else { return false }
        coreReadyGeneration = generation
        requestedAction = "connect"
        stopSource = ""
        snapshotSequence += 1
        return true
    }

    private func markStopRequested(_ generation: Int64, source: String) {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == sessionGeneration else { return }
        requestedAction = "stop"
        stopSource = source
        snapshotSequence += 1
    }

    private func clearCoreReady() {
        generationLock.lock()
        coreReadyGeneration = 0
        snapshotSequence += 1
        generationLock.unlock()
    }

    func sessionSnapshot() -> [String: Any] {
        generationLock.lock()
        defer { generationLock.unlock() }
        let generation = sessionGeneration
        let ready = generation > 0 && coreReadyGeneration == generation
        let action = requestedAction
        let currentStopSource = stopSource
        let status = manager.connection.status
        let phase: String
        switch status {
        case .connected:
            phase = ready ? "connected" : "verifying"
        case .connecting, .reasserting:
            phase = "starting_platform"
        case .disconnecting:
            phase = "stopping"
        case .disconnected, .invalid:
            phase = "disconnected"
        @unknown default:
            phase = "failed"
        }
        return [
            "generation": generation,
            "runtimeEpoch": runtimeEpoch,
            "sequenceNumber": snapshotSequence,
            "snapshotVersion": snapshotSequence,
            "phase": phase,
            "requestedAction": action,
            "stopSource": currentStopSource,
            "coreReady": ready,
            "coreStarted": ready,
            "commandEndpointReady": ready,
            "tunnelReady": status == .connected,
            "protectSucceeded": status == .connected,
            "platformVpnValidated": status == .connected,
            // The concrete selector is owned by the Go core and is fetched by
            // the proxy providers. A stable opaque id is enough for the common
            // snapshot contract to prove that this iOS core is usable.
            "selectedOutboundId": ready ? "ios-session-\(generation)" : "",
            "selectedOutboundLabel": ready ? VPNConfig.shared.activeProfileName : "",
            "strategy": "",
            "failureCode": "",
            "failureOwner": "",
            "recoverable": false,
        ]
    }

    private func migrateStoredProviderConfigurationIfNeeded() async throws {
        let config = VPNConfig.shared.activeConfigPath
        guard !config.isEmpty else { return }
        guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else { return }

        let grpcPort = VPNConfig.shared.grpcServiceModePort == 0 ? 17179 : VPNConfig.shared.grpcServiceModePort
        let nextConfiguration = providerConfiguration(
            config: config,
            grpcServiceModePort: grpcPort,
            disableMemoryLimit: VPNConfig.shared.disableMemoryLimit
        )
        let currentConfiguration = tunnelProtocol.providerConfiguration ?? [:]
        let currentPort = (currentConfiguration["GrpcServiceModePort"] as? NSNumber)?.intValue
            ?? currentConfiguration["GrpcServiceModePort"] as? Int
        if currentConfiguration["Config"] as? String == nextConfiguration["Config"] as? String,
           currentPort == grpcPort,
           currentConfiguration["DisableMemoryLimit"] as? String == nextConfiguration["DisableMemoryLimit"] as? String {
            return
        }

        let shouldRestartConnectedTunnel = isActiveTunnelStatus(manager.connection.status)
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        manager.onDemandRules = []
        tunnelProtocol.providerConfiguration = nextConfiguration
        manager.protocolConfiguration = tunnelProtocol
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        setState(manager.connection.status)

        if shouldRestartConnectedTunnel {
            manager.connection.stopVPNTunnel()
            for _ in 0..<20 {
                let status = manager.connection.status
                setState(status)
                if status == .disconnected || status == .invalid {
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? manager.connection.startVPNTunnel()
            setState(manager.connection.status)
        }
    }

    private func providerConfiguration(
        config: String,
        grpcServiceModePort: Int,
        disableMemoryLimit: Bool,
        generation: Int64 = 0
    ) -> [String: Any] {
        [
            "Config": config,
            "GrpcServiceModePort": grpcServiceModePort,
            "DisableMemoryLimit": disableMemoryLimit ? "YES" : "NO",
            "Generation": generation,
        ]
    }

    private func isActiveTunnelStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
    }

    private func isInactiveTunnelStatus(_ status: NEVPNStatus) -> Bool {
        status == .disconnected || status == .invalid
    }

    private func waitForInactiveTunnel(timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = manager.connection.status
            setState(status)
            if isInactiveTunnelStatus(status) {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        setState(manager.connection.status)
        return isInactiveTunnelStatus(manager.connection.status)
    }
    
    @MainActor private func set(upload: Int64, download: Int64) {
        self.upload = upload
        self.download = download
    }
    
    var isAnyVPNConnected: Bool {
        guard let cfDict = CFNetworkCopySystemProxySettings() else { return false }
        let nsDict = cfDict.takeRetainedValue() as NSDictionary
        guard let keys = nsDict["__SCOPED__"] as? NSDictionary else {
            return false
        }
        for key in keys.allKeys.compactMap({ $0 as? String }) {
            if key == "tap" || key == "tun" || key == "ppp" || key == "ipsec" || key == "ipsec0" {
                return true
            } else if key.starts(with: "utun") {
                return true
            }
        }
        return false
    }
    
    func reset() {
        loaded = false
        if state != .disconnected && state != .invalid {
            disconnect()
        }
        $state.filter { $0 == .disconnected || $0 == .invalid }.first().sink { [weak self] _ in
            Task { [weak self] () in
                self?.manager = .shared()
                do {
                    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                    for manager in managers ?? [] {
                        try await manager.removeFromPreferences()
                    }
                    try await self?.loadVPNPreference()
                } catch {
                    print(error.localizedDescription)
                }
            }
        }.store(in: &cancelBag)
        
    }
    
    
    private func updateStats() {
        let isAnyVPNConnected = self.isAnyVPNConnected
        if isConnectedToAnyVPN != isAnyVPNConnected {
            isConnectedToAnyVPN = isAnyVPNConnected
        }
        guard state == .connected else { return }
        guard let connection = manager.connection as? NETunnelProviderSession else { return }
        do {
            try connection.sendProviderMessage("stats".data(using: .utf8)!) { [weak self] response in
                guard
                    let response,
                    let response = String(data: response, encoding: .utf8)
                else { return }
                let responseComponents = response.components(separatedBy: ",")
                guard
                    responseComponents.count == 2,
                    let upload = Int64(responseComponents[0]),
                    let download = Int64(responseComponents[1])
                else { return }
                Task { [upload, download, weak self] () in
                    await self?.set(upload: upload, download: download)
                }
            }
        } catch {
            print(error.localizedDescription)
        }
    }
    
    func connect(
        with config: String,
        grpcServiceModePort:Int,
        disableMemoryLimit: Bool = false,
        generation: Int64
    ) async throws {
        guard isCurrentGeneration(generation) else { throw staleGenerationError() }
        
        await set(upload: 0, download: 0)
//        guard state == .disconnected else { return }
        try await enableVPNManager(
            config: config,
            grpcServiceModePort: grpcServiceModePort,
            disableMemoryLimit: disableMemoryLimit,
            generation: generation
        )
        guard isCurrentGeneration(generation) else { throw staleGenerationError() }

        let status = manager.connection.status
        if isActiveTunnelStatus(status) || status == .disconnecting {
            manager.connection.stopVPNTunnel()
            guard await waitForInactiveTunnel() else {
                throw NSError(
                    domain: "VPNManager",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "VPN tunnel did not stop before reconnect"]
                )
            }
            guard isCurrentGeneration(generation) else { throw staleGenerationError() }
        }

        try manager.connection.startVPNTunnel(options: [
            "Config": config as NSString,
            "GrpcServiceModePort":NSNumber(value: grpcServiceModePort),
            "DisableMemoryLimit": (disableMemoryLimit ? "YES" : "NO") as NSString,
            "Generation": NSNumber(value: generation),
        ])
        setState(manager.connection.status)
        connectTime = .now
    }

    func prepare(
        with config: String,
        grpcServiceModePort:Int,
        disableMemoryLimit: Bool = false,
        generation: Int64
    ) async throws {
        guard isCurrentGeneration(generation) else { throw staleGenerationError() }
        try await enableVPNManager(
            config: config,
            grpcServiceModePort: grpcServiceModePort,
            disableMemoryLimit: disableMemoryLimit,
            generation: generation
        )
        guard isCurrentGeneration(generation) else { throw staleGenerationError() }
    }
    
    func disconnect() {
        Task {
            await disconnectAsync()
        }
    }
    
    func disconnectAsync(generation: Int64? = nil) async {
        if let generation, !isCurrentGeneration(generation) {
            return
        }
        let stoppingGeneration = generation ?? currentSessionGeneration()
        markStopRequested(stoppingGeneration, source: "flutter")
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
            
            do {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            } catch {
                print("save error:", error.localizedDescription)
            }
        }

//        guard state == .connected else { return }
        let status = manager.connection.status
        if !isActiveTunnelStatus(status) && status != .disconnecting {
            setState(status)
            connectTime = nil
            return
        }
        manager.connection.stopVPNTunnel()
        _ = await waitForInactiveTunnel()
        clearCoreReady()
        connectTime = nil
    }

    private func refreshProviderReadinessIfNeeded() {
        generationLock.lock()
        let needsRefresh = manager.connection.status == .connected &&
            (sessionGeneration <= 0 || coreReadyGeneration != sessionGeneration) &&
            !providerStatusRequestInFlight
        if needsRefresh {
            providerStatusRequestInFlight = true
        }
        generationLock.unlock()
        guard needsRefresh, let connection = manager.connection as? NETunnelProviderSession else { return }

        do {
            try connection.sendProviderMessage(Data("session_status".utf8)) { [weak self] response in
                guard let self else { return }
                self.acceptProviderSessionStatus(response)
            }
        } catch {
            generationLock.lock()
            providerStatusRequestInFlight = false
            generationLock.unlock()
            NSLog("event=ios_provider_status_failed error=%@", error.localizedDescription)
        }
    }

    private func acceptProviderSessionStatus(_ response: Data?) {
        var providerGeneration: Int64 = 0
        var providerCoreStarted = false
        if let response,
           let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
        {
            if let value = object["generation"] as? NSNumber {
                providerGeneration = value.int64Value
            } else if let value = object["generation"] as? Int64 {
                providerGeneration = value
            }
            providerCoreStarted = object["coreStarted"] as? Bool ?? false
        }

        generationLock.lock()
        providerStatusRequestInFlight = false
        if providerCoreStarted && providerGeneration > 0 && providerGeneration >= sessionGeneration {
            sessionGeneration = providerGeneration
            coreReadyGeneration = providerGeneration
            requestedAction = "connect"
            stopSource = ""
            snapshotSequence += 1
        }
        let shouldRepublish = providerCoreStarted && providerGeneration > 0 && providerGeneration == sessionGeneration
        generationLock.unlock()

        if shouldRepublish {
            setState(manager.connection.status)
        }
    }
}
