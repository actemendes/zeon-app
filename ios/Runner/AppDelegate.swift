import UIKit
import Flutter
import HiddifyCore
import Sentry
@main
@objc class AppDelegate: FlutterAppDelegate {
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
#if targetEnvironment(simulator) && ZEON_IOS_SIMULATOR_LAB
        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
#else
        setupFileManager()
#if ZEON_IOS_LAB
        // A diagnostic build cannot start a tunnel without a bounded run lease.
        // A relaunch without these arguments must not renew an existing lease.
        if let raw = ProcessInfo.processInfo.environment["ZEON_IOS_LAB_DEADLINE"],
           let deadline = Double(raw), deadline > Date().timeIntervalSince1970,
           deadline <= Date().timeIntervalSince1970 + 600 {
            do {
                try raw.write(to: FilePath.sharedDirectory.appendingPathComponent("ios-lab-deadline"),
                              atomically: true, encoding: .utf8)
                let source = Bundle.main.infoDictionary?["ZeonLabSourceSHA"] as? String ?? "unknown"
                window?.accessibilityIdentifier = "zeon.lab.lease." + source
            } catch {
                window?.accessibilityIdentifier = "zeon.lab.lease.unavailable"
            }
        }
#endif
        GeneratedPluginRegistrant.register(with: self)
        registerHandlers()
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
#endif
    }
    
    func setupFileManager() {
        try? FileManager.default.createDirectory(at: FilePath.workingDirectory, withIntermediateDirectories: true)
        FileManager.default.changeCurrentDirectoryPath(FilePath.sharedDirectory.path)
    }
    
    func registerHandlers() {
        guard
            let methodRegistrar = registrar(forPlugin: MethodHandler.name),
            let platformRegistrar = registrar(forPlugin: PlatformMethodHandler.name),
            let fileRegistrar = registrar(forPlugin: FileMethodHandler.name),
            let statusRegistrar = registrar(forPlugin: StatusEventHandler.name),
            let alertsRegistrar = registrar(forPlugin: AlertsEventHandler.name)
        else {
            NSLog("Unable to create Flutter plugin registrars")
            return
        }

        MethodHandler.register(with: methodRegistrar)
        PlatformMethodHandler.register(with: platformRegistrar)
        FileMethodHandler.register(with: fileRegistrar)
        StatusEventHandler.register(with: statusRegistrar)
        AlertsEventHandler.register(with: alertsRegistrar)
//        LogsEventHandler.register(with: self.registrar(forPlugin: LogsEventHandler.name)!)
//        GroupsEventHandler.register(with: self.registrar(forPlugin: GroupsEventHandler.name)!)
//        ActiveGroupsEventHandler.register(with: self.registrar(forPlugin: ActiveGroupsEventHandler.name)!)
//        StatsEventHandler.register(with: self.registrar(forPlugin: StatsEventHandler.name)!)
    }
}
