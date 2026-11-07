//
//  NetworkInterfaceType.swift
//  CoreKit
//
//  The platform-neutral half of the old `NetworkStatus`: the interface-type
//  vocabulary and the actor that holds the last observed value. The Apple-only
//  `NWPathMonitor` that feeds it lives in CoreKitUI (`NetworkStatus`); a server
//  can feed `NetworkReachabilityStore` from its own reachability signal.
//

import Foundation

public enum NetworkInterfaceType: Sendable, Equatable {
    case unknown
    case wifi
    case cellular
    case ethernet
    case localhost
}

/// A thread-safe holder of the current network interface type, readable from
/// any isolation context. `nil` means "no observation yet".
public actor NetworkReachabilityStore {
    public static let shared = NetworkReachabilityStore()

    private var _interfaceType: NetworkInterfaceType?

    private init() {}

    public var interfaceType: NetworkInterfaceType? { _interfaceType }

    public func update(_ type: NetworkInterfaceType?) {
        _interfaceType = type
    }
}
