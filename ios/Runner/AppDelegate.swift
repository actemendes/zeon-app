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
        setupFileManager()
        GeneratedPluginRegistrant.register(with: self)
        registerHandlers()
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
