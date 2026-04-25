import SwiftUI

struct AlphabetIndexBar: View {
    let letters: [String]
    let onSelect: (String) -> Void

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
                    guard !letters.isEmpty else { return }
                    let index = min(max(Int(value.location.y / itemHeight), 0), letters.count - 1)
                    let letter = letters[index]
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
                            guard !Task.isCancelled else { return }
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
                    throttleTask?.cancel()
                    throttleTask = nil
                    throttled = false
                    if !pendingLetter.isEmpty {
                        guard !letters.isEmpty else { lastSelected = ""; pendingLetter = ""; return }
                        let index = min(max(Int(value.location.y / itemHeight), 0), letters.count - 1)
                        onSelect(letters[index])
                    }
                    lastSelected = ""
                    pendingLetter = ""
                }
        )
        .onDisappear {
            throttleTask?.cancel()
            throttleTask = nil
        }
    }
}
