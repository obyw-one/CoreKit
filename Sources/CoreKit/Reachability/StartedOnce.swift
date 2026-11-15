//
//  StartedOnce.swift
//  CoreKit
//
//  Spec c8fa126c W3. `start()` is documented idempotent on
//  ``ReachabilityProviding``, and "idempotent" across two concurrent callers is
//  a claim only a single serialised claim can make true. An actor, not a lock:
//  `start()` is already `async`.
//

import Foundation

/// One-shot claim. The first `claim()` returns true; every later one false.
public actor StartedOnce {
    private var claimed = false

    public init() {}

    public func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}
