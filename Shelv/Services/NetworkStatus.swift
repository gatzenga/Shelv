import Foundation
import Network

final class NetworkStatus {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "shelv.netstatus", qos: .utility)
    private let lock = NSLock()
    private var _isOnWifi: Bool = true
    private var _hasNetwork: Bool = true

    var isOnWifi: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isOnWifi
    }

    var hasNetwork: Bool {
        lock.lock(); defer { lock.unlock() }
        return _hasNetwork
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let any = path.status == .satisfied
            self.lock.lock()
            self._isOnWifi = wifi
            self._hasNetwork = any
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }
}
