import SwiftUI

struct MacPortOwnersButton: View {
    let port: Int
    let onRelease: () -> Void
    @State private var showsOwners = false

    var body: some View {
        Button("Show Listening Processes…") { showsOwners = true }
            .buttonStyle(.link)
            .font(.caption)
            .popover(isPresented: $showsOwners) {
                MacPortOwnersPopover(port: port, onRelease: onRelease)
                    .environment(\.locale, L10n.locale)
            }
    }
}

private struct MacPortOwnersPopover: View {
    let port: Int
    let onRelease: () -> Void
    @State private var owners: [MacPortOwner] = []
    @State private var busy = true
    @State private var message: String?
    @State private var pending: MacPortOwner?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mac TCP Port \(String(port))").font(.headline)
                Spacer()
                Button {
                    busy = true
                    Task { await refresh() }
                } label: {
                    Label("Refresh Processes", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(busy)
            }
            if busy {
                ProgressView().controlSize(.small)
            } else if owners.isEmpty && message == nil {
                Text("No visible processes are listening on this port.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(owners) { owner in
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(owner.name).fontWeight(.medium).textSelection(.enabled)
                        Text("PID \(String(owner.id)) · \(owner.endpoints)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 4)
                    if owner.canForceKill {
                        Button("Force Quit…", role: .destructive) { pending = owner }
                            .disabled(busy)
                    } else {
                        Text("Cannot Force Quit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 370, alignment: .leading)
        .task(id: port) { await refresh() }
        .alert("Force quit the listening process?", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), presenting: pending) { owner in
            Button("Force Quit", role: .destructive) {
                busy = true
                Task { await end(owner) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { owner in
            Text("SIGKILL will be sent to \(owner.name) (PID \(String(owner.id))). Unsaved data may be lost, and the process’s other connections will close.")
        }
    }

    private func refresh() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            owners = try await MacListener.owners(of: port)
        } catch {
            owners = []
            message = error.localizedDescription
        }
    }

    private func end(_ owner: MacPortOwner) async {
        defer { busy = false }
        do {
            try MacListener.forceKill(owner, port: port)
        } catch {
            await refresh()
            message = error.localizedDescription
            return
        }
        for _ in 0..<10 {
            if (try? MacListener.checkAvailability(port: port)) != nil {
                owners = []
                message = L10n.text("The port is now available.")
                onRelease()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await refresh()
        if message == nil {
            message = L10n.text("SIGKILL was sent. The port is still in use.")
        }
    }
}
