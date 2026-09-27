import Foundation

@main
struct NetworkSamplerTests {
    static func main() async {
        var meter = NetworkTrafficAccumulator()
        func counters(_ received: UInt64, _ sent: UInt64) -> NetworkTrafficCounters {
            NetworkTrafficCounters(received: received, sent: sent)
        }
        let first = meter.update(identity: "en10:10", counters: counters(9_000, 3_000), time: 1)
        precondition(first.download == 0 && meter.sessionReceived == 0, "Initial counters are not session usage")
        let rate = meter.update(identity: "en10:10", counters: counters(13_000, 4_000), time: 3)
        precondition(rate.download == 2_000 && rate.upload == 500)
        precondition(meter.sessionReceived == 4_000 && meter.sessionSent == 1_000)

        let slept = meter.update(identity: "en10:10", counters: counters(50_000, 20_000), time: 60)
        precondition(slept.download == 0 && meter.sessionReceived == 4_000, "Do not count a sleep gap")
        let resumed = meter.update(identity: "en10:10", counters: counters(52_000, 21_000), time: 62)
        precondition(resumed.download == 1_000 && meter.sessionReceived == 6_000)

        let reset = meter.update(identity: "en10:10", counters: counters(10, 10), time: 64)
        precondition(reset.download == 0 && meter.sessionReceived == 6_000, "Device counter reset must not underflow")
        meter.resetBaseline()
        let explicitReset = meter.update(identity: "en10:10", counters: counters(999, 999), time: 66)
        precondition(explicitReset.download == 0 && meter.sessionReceived == 6_000)

        let replaced = meter.update(identity: "en11:11", counters: counters(4_000_000_000, 2_000_000), time: 68)
        precondition(replaced.download == 0 && meter.sessionReceived == 6_000)
        let wide = meter.update(identity: "en11:11", counters: counters(5_000_000_000, 2_000_004), time: 70)
        precondition(wide.download == 500_000_000, "Counters retain 64-bit precision across 4 GiB")
        precondition(meter.sessionReceived == 1_000_006_000)
        _ = meter.update(identity: nil, counters: nil, time: 72)
        let missing = meter.update(identity: "en11:11", counters: counters(6_000_000_000, 3_000_000), time: 74)
        precondition(missing.download == 0, "An unreadable sample clears the baseline")

        let sampler = NetworkSampler()
        let snapshot = await sampler.sample()
        print("Network sampler tests passed. Live interface=\(snapshot.interface ?? "none") IPv4=\(snapshot.ipv4 ?? "none") router=\(snapshot.router ?? "none") active=\(snapshot.linkActive) default=\(snapshot.defaultInterface ?? "none") ambiguous=\(snapshot.ambiguous) rx=\(snapshot.receivedBytes) tx=\(snapshot.sentBytes)")
    }
}
