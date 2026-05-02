import Foundation
import Network

final class NetworkStatus {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "shelv.netstatus", qos: .utility)
    private let lock = NSLock()
    private var _isOnWifi: Bool = false
    private var _hasNetwork: Bool = false
    private var _isReady = false
    private var _readyContinuations: [CheckedContinuation<Void, Never>] = []

    var isOnWifi: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isOnWifi
    }

    var hasNetwork: Bool {
        lock.lock(); defer { lock.unlock() }
        return _hasNetwork
    }

    // Suspends until the first NWPathMonitor callback has fired.
    // Returns immediately on every call after the first update — typically <10 ms after init.
    func waitUntilReady() async {
        lock.lock()
        if _isReady { lock.unlock(); return }
        await withCheckedContinuation { continuation in
            _readyContinuations.append(continuation)
            lock.unlock()
        }
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let any = path.status == .satisfied
            self.lock.lock()
            self._isOnWifi = wifi
            self._hasNetwork = any
            let continuations: [CheckedContinuation<Void, Never>]
            if !self._isReady {
                self._isReady = true
                continuations = self._readyContinuations
                self._readyContinuations = []
            } else {
                continuations = []
            }
            self.lock.unlock()
            continuations.forEach { $0.resume() }
        }
        monitor.start(queue: queue)
    }
}
