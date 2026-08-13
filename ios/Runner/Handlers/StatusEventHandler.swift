//
//  StatusEventHandler.swift
//  Runner
//
//  Created by GFWFighter on 10/24/23.
//

import Foundation
import Combine

public class StatusEventHandler: NSObject, FlutterPlugin, FlutterStreamHandler {
    static let name = "\(Bundle.main.serviceIdentifier)/service.status"
    
    private var channel: FlutterEventChannel?
    
    private var cancellable: AnyCancellable?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = StatusEventHandler()
        instance.channel = FlutterEventChannel(name: Self.name, binaryMessenger: registrar.messenger(), codec: FlutterJSONMethodCodec())
        instance.channel?.setStreamHandler(instance)
    }
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        cancellable = VPNManager.shared.$state.sink { [events] status in
            var snapshot = VPNManager.shared.sessionSnapshot()
            let phase = snapshot["phase"] as? String
            let statusName: String
            switch phase {
            case "connected": statusName = "Started"
            case "stopping": statusName = "Stopping"
            case "disconnected": statusName = "Stopped"
            default: statusName = "Starting"
            }
            snapshot["status"] = statusName
            events(snapshot)
        }
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        cancellable?.cancel()
        return nil
    }
}
