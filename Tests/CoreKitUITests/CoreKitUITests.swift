//  CoreKitUITests.swift
//  CoreKitUITests

import CoreKit
import Testing
@testable import CoreKitUI

#if canImport(Network) && canImport(Combine)
@Suite("CoreKitUI network bridge")
struct CoreKitUINetworkTests {
    @Test("NetworkStatus.InterfaceType is the core NetworkInterfaceType (T-04)")
    func aliasIsCoreType() {
        let t: NetworkStatus.InterfaceType = .wifi
        #expect(t == NetworkInterfaceType.wifi)
    }
}
#endif
