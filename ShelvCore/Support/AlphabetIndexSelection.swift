import Foundation

nonisolated enum AlphabetIndexSelection {
    static func index(
        yPosition: Double,
        itemHeight: Double,
        itemCount: Int
    ) -> Int? {
        guard itemCount > 0,
              yPosition.isFinite,
              itemHeight.isFinite,
              itemHeight > 0
        else {
            return nil
        }

        let rawIndex = yPosition / itemHeight
        guard rawIndex.isFinite else { return nil }
        let clampedIndex = min(
            max(rawIndex, 0),
            Double(itemCount - 1)
        )
        return Int(clampedIndex)
    }
}
