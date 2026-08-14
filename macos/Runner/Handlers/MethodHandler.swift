import Combine
import FlutterMacOS
import Foundation
import HiddifyCore

public class MethodHandler: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?

  public static let name = "\(Bundle.main.serviceIdentifier)/method"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: Self.name, binaryMessenger: registrar.messenger)
    let instance = MethodHandler()
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.channel = channel
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    @Sendable func mainResult(_ res: Any?) async {
      await MainActor.run {
        result(res)
      }
    }

    switch call.method {
    case "set_session_generation":
      guard let generation = sessionGeneration(from: call.arguments) else {
        result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
        return
      }
      result(NSNumber(value: VPNManager.shared.setSessionGeneration(generation)))
    case "mark_core_started":
      guard let generation = sessionGeneration(from: call.arguments) else {
        result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
        return
      }
      guard VPNManager.shared.isCurrentSessionGeneration(generation) else {
        result(
          FlutterError(
            code: "STALE_GENERATION",
            message: "stale VPN session generation",
            details: NSNumber(value: VPNManager.shared.currentSessionGeneration())
          )
        )
        return
      }
      // The macOS packet-tunnel status channel remains the readiness source;
      // this acknowledgement only completes Dart's lifecycle fence.
      result(NSNumber(value: generation))
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
          await mainResult(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
          return
        }

        VPNConfig.shared.baseDir = baseDir
        VPNConfig.shared.workingDir = workingDir
        VPNConfig.shared.tempDir = tempDir

        try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: workingDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        let opts = MobileSetupOptions()
        opts.basePath = baseDir
        opts.workingDir = workingDir
        opts.tempDir = tempDir
        opts.listen = "127.0.0.1:\(grpcPort)"
        opts.secret = ""
        opts.debug = false
        opts.mode = mode
        opts.fixAndroidStack = false

        var error: NSError?
        MobileSetup(opts, nil, &error)
        if let error {
          await mainResult(FlutterError(code: String(error.code), message: error.localizedDescription, details: nil))
          return
        }

        do {
          try await VPNManager.shared.setup()
          await mainResult(true)
        } catch {
          await mainResult(FlutterError(code: "SETUP", message: error.localizedDescription, details: nil))
        }
      }
    case "start":
      Task {
        guard
          let args = call.arguments as? [String: Any?],
          let path = args["path"] as? String,
          let name = args["name"] as? String,
          let grpcPort = args["grpcPort"] as? Int,
          let generation = sessionGeneration(from: args)
        else {
          await mainResult(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
          return
        }

        VPNConfig.shared.activeConfigPath = path
        VPNConfig.shared.activeProfileName = name
        VPNConfig.shared.grpcServiceModePort = grpcPort

        do {
          guard VPNManager.shared.isCurrentSessionGeneration(generation) else {
            await mainResult(true)
            return
          }
          try await VPNManager.shared.connect(
            with: path,
            grpcServiceModePort: grpcPort,
            disableMemoryLimit: VPNConfig.shared.disableMemoryLimit,
            generation: generation
          )
          await mainResult(true)
        } catch {
          await mainResult(FlutterError(code: "SETUP_CONNECTION", message: error.localizedDescription, details: nil))
        }
      }
    case "stop":
      guard let generation = sessionGeneration(from: call.arguments) else {
        result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
        return
      }
      if VPNManager.shared.isCurrentSessionGeneration(generation) {
        VPNManager.shared.disconnect()
      } else {
        NSLog("event=stale_completion_ignored source=macos_stop")
      }
      result(NSNumber(value: VPNManager.shared.currentSessionGeneration()))
    case "reset":
      VPNManager.shared.reset()
      result(true)
    case "change_hiddify_options":
      guard let options = call.arguments as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
        return
      }
      VPNConfig.shared.configOptions = options
      result(true)
    case "get_grpc_server_public_key", "add_grpc_client_public_key":
      result("")
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func sessionGeneration(from arguments: Any?) -> Int64? {
    guard let args = arguments as? [String: Any?] else { return nil }
    if let value = args["generation"] as? NSNumber {
      return value.int64Value
    }
    if let value = args["generation"] as? Int64 {
      return value
    }
    if let value = args["generation"] as? Int {
      return Int64(value)
    }
    return nil
  }
}
