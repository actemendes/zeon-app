//
//  MethodHandler.swift
//  Runner
//
//  Created by GFWFighter on 10/23/23.
//

import Flutter
import Combine
import HiddifyCore

public class MethodHandler: NSObject, FlutterPlugin {
    
    private var cancelBag: Set<AnyCancellable> = []
    
    public static let name = "\(Bundle.main.serviceIdentifier)/method"
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: Self.name, binaryMessenger: registrar.messenger())
        let instance = MethodHandler()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.channel = channel
    }
    
    private var channel: FlutterMethodChannel?
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        @Sendable func mainResult(_ res: Any?) async -> Void {
            await MainActor.run {
                result(res)
            }
        }
        
        switch call.method {
        case "get_vpn_session_snapshot":
            result(VPNManager.shared.sessionSnapshot())
        case "set_session_generation":
            guard let generation = generation(from: call.arguments) else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            result(NSNumber(value: VPNManager.shared.setSessionGeneration(generation)))
        case "mark_core_started":
            guard let generation = generation(from: call.arguments) else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            Task {
                do {
                    try await VPNManager.shared.markCoreStarted(generation)
                    await mainResult(NSNumber(value: generation))
                } catch {
                    if !VPNManager.shared.isCurrentGeneration(generation) {
                        NSLog("event=stale_completion_ignored source=ios_mark_core_started")
                        await mainResult(NSNumber(value: VPNManager.shared.currentSessionGeneration()))
                        return
                    }
                    await mainResult(
                        FlutterError(code: "CORE_NOT_READY", message: error.localizedDescription, details: nil)
                    )
                }
            }
        case "get_grpc_server_public_key":
            result("")
        case "add_grpc_client_public_key":
            result("")
        case "parse_config":
            guard
                let args = call.arguments as? [String:Any?],
                let path = args["path"] as? String,
                let tempPath = args["tempPath"] as? String,
                let debug = (args["debug"] as? NSNumber)?.boolValue
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            var error: NSError?
            //MobileParse(path, tempPath, debug, &error)
            if let error {
                result(FlutterError(code: String(error.code), message: error.description, details: nil))
                return
            }
            result("")
        case "change_zeon_options":
            guard let options = call.arguments as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            VPNConfig.shared.configOptions = options
            result(true)
        case "setup":
                Task {
                    guard
                        let args = call.arguments as? [String: Any?],
                        let baseDir = args["baseDir"] as? String,
                        let workingDir = args["workingDir"] as? String,
                        let tempDir = args["tempDir"] as? String,
                        let mode = args["mode"] as? Int,
                        let grpcPort = args["grpcPort"] as? Int
                    else {
                        result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                        return
                    }
                    VPNConfig.shared.baseDir=baseDir
                    VPNConfig.shared.workingDir=workingDir
                    VPNConfig.shared.tempDir=tempDir
                    var error: NSError?
                    let opts = MobileSetupOptions()
                    opts.basePath = baseDir
                    opts.workingDir = workingDir
                    opts.tempDir = tempDir
                    opts.listen = "127.0.0.1:\(grpcPort)"
                    opts.secret = ""
                    opts.debug = false
                    opts.mode = 4
                    opts.fixAndroidStack = false
                    MobileSetup(opts,
                        nil,
                        &error
                    )
                    
                    if let error {
                        result(FlutterError(code: String(error.code), message: error.localizedDescription, details: nil))
                        return
                    }
                    do {
                        try await VPNManager.shared.setup()
                    } catch {
                        result(FlutterError(code: "SETUP", message: error.localizedDescription, details: nil))
                        return
                    }
                    result(true)
                }
        case "start":
            Task {
                guard
                    let args = call.arguments as? [String:Any?],
                    let path = args["path"] as? String,
                    let name = args["name"] as? String,
                    let grpcPort=args["grpcPort"] as? Int,
                    let generation = generation(from: args)
                else {
                    await mainResult(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                    return
                }
                VPNConfig.shared.activeConfigPath = path
                VPNConfig.shared.activeProfileName = name
                VPNConfig.shared.grpcServiceModePort=grpcPort
                
                var error: NSError?
                //let configstr=MobileBuildConfig(path,&error) as String
                if let error {
                    await mainResult(FlutterError(code: String(error.code), message: error.description, details: nil))
                    return
                }
                do {
                    guard VPNManager.shared.isCurrentGeneration(generation) else {
                        await mainResult(true)
                        return
                    }
                    try await VPNManager.shared.setup()
                    try await VPNManager.shared.connect(
                        with: path,
                        grpcServiceModePort: grpcPort,
                        disableMemoryLimit: VPNConfig.shared.disableMemoryLimit,
                        generation: generation
                    )
                } catch {
                    if !VPNManager.shared.isCurrentGeneration(generation) {
                        NSLog("event=stale_exception_ignored source=ios_start")
                        await mainResult(true)
                        return
                    }
                    await mainResult(FlutterError(code: "SETUP_CONNECTION", message: error.localizedDescription, details: nil))
                    return
                }
                await mainResult(true)
            }
        case "prepare_vpn":
            Task {
                guard
                    let args = call.arguments as? [String:Any?],
                    let path = args["path"] as? String,
                    let name = args["name"] as? String,
                    let grpcPort=args["grpcPort"] as? Int,
                    let generation = generation(from: args)
                else {
                    await mainResult(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                    return
                }
                let disableMemoryLimit = args["disableMemoryLimit"] as? Bool ?? VPNConfig.shared.disableMemoryLimit
                VPNConfig.shared.activeConfigPath = path
                VPNConfig.shared.activeProfileName = name
                VPNConfig.shared.grpcServiceModePort=grpcPort
                VPNConfig.shared.disableMemoryLimit = disableMemoryLimit
                do {
                    guard VPNManager.shared.isCurrentGeneration(generation) else {
                        await mainResult(true)
                        return
                    }
                    try await VPNManager.shared.setup()
                    try await VPNManager.shared.prepare(
                        with: path,
                        grpcServiceModePort: grpcPort,
                        disableMemoryLimit: disableMemoryLimit,
                        generation: generation
                    )
                } catch {
                    if !VPNManager.shared.isCurrentGeneration(generation) {
                        NSLog("event=stale_exception_ignored source=ios_prepare")
                        await mainResult(true)
                        return
                    }
                    await mainResult(FlutterError(code: "PREPARE_VPN", message: error.localizedDescription, details: nil))
                    return
                }
                await mainResult(true)
            }
//        case "restart":
//            Task { [unowned self] in
//                guard
//                    let args = call.arguments as? [String:Any?],
//                    let path = args["path"] as? String,
//                    let name = args["name"] as? String,
//                    let grpcPort=args["grpcPort"] as? Int
//                else {
//                    await mainResult(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
//                    return
//                }
//                VPNConfig.shared.activeConfigPath = path
//                VPNConfig.shared.activeProfileName = name
//                VPNConfig.shared.grpcServiceModePort=grpcPort
//                
//                
//                VPNManager.shared.disconnect()
//                await waitForStop().value
//                var error: NSError?
//                do {
//                    try await VPNManager.shared.setup()
//                    try await VPNManager.shared.connect(with: path, disableMemoryLimit: VPNConfig.shared.disableMemoryLimit)
//                } catch {
//                    await mainResult(FlutterError(code: "SETUP_CONNECTION", message: error.localizedDescription, details: nil))
//                    return
//                }
//                await mainResult(true)
//            }
        case "stop":
            Task {
                guard let generation = generation(from: call.arguments) else {
                    await mainResult(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                    return
                }
                if VPNManager.shared.isCurrentGeneration(generation) {
                    await VPNManager.shared.disconnectAsync(generation: generation)
                } else {
                    NSLog("event=stale_completion_ignored source=ios_stop")
                }
                await mainResult(true)
            }
        case "reset":
            VPNManager.shared.reset()
            result(true)
        case "url_test":
            guard
                let args = call.arguments as? [String:Any?]
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            let group = args["groupTag"] as? String
            FileManager.default.changeCurrentDirectoryPath(FilePath.sharedDirectory.path)
            do {
                try LibboxNewStandaloneCommandClient()?.urlTest(group)
            } catch {
                result(FlutterError(code: "URL_TEST", message: error.localizedDescription, details: nil))
                return
            }
            result(true)
        case "select_outbound":
            guard
                let args = call.arguments as? [String:Any?],
                let group = args["groupTag"] as? String,
                let outbound = args["outboundTag"] as? String
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            FileManager.default.changeCurrentDirectoryPath(FilePath.sharedDirectory.path)
            do {
                try LibboxNewStandaloneCommandClient()?.selectOutbound(group, outboundTag: outbound)
            } catch {
                result(FlutterError(code: "SELECT_OUTBOUND", message: error.localizedDescription, details: nil))
                return
            }
            result(true)
        case "generate_config":
            guard
                let args = call.arguments as? [String:Any?],
                let path = args["path"] as? String
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            var error: NSError?
//            let config = MobileBuildConfig(path, VPNConfig.shared.configOptions, &error)
//            if let error {
//                result(FlutterError(code: "BUILD_CONFIG", message: error.localizedDescription, details: nil))
//                return
//            }
//            result(config)
        case "generate_warp_config":
            guard let args = call.arguments as? [String: Any],
                  let licenseKey = args["license-key"] as? String,
                  let accountId = args["previous-account-id"] as? String,
                  let accessToken = args["previous-access-token"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
//            let warpConfig = MobileGenerateWarpConfig(licenseKey, accountId, accessToken, nil)
//            result(warpConfig)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func generation(from arguments: Any?) -> Int64? {
        guard let args = arguments as? [String: Any?] else { return nil }
        if let value = args["generation"] as? NSNumber {
            return value.int64Value
        }
        if let value = args["generation"] as? Int {
            return Int64(value)
        }
        if let value = args["generation"] as? String {
            return Int64(value)
        }
        return nil
    }
    
    private func waitForStop() -> Future<Void, Never> {
        return Future { promise in
            var cancellable: AnyCancellable? = nil
            cancellable = VPNManager.shared.$state
                .filter { $0 == .disconnected }
                .first()
                .delay(for: 0.5, scheduler: RunLoop.current)
                .sink(receiveValue: { _ in
                    promise(.success(()))
                    cancellable?.cancel()
                })
        }
    }
}
