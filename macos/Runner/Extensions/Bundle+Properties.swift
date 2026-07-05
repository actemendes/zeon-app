import Foundation

extension Bundle {
  var serviceIdentifier: String {
    (infoDictionary?["SERVICE_IDENTIFIER"] as? String) ?? "com.zeon.app"
  }

  var baseBundleIdentifier: String {
    (infoDictionary?["BASE_BUNDLE_IDENTIFIER"] as? String)
      ?? bundleIdentifier
      ?? "app.zeon.ios"
  }
}
