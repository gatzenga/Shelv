import AVKit
import AppKit
import SwiftUI

struct AVRoutePickerViewRepresentable: NSViewRepresentable {
    var normalColor: NSColor = .secondaryLabelColor
    var activeColor: NSColor = .controlAccentColor

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: AVRoutePickerView) {
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(normalColor, for: .normal)
        view.setRoutePickerButtonColor(normalColor, for: .normalHighlighted)
        view.setRoutePickerButtonColor(activeColor, for: .active)
        view.setRoutePickerButtonColor(activeColor, for: .activeHighlighted)
    }
}
