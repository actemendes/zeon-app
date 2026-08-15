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

enum ProviderSessionStatusDisposition: Equatable {
    case ignore
    case adopt
    case rejectPendingStop
}

private actor VPNPreferenceMutationMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

class VPNManager: ObservableObject {
    private var cancelBag: Set<AnyCancellable> = []
    private let generationLock = NSLock()
    private let preferenceMutationMutex = VPNPreferenceMutationMutex()
    private var sessionGeneration: Int64 = 0
    private var coreReadyGeneration: Int64 = 0
    private var requestedAction = ""
    private var stopSource = ""
    private var pendingStopCancellationGeneration: Int64?
    private var pendingStopReachedInactiveGeneration: Int64?
    private var pendingStopActiveCandidateStartedAt: Date?
    private var lastObservedStatus: NEVPNStatus = .invalid
    private var providerStatusRequestInFlight = false
    private var providerStatusRequestID: UUID?
    private var providerStatusRequestStartedAt: Date?
    private let providerStatusRequestTimeout: TimeInterval = 3
    private var providerCoreReadyAcknowledgedGeneration: Int64 = 0
    // Optional bootstrap preparation is not a user lifecycle intent. Keep its
    // lineage until an explicit local Start/Stop wins so a provider that was
    // already launched from the previous configuration can prove ownership
    // even if NEVPNStatus was still inactive when preparation was accepted.
    private var bootstrapPreparationGeneration: Int64?
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
        try await withPreferenceMutation {
            try await self.loadVPNPreferenceUnlocked()
            try await self.migrateStoredProviderConfigurationIfNeeded()
            self.loaded = true
        }
    }

    private func withPreferenceMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await preferenceMutationMutex.acquire()
        do {
            let value = try await operation()
            await preferenceMutationMutex.release()
            return value
        } catch {
            await preferenceMutationMutex.release()
            throw error
        }
    }
    
    private func loadVPNPreferenceUnlocked() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let expectedProviderBundleIdentifier = Bundle.main.baseBundleIdentifier + ".ZeonPacketTunnel"
        let candidates = managers.map { candidate -> (isExact: Bool, isValid: Bool, isActive: Bool) in
            let tunnelProtocol = candidate.protocolConfiguration as? NETunnelProviderProtocol
            let status = candidate.connection.status
            let isActive: Bool
            switch status {
            case .connected, .connecting, .reasserting, .disconnecting:
                isActive = true
            case .disconnected, .invalid:
                isActive = false
            @unknown default:
                isActive = true
            }
            return (
                tunnelProtocol?.providerBundleIdentifier == expectedProviderBundleIdentifier,
                tunnelProtocol != nil,
                isActive
            )
        }
        if let selectedIndex = Self.preferredTunnelManagerIndex(candidates) {
            let selectedManager = managers[selectedIndex]
            if !candidates[selectedIndex].isExact {
                NSLog("event=ios_vpn_manager_legacy_fallback")
                if candidates[selectedIndex].isActive {
                    // Never rewrite the protocol underneath a live Settings
                    // session. Explicit Prepare/Connect will repair it while
                    // performing the requested replacement; an inactive setup
                    // can normalize it safely below.
                    NSLog("event=ios_vpn_manager_legacy_repair_deferred reason=active")
                } else {
                    selectedManager.protocolConfiguration = Self.tunnelProtocolForSaving(
                        existingProtocol: selectedManager.protocolConfiguration,
                        providerBundleIdentifier: expectedProviderBundleIdentifier
                    )
                    selectedManager.localizedDescription = selectedManager.localizedDescription ?? "ZEON"
                    try await selectedManager.saveToPreferences()
                    try await selectedManager.loadFromPreferences()
                }
            }
            for duplicateIndex in Self.inactiveDuplicateManagerIndices(
                candidates,
                selectedIndex: selectedIndex
            ) {
                let duplicate = managers[duplicateIndex]
                guard duplicate.connection.status == .disconnected || duplicate.connection.status == .invalid else {
                    NSLog("event=ios_vpn_manager_duplicate_cleanup_skipped reason=became_active")
                    continue
                }
                do {
                    try await duplicate.removeFromPreferences()
                    NSLog("event=ios_vpn_manager_inactive_duplicate_removed")
                } catch {
                    // Duplicate cleanup must not make the canonical manager
                    // unusable. A later serialized setup will retry it.
                    NSLog(
                        "event=ios_vpn_manager_duplicate_cleanup_failed error=%@",
                        error.localizedDescription
                    )
                }
            }
            self.manager = selectedManager
            setState(selectedManager.connection.status)
            return
        }
        let newManager = NETunnelProviderManager()
        newManager.protocolConfiguration = Self.tunnelProtocolForSaving(
            existingProtocol: nil,
            providerBundleIdentifier: expectedProviderBundleIdentifier
        )
        newManager.localizedDescription = "ZEON"
        try await newManager.saveToPreferences()
        try await newManager.loadFromPreferences()
        self.manager = newManager
        setState(newManager.connection.status)
    }

    static func preferredTunnelManagerIndex(
        _ candidates: [(isExact: Bool, isValid: Bool, isActive: Bool)]
    ) -> Int? {
        var preferredIndex: Int?
        var preferredPriority = Int.max
        for (index, candidate) in candidates.enumerated() {
            let priority: Int
            switch (candidate.isExact, candidate.isValid, candidate.isActive) {
            case (true, _, true): priority = 0
            case (false, true, true): priority = 1
            case (false, false, true): priority = 2
            case (true, _, false): priority = 3
            case (false, true, false): priority = 4
            case (false, false, false): priority = 5
            }
            if priority < preferredPriority {
                preferredPriority = priority
                preferredIndex = index
            }
        }
        return preferredIndex
    }

    static func inactiveDuplicateManagerIndices(
        _ candidates: [(isExact: Bool, isValid: Bool, isActive: Bool)],
        selectedIndex: Int
    ) -> [Int] {
        guard candidates.indices.contains(selectedIndex) else { return [] }
        return candidates.indices.filter { index in
            index != selectedIndex && !candidates[index].isActive
        }
    }
    
    private func enableVPNManager(
        config: String,
        grpcServiceModePort: Int,
        disableMemoryLimit: Bool,
        generation: Int64 = 0,
        bootstrapPreparation: Bool = false
    ) async throws {
        try await withPreferenceMutation {
            try await self.enableVPNManagerUnlocked(
                config: config,
                grpcServiceModePort: grpcServiceModePort,
                disableMemoryLimit: disableMemoryLimit,
                generation: generation,
                bootstrapPreparation: bootstrapPreparation
            )
        }
    }

    private func enableVPNManagerUnlocked(
        config: String,
        grpcServiceModePort: Int,
        disableMemoryLimit: Bool,
        generation: Int64,
        bootstrapPreparation: Bool
    ) async throws {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                guard isCurrentGeneration(generation) else { throw staleGenerationError() }
                if manager is NETunnelProviderManager {
                    try await manager.loadFromPreferences()
                    guard isCurrentGeneration(generation) else { throw staleGenerationError() }
                }
                let targetManager = (manager as? NETunnelProviderManager) ?? NETunnelProviderManager()
                let nextProviderConfiguration = providerConfiguration(
                    config: config,
                    grpcServiceModePort: grpcServiceModePort,
                    disableMemoryLimit: disableMemoryLimit,
                    generation: generation
                )
                if Self.shouldDeferBootstrapPreparationAfterReload(
                    bootstrapPreparation: bootstrapPreparation,
                    generationIsCurrent: isCurrentGeneration(generation),
                    status: targetManager.connection.status
                ) {
                    // This check intentionally lives inside the preference
                    // mutex, after the freshest load and before any mutation.
                    // A Settings Start that wins this gap owns the live
                    // protocol; bootstrap observes it instead of saving over
                    // it. Explicit Connect never carries the bootstrap flag.
                    refreshProviderReadinessIfNeeded()
                    NSLog(
                        "event=ios_bootstrap_prepare_deferred_before_save generation=%lld status=\(targetManager.connection.status.rawValue)",
                        generation
                    )
                    return
                }
                guard isCurrentGeneration(generation) else { throw staleGenerationError() }
                targetManager.isEnabled = true
                targetManager.isOnDemandEnabled = false
                targetManager.onDemandRules = []
                targetManager.localizedDescription = manager.localizedDescription ?? "ZEON"
                targetManager.protocolConfiguration = Self.tunnelProtocolForSaving(
                    existingProtocol: targetManager.protocolConfiguration,
                    providerBundleIdentifier: Bundle.main.baseBundleIdentifier + ".ZeonPacketTunnel",
                    providerConfiguration: nextProviderConfiguration
                )

                try await targetManager.saveToPreferences()
                guard isCurrentGeneration(generation) else { throw staleGenerationError() }
                try await targetManager.loadFromPreferences()
                guard isCurrentGeneration(generation) else { throw staleGenerationError() }
                manager = targetManager
                setState(targetManager.connection.status)
                return
            } catch {
                lastError = error
                print(error.localizedDescription)
                if attempt == 0 {
                    try await loadVPNPreferenceUnlocked()
                    continue
                }
                throw error
            }
        }
        if let lastError = lastError {
            throw lastError
        }
    }

    static func tunnelProtocolForSaving(
        existingProtocol: NEVPNProtocol?,
        providerBundleIdentifier: String,
        providerConfiguration: [String: Any]? = nil
    ) -> NETunnelProviderProtocol {
        let tunnelProtocol = existingProtocol as? NETunnelProviderProtocol ?? NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
        if tunnelProtocol.serverAddress?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            tunnelProtocol.serverAddress = "localhost"
        }
        if let providerConfiguration {
            tunnelProtocol.providerConfiguration = providerConfiguration
        }
        return tunnelProtocol
    }

    private func setState(_ status: NEVPNStatus) {
        generationLock.lock()
        let previousStatus = lastObservedStatus
        lastObservedStatus = status
        let intent = Self.intentAfterStatusTransition(
            previousStatus: previousStatus,
            status: status,
            requestedAction: requestedAction,
            stopSource: stopSource,
            stopCancellationPending: pendingStopCancellationGeneration == sessionGeneration
        )
        requestedAction = intent.requestedAction
        stopSource = intent.stopSource
        let shouldRefreshReadiness = status == .connected && intent.requestedAction == "connect"
        let pendingStopOwnsGeneration = pendingStopCancellationGeneration == sessionGeneration &&
            intent.requestedAction == "stop"
        let statusIsActive = status == .connected || status == .connecting || status == .reasserting
        var shouldValidateSettingsStart = false
        var shouldReassertPendingStop = false
        if pendingStopOwnsGeneration && statusIsActive {
            if pendingStopReachedInactiveGeneration == sessionGeneration {
                if pendingStopActiveCandidateStartedAt == nil {
                    pendingStopActiveCandidateStartedAt = Date()
                }
                shouldValidateSettingsStart = status == .connected
            } else {
                // Stop has not reached a stable inactive state yet. Any active
                // callback still belongs to the owner being cancelled, not to
                // a later Settings start.
                shouldReassertPendingStop = true
            }
        } else if status == .disconnected || status == .invalid {
            pendingStopActiveCandidateStartedAt = nil
        }
        snapshotSequence += 1
        generationLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.state = status
        }
        if shouldRefreshReadiness || shouldValidateSettingsStart {
            refreshProviderReadinessIfNeeded()
        }
        if shouldReassertPendingStop {
            // startVPNTunnel() may have returned while NEVPNStatus was still
            // inactive. A Stop accepted in that window owns the generation;
            // cancel any delayed active transition instead of relabeling it
            // as a Settings start.
            manager.connection.stopVPNTunnel()
        }
    }

    static func intentAfterStatusTransition(
        previousStatus: NEVPNStatus,
        status: NEVPNStatus,
        requestedAction: String,
        stopSource: String,
        stopCancellationPending: Bool = false
    ) -> (requestedAction: String, stopSource: String) {
        switch status {
        case .connected, .connecting, .reasserting:
            let previousWasInactive = previousStatus == .disconnected || previousStatus == .invalid
            if requestedAction == "stop" && (stopCancellationPending || !previousWasInactive) {
                // A late active notification must not resurrect a session after
                // Stop was accepted. An active transition from an inactive
                // state is instead a genuine Settings/system start.
                return ("stop", stopSource)
            }
            return ("connect", "")
        case .disconnecting:
            if requestedAction == "connect" &&
                (previousStatus == .disconnected || previousStatus == .invalid)
            {
                // A delayed teardown notification from the previous owner can
                // arrive after a new generation has already accepted Connect.
                return ("connect", "replacement")
            }
            if requestedAction != "stop" {
                return ("stop", "system")
            }
        case .disconnected, .invalid:
            let previousWasActive = previousStatus == .connected ||
                previousStatus == .connecting ||
                previousStatus == .reasserting
            if previousWasActive && requestedAction != "stop" {
                return ("stop", "system")
            }
        @unknown default:
            break
        }
        return (requestedAction, stopSource)
    }

    static func preemptiveStopGeneration(
        currentGeneration: Int64,
        requestedGeneration: Int64
    ) -> Int64 {
        let nextGeneration = currentGeneration == Int64.max
            ? Int64.max
            : currentGeneration + 1
        return max(max(requestedGeneration, 1), nextGeneration)
    }

    /// Atomically rebases a preemptive Stop above every native operation that
    /// has already reached this process. The requested action and tombstone are
    /// installed under the same lock as the generation, so no late Connect can
    /// win the gap between two MethodChannel calls.
    @discardableResult
    func reservePreemptiveStopGeneration(
        _ requestedGeneration: Int64,
        source: String = "flutter"
    ) -> Int64 {
        generationLock.lock()
        defer { generationLock.unlock() }

        let acceptedGeneration = Self.preemptiveStopGeneration(
            currentGeneration: sessionGeneration,
            requestedGeneration: requestedGeneration
        )
        if acceptedGeneration > sessionGeneration {
            sessionGeneration = acceptedGeneration
        }
        coreReadyGeneration = 0
        providerCoreReadyAcknowledgedGeneration = 0
        bootstrapPreparationGeneration = nil
        requestedAction = "stop"
        stopSource = source
        pendingStopCancellationGeneration = acceptedGeneration
        pendingStopReachedInactiveGeneration = nil
        pendingStopActiveCandidateStartedAt = nil
        providerStatusRequestInFlight = false
        providerStatusRequestID = nil
        providerStatusRequestStartedAt = nil
        snapshotSequence += 1
        return acceptedGeneration
    }

    @discardableResult
    func setSessionGeneration(
        _ generation: Int64,
        requestedAction nextRequestedAction: String = "connect"
    ) -> Int64 {
        generationLock.lock()
        if nextRequestedAction == "prepare",
           Self.shouldDeferPreparationGeneration(
               currentGeneration: sessionGeneration,
               requestedGeneration: generation,
               status: manager.connection.status,
               providerStatusRequestInFlight: providerStatusRequestInFlight
           )
        {
            let acceptedGeneration = sessionGeneration
            generationLock.unlock()
            // A connected provider with generation zero belongs to a session
            // that this freshly launched host has not adopted yet. Preserve
            // that zero so session_status can establish its real generation.
            refreshProviderReadinessIfNeeded()
            NSLog(
                "event=ios_prepare_generation_deferred requested=%lld current=%lld",
                generation,
                acceptedGeneration
            )
            return acceptedGeneration
        }
        defer { generationLock.unlock() }
        if generation > sessionGeneration {
            sessionGeneration = generation
            coreReadyGeneration = 0
            requestedAction = nextRequestedAction == "prepare" ? "prepare" : "connect"
            bootstrapPreparationGeneration = nextRequestedAction == "prepare" ? generation : nil
            stopSource = ""
            providerStatusRequestInFlight = false
            providerStatusRequestID = nil
            providerStatusRequestStartedAt = nil
            providerCoreReadyAcknowledgedGeneration = 0
            pendingStopCancellationGeneration = nil
            pendingStopReachedInactiveGeneration = nil
            pendingStopActiveCandidateStartedAt = nil
            snapshotSequence += 1
        } else if generation == sessionGeneration,
                  nextRequestedAction == "connect",
                  requestedAction == "prepare"
        {
            // Prepare and Start deliberately share one operation generation.
            // Promote only that state pair: a generic same-generation call
            // must never revive a Stop that has already been accepted.
            requestedAction = "connect"
            stopSource = ""
            bootstrapPreparationGeneration = nil
            snapshotSequence += 1
        }
        return sessionGeneration
    }

    static func shouldDeferPreparationGeneration(
        currentGeneration: Int64,
        requestedGeneration: Int64,
        status: NEVPNStatus,
        providerStatusRequestInFlight: Bool
    ) -> Bool {
        // `prepare` is reserved for optional bootstrap work. A real user
        // Start reaches native as `connect`, so preparation can always defer
        // when any system tunnel may already own the session, including a
        // Settings Start racing a warm Runner with a non-zero generation.
        guard requestedGeneration > currentGeneration else {
            return false
        }
        let tunnelMayOwnColdSession: Bool
        switch status {
        case .connected, .connecting, .reasserting, .disconnecting:
            tunnelMayOwnColdSession = true
        case .disconnected, .invalid:
            tunnelMayOwnColdSession = false
        @unknown default:
            tunnelMayOwnColdSession = true
        }
        return tunnelMayOwnColdSession || providerStatusRequestInFlight
    }

    static func shouldDeferBootstrapPreparationAfterReload(
        bootstrapPreparation: Bool,
        generationIsCurrent: Bool,
        status: NEVPNStatus
    ) -> Bool {
        guard bootstrapPreparation, generationIsCurrent else { return false }
        switch status {
        case .connected, .connecting, .reasserting, .disconnecting:
            return true
        case .disconnected, .invalid:
            return false
        @unknown default:
            return true
        }
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

    func isBootstrapPreparationRequest(_ generation: Int64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation > 0 &&
            generation == sessionGeneration &&
            bootstrapPreparationGeneration == generation &&
            requestedAction == "prepare"
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
                notifyProviderCoreStarted(generation)
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
        guard generation == sessionGeneration, requestedAction == "connect" else { return false }
        coreReadyGeneration = generation
        bootstrapPreparationGeneration = nil
        requestedAction = "connect"
        stopSource = ""
        snapshotSequence += 1
        return true
    }

    @discardableResult
    private func markStopRequested(_ generation: Int64, source: String) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == sessionGeneration else { return false }
        requestedAction = "stop"
        bootstrapPreparationGeneration = nil
        stopSource = source
        pendingStopCancellationGeneration = generation
        pendingStopReachedInactiveGeneration = nil
        pendingStopActiveCandidateStartedAt = nil
        coreReadyGeneration = 0
        providerCoreReadyAcknowledgedGeneration = 0
        snapshotSequence += 1
        return true
    }

    @discardableResult
    private func markConnectRequested(
        _ generation: Int64,
        allowInternalReplacementPromotion: Bool = false
    ) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == sessionGeneration else { return false }
        let intent = Self.intentAfterConnectRequest(
            requestedAction: requestedAction,
            stopSource: stopSource,
            allowInternalReplacementPromotion: allowInternalReplacementPromotion
        )
        guard intent.accepted else { return false }
        coreReadyGeneration = 0
        bootstrapPreparationGeneration = nil
        requestedAction = intent.requestedAction
        stopSource = intent.stopSource
        pendingStopCancellationGeneration = nil
        pendingStopReachedInactiveGeneration = nil
        pendingStopActiveCandidateStartedAt = nil
        providerCoreReadyAcknowledgedGeneration = 0
        snapshotSequence += 1
        return true
    }

    static func intentAfterConnectRequest(
        requestedAction: String,
        stopSource: String,
        allowInternalReplacementPromotion: Bool
    ) -> (accepted: Bool, requestedAction: String, stopSource: String) {
        if requestedAction == "stop" {
            let mayPromoteReplacement = allowInternalReplacementPromotion && stopSource == "replacement"
            guard mayPromoteReplacement else {
                return (false, requestedAction, stopSource)
            }
        }
        return (true, "connect", "")
    }

    @discardableResult
    private func markInternalReplacementStopRequestedForConnect(_ generation: Int64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == sessionGeneration else { return false }
        let intent = Self.intentAfterInternalReplacementStopRequest(
            requestedAction: requestedAction,
            stopSource: stopSource
        )
        guard intent.accepted else { return false }
        requestedAction = intent.requestedAction
        stopSource = intent.stopSource
        snapshotSequence += 1
        return true
    }

    static func intentAfterInternalReplacementStopRequest(
        requestedAction: String,
        stopSource: String
    ) -> (accepted: Bool, requestedAction: String, stopSource: String) {
        // Once any Stop has been accepted, an older async Connect continuation
        // must not relabel it as an internal replacement teardown.
        guard requestedAction != "stop" else {
            return (false, requestedAction, stopSource)
        }
        return (true, "stop", "replacement")
    }

    @discardableResult
    private func markPrepareRequested(_ generation: Int64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == sessionGeneration else { return false }
        let intent = Self.intentAfterPrepareRequest(
            requestedAction: requestedAction,
            stopSource: stopSource
        )
        guard intent.accepted else { return false }
        // Preparation may run as an implementation detail of an already
        // accepted Connect, but it must not demote that public intent or clear
        // readiness belonging to it.
        guard intent.requestedAction == "prepare" else { return true }
        coreReadyGeneration = 0
        requestedAction = intent.requestedAction
        stopSource = intent.stopSource
        providerCoreReadyAcknowledgedGeneration = 0
        snapshotSequence += 1
        return true
    }

    static func intentAfterPrepareRequest(
        requestedAction: String,
        stopSource: String
    ) -> (accepted: Bool, requestedAction: String, stopSource: String) {
        switch requestedAction {
        case "stop":
            return (false, requestedAction, stopSource)
        case "connect":
            return (true, requestedAction, stopSource)
        default:
            return (true, "prepare", "")
        }
    }

    private func clearCoreReady() {
        generationLock.lock()
        coreReadyGeneration = 0
        providerCoreReadyAcknowledgedGeneration = 0
        snapshotSequence += 1
        generationLock.unlock()
    }

    private func notifyProviderCoreStarted(_ generation: Int64) {
        Task { [weak self] in
            guard let self else { return }
            for attempt in 1...3 {
                guard self.canNotifyProviderCoreStarted(generation) else { return }
                if self.isProviderCoreReadyAcknowledged(generation) { return }
                self.sendProviderCoreStarted(generation, attempt: attempt)
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
    }

    private func canNotifyProviderCoreStarted(_ generation: Int64) -> Bool {
        generationLock.lock()
        let ready = generation > 0 &&
            generation == sessionGeneration &&
            coreReadyGeneration == generation &&
            requestedAction == "connect"
        generationLock.unlock()
        return ready && manager.connection.status == .connected
    }

    private func isProviderCoreReadyAcknowledged(_ generation: Int64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation > 0 && providerCoreReadyAcknowledgedGeneration == generation
    }

    @discardableResult
    private func markProviderCoreReadyAcknowledged(_ generation: Int64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation > 0,
              generation == sessionGeneration,
              coreReadyGeneration == generation,
              requestedAction == "connect"
        else {
            return false
        }
        providerCoreReadyAcknowledgedGeneration = generation
        return true
    }

    private func sendProviderCoreStarted(_ generation: Int64, attempt: Int) {
        guard canNotifyProviderCoreStarted(generation) else { return }
        guard let connection = manager.connection as? NETunnelProviderSession else {
            NSLog("event=ios_provider_core_started_skipped reason=invalid_session")
            return
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: [
            "command": "mark_core_started",
            "generation": generation,
        ]) else {
            NSLog("event=ios_provider_core_started_skipped reason=serialization")
            return
        }

        do {
            try connection.sendProviderMessage(payload) { [weak self, weak connection] response in
                guard let self, let connection else { return }
                guard connection === self.manager.connection,
                      self.canNotifyProviderCoreStarted(generation),
                      let response,
                      let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                      object["ack"] as? String == "mark_core_started",
                      object["accepted"] as? Bool == true,
                      (object["generation"] as? NSNumber)?.int64Value == generation,
                      self.markProviderCoreReadyAcknowledged(generation)
                else {
                    NSLog(
                        "event=ios_provider_core_started_rejected generation=%lld attempt=%d",
                        generation,
                        attempt
                    )
                    return
                }
                NSLog(
                    "event=ios_provider_core_started_ack generation=%lld attempt=%d",
                    generation,
                    attempt
                )
            }
        } catch {
            // The host already has direct proof that the core started. This
            // notification only lets a future cold Runner process recover that
            // readiness from the still-running packet-tunnel process.
            NSLog(
                "event=ios_provider_core_started_failed attempt=%d error=%@",
                attempt,
                error.localizedDescription
            )
        }
    }

    func sessionSnapshot() -> [String: Any] {
        generationLock.lock()
        defer { generationLock.unlock() }
        let generation = sessionGeneration
        let ready = generation > 0 && coreReadyGeneration == generation
        let action = requestedAction
        let currentStopSource = stopSource
        let status = manager.connection.status
        let phase = Self.sessionPhase(
            status: status,
            generation: generation,
            coreReady: ready,
            requestedAction: action
        )
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

    static func sessionPhase(
        status: NEVPNStatus,
        generation: Int64,
        coreReady: Bool,
        requestedAction: String
    ) -> String {
        switch status {
        case .connected:
            if requestedAction == "stop" { return "stopping" }
            return coreReady ? "connected" : "verifying"
        case .connecting, .reasserting:
            return requestedAction == "stop" ? "stopping" : "starting_platform"
        case .disconnecting:
            return "stopping"
        case .disconnected, .invalid:
            return generation > 0 && requestedAction == "connect" ? "start_requested" : "disconnected"
        @unknown default:
            return "failed"
        }
    }

    private func migrateStoredProviderConfigurationIfNeeded() async throws {
        let config = VPNConfig.shared.activeConfigPath
        guard !config.isEmpty else { return }
        guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else { return }

        let grpcPort = VPNConfig.shared.grpcServiceModePort == 0 ? 17179 : VPNConfig.shared.grpcServiceModePort
        let currentConfiguration = tunnelProtocol.providerConfiguration ?? [:]
        let storedGeneration = (currentConfiguration["Generation"] as? NSNumber)?.int64Value
            ?? (currentConfiguration["Generation"] as? Int64)
            ?? Int64(currentConfiguration["Generation"] as? Int ?? 0)
        let localGeneration = currentSessionGeneration()
        let configurationGeneration = localGeneration > 0 ? localGeneration : storedGeneration
        let nextConfiguration = providerConfiguration(
            config: config,
            grpcServiceModePort: grpcPort,
            disableMemoryLimit: VPNConfig.shared.disableMemoryLimit,
            generation: configurationGeneration
        )
        let currentPort = (currentConfiguration["GrpcServiceModePort"] as? NSNumber)?.intValue
            ?? currentConfiguration["GrpcServiceModePort"] as? Int
        if currentConfiguration["Config"] as? String == nextConfiguration["Config"] as? String,
           currentPort == grpcPort,
           currentConfiguration["DisableMemoryLimit"] as? String == nextConfiguration["DisableMemoryLimit"] as? String,
           storedGeneration == configurationGeneration {
            return
        }

        let status = manager.connection.status
        if isActiveTunnelStatus(status) || status == .disconnecting {
            // Bootstrap must not tear down a live provider before its generation
            // and readiness have been adopted. The next inactive setup/start
            // will persist the migrated configuration.
            NSLog("event=ios_provider_config_migration_deferred status=\(status.rawValue)")
            return
        }

        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        manager.onDemandRules = []
        tunnelProtocol.providerConfiguration = nextConfiguration
        manager.protocolConfiguration = tunnelProtocol
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        setState(manager.connection.status)
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

    static func providerConfigurationByUpdatingGeneration(
        _ configuration: [String: Any],
        generation: Int64
    ) -> [String: Any] {
        var updated = configuration
        updated["Generation"] = NSNumber(value: generation)
        return updated
    }

    private func storedProviderGeneration(_ configuration: [String: Any]) -> Int64 {
        if let value = configuration["Generation"] as? NSNumber {
            return value.int64Value
        }
        if let value = configuration["Generation"] as? Int64 {
            return value
        }
        if let value = configuration["Generation"] as? Int {
            return Int64(value)
        }
        if let value = configuration["Generation"] as? String {
            return Int64(value) ?? 0
        }
        return 0
    }

    /// Settings launches the extension from the persisted provider
    /// configuration, not from this process's in-memory generation. Persist
    /// the accepted Stop generation before declaring its transport teardown
    /// stable so a later Settings start can prove exact ownership. A delayed
    /// app start
    /// still carries its older generation in `options` and is rejected by the
    /// pending-stop tombstone.
    private func persistAcceptedStopGeneration(_ generation: Int64) async throws {
        try await withPreferenceMutation {
            try await self.persistAcceptedStopGenerationUnlocked(generation)
        }
    }

    private func persistAcceptedStopGenerationUnlocked(_ generation: Int64) async throws {
        var lastError: Error?
        for attempt in 0..<2 {
            guard stopTombstoneOwns(generation) else { throw staleGenerationError() }
            do {
                try await manager.loadFromPreferences()
                guard stopTombstoneOwns(generation) else { throw staleGenerationError() }
                guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                    throw NSError(
                        domain: "VPNManager",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "packet tunnel provider configuration is unavailable"]
                    )
                }
                let currentConfiguration = tunnelProtocol.providerConfiguration ?? [:]
                if storedProviderGeneration(currentConfiguration) == generation {
                    return
                }
                tunnelProtocol.providerConfiguration = Self.providerConfigurationByUpdatingGeneration(
                    currentConfiguration,
                    generation: generation
                )
                manager.protocolConfiguration = tunnelProtocol
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                guard stopTombstoneOwns(generation) else { throw staleGenerationError() }
                guard
                    let savedProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol,
                    storedProviderGeneration(savedProtocol.providerConfiguration ?? [:]) == generation
                else {
                    throw NSError(
                        domain: "VPNManager",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "packet tunnel stop generation was not persisted"]
                    )
                }
                return
            } catch {
                lastError = error
                if attempt == 0 {
                    try await loadVPNPreferenceUnlocked()
                }
            }
        }
        throw lastError ?? NSError(
            domain: "VPNManager",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "packet tunnel stop generation was not persisted"]
        )
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

    private func waitForInactiveTunnel(
        timeout: TimeInterval = 8,
        generation: Int64? = nil,
        stableInactiveObservations: Int = 1
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var inactiveObservations = 0
        while Date() < deadline {
            if let generation, !sessionGenerationMatches(generation) {
                return false
            }
            let status = manager.connection.status
            setState(status)
            if isInactiveTunnelStatus(status) {
                inactiveObservations += 1
                if inactiveObservations >= stableInactiveObservations {
                    return true
                }
            } else {
                inactiveObservations = 0
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if let generation, !sessionGenerationMatches(generation) {
            return false
        }
        setState(manager.connection.status)
        return isInactiveTunnelStatus(manager.connection.status)
    }

    private func markStopReachedStableInactive(_ generation: Int64) {
        generationLock.lock()
        if pendingStopCancellationGeneration == generation {
            // Keep the tombstone after transport teardown. It is cleared only
            // by a newer explicit generation/Connect, or when a subsequently
            // launched provider proves that Settings started this exact
            // persisted generation and its core is already running.
            pendingStopReachedInactiveGeneration = generation
            pendingStopActiveCandidateStartedAt = nil
            snapshotSequence += 1
        }
        generationLock.unlock()
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
        if state != .disconnected && state != .invalid {
            disconnect()
        }
        $state.filter { $0 == .disconnected || $0 == .invalid }.first().sink { [weak self] _ in
            Task { [weak self] () in
                guard let self else { return }
                do {
                    try await self.withPreferenceMutation {
                        self.loaded = false
                        self.manager = .shared()
                        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                        for manager in managers {
                            try await manager.removeFromPreferences()
                        }
                        try await self.loadVPNPreferenceUnlocked()
                    }
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
        // setupBackground may have deliberately stopped the previous tunnel
        // with this same generation and source=replacement. That is the only
        // accepted Stop an entering Connect is allowed to promote.
        guard markConnectRequested(
            generation,
            allowInternalReplacementPromotion: true
        ) else {
            throw staleGenerationError()
        }
        
        await set(upload: 0, download: 0)
//        guard state == .disconnected else { return }
        try await enableVPNManager(
            config: config,
            grpcServiceModePort: grpcServiceModePort,
            disableMemoryLimit: disableMemoryLimit,
            generation: generation
        )
        guard isCurrentGeneration(generation) else { throw staleGenerationError() }

        var performedInternalReplacementStop = false
        let status = manager.connection.status
        if isActiveTunnelStatus(status) || status == .disconnecting {
            guard markInternalReplacementStopRequestedForConnect(generation) else {
                throw staleGenerationError()
            }
            performedInternalReplacementStop = true
            guard isCurrentGeneration(generation) else { throw staleGenerationError() }
            manager.connection.stopVPNTunnel()
            let stopped = await waitForInactiveTunnel(generation: generation)
            guard isCurrentGeneration(generation) else { throw staleGenerationError() }
            guard stopped else {
                throw NSError(
                    domain: "VPNManager",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "VPN tunnel did not stop before reconnect"]
                )
            }
        }

        // A fallback teardown above may have published a stop intent. Reassert
        // this generation's Connect immediately before handing it to NE.
        guard markConnectRequested(
            generation,
            allowInternalReplacementPromotion: performedInternalReplacementStop
        ) else {
            throw staleGenerationError()
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
        generation: Int64,
        bootstrapPreparation: Bool = false
    ) async throws {
        guard isCurrentGeneration(generation) else { throw staleGenerationError() }
        let reloadedStatus = manager.connection.status
        if Self.shouldDeferBootstrapPreparationAfterReload(
            bootstrapPreparation: bootstrapPreparation,
            generationIsCurrent: isCurrentGeneration(generation),
            status: reloadedStatus
        ) {
            // setup() has just refreshed preferences. If Settings won the gap
            // after setPreparationGeneration observed an inactive manager,
            // bootstrap must observe/adopt that owner instead of rewriting its
            // live protocol. A user Connect never carries this bootstrap flag.
            refreshProviderReadinessIfNeeded()
            NSLog(
                "event=ios_bootstrap_prepare_deferred_after_reload generation=%lld status=\(reloadedStatus.rawValue)",
                generation
            )
            return
        }
        guard markPrepareRequested(generation) else { throw staleGenerationError() }
        try await enableVPNManager(
            config: config,
            grpcServiceModePort: grpcServiceModePort,
            disableMemoryLimit: disableMemoryLimit,
            generation: generation,
            bootstrapPreparation: bootstrapPreparation
        )
        guard isCurrentGeneration(generation) else { throw staleGenerationError() }
    }
    
    func disconnect() {
        Task {
            try? await disconnectAsync()
        }
    }
    
    func disconnectAsync(generation: Int64? = nil, source: String = "flutter") async throws {
        if let generation, !isCurrentGeneration(generation) {
            return
        }
        let stoppingGeneration = generation ?? currentSessionGeneration()
        let status = manager.connection.status
        if source == "replacement" && isInactiveTunnelStatus(status) {
            // Preparing a new session must not publish a terminal stop for a
            // tunnel that is already inactive. The current connect intent and
            // generation remain authoritative.
            return
        }

        guard markStopRequested(stoppingGeneration, source: source) else { return }
        do {
            try await disableOnDemandForStopIfNeeded(stoppingGeneration)
        } catch {
            guard sessionGenerationMatches(stoppingGeneration) else { return }
            print("save error:", error.localizedDescription)
        }

        var generationPersistenceError: Error?
        do {
            try await persistAcceptedStopGeneration(stoppingGeneration)
        } catch {
            guard sessionGenerationMatches(stoppingGeneration) else { return }
            generationPersistenceError = error
            NSLog(
                "event=ios_stop_generation_persist_retry generation=%lld error=%@",
                stoppingGeneration,
                error.localizedDescription
            )
        }

        guard sessionGenerationMatches(stoppingGeneration) else { return }
        // This is intentionally issued even when NE still reports inactive:
        // startVPNTunnel() can already be pending before `.connecting` is
        // published, and an idempotent stop is the only way to cancel it.
        manager.connection.stopVPNTunnel()
        let stopped = await waitForInactiveTunnel(
            generation: stoppingGeneration,
            stableInactiveObservations: 3
        )
        guard sessionGenerationMatches(stoppingGeneration) else { return }
        guard stopped else {
            throw NSError(
                domain: "VPNManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "VPN tunnel did not stop before the timeout"]
            )
        }

        if generationPersistenceError != nil {
            do {
                try await persistAcceptedStopGeneration(stoppingGeneration)
                generationPersistenceError = nil
            } catch {
                guard sessionGenerationMatches(stoppingGeneration) else { return }
                generationPersistenceError = error
            }
        }

        clearCoreReady()
        connectTime = nil
        if let generationPersistenceError {
            throw generationPersistenceError
        }
        markStopReachedStableInactive(stoppingGeneration)
    }

    private func disableOnDemandForStopIfNeeded(_ generation: Int64) async throws {
        try await withPreferenceMutation {
            guard self.stopTombstoneOwns(generation) else { throw self.staleGenerationError() }
            guard self.manager.isOnDemandEnabled else { return }
            self.manager.isOnDemandEnabled = false
            self.manager.onDemandRules = []
            try await self.manager.saveToPreferences()
            guard self.stopTombstoneOwns(generation) else { throw self.staleGenerationError() }
            try await self.manager.loadFromPreferences()
            guard self.stopTombstoneOwns(generation) else { throw self.staleGenerationError() }
        }
    }

    private func sessionGenerationMatches(_ generation: Int64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == sessionGeneration
    }

    private func stopTombstoneOwns(_ generation: Int64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation > 0 &&
            generation == sessionGeneration &&
            pendingStopCancellationGeneration == generation &&
            requestedAction == "stop"
    }

    static func providerSessionStatusDisposition(
        connectionIsCurrent: Bool,
        generationIsCurrent: Bool,
        expectedGeneration: Int64,
        providerGeneration: Int64,
        providerCoreStarted: Bool,
        requestedAction: String,
        stopCancellationPending: Bool,
        stopReachedStableInactive: Bool,
        bootstrapPreparationPending: Bool = false
    ) -> ProviderSessionStatusDisposition {
        guard connectionIsCurrent, generationIsCurrent else { return .ignore }

        if stopCancellationPending && requestedAction == "stop" {
            guard stopReachedStableInactive else { return .rejectPendingStop }
            return providerCoreStarted &&
                providerGeneration > 0 &&
                providerGeneration == expectedGeneration
                ? .adopt
                : .rejectPendingStop
        }

        guard requestedAction != "stop", providerCoreStarted, providerGeneration > 0 else {
            return .ignore
        }
        let canAdoptColdSession = expectedGeneration == 0
        let matchesCurrentSession = expectedGeneration > 0 && providerGeneration == expectedGeneration
        let providerIsNewer = expectedGeneration > 0 && providerGeneration > expectedGeneration
        return canAdoptColdSession || matchesCurrentSession || providerIsNewer || bootstrapPreparationPending
            ? .adopt
            : .ignore
    }

    static func adoptedProviderGeneration(
        expectedGeneration: Int64,
        providerGeneration: Int64,
        bootstrapPreparationPending: Bool
    ) -> Int64 {
        // A bootstrap save may race an already-issued Settings start whose
        // provider still owns the previously persisted generation. Keep the
        // host generation monotonic and project that proven provider readiness
        // onto the bootstrap generation. Ordinary cold/newer adoption uses the
        // provider's own generation.
        if bootstrapPreparationPending,
           expectedGeneration > 0,
           providerGeneration > 0,
           providerGeneration < expectedGeneration
        {
            return expectedGeneration
        }
        return providerGeneration
    }

    private func refreshProviderReadinessIfNeeded() {
        let now = Date()
        let requestID = UUID()
        generationLock.lock()
        let expectedGeneration = sessionGeneration
        let pendingStopOwnsGeneration = pendingStopCancellationGeneration == sessionGeneration &&
            requestedAction == "stop"
        let pendingStopCanValidateSettingsStart = pendingStopOwnsGeneration &&
            pendingStopReachedInactiveGeneration == sessionGeneration
        let status = manager.connection.status
        let statusIsActive = status == .connected || status == .connecting || status == .reasserting
        if pendingStopCanValidateSettingsStart,
           statusIsActive,
           pendingStopActiveCandidateStartedAt == nil
        {
            pendingStopActiveCandidateStartedAt = now
        }
        var shouldRejectPendingStop = pendingStopOwnsGeneration &&
            statusIsActive &&
            !pendingStopCanValidateSettingsStart
        if providerStatusRequestInFlight,
           let startedAt = providerStatusRequestStartedAt,
           now.timeIntervalSince(startedAt) >= providerStatusRequestTimeout
        {
            if pendingStopCanValidateSettingsStart {
                shouldRejectPendingStop = true
            }
            providerStatusRequestInFlight = false
            providerStatusRequestID = nil
            providerStatusRequestStartedAt = nil
        }
        if pendingStopCanValidateSettingsStart,
           statusIsActive,
           status != .connected,
           let candidateStartedAt = pendingStopActiveCandidateStartedAt,
           now.timeIntervalSince(candidateStartedAt) >= providerStatusRequestTimeout
        {
            shouldRejectPendingStop = true
        }
        let intentAllowsRefresh = sessionGeneration <= 0 ||
            requestedAction == "connect" ||
            pendingStopCanValidateSettingsStart
        let needsRefresh = !shouldRejectPendingStop &&
            status == .connected &&
            intentAllowsRefresh &&
            (sessionGeneration <= 0 || coreReadyGeneration != sessionGeneration) &&
            !providerStatusRequestInFlight
        if needsRefresh {
            providerStatusRequestInFlight = true
            providerStatusRequestID = requestID
            providerStatusRequestStartedAt = now
        }
        generationLock.unlock()
        if shouldRejectPendingStop {
            rejectPendingStopCandidate(expectedGeneration, reason: "provider_status_timeout_or_unproven")
            return
        }
        guard needsRefresh else { return }
        guard let connection = manager.connection as? NETunnelProviderSession else {
            finishProviderStatusRequest(requestID)
            rejectPendingStopCandidate(expectedGeneration, reason: "invalid_provider_session")
            return
        }

        do {
            try connection.sendProviderMessage(Data("session_status".utf8)) { [weak self, weak connection] response in
                guard let self, let connection else { return }
                self.acceptProviderSessionStatus(
                    response,
                    requestID: requestID,
                    expectedGeneration: expectedGeneration,
                    connection: connection
                )
            }
        } catch {
            finishProviderStatusRequest(requestID)
            rejectPendingStopCandidate(expectedGeneration, reason: "provider_message_failed")
            NSLog("event=ios_provider_status_failed error=%@", error.localizedDescription)
        }
    }

    private func rejectPendingStopCandidate(_ generation: Int64, reason: String) {
        generationLock.lock()
        let shouldReject = generation > 0 &&
            generation == sessionGeneration &&
            pendingStopCancellationGeneration == generation &&
            requestedAction == "stop"
        if shouldReject {
            pendingStopActiveCandidateStartedAt = nil
            providerStatusRequestInFlight = false
            providerStatusRequestID = nil
            providerStatusRequestStartedAt = nil
        }
        generationLock.unlock()
        guard shouldReject else { return }
        NSLog(
            "event=ios_pending_stop_candidate_rejected generation=%lld reason=%@",
            generation,
            reason
        )
        manager.connection.stopVPNTunnel()
    }

    private func finishProviderStatusRequest(_ requestID: UUID) {
        generationLock.lock()
        if providerStatusRequestID == requestID {
            providerStatusRequestInFlight = false
            providerStatusRequestID = nil
            providerStatusRequestStartedAt = nil
        }
        generationLock.unlock()
    }

    private func acceptProviderSessionStatus(
        _ response: Data?,
        requestID: UUID,
        expectedGeneration: Int64,
        connection: NETunnelProviderSession
    ) {
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

        let connectionIsCurrent = connection === manager.connection && connection.status == .connected
        generationLock.lock()
        guard providerStatusRequestID == requestID else {
            generationLock.unlock()
            return
        }
        providerStatusRequestInFlight = false
        providerStatusRequestID = nil
        providerStatusRequestStartedAt = nil
        let disposition = Self.providerSessionStatusDisposition(
            connectionIsCurrent: connectionIsCurrent,
            generationIsCurrent: sessionGeneration == expectedGeneration,
            expectedGeneration: expectedGeneration,
            providerGeneration: providerGeneration,
            providerCoreStarted: providerCoreStarted,
            requestedAction: requestedAction,
            stopCancellationPending: pendingStopCancellationGeneration == expectedGeneration,
            stopReachedStableInactive: pendingStopReachedInactiveGeneration == expectedGeneration,
            bootstrapPreparationPending: bootstrapPreparationGeneration != nil
        )
        if disposition == .adopt {
            let adoptedGeneration = Self.adoptedProviderGeneration(
                expectedGeneration: expectedGeneration,
                providerGeneration: providerGeneration,
                bootstrapPreparationPending: bootstrapPreparationGeneration != nil
            )
            sessionGeneration = adoptedGeneration
            coreReadyGeneration = adoptedGeneration
            providerCoreReadyAcknowledgedGeneration = adoptedGeneration
            requestedAction = "connect"
            stopSource = ""
            pendingStopCancellationGeneration = nil
            pendingStopReachedInactiveGeneration = nil
            pendingStopActiveCandidateStartedAt = nil
            bootstrapPreparationGeneration = nil
            snapshotSequence += 1
        }
        let shouldRepublish = disposition == .adopt
        let shouldRejectPendingStop = disposition == .rejectPendingStop
        generationLock.unlock()

        if shouldRepublish {
            setState(manager.connection.status)
        } else if shouldRejectPendingStop {
            rejectPendingStopCandidate(expectedGeneration, reason: "provider_generation_or_readiness_mismatch")
        }
    }
}
