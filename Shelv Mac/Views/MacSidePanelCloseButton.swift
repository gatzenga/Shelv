import SwiftUI

struct MacSidePanelCloseButton: View {
    let action: () -> Void
    @AppStorage(PersonalizationPreferenceKey.miniPlayerStyle) private var interfaceStyleRaw = PersonalizationMiniPlayerStyle.shelv.rawValue
    @State private var isHovered = false

    private var usesNativeInterface: Bool {
        PersonalizationMiniPlayerStyle(rawValue: interfaceStyleRaw) == .native
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background {
                    Circle()
                        .fill(Color.primary.opacity(backgroundOpacity))
                        .overlay {
                            if usesNativeInterface {
                                Circle()
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                            }
                        }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "done"))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundOpacity: Double {
        if usesNativeInterface {
            return isHovered ? 0.11 : 0.075
        }
        return isHovered ? 0.10 : 0.06
    }
}
