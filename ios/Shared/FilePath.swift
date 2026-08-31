//
//  FilePath.swift
//  SingBoxPacketTunnel
//
//  Created by GFWFighter on 7/25/1402 AP.
//

import Foundation

public enum FilePath {
    public static let packageName = {
        if let configuredIdentifier = Bundle.main.infoDictionary?["BASE_BUNDLE_IDENTIFIER"] as? String,
           !configuredIdentifier.isEmpty
        {
            return configuredIdentifier
        }
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            let extensionSuffix = ".ZeonPacketTunnel"
            if bundleIdentifier.hasSuffix(extensionSuffix) {
                return String(bundleIdentifier.dropLast(extensionSuffix.count))
            }
            return bundleIdentifier
        }
        return "app.zeon.ios"
    }()
}

public extension FilePath {
    static let groupName = "group.\(packageName)"

    private static let fallbackSharedDirectory: URL = {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseDirectory.appendingPathComponent(packageName, isDirectory: true)
    }()

    static let sharedDirectory: URL = {
        guard let sharedDirectory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: FilePath.groupName
        ) else {
            NSLog(
                "[FilePath] App Group container %@ is unavailable; using sandbox fallback %@",
                FilePath.groupName,
                fallbackSharedDirectory.path
            )
            return fallbackSharedDirectory
        }
        return sharedDirectory
    }()

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
