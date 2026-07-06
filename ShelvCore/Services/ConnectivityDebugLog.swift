import Foundation

nonisolated enum ConnectivityDebugLog {
    static func log(_ message: String) {
        #if DEBUG
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[Connectivity] [\(stamp)] \(message)")
        #endif
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            var parts = [
                "URLError.\(urlError.code)",
                "code=\(urlError.errorCode)",
                "description=\(urlError.localizedDescription)"
            ]
            if let failingURL = urlError.failingURL {
                parts.append("failingURL=\(redacted(failingURL))")
            }
            if let failureReason = (urlError as NSError).localizedFailureReason {
                parts.append("reason=\(failureReason)")
            }
            return parts.joined(separator: ", ")
        }

        let nsError = error as NSError
        return "\(type(of: error))(domain=\(nsError.domain), code=\(nsError.code), description=\(error.localizedDescription))"
    }

    static func short(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError.\(urlError.code)"
        }
        if error is DecodingError {
            return "DecodingError"
        }
        let nsError = error as NSError
        return "\(type(of: error))(domain=\(nsError.domain), code=\(nsError.code))"
    }

    static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.queryItems = nil
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }
}
