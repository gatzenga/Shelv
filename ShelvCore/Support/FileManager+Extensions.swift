import Foundation

extension FileManager {
    nonisolated func directorySize(at url: URL) -> Int {
        guard let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
        return enumerator.reduce(0) { acc, item in
            guard let fileURL = item as? URL,
                  let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { return acc }
            return acc + size
        }
    }
}
