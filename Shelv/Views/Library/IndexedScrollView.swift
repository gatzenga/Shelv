import SwiftUI

struct IndexedScrollView<Content: View>: View {
    let letters: [String]
    let idPrefix: String
    @Binding var scrollID: String?
    private let content: () -> Content

    init(
        letters: [String],
        idPrefix: String,
        scrollID: Binding<String?>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.letters = letters
        self.idPrefix = idPrefix
        self._scrollID = scrollID
        self.content = content
    }

    var body: some View {
        ScrollView {
            content()
                .padding(.trailing, letters.isEmpty ? 0 : 16)
        }
        .scrollPosition(id: $scrollID)
        .scrollIndicators(.hidden)
        .overlay(alignment: .trailing) {
            if !letters.isEmpty {
                AlphabetIndexBar(letters: letters) { letter in
                    withAnimation(.none) {
                        scrollID = "\(idPrefix)-\(letter)"
                    }
                }
                .frame(width: 14)
                .padding(.vertical, 16)
                .padding(.trailing, 2)
            }
        }
    }
}
