import SwiftUI

struct ShelveToast: Equatable {
    let message: String
    var isError: Bool = false
}

private struct ToastViewModifier: ViewModifier {
    @Binding var toast: ShelveToast?
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @State private var isVisible = false
    @State private var displayedToast: ShelveToast?
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isVisible, let t = displayedToast {
                    toastBanner(t)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: toast) { _, newToast in
                if let newToast {
                    displayedToast = newToast
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isVisible = true
                    }
                    dismissTask?.cancel()
                    dismissTask = Task {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isVisible = false
                            toast = nil
                        }
                    }
                } else if isVisible {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isVisible = false
                    }
                }
            }
    }

    private func toastBanner(_ t: ShelveToast) -> some View {
        HStack(spacing: 8) {
            Image(systemName: t.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text(t.message)
                .font(.subheadline).bold()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(t.isError ? Color.red : accentColor)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .padding(.top, 8)
    }
}

extension View {
    func shelveToast(_ toast: Binding<ShelveToast?>) -> some View {
        modifier(ToastViewModifier(toast: toast))
    }
}
