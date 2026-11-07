//
//  NetworkStatus.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 12/02/2024.
//  Code linked to this article: https://medium.com/@bingkuo/how-to-check-internet-connectivity-69588c7770c4 by Bing Kuo
//

#if canImport(Network) && canImport(Combine)
import Combine
import CoreKit
import Foundation
import Network

@MainActor
public class NetworkStatus: ObservableObject {
    /// Source-compatible alias: the type lives in CoreKit so the core is platform-neutral.
    public typealias InterfaceType = NetworkInterfaceType

    private let monitor = NWPathMonitor()
    @Published public private(set) var interfaceType: InterfaceType? {
        didSet {
            // Cache the value in the actor for nonisolated access
            Task {
                await NetworkReachabilityStore.shared.update(interfaceType)
            }
        }
    }

    nonisolated public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.interfaceType = self.checkInterfaceType(path)
            }
        }
    }

    public func start(queue: DispatchQueue = DispatchQueue.global()) {
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
    }

    private func checkInterfaceType(_ path: NWPath) -> InterfaceType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.loopback) {
            return .localhost
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .ethernet
        }
        return .unknown
    }

    /// Async access to the current network interface type.
    /// Uses the cached value stored in `NetworkStatusStorage` actor.
    /// This is safe to call from any isolation context.
    nonisolated public static var currentInterfaceType: InterfaceType? {
        get async {
            await NetworkReachabilityStore.shared.interfaceType
        }
    }
}

#endif
