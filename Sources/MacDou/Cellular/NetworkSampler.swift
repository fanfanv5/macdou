import Darwin
import Foundation
import SystemConfiguration

/// Interface-level observations. An assigned IP address does not prove Internet access.
struct NetworkSnapshot: Sendable, Equatable {
    var interface: String?
    var ipv4: String?
    var router: String?
    var defaultInterface: String?
    var linkActive: Bool
    var receivedBytes: UInt64
    var sentBytes: UInt64
    var downloadBytesPerSecond: Double
    var uploadBytesPerSecond: Double
    var sessionReceivedBytes: UInt64
    var sessionSentBytes: UInt64
    var ambiguous: Bool
}

struct NetworkTrafficCounters: Sendable {
    var received: UInt64
    var sent: UInt64
}

/// Kept independent of the OS sampling so counter resets and sleep gaps can be tested.
struct NetworkTrafficAccumulator {
    private var previous: (identity: String, counters: NetworkTrafficCounters, time: Double)?
    private(set) var sessionReceived: UInt64 = 0
    private(set) var sessionSent: UInt64 = 0

    mutating func resetBaseline() {
        previous = nil
    }

    mutating func update(identity: String?, counters: NetworkTrafficCounters?, time: Double)
        -> (download: Double, upload: Double)
    {
        guard let identity, let counters, time.isFinite else {
            previous = nil
            return (0, 0)
        }
        defer { previous = (identity, counters, time) }
        guard let old = previous, old.identity == identity else { return (0, 0) }
        let elapsed = time - old.time
        // Do not attribute bytes from sleep, process suspension, interface replacement,
        // or reset to the current interval. The caller also clears this on wake.
        guard elapsed > 0, elapsed <= 10,
              counters.received >= old.counters.received,
              counters.sent >= old.counters.sent else { return (0, 0) }
        let received = counters.received - old.counters.received
        let sent = counters.sent - old.counters.sent
        sessionReceived = saturatingAdd(sessionReceived, received)
        sessionSent = saturatingAdd(sessionSent, sent)
        return (Double(received) / elapsed, Double(sent) / elapsed)
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

/// Native, read-only sampler. The app adjusts its sampling interval to visibility and menu settings.
actor NetworkSampler {
    private let store = SCDynamicStoreCreate(nil, "DJI4GGuard.NetworkSampler" as CFString, nil, nil)
    private var traffic = NetworkTrafficAccumulator()

    func resetBaseline() {
        traffic.resetBaseline()
    }

    func sample() -> NetworkSnapshot {
        let candidates = modemInterfaces()
        let defaultInterface = currentDefaultInterface()
        // Multiple matching devices require an explicit device selection; do not guess.
        guard candidates.count == 1, let interface = candidates.first else {
            _ = traffic.update(identity: nil, counters: nil, time: continuousTime())
            return NetworkSnapshot(
                interface: nil, ipv4: nil, router: nil, defaultInterface: defaultInterface,
                linkActive: false, receivedBytes: 0, sentBytes: 0,
                downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
                sessionReceivedBytes: traffic.sessionReceived,
                sessionSentBytes: traffic.sessionSent,
                ambiguous: candidates.count > 1
            )
        }
        let index = if_nametoindex(interface)
        let address = interfaceAddress(interface)
        let counters = interfaceCounters(index: index)
        let rates = traffic.update(
            identity: "\(interface):\(index)", counters: counters, time: continuousTime()
        )
        return NetworkSnapshot(
            interface: interface, ipv4: address.ipv4, router: currentRouter(interface: interface),
            defaultInterface: defaultInterface, linkActive: address.running && address.ipv4 != nil,
            receivedBytes: counters?.received ?? 0, sentBytes: counters?.sent ?? 0,
            downloadBytesPerSecond: rates.download, uploadBytesPerSecond: rates.upload,
            sessionReceivedBytes: traffic.sessionReceived, sessionSentBytes: traffic.sessionSent,
            ambiguous: false
        )
    }

    private func modemInterfaces() -> [String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        var matches = Set<String>()
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  if_nametoindex(bsdName) != 0,
                  let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else {
                continue
            }
            let lower = displayName.lowercased()
            if ["eg25", "qdc507", "baiwang", "百旺"].contains(where: lower.contains) {
                matches.insert(bsdName)
            }
        }
        return matches.sorted()
    }

    private func interfaceAddress(_ interface: String) -> (ipv4: String?, running: Bool) {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return (nil, false) }
        defer { freeifaddrs(first) }
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        var ipv4: String?
        var running = false
        while let current = entry {
            let value = current.pointee
            entry = value.ifa_next
            guard String(cString: value.ifa_name) == interface else { continue }
            let required = UInt32(IFF_UP | IFF_RUNNING)
            running = running || (value.ifa_flags & required) == required
            guard let address = value.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            var ipv4Address = UnsafeRawPointer(address).load(as: sockaddr_in.self).sin_addr
            let hostOrder = UInt32(bigEndian: ipv4Address.s_addr)
            // Ignore self-assigned/link-local and unspecified/loopback addresses.
            guard hostOrder != 0,
                  (hostOrder & 0xffff0000) != 0xa9fe0000,
                  (hostOrder & 0xff000000) != 0x7f000000 else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &ipv4Address, &text, socklen_t(text.count)) != nil {
                ipv4 = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return (ipv4, running)
    }

    /// NET_RT_IFLIST2 exposes if_data64. getifaddrs' if_data counters can wrap at 4 GiB.
    private func interfaceCounters(index: UInt32) -> NetworkTrafficCounters? {
        guard index != 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // The interface list can grow between queries. Retry once with a fresh size.
        for _ in 0..<2 {
            var bytes = [UInt8](repeating: 0, count: size)
            var actualSize = size
            let result = bytes.withUnsafeMutableBytes {
                sysctl(&mib, u_int(mib.count), $0.baseAddress, &actualSize, nil, 0)
            }
            if result == 0 {
                return bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset + 4 <= actualSize {
                        let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        guard length >= 4, offset + length <= actualSize else { break }
                        let type = raw[offset + 3]
                        if type == UInt8(RTM_IFINFO2), length >= MemoryLayout<if_msghdr2>.size {
                            let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                            if UInt32(message.ifm_index) == index {
                                return NetworkTrafficCounters(
                                    received: message.ifm_data.ifi_ibytes,
                                    sent: message.ifm_data.ifi_obytes
                                )
                            }
                        }
                        offset += length
                    }
                    return nil
                }
            }
            guard errno == ENOMEM,
                  sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        }
        return nil
    }

    private func currentDefaultInterface() -> String? {
        guard let store else { return nil }
        for protocolName in ["IPv4", "IPv6"] {
            if let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(protocolName)" as CFString)
                as? [String: Any], let name = state["PrimaryInterface"] as? String {
                return name
            }
        }
        return nil
    }

    private func currentRouter(interface: String) -> String? {
        guard let store,
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString)
                as? [String] else { return nil }
        let routers = Set(keys.compactMap { key -> String? in
            guard let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  state["InterfaceName"] as? String == interface else { return nil }
            return state["Router"] as? String
        })
        return routers.count == 1 ? routers.first : nil
    }

    private func continuousTime() -> Double {
        // Unlike an uptime clock, this clock includes sleep so long gaps are rejected.
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}
