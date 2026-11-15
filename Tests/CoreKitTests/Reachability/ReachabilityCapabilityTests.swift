import Foundation
import Testing
@testable import CoreKit

/// Spec c8fa126c W3, T-L-08: a fake ``ReachabilityProviding`` drives a consumer,
/// and no test binds a real interface. The fanout — the only part both
/// implementations share — is tested directly, because that is where a swallowed
/// event would hide.
@Suite("Reachability capability")
struct ReachabilityCapabilityTests {
    /// T-L-08's fake. No monitor, no socket, no syscall: a test script.
    final class ScriptedReachability: ReachabilityProviding, @unchecked Sendable {
        private let fanout = ReachabilityFanout()
        private let started = StartedOnce()

        var current: NetworkInterfaceType? {
            get async { await fanout.current }
        }

        func updates() -> AsyncStream<NetworkInterfaceType> {
            let fanout = self.fanout
            return AsyncStream { continuation in
                let task = Task {
                    for await value in await fanout.makeStream() { continuation.yield(value) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func start() async { _ = await started.claim() }
        func cancel() async { await fanout.finish() }

        func script(_ interface: NetworkInterfaceType) async { await fanout.publish(interface) }
    }

    @Test("a fake provider drives a consumer through the protocol only (T-L-08)")
    func fakeProviderDrivesAConsumer() async throws {
        let sut = ScriptedReachability()
        await sut.start()
        #expect(await sut.current == nil, "nil means not observed yet, never 'offline'")

        await sut.script(.cellular)
        #expect(await sut.current == .cellular)
        await sut.script(.wifi)
        #expect(await sut.current == .wifi)
        await sut.cancel()
    }

    @Test("the fanout replays the last value to a new stream and then streams changes")
    func fanoutReplaysThenStreams() async throws {
        let fanout = ReachabilityFanout()
        await fanout.publish(.ethernet)

        let stream = await fanout.makeStream()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .ethernet, "a late subscriber must see the current value")

        await fanout.publish(.wifi)
        #expect(await iterator.next() == .wifi)

        await fanout.finish()
        #expect(await iterator.next() == nil, "finish() must end every live stream")
    }

    @Test("two streams both see the same change")
    func fanoutIsMulticast() async throws {
        let fanout = ReachabilityFanout()
        var first = await fanout.makeStream().makeAsyncIterator()
        var second = await fanout.makeStream().makeAsyncIterator()
        await fanout.publish(.cellular)
        #expect(await first.next() == .cellular)
        #expect(await second.next() == .cellular)
        await fanout.finish()
    }

    @Test("publishing feeds the process-wide store the cache already reads")
    func publishingFeedsTheSharedStore() async {
        let fanout = ReachabilityFanout()
        await fanout.publish(.localhost)
        #expect(await NetworkReachabilityStore.shared.interfaceType == .localhost)
        await fanout.publish(nil)
        #expect(await NetworkReachabilityStore.shared.interfaceType == nil)
    }

    @Test("start() is idempotent, as the protocol claims")
    func startIsIdempotent() async {
        let once = StartedOnce()
        #expect(await once.claim())
        #expect(await once.claim() == false)
    }

    // MARK: - the POSIX classifier, which is pure and therefore testable anywhere

    @Test("getifaddrs name classification covers classic and predictable names")
    func posixClassifierNames() {
        #expect(GetifaddrsReachability.classify(interfaceName: "wlan0") == .wifi)
        #expect(GetifaddrsReachability.classify(interfaceName: "wlp2s0") == .wifi)
        #expect(GetifaddrsReachability.classify(interfaceName: "wwan0") == .cellular)
        #expect(GetifaddrsReachability.classify(interfaceName: "ppp0") == .cellular)
        #expect(GetifaddrsReachability.classify(interfaceName: "rmnet_data0") == .cellular)
        #expect(GetifaddrsReachability.classify(interfaceName: "eth0") == .ethernet)
        #expect(GetifaddrsReachability.classify(interfaceName: "enp0s3") == .ethernet)
        #expect(GetifaddrsReachability.classify(interfaceName: "en0") == .ethernet)
        #expect(GetifaddrsReachability.classify(interfaceName: "tun0") == .unknown)
        #expect(GetifaddrsReachability.classify(interfaceName: "docker0") == .unknown)
    }

    /// The REAL provider, end to end, through the protocol only.
    ///
    /// `ScriptedReachability` above duplicates `updates()`'s bridging, so until
    /// this test existed the bridging in the shipped providers — the
    /// `AsyncStream` that forwards from the actor's own stream and cancels its
    /// pump on termination — was covered by nothing
    /// ([[a-capability-that-exists-but-is-never-called-passes-every-unit-test-and-ships-nothing]]).
    /// `GetifaddrsReachability` is constructible on every POSIX target, macOS
    /// included, so the gate on this machine sees it.
    @Test("the shipped POSIX provider starts, answers, streams and cancels")
    func theRealProviderWorksEndToEnd() async throws {
        let sut = GetifaddrsReachability(pollInterval: .milliseconds(50))
        let stream = sut.updates()
        var iterator = stream.makeAsyncIterator()

        await sut.start()

        // The first reading is taken before the first sleep, by contract, so a
        // caller that starts and reads immediately is not told "not observed
        // yet" about a host whose interfaces are right there. Awaiting the
        // stream is the bounded wait — no sleep, no guessed interval.
        let first = await iterator.next()
        #expect(first != nil, "start() must publish a reading without a caller polling for it")
        #expect(await sut.current == first, "current and the stream must agree")

        await sut.cancel()
        #expect(await iterator.next() == nil, "cancel() must finish every live stream")
    }

    /// The real probe runs here too — on macOS, through the same `getifaddrs`
    /// that musl has — because a provider only Linux can execute is a provider
    /// no gate on this machine can see. It asserts a SHAPE, not a value: a
    /// laptop on wifi, a CI box on ethernet and a container on loopback are all
    /// correct answers.
    @Test("the real getifaddrs read answers something, and never crashes")
    func posixProbeIsHonest() {
        let observed = GetifaddrsReachability.readInterface()
        #expect(observed != nil, "a host with any interface up must classify, not report a probe failure")
        if let observed {
            #expect(NetworkInterfaceType.allKnown.contains(observed))
        }
    }
}

extension NetworkInterfaceType {
    /// Every case, for a test that asserts "one of the known values".
    /// Deliberately in the test target: `CaseIterable` on the public enum would
    /// be a public API change this spec does not need.
    static var allKnown: [NetworkInterfaceType] { [.unknown, .wifi, .cellular, .ethernet, .localhost] }
}
