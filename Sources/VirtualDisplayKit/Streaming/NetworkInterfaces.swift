//
//  NetworkInterfaces.swift
//  VirtualDisplayKit
//
//  Discovers the LAN addresses a browser client can use to reach this Mac.
//

import Darwin
import Foundation

/// A reachable IPv4 address on one of this machine's network interfaces
public struct NetworkAddress: Sendable, Hashable, Identifiable {

    /// BSD interface name, e.g. `en0`
    public let interface: String

    /// Dotted-quad IPv4 address, e.g. `192.168.1.42`
    public let address: String

    public var id: String { "\(interface)-\(address)" }

    /// A friendly name for the interface, e.g. "Wi-Fi"
    public var displayName: String {
        switch interface {
        case "en0": return "Wi-Fi"
        case let name where name.hasPrefix("en"): return "Ethernet (\(name))"
        case let name where name.hasPrefix("bridge"): return "Bridge (\(name))"
        case let name where name.hasPrefix("utun"), let name where name.hasPrefix("ipsec"): return "VPN (\(interface))"
        default: return interface
        }
    }

    /// Whether this looks like a private LAN address other devices can reach
    public var isPrivateLAN: Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}

/// A browser-reachable address for a running stream server
public struct BrowserStreamEndpoint: Sendable, Hashable, Identifiable {

    public let address: NetworkAddress
    public let port: UInt16

    public var url: String { "http://\(address.address):\(port)" }
    public var id: String { url }

    /// Friendly interface label, e.g. "Wi-Fi"
    public var interfaceName: String { address.displayName }

    public init(address: NetworkAddress, port: UInt16) {
        self.address = address
        self.port = port
    }
}

public enum NetworkInterfaces {

    /// All usable IPv4 addresses on this machine, best candidate first.
    ///
    /// Loopback, link-local and inactive interfaces are excluded; private LAN
    /// addresses on physical interfaces are ranked ahead of everything else.
    public static func localIPv4Addresses() -> [NetworkAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var results: [NetworkAddress] = []

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addressPointer = pointer.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addressPointer,
                socklen_t(addressPointer.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }

            let address = String(cString: buffer)
            guard !address.hasPrefix("169.254"), address != "0.0.0.0" else { continue }

            let name = String(cString: pointer.pointee.ifa_name)
            results.append(NetworkAddress(interface: name, address: address))
        }

        return results.sorted { lhs, rhs in
            if lhs.isPrivateLAN != rhs.isPrivateLAN { return lhs.isPrivateLAN }
            let lhsPhysical = lhs.interface.hasPrefix("en")
            let rhsPhysical = rhs.interface.hasPrefix("en")
            if lhsPhysical != rhsPhysical { return lhsPhysical }
            return lhs.interface < rhs.interface
        }
    }

    /// The single best address to advertise, or `nil` when offline.
    public static func preferredIPv4Address() -> NetworkAddress? {
        localIPv4Addresses().first
    }
}
