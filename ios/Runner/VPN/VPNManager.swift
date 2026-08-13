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
            guard let connection = notification.object as? NEVPNConnection else { return }
            self?.setState(connection.status)
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            updateStats()
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
    
    private func enableVPNManager(config: String, grpcServiceModePort: Int, disableMemoryLimit: Bool) async throws {
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
                        disableMemoryLimit: disableMemoryLimit
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
        DispatchQueue.main.async { [weak self] in
            self?.state = status
        }
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
        disableMemoryLimit: Bool
    ) -> [String: Any] {
        [
            "Config": config,
            "GrpcServiceModePort": grpcServiceModePort,
            "DisableMemoryLimit": disableMemoryLimit ? "YES" : "NO",
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
    
    func connect(with config: String, grpcServiceModePort:Int, disableMemoryLimit: Bool = false) async throws {
        
        await set(upload: 0, download: 0)
//        guard state == .disconnected else { return }
        try await enableVPNManager(
            config: config,
            grpcServiceModePort: grpcServiceModePort,
            disableMemoryLimit: disableMemoryLimit
        )

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
        }

        try manager.connection.startVPNTunnel(options: [
            "Config": config as NSString,
            "GrpcServiceModePort":NSNumber(value: grpcServiceModePort),
            "DisableMemoryLimit": (disableMemoryLimit ? "YES" : "NO") as NSString,
        ])
        setState(manager.connection.status)
        connectTime = .now
    }

    func prepare(with config: String, grpcServiceModePort:Int, disableMemoryLimit: Bool = false) async throws {
        try await enableVPNManager(
            config: config,
            grpcServiceModePort: grpcServiceModePort,
            disableMemoryLimit: disableMemoryLimit
        )
    }
    
    func disconnect() {
        Task {
            await disconnectAsync()
        }
    }
    
    func disconnectAsync() async {
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
        connectTime = nil
    }
}
