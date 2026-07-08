import SwiftUI

struct SongInfoPanel: View {
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.themeColor) private var themeColor

    @State private var displayedSong: Song?
    @State private var selectedTab = SongInfoTab.credits
    @State private var isLoading = false

    private var sourceSong: Song? {
        appState.songInfoSong ?? player.currentSong
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            Divider()
            tabContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: sourceSong?.id) {
            displayedSong = sourceSong
            await refreshSong(sourceSong)
        }
    }

    @ViewBuilder
    private var header: some View {
        if let song = displayedSong {
            HStack(spacing: 12) {
                CoverArtView(
                    url: song.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(id: $0, size: 160) },
                    size: 58,
                    cornerRadius: 8
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let artist = Self.trimmedNonEmpty(song.displayArtist) ?? Self.trimmedNonEmpty(song.artist) {
                        Text(artist)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let album = Self.trimmedNonEmpty(song.album) {
                        Text(album)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                closeButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        } else {
            HStack {
                Text(String(localized: "song_info"))
                    .font(.headline)
                Spacer()
                closeButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var closeButton: some View {
        MacSidePanelCloseButton {
            appState.closeSongInfo()
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(SongInfoTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var tabContent: some View {
        if let displayedSong {
            switch selectedTab {
            case .credits:
                creditsContent(for: displayedSong)
            case .details:
                detailsContent(for: displayedSong)
            }
        } else {
            emptyState(icon: "music.note", title: String(localized: "no_track"))
        }
    }

    @ViewBuilder
    private func creditsContent(for song: Song) -> some View {
        let sections = Self.creditSections(for: song)
        if sections.isEmpty {
            emptyState(icon: "person.2.slash", title: String(localized: "song_info_no_credits"))
        } else {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            SongInfoCreditRow(item: item)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func detailsContent(for song: Song) -> some View {
        let sections = Self.detailSections(for: song)
        if sections.isEmpty {
            emptyState(icon: "info.circle", title: String(localized: "song_info_no_details"))
        } else {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            SongInfoDetailRow(row: row)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func emptyState(icon: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func refreshSong(_ song: Song?) async {
        guard !offlineMode.isOffline, let song else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let refreshed = try await SubsonicAPIService.shared.getSong(id: song.id)
            guard !Task.isCancelled, refreshed.id == sourceSong?.id else { return }
            displayedSong = refreshed
        } catch {
            // Keep the player metadata if the server cannot refresh richer details.
        }
    }
}

private enum SongInfoTab: CaseIterable, Identifiable {
    case credits
    case details

    var id: Self { self }

    var title: String {
        switch self {
        case .credits: return String(localized: "song_info_credits")
        case .details: return String(localized: "song_info_details")
        }
    }
}

private struct SongInfoCreditSection: Identifiable {
    let id: String
    let title: String
    let items: [SongInfoCreditItem]
}

private struct SongInfoCreditItem: Identifiable, Hashable {
    let name: String
    let detail: String?

    var id: String { "\(name)|\(detail ?? "")" }
}

private struct SongInfoDetailSection: Identifiable {
    let id: String
    let title: String
    let rows: [SongInfoDetailItem]
}

private struct SongInfoDetailItem: Identifiable, Hashable {
    let title: String
    let value: String
    let prefersSingleLineValue: Bool

    var id: String { "\(title)|\(value)" }
}

private struct SongInfoCreditRow: View {
    let item: SongInfoCreditItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.name)
                .font(.body)
                .lineLimit(2)

            if let detail = item.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SongInfoDetailRow: View {
    let row: SongInfoDetailItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.title)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(row.value)
                .multilineTextAlignment(.trailing)
                .lineLimit(row.prefersSingleLineValue ? 1 : nil)
                .minimumScaleFactor(row.prefersSingleLineValue ? 0.65 : 1)
                .allowsTightening(row.prefersSingleLineValue)
                .fixedSize(horizontal: false, vertical: !row.prefersSingleLineValue)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

private extension SongInfoPanel {
    static func creditSections(for song: Song) -> [SongInfoCreditSection] {
        var sections: [SongInfoCreditSection] = []

        if let displayArtist = trimmedNonEmpty(song.displayArtist) {
            appendCreditSection(
                &sections,
                id: "artists",
                title: String(localized: "song_info_artists"),
                items: [SongInfoCreditItem(name: displayArtist, detail: nil)]
            )
        } else if let artists = nonEmptyArtists(song.artists) {
            appendCreditSection(
                &sections,
                id: "artists",
                title: String(localized: "song_info_artists"),
                items: artists.map { SongInfoCreditItem(name: $0.name, detail: nil) }
            )
        } else if let artist = trimmedNonEmpty(song.artist) {
            appendCreditSection(
                &sections,
                id: "artists",
                title: String(localized: "song_info_artists"),
                items: [SongInfoCreditItem(name: artist, detail: nil)]
            )
        }

        if let displayAlbumArtist = trimmedNonEmpty(song.displayAlbumArtist) {
            appendCreditSection(
                &sections,
                id: "album-artists",
                title: String(localized: "song_info_album_artists"),
                items: [SongInfoCreditItem(name: displayAlbumArtist, detail: nil)]
            )
        } else if let albumArtists = nonEmptyArtists(song.albumArtists) {
            appendCreditSection(
                &sections,
                id: "album-artists",
                title: String(localized: "song_info_album_artists"),
                items: albumArtists.map { SongInfoCreditItem(name: $0.name, detail: nil) }
            )
        }

        let contributors = (song.contributors ?? []).filter {
            trimmedNonEmpty($0.role) != nil && trimmedNonEmpty($0.artist.name) != nil
        }
        let contributorRoleKeys = Set(contributors.map { normalizedRole($0.role) })

        if !contributorRoleKeys.contains("composer"),
           let composer = trimmedNonEmpty(song.displayComposer) {
            appendCreditSection(
                &sections,
                id: "composer",
                title: String(localized: "song_info_composers"),
                items: [SongInfoCreditItem(name: composer, detail: nil)]
            )
        }

        let contributorGroups = Dictionary(grouping: contributors) { normalizedRole($0.role) }
        let sortedGroups = contributorGroups.keys.sorted { lhs, rhs in
            let lhsPriority = rolePriority(lhs)
            let rhsPriority = rolePriority(rhs)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return roleTitle(for: lhs, fallback: lhs) < roleTitle(for: rhs, fallback: rhs)
        }

        for key in sortedGroups {
            guard let contributors = contributorGroups[key] else { continue }
            let items = dedupeCreditItems(contributors.map { contributor in
                SongInfoCreditItem(
                    name: contributor.artist.name,
                    detail: trimmedNonEmpty(contributor.subRole)
                )
            })
            appendCreditSection(
                &sections,
                id: "contributors-\(key)",
                title: roleTitle(for: key, fallback: contributors.first?.role ?? key),
                items: items
            )
        }

        return sections
    }

    static func detailSections(for song: Song) -> [SongInfoDetailSection] {
        var sections: [SongInfoDetailSection] = []

        appendDetailSection(
            &sections,
            id: "release",
            title: String(localized: "song_info_release"),
            rows: [
                detailRow(String(localized: "song_info_album"), value: song.album),
                detailRow(String(localized: "song_info_album_artist"), value: albumArtistDisplay(for: song)),
                detailRow(String(localized: "year"), value: song.year.map { String($0) }),
                detailRow(String(localized: "genre"), value: genreDisplay(for: song)),
                detailRow(String(localized: "song_info_disc"), value: song.discNumber.map { String($0) }),
                detailRow(String(localized: "song_info_track"), value: song.track.map { String($0) }),
                detailRow(String(localized: "song_info_duration"), value: trimmedNonEmpty(song.durationFormatted)),
                detailRow(String(localized: "song_info_play_count"), value: song.playCount.map { String($0) }),
                detailRow(String(localized: "song_info_explicit_status"), value: explicitStatusDisplay(song.explicitStatus))
            ].compactMap { $0 }
        )

        appendDetailSection(
            &sections,
            id: "audio",
            title: String(localized: "song_info_audio"),
            rows: [
                detailRow(String(localized: "format"), value: formatDisplay(for: song)),
                detailRow(String(localized: "song_info_file_size"), value: song.fileSize.map { formatFileSize($0) }),
                detailRow(String(localized: "bitrate"), value: song.bitRate.map { "\($0) kbps" }),
                detailRow(String(localized: "song_info_bit_depth"), value: song.bitDepth.map { "\($0)-bit" }),
                detailRow(String(localized: "song_info_sample_rate"), value: song.samplingRate.map { formatSampleRate($0) }),
                detailRow(String(localized: "song_info_channels"), value: song.channelCount.map { channelDisplay($0) }),
                detailRow(String(localized: "track_gain"), value: song.replayGain?.trackGain.map { formatGain($0) }),
                detailRow(String(localized: "album_gain"), value: song.replayGain?.albumGain.map { formatGain($0) })
            ].compactMap { $0 }
        )

        appendDetailSection(
            &sections,
            id: "identifiers",
            title: String(localized: "song_info_identifiers"),
            rows: [
                detailRow(String(localized: "song_info_song_id"), value: song.id, prefersSingleLineValue: true),
                detailRow(String(localized: "song_info_isrc"), value: nonEmptyList(song.isrc), prefersSingleLineValue: true),
                detailRow(String(localized: "song_info_musicbrainz_id"), value: song.musicBrainzId, prefersSingleLineValue: true)
            ].compactMap { $0 }
        )

        appendDetailSection(
            &sections,
            id: "tags",
            title: String(localized: "song_info_tags"),
            rows: [
                detailRow(String(localized: "song_info_bpm"), value: bpmDisplay(song.bpm)),
                detailRow(String(localized: "song_info_moods"), value: nonEmptyList(song.moods)),
                detailRow(String(localized: "song_info_groupings"), value: nonEmptyList(song.groupings)),
                detailRow(String(localized: "song_info_works"), value: worksDisplay(song.works)),
                detailRow(String(localized: "song_info_movements"), value: movementsDisplay(song.movements)),
                detailRow(String(localized: "comment"), value: song.comment)
            ].compactMap { $0 }
        )

        return sections
    }

    static func appendCreditSection(
        _ sections: inout [SongInfoCreditSection],
        id: String,
        title: String,
        items: [SongInfoCreditItem]
    ) {
        let deduped = dedupeCreditItems(items)
        guard !deduped.isEmpty else { return }
        sections.append(SongInfoCreditSection(id: id, title: title, items: deduped))
    }

    static func appendDetailSection(
        _ sections: inout [SongInfoDetailSection],
        id: String,
        title: String,
        rows: [SongInfoDetailItem]
    ) {
        guard !rows.isEmpty else { return }
        sections.append(SongInfoDetailSection(id: id, title: title, rows: rows))
    }

    static func detailRow(
        _ title: String,
        value: String?,
        prefersSingleLineValue: Bool = false
    ) -> SongInfoDetailItem? {
        guard let value = trimmedNonEmpty(value) else { return nil }
        return SongInfoDetailItem(
            title: title,
            value: value,
            prefersSingleLineValue: prefersSingleLineValue
        )
    }

    static func nonEmptyArtists(_ artists: [Artist]?) -> [Artist]? {
        let cleaned = (artists ?? []).filter { trimmedNonEmpty($0.name) != nil }
        return cleaned.isEmpty ? nil : cleaned
    }

    static func dedupeCreditItems(_ items: [SongInfoCreditItem]) -> [SongInfoCreditItem] {
        var seen = Set<String>()
        var result: [SongInfoCreditItem] = []
        for item in items where trimmedNonEmpty(item.name) != nil {
            let key = item.id.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(item)
        }
        return result
    }

    static func albumArtistDisplay(for song: Song) -> String? {
        if let display = trimmedNonEmpty(song.displayAlbumArtist) {
            return display
        }
        if let albumArtists = nonEmptyArtists(song.albumArtists) {
            return albumArtists.map(\.name).joined(separator: ", ")
        }
        return nil
    }

    static func genreDisplay(for song: Song) -> String? {
        if let genres = song.genres?.map(\.name), let display = nonEmptyList(genres) {
            return display
        }
        return song.genre
    }

    static func formatDisplay(for song: Song) -> String? {
        if let suffix = trimmedNonEmpty(song.suffix)?.uppercased() {
            return suffix
        }
        return trimmedNonEmpty(song.contentType)
    }

    static func explicitStatusDisplay(_ status: String?) -> String? {
        guard let status = trimmedNonEmpty(status) else { return nil }
        switch status.lowercased() {
        case "explicit":
            return String(localized: "song_info_explicit")
        case "clean":
            return String(localized: "song_info_clean")
        default:
            return status
        }
    }

    static func nonEmptyList(_ values: [String]?) -> String? {
        let cleaned = (values ?? []).compactMap { trimmedNonEmpty($0) }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ")
    }

    static func worksDisplay(_ works: [SongWork]?) -> String? {
        nonEmptyList(works?.map(\.name))
    }

    static func movementsDisplay(_ movements: [SongMovement]?) -> String? {
        let values = (movements ?? []).compactMap { movement -> String? in
            guard let name = trimmedNonEmpty(movement.name) else { return nil }
            if let number = movement.number, let count = movement.count {
                return "\(number)/\(count): \(name)"
            }
            if let number = movement.number {
                return "\(number): \(name)"
            }
            return name
        }
        return nonEmptyList(values)
    }

    static func bpmDisplay(_ bpm: Int?) -> String? {
        guard let bpm, bpm > 0 else { return nil }
        return String(bpm)
    }

    static func formatSampleRate(_ rate: Int) -> String {
        let khz = Double(rate) / 1_000
        if khz.rounded() == khz {
            return "\(Int(khz)) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func channelDisplay(_ count: Int) -> String {
        switch count {
        case 1:
            return String(localized: "song_info_mono")
        case 2:
            return String(localized: "song_info_stereo")
        default:
            return String(format: String(localized: "song_info_channels_format"), count)
        }
    }

    static func formatGain(_ gain: Float) -> String {
        String(format: "%+.1f dB", gain)
    }

    static func normalizedRole(_ role: String) -> String {
        role
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func rolePriority(_ key: String) -> Int {
        switch key {
        case "performer": return 0
        case "composer": return 1
        case "lyricist": return 2
        case "producer": return 3
        case "arranger": return 4
        case "conductor": return 5
        case "engineer", "recordingengineer", "audioengineer": return 6
        case "mixer", "mixengineer", "mixingengineer", "djmixer": return 7
        case "mastering", "masteringengineer": return 8
        case "remixer": return 9
        default: return 50
        }
    }

    static func roleTitle(for key: String, fallback: String) -> String {
        switch key {
        case "performer":
            return String(localized: "song_info_performers")
        case "composer":
            return String(localized: "song_info_composers")
        case "lyricist":
            return String(localized: "song_info_lyricists")
        case "producer":
            return String(localized: "song_info_producers")
        case "arranger":
            return String(localized: "song_info_arrangers")
        case "conductor":
            return String(localized: "song_info_conductors")
        case "engineer", "recordingengineer", "audioengineer":
            return String(localized: "song_info_engineers")
        case "mixer", "mixengineer", "mixingengineer", "djmixer":
            return String(localized: "song_info_mixers")
        case "mastering", "masteringengineer":
            return String(localized: "song_info_mastering")
        case "remixer":
            return String(localized: "song_info_remixers")
        default:
            return humanizedRole(fallback)
        }
    }

    static func humanizedRole(_ role: String) -> String {
        role
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
