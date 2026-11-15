//
//  CoreKitPlatformDefaults.swift
//  CoreKit
//
//  Spec c8fa126c, BR-L-03/BR-L-05. The per-target choice, factored out of
//  ``CoreKitPlatformAssembly`` so there is exactly ONE expression of it and both
//  the container and the deprecated ``AppLog`` facade read the same one.
//
//  Why this type exists at all: `AppLog.provider` needs a seed, because `AppLog`
//  is a static facade called from sites that hold no resolver. Seeding it with
//  ``SwiftLogLogger`` was MEASURED to change behaviour on Apple — an existing
//  consumer that never registers an assembly would start writing to stdout
//  instead of the unified log, which is a behaviour change at a call site that
//  was already portable (BR-L-05). Seeding it from the same factory the assembly
//  uses makes the facade's default byte-for-byte what `AppLog` did before.
//
//  It lives in `Sources/CoreKit/Platform/`, the one subtree where a condition
//  may appear, so the BR-L-04 ratchet still measures zero everywhere else.
//

import Foundation

/// The implementation each capability gets on the current compilation target.
///
/// ``CoreKitPlatformAssembly`` registers exactly these; nothing else in CoreKit
/// names an implementation.
public enum CoreKitPlatformDefaults {
    /// ``OSLogLogger`` where `os` exists, ``SwiftLogLogger`` everywhere else.
    public static func makeLogger(subsystem: String) -> any LoggingProviding {
        #if canImport(os)
            return OSLogLogger(subsystem: subsystem)
        #else
            return SwiftLogLogger(subsystem: subsystem)
        #endif
    }

    /// ``NWPathReachability`` where `Network` exists, ``GetifaddrsReachability``
    /// everywhere else.
    public static func makeReachability() -> any ReachabilityProviding {
        #if canImport(Network)
            return NWPathReachability()
        #else
            return GetifaddrsReachability()
        #endif
    }

    /// ``PlatformCapacityProber`` on Apple, ``ProcMeminfoCapacityProber`` on a
    /// Linux host with `/proc`.
    public static func makeCapacityProber() -> any DeviceCapacityProbing {
        #if canImport(Darwin)
            return PlatformCapacityProber()
        #else
            return ProcMeminfoCapacityProber()
        #endif
    }
}
