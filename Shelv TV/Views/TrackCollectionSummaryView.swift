import SwiftUI

struct TrackCollectionSummaryView: View {
    enum Layout: Equatable {
        case inline
        case stacked
    }

    let songs: [Song]
    var preferredDuration: Int? = nil
    var layout: Layout = .inline

    var body: some View {
        Group {
            switch layout {
            case .inline:
                Text(summaryText)
            case .stacked:
                VStack(alignment: .leading, spacing: 2) {
                    Text(countText)
                        .lineLimit(1)
                    if let durationText {
                        Text(durationText)
                            .lineLimit(1)
                    }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, layout == .inline ? 8 : 4)
    }

    private var countText: String {
        let countFormat = songs.count == 1
            ? String(localized: "track_collection_count_one_format")
            : String(localized: "track_collection_count_other_format")
        return String(format: countFormat, locale: .current, songs.count)
    }

    private var durationText: String? {
        let summedDuration = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        let suppliedDuration = preferredDuration ?? 0
        let duration = suppliedDuration > 0 ? suppliedDuration : summedDuration

        guard duration > 0 else { return nil }
        return formattedDuration(duration)
    }

    private var summaryText: String {
        guard let durationText else { return countText }
        return "\(countText) · \(durationText)"
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
