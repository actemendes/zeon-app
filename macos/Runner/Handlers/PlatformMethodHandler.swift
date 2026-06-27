import AppKit
import FlutterMacOS
import Foundation
import IOKit

public class PlatformMethodHandler: NSObject, FlutterPlugin {
  public static let name = "\(Bundle.main.serviceIdentifier)/platform"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: Self.name, binaryMessenger: registrar.messenger)
    let instance = PlatformMethodHandler()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "get_paths":
      result([
        "base": FilePath.sharedDirectory.path,
        "working": FilePath.workingDirectory.path,
        "temp": FilePath.cacheDirectory.path,
      ])
    case "get_stable_device_id":
      result(stableDeviceId())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func stableDeviceId() -> String {
    let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(service) }
    guard service != 0,
          let uuid = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
          )?.takeRetainedValue() as? String
    else {
      return Host.current().localizedName ?? ""
    }
    return uuid
  }
}
