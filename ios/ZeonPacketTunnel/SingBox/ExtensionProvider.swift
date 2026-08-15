import Foundation
import HiddifyCore
import NetworkExtension
import os.log

open class ExtensionProvider: NEPacketTunnelProvider {
    public static let errorFile = FilePath.workingDirectory.appendingPathComponent("network_extension_error.log")
    private let logger = Logger(subsystem: "app.zeon.ios.ZeonPacketTunnel", category: "PacketTunnel")
    
//    private var commandServer: LibboxCommandServer!
    private var systemProxyAvailable = false
    private var systemProxyEnabled = false
    private var platformInterface: ExtensionPlatformInterface!
    private var config: String!
    private var sessionGeneration: Int64 = 0
    private var serviceStarted = false

    override open func startTunnel(options: [String: NSObject]?) async throws {
        // Preserve the previous provider session. A crash/jetsam cannot upload
        // its own tail, so the host app must be able to collect it afterwards.
        let previousErrorFile = FilePath.workingDirectory.appendingPathComponent("network_extension_error.previous.log")
        try? FileManager.default.removeItem(at: previousErrorFile)
        if FileManager.default.fileExists(atPath: ExtensionProvider.errorFile.path) {
            try? FileManager.default.moveItem(at: ExtensionProvider.errorFile, to: previousErrorFile)
        }
        try? FileManager.default.removeItem(at: FilePath.workingDirectory.appendingPathComponent("TestLog"))
        
        do {
            serviceStarted = false
            writeMessage("(packet-tunnel) starting")
            
            let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
            let launchedFromApp = options?["Config"] != nil
            let disableMemoryLimit = false && optionString(
                "DisableMemoryLimit",
                options: options,
                providerConfiguration: providerConfiguration
            ) == "YES"
            let grpcServiceModePort = optionInt(
                "GrpcServiceModePort",
                options: options,
                providerConfiguration: providerConfiguration
            ) ?? 17179
            sessionGeneration = Int64(optionInt(
                "Generation",
                options: options,
                providerConfiguration: providerConfiguration
            ) ?? 0)
            let config = optionString("Config", options: options, providerConfiguration: providerConfiguration) ?? ""
            
            // guard let config = SingBox.setupConfig(config: config2) else {
            //             writeFatalError("(packet-tunnel) error: config is invalid")
            //             return
            // }
//            self.config = config

            do {
                try FileManager.default.createDirectory(at: FilePath.workingDirectory, withIntermediateDirectories: true)
            } catch {
                writeFatalError("(packet-tunnel) error: create working directory: \(error.localizedDescription)")
                return
            }
            
            // Ensure directories exist
            try createRequiredDirectories()
            
            // Log directory paths for debugging
            let sharedDir = FilePath.sharedDirectory.relativePath
            let workDir = FilePath.workingDirectory.relativePath
            let cacheDir = FilePath.cacheDirectory.relativePath
            if platformInterface == nil {
                platformInterface = ExtensionPlatformInterface(self)
            }
            // Initialize mobile setup with error handling
            var setupError: NSError?
            let opts = MobileSetupOptions()
            opts.basePath = sharedDir
            opts.workingDir = workDir
            opts.tempDir = cacheDir
            opts.listen = "127.0.0.1:\(grpcServiceModePort)"
            opts.secret = ""
            opts.debug = false
            opts.mode = 4
            opts.fixAndroidStack = false

            MobileSetup(opts,
                platformInterface,
                &setupError
            )
            
            if let setupError = setupError {
                throw setupError
            }
            
            
            LibboxSetMemoryLimit(!disableMemoryLimit)
            
            writeMessage("(packet-tunnel) setup completed generation=\(sessionGeneration)")
            if (!launchedFromApp) {
                if config.isEmpty {
                    writeMessage("(packet-tunnel) saved configuration is missing; waiting for app start command")
                    return
                }
                try await startService1(config)
            }

            
        } catch {
            logger.error("Tunnel setup failed: \(error.localizedDescription)")
            writeFatalError("(packet-tunnel) setup failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func startService1(_ config: String) async throws {
        writeMessage("Starting service")
        var error: NSError?
//        
        do {
            try MobileStart(config, "", &error)
            if let error = error {
                throw error
            }
            writeMessage("(packet-tunnel) service started successfully")
            serviceStarted = true
        } catch {
            writeFatalError("(packet-tunnel) error: start service: \(error.localizedDescription)")
            throw error
        }
    }

    private func optionString(
        _ key: String,
        options: [String: NSObject]?,
        providerConfiguration: [String: Any]
    ) -> String? {
        if let value = options?[key] as? NSString {
            return value as String
        }
        if let value = options?[key] as? String {
            return value
        }
        if let value = providerConfiguration[key] as? String {
            return value
        }
        if let value = providerConfiguration[key] as? NSString {
            return value as String
        }
        return nil
    }

    private func optionInt(
        _ key: String,
        options: [String: NSObject]?,
        providerConfiguration: [String: Any]
    ) -> Int? {
        if let value = options?[key] as? NSNumber {
            return value.intValue
        }
        if let value = options?[key] as? NSString {
            return Int(value as String)
        }
        if let value = providerConfiguration[key] as? NSNumber {
            return value.intValue
        }
        if let value = providerConfiguration[key] as? Int {
            return value
        }
        if let value = providerConfiguration[key] as? String {
            return Int(value)
        }
        return nil
    }
    
    private func createRequiredDirectories() throws {
        let directories = [
            FilePath.workingDirectory,
            FilePath.sharedDirectory,
            FilePath.cacheDirectory
        ]
        
        for directory in directories {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                logger.error("Failed to create directory at \(directory.path): \(error.localizedDescription)")
                throw error
            }
        }
    }
    
    func writeMessage(_ message: String) {
        logger.debug("\(message)")
        writeError(message)
    }
    
    func writeError(_ message: String) {
        let messageWithNewline = "[\(Date())] \(message)\n"
        do {
            if FileManager.default.fileExists(atPath: ExtensionProvider.errorFile.path) {
                if let fileHandle = try? FileHandle(forWritingTo: ExtensionProvider.errorFile) {
                    defer { fileHandle.closeFile() }
                    fileHandle.seekToEndOfFile()
                    if let data = messageWithNewline.data(using: .utf8) {
                        fileHandle.write(data)
                    }
                }
            } else {
                try messageWithNewline.write(to: ExtensionProvider.errorFile, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Failed to write to error file: \(error.localizedDescription)")
        }
    }
    
    public func writeFatalError(_ message: String) {
        logger.fault("Fatal error: \(message)")
        writeError("FATAL: \(message)")
        cancelTunnelWithError(NSError(domain: "ExtensionProvider", code: 0, userInfo: [NSLocalizedDescriptionKey: message]))
    }
    
    override open func stopTunnel(with reason: NEProviderStopReason) async {
//        logger.debug("Stopping tunnel with reason: \(reason)")
        writeMessage("(packet-tunnel) stopping, reason: \(reason)")
        stopService()
        serviceStarted = false
        sessionGeneration = 0
        
//        // Allow time for cleanup
//        try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
//        
//        if let server = commandServer {
//            try? server.close()
//            commandServer = nil
//        }
    }
    
    private func stopService() {
        logger.debug("Stopping service")
        MobileClose(4)
        if let platformInterface {
            platformInterface.reset()
        }
    }
    
    func reloadService() async {
        logger.debug("Reloading service")
        writeMessage("(packet-tunnel) reloading service")
//        reasserting = true
//        defer { reasserting = false }
//        
//        stopService()
//        do {
//            guard let config = try? String(contentsOf: FilePath.configFile) else {
//                writeFatalError("(packet-tunnel) error: cannot read config file")
//                return
//            }
//            try await startService(config)
//        } catch {
//            writeFatalError("(packet-tunnel) error: reload service: \(error.localizedDescription)")
//        }
    }
    
    override open func handleAppMessage(_ messageData: Data) async -> Data? {
        logger.debug("Handling app message")
        return messageData
    }

    func sessionStatusData() -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "generation": sessionGeneration,
            "coreStarted": serviceStarted,
        ])
    }

