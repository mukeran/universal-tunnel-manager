import SwiftUI
import TunnelUI

struct TunnelHookFields: View {
    @Binding var hooks: TunnelHooks?
    var supportsRemote: Bool = false
    @State private var expanded: Bool

    init(hooks: Binding<TunnelHooks?>, supportsRemote: Bool = false) {
        _hooks = hooks
        self.supportsRemote = supportsRemote
        _expanded = State(initialValue: hooks.wrappedValue != nil)
    }

    var body: some View {
        DisclosureGroup("Connection Commands", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                fields("On This Mac", site: \.local)
                if supportsRemote {
                    Divider()
                    fields("On the SSH Host", site: \.remote)
                }
                Text("Commands run through /bin/sh. A failed Before Connect command prevents the connection from starting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func fields(_ title: LocalizedStringKey,
                        site: WritableKeyPath<TunnelHooks, TunnelHooks.Commands?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            field("Before Connect", site: site, phase: \.beforeConnect)
            field("After Connect", site: site, phase: \.afterConnect)
            field("After Disconnect", site: site, phase: \.afterDisconnect)
        }
    }

    private func field(_ title: LocalizedStringKey,
                       site: WritableKeyPath<TunnelHooks, TunnelHooks.Commands?>,
                       phase: WritableKeyPath<TunnelHooks.Commands, String?>) -> some View {
        TunnelEditorField(title) {
            TextEditor(text: Binding(get: { hooks?[keyPath: site]?[keyPath: phase] ?? "" }, set: { value in
                var updated = hooks ?? TunnelHooks()
                var commands = updated[keyPath: site] ?? TunnelHooks.Commands()
                commands[keyPath: phase] = value.isEmpty ? nil : value
                updated[keyPath: site] = commands == TunnelHooks.Commands() ? nil : commands
                hooks = updated == TunnelHooks() ? nil : updated
            }))
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(height: 72)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(Text(title))
        }
    }
}
