import Foundation

enum PlaylistSortOption: String, CaseIterable {
    case alphabetical, lastModified, dateCreated

    var label: String {
        switch self {
        case .alphabetical: return String(localized: "name")
        case .lastModified: return String(localized: "last_modified")
        case .dateCreated:  return String(localized: "date_created")
        }
    }
}