    func markCoreStartedData(generation: Int64) -> Data? {
        let accepted = generation > 0 && generation == sessionGeneration
        if accepted {
            serviceStarted = true
            writeMessage("(packet-tunnel) app core readiness acknowledged generation=\(generation)")
        } else {
            writeMessage(
                "(packet-tunnel) rejected app core readiness generation=\(generation) current=\(sessionGeneration)"
            )
        }
        return try? JSONSerialization.data(withJSONObject: [
            "ack": "mark_core_started",
            "accepted": accepted,
            "generation": sessionGeneration,
            "coreStarted": serviceStarted,
        ])
    }
    
    override open func sleep() async {
        logger.debug("Entering sleep mode")
//        MobilePause()
        // Add any sleep mode handling if needed
    }
    
    override open func wake() {
        logger.debug("Waking from sleep")
        MobileWake()
        // Add any wake handling if needed
    }
}

// Extension to support error handling
extension ExtensionProvider {
    enum ExtensionError: Error {
        case configurationMissing
        case directoryCreationFailed
        case serviceStartFailed
        
        var localizedDescription: String {
            switch self {
            case .configurationMissing:
                return "Configuration not provided"
            case .directoryCreationFailed:
                return "Failed to create required directories"
            case .serviceStartFailed:
                return "Failed to start the service"
            }
        }
    }
}
