import SwiftUI

struct MacPortOwnersButton: View {
    let port: Int
    let onRelease: () -> Void
    @State private var showsOwners = false

    var body: some View {
        Button("查看占用进程…") { showsOwners = true }
            .buttonStyle(.link)
            .font(.caption)
            .popover(isPresented: $showsOwners) {
                MacPortOwnersPopover(port: port, onRelease: onRelease)
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
                Text("Mac TCP 端口 \(String(port))").font(.headline)
                Spacer()
                Button {
                    busy = true
                    Task { await refresh() }
                } label: {
                    Label("刷新进程", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(busy)
            }
            if busy {
                ProgressView().controlSize(.small)
            } else if owners.isEmpty && message == nil {
                Text("未找到此端口的可见监听进程。")
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
                        Button("强制结束…", role: .destructive) { pending = owner }
                            .disabled(busy)
                    } else {
                        Text("无法从此处结束")
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
        .alert("强制结束监听进程？", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), presenting: pending) { owner in
            Button("强制结束", role: .destructive) {
                busy = true
                Task { await end(owner) }
            }
            Button("取消", role: .cancel) {}
        } message: { owner in
            Text("将向 \(owner.name)（PID \(String(owner.id))）发送 SIGKILL。未保存的数据可能丢失，该进程的其他连接也会中断。")
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
                message = "端口已释放。"
                onRelease()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await refresh()
        if message == nil {
            message = "已发送 SIGKILL，端口仍被占用。"
        }
    }
}
