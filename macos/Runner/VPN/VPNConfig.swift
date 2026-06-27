import Combine
import Foundation

class VPNConfig: ObservableObject {
  static let shared = VPNConfig()

  @Stored(key: "VPN.ActiveConfigPath", defaultValue: "")
  var activeConfigPath: String

  @Stored(key: "VPN.ActiveProfileName", defaultValue: "")
  var activeProfileName: String

  @Stored(key: "VPN.GrpcServiceModePort", defaultValue: 0)
  var grpcServiceModePort: Int

  @Stored(key: "VPN.workingDir", defaultValue: "")
  var workingDir: String

  @Stored(key: "VPN.tempDir", defaultValue: "")
  var tempDir: String

  @Stored(key: "VPN.baseDir", defaultValue: "")
  var baseDir: String

  @Stored(key: "VPN.ConfigOptions", defaultValue: "")
  var configOptions: String

  @Stored(key: "VPN.DisableMemoryLimit", defaultValue: false)
  var disableMemoryLimit: Bool
}
