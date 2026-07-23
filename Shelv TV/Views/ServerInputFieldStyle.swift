import SwiftUI

extension View {
    func tvServerInputField() -> some View {
        font(.body)
            .lineLimit(1)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
    }
}
