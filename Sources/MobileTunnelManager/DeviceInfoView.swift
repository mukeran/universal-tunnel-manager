import SwiftUI

struct DeviceInfoButton: View {
    let device: Device?
    @State private var showDetails = false

    var body: some View {
        Button { showDetails.toggle() } label: {
            Label("Device Details", systemImage: "info.circle").labelStyle(.iconOnly)
        }
        .help("Show Device Details")
        .disabled(device == nil)
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            if let device {
                DeviceInfoView(device: device).environment(\.locale, L10n.locale)
            }
        }
    }
}

private struct DeviceInfoView: View {
    let device: Device
    @State private var model: String?
    @State private var version: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(device.name, systemImage: device.id.platform.icon)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                detail("Platform", value: device.id.platform.title)
                detail("Connection Type", value: device.connectionType ?? L10n.text("Not reported"))
                detail("Connection Status", value: device.ready ? L10n.text("Connected") : device.connection)
                if let model { detail("Model", value: model) }
                if let version { detail("OS Version", value: version) }
                if let transport = device.transport { detail("ADB Transport ID", value: transport) }
            }
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading device details…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            identifier(device.id.label, value: device.id.serial)
            if let address = device.adbSerial, address != device.id.serial {
                identifier(L10n.text("Current ADB Address"), value: address)
            }
        }
        .padding(16)
        .frame(width: 346, alignment: .leading)
        .task(id: device) {
            model = nil
            version = nil
            isLoading = device.ready
            let details = await DeviceTools().deviceDetails(for: device)
            guard !Task.isCancelled else { return }
            model = details.model
            version = details.version
            isLoading = false
        }
    }

    private func detail(_ title: LocalizedStringKey, value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func identifier(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
