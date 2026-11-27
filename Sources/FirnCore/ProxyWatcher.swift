import Foundation
import SystemConfiguration

public struct HostProxyState: Codable, Sendable, Equatable {
    public var httpProxy: String
    public var httpsProxy: String
    public var noProxy: String
    public var vpnActive: Bool
    public var hostDnsRelay: Bool

    public init(
        httpProxy: String = "",
        httpsProxy: String = "",
        noProxy: String = "",
        vpnActive: Bool = false,
        hostDnsRelay: Bool = true
    ) {
        self.httpProxy = httpProxy
        self.httpsProxy = httpsProxy
        self.noProxy = noProxy
        self.vpnActive = vpnActive
        self.hostDnsRelay = hostDnsRelay
    }
}

public enum ProxyInspector {
    public static func currentState() -> HostProxyState {
        var state = HostProxyState()
        if let raw = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
            if let enabled = raw[kSCPropNetProxiesHTTPEnable as String] as? Int, enabled == 1,
               let host = raw[kSCPropNetProxiesHTTPProxy as String] as? String, !host.isEmpty {
                let port = (raw[kSCPropNetProxiesHTTPPort as String] as? Int) ?? 80
                state.httpProxy = "http://\(host):\(port)"
            }
            if let enabled = raw[kSCPropNetProxiesHTTPSEnable as String] as? Int, enabled == 1,
               let host = raw[kSCPropNetProxiesHTTPSProxy as String] as? String, !host.isEmpty {
                let port = (raw[kSCPropNetProxiesHTTPSPort as String] as? Int) ?? 443
                state.httpsProxy = "http://\(host):\(port)"
            }
            if let exceptions = raw[kSCPropNetProxiesExceptionsList as String] as? [String], !exceptions.isEmpty {
                state.noProxy = exceptions.joined(separator: ",")
            }
        }
        state.vpnActive = detectActiveVPNInterface()
        return state
    }

    public static func detectActiveVPNInterface() -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "firn-vpn-probe" as CFString, nil, nil),
              let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = ipv4["PrimaryInterface"] as? String else {
            return hasTunnelRoute()
        }
        if primary.hasPrefix("utun") || primary.hasPrefix("ppp") || primary.hasPrefix("ipsec") {
            return true
        }
        return hasTunnelRoute()
    }

    private static func hasTunnelRoute() -> Bool {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else {
            return false
        }
        defer { freeifaddrs(ifap) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cur {
            let flags = Int32(node.pointee.ifa_flags)
            let up = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let name = String(cString: node.pointee.ifa_name)
            if up && (name.hasPrefix("ppp") || name.hasPrefix("ipsec")) {
                return true
            }
            cur = node.pointee.ifa_next
        }
        return false
    }
}

public final class ProxyWatcher {
    private let onChange: (HostProxyState) -> Void
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private var lastState: HostProxyState?

    public init(onChange: @escaping (HostProxyState) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        let state = ProxyInspector.currentState()
        lastState = state
        onChange(state)

        var context = SCDynamicStoreContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let watcher = Unmanaged<ProxyWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleUpdate()
        }
        guard let store = SCDynamicStoreCreate(nil, "firn-proxy-watcher" as CFString, callback, &context) else {
            return
        }
        self.store = store
        let keys = [
            "State:/Network/Global/Proxies" as CFString,
            "State:/Network/Global/DNS" as CFString,
            "State:/Network/Global/IPv4" as CFString
        ] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, nil)
        if let src = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            self.source = src
            DispatchQueue.main.async {
                CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            }
        }
    }

    private func handleUpdate() {
        let current = ProxyInspector.currentState()
        if current != lastState {
            lastState = current
            onChange(current)
        }
    }
}
