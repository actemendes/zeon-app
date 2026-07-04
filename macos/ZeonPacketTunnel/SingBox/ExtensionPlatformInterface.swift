import Foundation
import HiddifyCore
import Network
import NetworkExtension
import Darwin
import SystemConfiguration

public class ExtensionPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
  private let tunnel: ExtensionProvider
  private var networkSettings: NEPacketTunnelNetworkSettings?
  private var nwMonitor: NWPathMonitor?
  private var lastInterfaceLog = ""

  init(_ tunnel: ExtensionProvider) {
    self.tunnel = tunnel
  }

  public func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
    try runBlocking { [self] in
      try await openTun0(options, ret0_)
    }
  }

  private func openTun0(_ options: LibboxTunOptionsProtocol?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
    guard let options else {
      throw NSError(domain: "ExtensionPlatformInterface", code: 1, userInfo: [NSLocalizedDescriptionKey: "nil TUN options"])
    }
    guard let ret0_ else {
      throw NSError(domain: "ExtensionPlatformInterface", code: 2, userInfo: [NSLocalizedDescriptionKey: "nil TUN return pointer"])
    }

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "::1")
    settings.mtu = NSNumber(value: options.getMTU())

    let dnsServer = try options.getDNSServerAddress()
    let dnsSettings = NEDNSSettings(servers: [dnsServer.value])
    dnsSettings.matchDomains = [""]
    dnsSettings.matchDomainsNoSearch = true
    settings.dnsSettings = dnsSettings

    var ipv4Address: [String] = []
    var ipv4Mask: [String] = []
    let ipv4AddressIterator = options.getInet4Address()
    while ipv4AddressIterator?.hasNext() == true {
      let prefix = ipv4AddressIterator?.next()
      if let prefix {
        ipv4Address.append(prefix.address())
        ipv4Mask.append(prefix.mask())
      }
    }
    if !ipv4Address.isEmpty {
      let ipv4Settings = NEIPv4Settings(addresses: ipv4Address, subnetMasks: ipv4Mask)
      var routes: [NEIPv4Route] = []
      let routeIterator = options.getInet4RouteAddress()
      while routeIterator?.hasNext() == true {
        if let prefix = routeIterator?.next() {
          routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
        }
      }
      if routes.isEmpty {
        routes.append(.default())
      }
      var excludedRoutes: [NEIPv4Route] = []
      let excludeIterator = options.getInet4RouteExcludeAddress()
      while excludeIterator?.hasNext() == true {
        if let prefix = excludeIterator?.next() {
          excludedRoutes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
        }
      }
      ipv4Settings.includedRoutes = routes
      ipv4Settings.excludedRoutes = excludedRoutes
      settings.ipv4Settings = ipv4Settings
    }

    var ipv6Address: [String] = []
    var ipv6Prefixes: [NSNumber] = []
    let ipv6AddressIterator = options.getInet6Address()
    while ipv6AddressIterator?.hasNext() == true {
      let prefix = ipv6AddressIterator?.next()
      if let prefix {
        ipv6Address.append(prefix.address())
        ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
      }
    }
    if !ipv6Address.isEmpty {
      let ipv6Settings = NEIPv6Settings(addresses: ipv6Address, networkPrefixLengths: ipv6Prefixes)
      var routes: [NEIPv6Route] = []
      let routeIterator = options.getInet6RouteAddress()
      while routeIterator?.hasNext() == true {
        if let prefix = routeIterator?.next() {
          routes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
        }
      }
      if routes.isEmpty {
        routes.append(.default())
      }
      var excludedRoutes: [NEIPv6Route] = []
      let excludeIterator = options.getInet6RouteExcludeAddress()
      while excludeIterator?.hasNext() == true {
        if let prefix = excludeIterator?.next() {
          excludedRoutes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
        }
      }
      ipv6Settings.includedRoutes = routes
      ipv6Settings.excludedRoutes = excludedRoutes
      settings.ipv6Settings = ipv6Settings
    }

    networkSettings = settings
    try await tunnel.setTunnelNetworkSettings(settings)

    if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
      ret0_.pointee = tunFd
      return
    }

    let tunFdFromLoop = LibboxGetTunnelFileDescriptor()
    if tunFdFromLoop != -1 {
      ret0_.pointee = tunFdFromLoop
      return
    }

    throw NSError(domain: "ExtensionPlatformInterface", code: 3, userInfo: [NSLocalizedDescriptionKey: "missing TUN file descriptor"])
  }

  public func autoDetectControl(_ fd: Int32) throws {
  }

  public func autoDetectInterfaceControl(_ fd: Int32) throws -> Bool {
    false
  }

  public func clearDNSCache() {
    guard let networkSettings else { return }
    try? runBlocking {
      self.tunnel.reasserting = true
      defer { self.tunnel.reasserting = false }
      await withCheckedContinuation { continuation in
        self.tunnel.setTunnelNetworkSettings(nil) { _ in continuation.resume() }
      }
      await withCheckedContinuation { continuation in
        self.tunnel.setTunnelNetworkSettings(networkSettings) { _ in continuation.resume() }
      }
    }
  }

  public func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
    nwMonitor?.cancel()
    nwMonitor = nil
  }

  public func findConnectionOwner(
    _ ipProtocol: Int32,
    sourceAddress: String?,
    sourcePort: Int32,
    destinationAddress: String?,
    destinationPort: Int32
  ) throws -> LibboxConnectionOwner {
    throw NSError(domain: "ExtensionPlatformInterface", code: 4, userInfo: [NSLocalizedDescriptionKey: "findConnectionOwner is not implemented"])
  }

  public func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
    let nwInterfaces = nwMonitor?.currentPath.availableInterfaces ?? []
    let interfaces = systemNetworkInterfaces(nwInterfaces: nwInterfaces)
    logInterfacesIfChanged(interfaces)
    return NetworkInterfaceArray(interfaces)
  }

  public func includeAllNetworks() -> Bool {
    true
  }

  public func localDNSTransport() -> LibboxLocalDNSTransportProtocol? {
    nil
  }

  public func readWIFIState() -> LibboxWIFIState? {
    nil
  }

  public func send(_ notification: LibboxNotification?) throws {
  }

  public func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
    guard let listener else { return }
    let monitor = NWPathMonitor()
    nwMonitor = monitor
    let firstUpdate = DispatchSemaphore(value: 0)
    var didSendFirstUpdate = false
    monitor.pathUpdateHandler = { path in
      self.updateDefaultInterface(listener, path)
      if !didSendFirstUpdate {
        didSendFirstUpdate = true
        firstUpdate.signal()
      }
    }
    monitor.start(queue: DispatchQueue.global())
    _ = firstUpdate.wait(timeout: .now() + .seconds(2))
  }

  public func systemCertificates() -> LibboxStringIteratorProtocol? {
    nil
  }

  public func underNetworkExtension() -> Bool {
    true
  }

  public func usePlatformAutoDetectControl() -> Bool {
    false
  }

  func preferredPhysicalInterfaceName() -> String? {
    if let primaryInterface = primaryIPv4InterfaceName(), isPhysicalInterfaceName(primaryInterface) {
      return primaryInterface
    }

    let interfaces = systemNetworkInterfaces(nwInterfaces: nwMonitor?.currentPath.availableInterfaces ?? [])
    logInterfacesIfChanged(interfaces)
    return interfaces.first?.name
  }

  public func useProcFS() -> Bool {
    false
  }

  private func updateDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
    if let nwInterface = path.availableInterfaces.first(where: { isPhysicalInterfaceName($0.name) }) {
      listener.updateDefaultInterface(
        nwInterface.name,
        interfaceIndex: Int32(nwInterface.index),
        isExpensive: path.isExpensive,
        isConstrained: path.isConstrained
      )
      return
    }

    guard let defaultInterface = defaultSystemInterface() else {
      listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
      return
    }
    listener.updateDefaultInterface(
      defaultInterface.name,
      interfaceIndex: defaultInterface.index,
      isExpensive: path.isExpensive,
      isConstrained: path.isConstrained
    )
  }

  private func systemNetworkInterfaces(nwInterfaces: [Network.NWInterface]) -> [LibboxNetworkInterface] {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddress = ifaddr else {
      return nwInterfaces
        .filter { isPhysicalInterfaceName($0.name) }
        .map { libboxInterface(name: $0.name, index: Int32($0.index), flags: Int32(IFF_UP | IFF_RUNNING), type: interfaceType(for: $0.type)) }
    }
    defer { freeifaddrs(ifaddr) }

    var interfacesByName: [String: LibboxNetworkInterface] = [:]
    var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
    while let current = pointer {
      defer { pointer = current.pointee.ifa_next }
      guard let rawName = current.pointee.ifa_name else { continue }
      let name = String(cString: rawName)
      guard isPhysicalInterfaceName(name) else { continue }

      let flags = current.pointee.ifa_flags
      guard flags & UInt32(IFF_UP) != 0 else { continue }
      guard flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

      if interfacesByName[name] == nil {
        let nwInterface = nwInterfaces.first { $0.name == name }
        let index = Int32(if_nametoindex(rawName))
        guard index > 0 else { continue }
        interfacesByName[name] = libboxInterface(
          name: name,
          index: index,
          flags: Int32(bitPattern: flags),
          type: nwInterface.map { interfaceType(for: $0.type) } ?? interfaceType(forName: name)
        )
      } else if let networkInterface = interfacesByName[name] {
        networkInterface.flags = networkInterface.flags | Int32(bitPattern: flags)
      }
    }

    return interfacesByName.values.sorted { $0.index < $1.index }
  }

  private func defaultSystemInterface() -> NetworkInterfaceIdentity? {
    if let primaryInterface = primaryIPv4InterfaceName(), isPhysicalInterfaceName(primaryInterface) {
      let index = if_nametoindex(primaryInterface)
      if index > 0 {
        return NetworkInterfaceIdentity(name: primaryInterface, index: Int32(index))
      }
    }

    let interfaces = systemNetworkInterfaces(nwInterfaces: [])
    guard let firstInterface = interfaces.first else { return nil }
    return NetworkInterfaceIdentity(name: firstInterface.name, index: firstInterface.index)
  }

  private func primaryIPv4InterfaceName() -> String? {
    guard let dictionary = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
      return nil
    }
    return dictionary["PrimaryInterface"] as? String
  }

  private func libboxInterface(name: String, index: Int32, flags: Int32, type: Int32) -> LibboxNetworkInterface {
    let networkInterface = LibboxNetworkInterface()
    networkInterface.name = name
    networkInterface.index = index
    networkInterface.mtu = 1500
    networkInterface.flags = flags
    networkInterface.type = type
    return networkInterface
  }

  private func isPhysicalInterfaceName(_ name: String) -> Bool {
    !name.hasPrefix("utun")
      && !name.hasPrefix("lo")
      && !name.hasPrefix("awdl")
      && !name.hasPrefix("llw")
      && !name.hasPrefix("bridge")
      && !name.hasPrefix("gif")
      && !name.hasPrefix("stf")
  }

  private func interfaceType(for type: Network.NWInterface.InterfaceType) -> Int32 {
    switch type {
    case .wifi:
      LibboxInterfaceTypeWIFI
    case .cellular:
      LibboxInterfaceTypeCellular
    case .wiredEthernet:
      LibboxInterfaceTypeEthernet
    default:
      LibboxInterfaceTypeOther
    }
  }

  private func interfaceType(forName name: String) -> Int32 {
    if name.hasPrefix("en") {
      return LibboxInterfaceTypeEthernet
    }
    return LibboxInterfaceTypeOther
  }

  private func logInterfacesIfChanged(_ interfaces: [LibboxNetworkInterface]) {
    let snapshot = interfaces.map { "\($0.name)#\($0.index)" }.joined(separator: ",")
    guard snapshot != lastInterfaceLog else { return }
    lastInterfaceLog = snapshot
    tunnel.writeMessage("(packet-tunnel) platform interfaces: [\(snapshot)]")
  }

  private struct NetworkInterfaceIdentity {
    let name: String
    let index: Int32
  }

  private class NetworkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    private var nextValue: LibboxNetworkInterface?

    init(_ array: [LibboxNetworkInterface]) {
      iterator = array.makeIterator()
    }

    func hasNext() -> Bool {
      nextValue = iterator.next()
      return nextValue != nil
    }

    func next() -> LibboxNetworkInterface? {
      nextValue
    }
  }
}
