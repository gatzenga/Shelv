import SwiftUI

struct TrackCollectionSummaryView: View {
    let songs: [Song]
    var preferredDuration: Int? = nil

    var body: some View {
        Text(summaryText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private var summaryText: String {
        let countFormat = songs.count == 1
            ? String(localized: "track_collection_count_one_format")
            : String(localized: "track_collection_count_other_format")
        let countText = String(format: countFormat, locale: .current, songs.count)
        let summedDuration = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        let suppliedDuration = preferredDuration ?? 0
        let duration = suppliedDuration > 0 ? suppliedDuration : summedDuration

        guard duration > 0 else { return countText }
        return "\(countText) · \(formattedDuration(duration))"
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let totalMinutes = max(1, Int((Double(seconds) / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0, minutes > 0 {
            return String(
                format: String(localized: "track_collection_duration_hours_minutes_format"),
                locale: .current,
                hours,
                minutes
            )
        }
        if hours > 0 {
            return String(
                format: String(localized: "track_collection_duration_hours_format"),
                locale: .current,
                hours
            )
        }
        return String(
            format: String(localized: "track_collection_duration_minutes_format"),
            locale: .current,
            minutes
        )
    }
}
