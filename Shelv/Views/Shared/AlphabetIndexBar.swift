import SwiftUI

struct AlphabetIndexBar: View {
    let letters: [String]
    let onSelect: (String) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var lastSelected = ""
    @State private var throttled = false
    @State private var pendingLetter = ""
    @State private var throttleTask: Task<Void, Never>?
    private let itemHeight: CGFloat = 14
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: itemHeight)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard scenePhase == .active,
                          let letter = letter(at: value.location.y)
                    else { return }
                    guard letter != lastSelected else { return }
                    lastSelected = letter
                    feedback.impactOccurred()
                    if throttled {
                        pendingLetter = letter
                    } else {
                        throttled = true
                        pendingLetter = ""
                        onSelect(letter)
                        throttleTask?.cancel()
                        throttleTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 40_000_000)
                            guard !Task.isCancelled, scenePhase == .active else { return }
                            throttleTask = nil
                            throttled = false
                            if !pendingLetter.isEmpty {
                                let l = pendingLetter
                                pendingLetter = ""
                                onSelect(l)
                            }
                        }
                    }
                }
                .onEnded { value in
                    guard scenePhase == .active else {
                        resetInteraction()
                        return
                    }
                    cancelPendingSelection()
                    if !pendingLetter.isEmpty {
                        if let letter = letter(at: value.location.y) {
                            onSelect(letter)
                        }
                    }
                    lastSelected = ""
                    pendingLetter = ""
                }
        )
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                resetInteraction()
            }
        }
        .onChange(of: letters) { _, _ in
            resetInteraction()
        }
        .onDisappear {
            resetInteraction()
        }
    }

    private func cancelPendingSelection() {
        throttleTask?.cancel()
        throttleTask = nil
        throttled = false
    }

    private func resetInteraction() {
        cancelPendingSelection()
        lastSelected = ""
        pendingLetter = ""
    }

    private func letter(at yPosition: CGFloat) -> String? {
        guard yPosition.isFinite, !letters.isEmpty else { return nil }
        let rawIndex = yPosition / itemHeight
        guard rawIndex.isFinite else { return nil }
        let clampedIndex = min(max(rawIndex, 0), CGFloat(letters.count - 1))
        return letters[Int(clampedIndex)]
    }
}
