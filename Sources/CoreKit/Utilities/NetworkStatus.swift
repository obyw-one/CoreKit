//
//  NetworkStatus.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 12/02/2024.
//  Code linked to this article: https://medium.com/@bingkuo/how-to-check-internet-connectivity-69588c7770c4 by Bing Kuo
//

import Combine
import Foundation
import Network

public extension NetworkStatus {
    enum InterfaceType: Sendable, Equatable {
        case unknown
        case wifi
        case cellular
        case ethernet
        case localhost
    }
}

/// A thread-safe container for storing the current network interface type.
/// This allows nonisolated code to access the network status without requiring main actor isolation.
actor NetworkStatusStorage {
    static let shared = NetworkStatusStorage()

    private var _interfaceType: NetworkStatus.InterfaceType?

    private init() {}

    var interfaceType: NetworkStatus.InterfaceType? {
        _interfaceType
    }

    func update(_ type: NetworkStatus.InterfaceType?) {
        _interfaceType = type
    }
}

@MainActor
public class NetworkStatus: ObservableObject {
    private let monitor = NWPathMonitor()
    @Published public private(set) var interfaceType: InterfaceType? {
        didSet {
            // Cache the value in the actor for nonisolated access
            Task {
                await NetworkStatusStorage.shared.update(interfaceType)
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
            await NetworkStatusStorage.shared.interfaceType
        }
    }
}
