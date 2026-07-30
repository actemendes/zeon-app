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
            let generation = VPNManager.shared.currentSessionGeneration()
            switch status {
            case .reasserting, .connecting:
                events(["status": "Starting", "generation": generation])
            case .connected:
                // NetworkExtension being connected proves packet-tunnel
                // readiness, but not that the current core start completed.
                let ready = VPNManager.shared.isCoreReadyForCurrentGeneration()
                events(["status": ready ? "Started" : "Starting", "generation": generation])
            case .disconnecting:
                events(["status": "Stopping", "generation": generation])
            case .disconnected, .invalid:
                events(["status": "Stopped", "generation": generation])
            @unknown default:
                events(["status": "Stopped", "generation": generation])
            }
        }
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        cancellable?.cancel()
        return nil
    }
}
