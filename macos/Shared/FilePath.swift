import Foundation

public enum FilePath {
  public static let packageName = {
    Bundle.main.infoDictionary?["BASE_BUNDLE_IDENTIFIER"] as? String
      ?? Bundle.main.bundleIdentifier
      ?? "app.zeon.ios"
  }()
}

public extension FilePath {
  static let groupName = "group.\(packageName)"

  private static let fallbackSharedDirectory: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent(packageName, isDirectory: true)
  }()

  static let sharedDirectory = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: FilePath.groupName
  ) ?? fallbackSharedDirectory

  static let cacheDirectory = sharedDirectory
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Caches", isDirectory: true)

  static let workingDirectory = cacheDirectory.appendingPathComponent("Working", isDirectory: true)
}

public extension URL {
  var fileName: String {
    var path = relativePath
    if let index = path.lastIndex(of: "/") {
      path = String(path[path.index(index, offsetBy: 1)...])
    }
    return path
  }
}
