import Darwin
import Foundation
import Network

/// Finds the PC debuglink server with no typing:
/// 1. the last host that worked (one quick `GET /health`);
/// 2. Bonjour `_groovedebug._tcp` via `NWBrowser` (the server's TXT record carries its IPv4 addresses; otherwise
///    the service is resolved with a short `NWConnection`), up to `bonjourTimeout`;
/// 3. a `GET /health` probe of every address on the phone's own /24 (bounded concurrency, short timeouts).
/// A server only counts if `/health` answers 200 with the `X-Groove-Debuglink` header. Nothing here runs on the main
/// thread except the bookkeeping; no raw UDP multicast/broadcast (needs an entitlement a sideloaded app lacks).
enum DebugDiscovery {
    static let serviceType = "_groovedebug._tcp"
    static let lastHostKey = "debugLink.lastHost"
    static let healthHeader = "X-Groove-Debuglink"
    static let bonjourTimeout = 3.0
    static let probeTimeout = 0.8
    static let probeConcurrency = 24

    enum Source: String {
        case manual, remembered, bonjour, subnet
    }

    struct Found {
        let base: URL
        let source: Source
    }

    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = probeTimeout
        config.timeoutIntervalForResource = probeTimeout * 2
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    static var rememberedHost: String? {
        get { UserDefaults.standard.string(forKey: lastHostKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastHostKey) }
    }

    /// Runs the whole search once; nil when nothing answered.
    static func find() async -> Found? {
        if let host = rememberedHost, let base = DebugLinkSettings.baseURL(from: host),
           await isServer(base, timeout: 1.2) {
            return Found(base: base, source: .remembered)
        }
        let viaBonjour = await browse(timeout: bonjourTimeout)
        for base in viaBonjour {
            if await isServer(base, timeout: 1.5) {
                remember(base)
                return Found(base: base, source: .bonjour)
            }
        }
        if Task.isCancelled { return nil }
        if let base = await scanSubnet() {
            remember(base)
            return Found(base: base, source: .subnet)
        }
        return nil
    }

    static func remember(_ base: URL) {
        guard let host = base.host else { return }
        rememberedHost = "\(host):\(base.port ?? DebugLinkSettings.defaultPort)"
    }

    /// `GET /health` == 200 with the debuglink header.
    static func isServer(_ base: URL, timeout: Double = probeTimeout) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = timeout
        guard let result = try? await probeSession.data(for: req),
              let http = result.1 as? HTTPURLResponse, http.statusCode == 200 else { return false }
        return http.value(forHTTPHeaderField: healthHeader) != nil
    }

    // MARK: - Bonjour

    private final class BrowseState: @unchecked Sendable {
        var done = false
        var resolving: [NWConnection] = []
    }

    static func browse(timeout: Double) async -> [URL] {
        await withCheckedContinuation { (cont: CheckedContinuation<[URL], Never>) in
            let queue = DispatchQueue(label: "groove.debuglink.bonjour")
            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: params)
            let state = BrowseState()

            // Everything below runs on `queue`.
            func finish(_ urls: [URL]) {
                guard !state.done else { return }
                state.done = true
                browser.cancel()
                state.resolving.forEach { $0.cancel() }
                state.resolving.removeAll()
                cont.resume(returning: urls)
            }

            func resolve(_ endpoint: NWEndpoint) {
                let tcp = NWParameters.tcp
                if let ip = tcp.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                    ip.version = .v4
                }
                let conn = NWConnection(to: endpoint, using: tcp)
                state.resolving.append(conn)
                conn.stateUpdateHandler = { st in
                    switch st {
                    case .ready:
                        if case .hostPort(let host, let port)? = conn.currentPath?.remoteEndpoint,
                           case .ipv4(let addr) = host {
                            let b = [UInt8](addr.rawValue)
                            if b.count == 4,
                               let u = DebugLinkSettings.baseURL(from: "\(b[0]).\(b[1]).\(b[2]).\(b[3]):\(port.rawValue)") {
                                finish([u])
                                return
                            }
                        }
                        conn.cancel()
                    case .failed, .waiting:
                        conn.cancel()
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
            }

            browser.browseResultsChangedHandler = { results, _ in
                var urls: [URL] = []
                var unresolved: [NWEndpoint] = []
                for r in results {
                    if case .bonjour(let txt) = r.metadata, let ips = txt["ips"], !ips.isEmpty {
                        let port = txt["port"].flatMap(Int.init) ?? DebugLinkSettings.defaultPort
                        for ip in ips.split(separator: ",") {
                            if let u = DebugLinkSettings.baseURL(from: "\(ip.trimmingCharacters(in: .whitespaces)):\(port)") {
                                urls.append(u)
                            }
                        }
                    } else {
                        unresolved.append(r.endpoint)
                    }
                }
                // Same-subnet addresses first (the server may list VPN / virtual adapters too).
                if let prefix = localIPv4()?.prefix24 {
                    urls.sort { a, b in
                        (a.host?.hasPrefix(prefix) == true ? 0 : 1) < (b.host?.hasPrefix(prefix) == true ? 0 : 1)
                    }
                }
                if !urls.isEmpty {
                    finish(urls)
                    return
                }
                for endpoint in unresolved { resolve(endpoint) }
            }

            browser.stateUpdateHandler = { st in
                switch st {
                case .failed, .cancelled:
                    finish([])
                default:
                    break
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish([]) }
        }
    }

    // MARK: - Subnet probe

    struct LocalAddress {
        let octets: [UInt8]
        var prefix24: String { "\(octets[0]).\(octets[1]).\(octets[2])." }
        var string: String { octets.map(String.init).joined(separator: ".") }
    }

    /// The phone's Wi-Fi IPv4 (en0 preferred; any up, non-loopback, non-link-local IPv4 otherwise).
    static func localIPv4() -> LocalAddress? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: LocalAddress?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let v = UInt32(bigEndian: addr)
            let octets = [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
            if octets[0] == 169 && octets[1] == 254 { continue }
            let name = String(cString: p.pointee.ifa_name)
            if name == "en0" { return LocalAddress(octets: octets) }
            if best == nil && !name.hasPrefix("pdp_ip") && !name.hasPrefix("utun") { best = LocalAddress(octets: octets) }
        }
        return best
    }

    /// Probes x.y.z.1...254 (own address skipped) with `probeConcurrency` requests in flight; first hit wins.
    static func scanSubnet() async -> URL? {
        guard let me = localIPv4() else { return nil }
        let prefix = me.prefix24
        let candidates = (1...254).map { UInt8($0) }.filter { $0 != me.octets[3] }
            .compactMap { DebugLinkSettings.baseURL(from: "\(prefix)\($0):\(DebugLinkSettings.defaultPort)") }
        return await withTaskGroup(of: URL?.self) { group in
            var next = 0
            while next < min(probeConcurrency, candidates.count) {
                let url = candidates[next]
                next += 1
                group.addTask { await isServer(url) ? url : nil }
            }
            while let result = await group.next() {
                if let result {
                    group.cancelAll()
                    return result
                }
                if Task.isCancelled { break }
                if next < candidates.count {
                    let url = candidates[next]
                    next += 1
                    group.addTask { await isServer(url) ? url : nil }
                }
            }
            group.cancelAll()
            return nil
        }
    }
}
