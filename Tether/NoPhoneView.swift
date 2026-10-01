import SwiftUI

/// Shown when no phone is connected: what to do, with a picture of Android's USB notification.
struct NoPhoneView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "cable.connector")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Connect an Android Phone").font(.title2.bold())
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Connect the phone with a USB cable.")
                step(2, "Unlock the phone.")
                step(3, "In the USB notification, choose “File transfer”.")
            }
            USBNotificationMock()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("noPhoneView")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number, format: .number)
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.2)))
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A simplified drawing of Android's "Use USB for" choice with File transfer selected.
private struct USBNotificationMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Use USB for", systemImage: "cable.connector.horizontal")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            option("File transfer", selected: true)
            option("USB tethering", selected: false)
            option("MIDI", selected: false)
            option("No data transfer", selected: false)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .tetherCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example: in the phone’s USB notification, File transfer is selected.")
    }

    private func option(_ title: LocalizedStringKey, selected: Bool) -> some View {
        HStack {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(title).fontWeight(selected ? .semibold : .regular)
        }
        .font(.callout)
    }
}
