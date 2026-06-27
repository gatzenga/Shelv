import SwiftUI

struct TVSettingsChoiceOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

struct TVSettingsChoiceRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [TVSettingsChoiceOption<Value>]
    var onSelectionChange: ((Value) -> Void)? = nil

    @State private var isPresented = false

    private var selectedTitle: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(selectedTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .confirmationDialog(title, isPresented: $isPresented, titleVisibility: .visible) {
            ForEach(options) { option in
                Button(option.title) {
                    guard selection != option.value else { return }
                    selection = option.value
                    onSelectionChange?(option.value)
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
    }
}
