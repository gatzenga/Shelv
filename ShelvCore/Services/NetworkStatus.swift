import Foundation
import Network

extension Notification.Name {
    nonisolated static var networkStatusChanged: Notification.Name {
        Notification.Name("shelv.networkStatusChanged")
    }
}

nonisolated final class NetworkStatus: @unchecked Sendable {
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
        if isReady { return }
        await withCheckedContinuation { continuation in
            appendReadyContinuation(continuation)
        }
    }

    func waitUntilNetworkAvailable(timeoutNanoseconds: UInt64 = 3_000_000_000) async -> Bool {
        await waitUntilReady()
        guard !hasNetwork else { return true }

        let interval: UInt64 = 100_000_000
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: interval)
            if hasNetwork { return true }
            elapsed += interval
        }
        return hasNetwork
    }

    private var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isReady
    }

    private func appendReadyContinuation(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if _isReady {
            lock.unlock()
            continuation.resume()
            return
        }
        _readyContinuations.append(continuation)
        lock.unlock()
    }

    // Synchroner Path-Sync, damit ein anderer Pfad-Monitor (z.B. AudioPlayerService.networkMonitor)
    // den Stand vor dem ersten Read garantieren kann. Verhindert dass z.B. die TranscodingPolicy
    // direkt nach WLAN-Reconnect noch den alten "kein WLAN"-Wert liest.
    func update(from path: NWPath) {
        let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
        let any = path.status == .satisfied
        lock.lock()
        let changed = _isOnWifi != wifi || _hasNetwork != any
        _isOnWifi = wifi
        _hasNetwork = any
        let continuations: [CheckedContinuation<Void, Never>]
        if !_isReady {
            _isReady = true
            continuations = _readyContinuations
            _readyContinuations = []
        } else {
            continuations = []
        }
        lock.unlock()
        continuations.forEach { $0.resume() }
        if changed {
            ConnectivityDebugLog.log("network status changed via sync update: hasNetwork=\(any), isOnWifi=\(wifi), status=\(path.status)")
            postNetworkStatusChanged()
        }
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let any = path.status == .satisfied
            self.lock.lock()
            let changed = self._isOnWifi != wifi || self._hasNetwork != any
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
            if changed {
                ConnectivityDebugLog.log("network status changed: hasNetwork=\(any), isOnWifi=\(wifi), status=\(path.status)")
                self.postNetworkStatusChanged()
            }
        }
        monitor.start(queue: queue)
    }

    private func postNetworkStatusChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .networkStatusChanged, object: nil)
        } else {
            Task { @MainActor in
                NotificationCenter.default.post(name: .networkStatusChanged, object: nil)
            }
        }
    }
}
