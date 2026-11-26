import AppKit
import SwiftUI

public enum TunnelDetailLayout {
    public static let insets = EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24)
}

public struct TunnelDetailPane<Actions: View, Content: View>: View {
    private let heading: TunnelHeading<Actions>
    private let content: Content

    public init(_ title: String, subtitle: String, icon: String,
                @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        heading = TunnelHeading(title, subtitle: subtitle, icon: icon, actions: actions)
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            heading
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
    }
}

public extension View {
    func tunnelDetailCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .labeledContentStyle(DetailFieldStyle())
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
    }
}

private struct DetailFieldStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            configuration.content
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.callout)
    }
}

public struct TunnelDetailSection<Actions: View, Content: View>: View {
    private let title: LocalizedStringKey
    private let actions: Actions
    private let content: Content

    public init(_ title: LocalizedStringKey, @ViewBuilder actions: () -> Actions,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                actions
            }
            content.tunnelDetailCard()
        }
    }
}

public extension TunnelDetailSection where Actions == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(title, actions: { EmptyView() }, content: content)
    }
}

private struct TunnelHeading<Actions: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let actions: Actions

    init(_ title: String, subtitle: String, icon: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            headline
                .padding(.vertical, TunnelDetailLayout.insets.top)
            Divider()
        }
        .padding(.horizontal, TunnelDetailLayout.insets.leading)
    }

    private var headline: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold)).lineLimit(1).help(title)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { actions }
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

public struct TunnelRoute: View {
    let source: String
    let target: String?
    let bidirectional: Bool

    public init(_ source: String, to target: String? = nil, bidirectional: Bool = false) {
        self.source = source
        self.target = target
        self.bidirectional = bidirectional
    }

    public var body: some View {
        HStack(spacing: 8) {
            endpoint(source)
            if let target {
                Image(systemName: bidirectional ? "arrow.left.arrow.right" : "arrow.right")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .accessibilityLabel(bidirectional ? Text("Bidirectional Forward") : Text("Forward To"))
                endpoint(target)
            }
        }
    }

    private func endpoint(_ value: String) -> some View {
        Text(value)
            .font(.callout.monospacedDigit()).lineLimit(1).help(value).textSelection(.enabled)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
}

public struct TunnelProfileEditor<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    let title: String
    let subtitle: String
    let icon: String
    let width: CGFloat
    let height: CGFloat?
    let preview: String?
    let footerNote: LocalizedStringKey?
    let saveTitle: LocalizedStringKey
    let canSave: Bool
    let onSave: () -> String?
    let content: Content

    public init(_ title: String, subtitle: String, icon: String, width: CGFloat = 560, height: CGFloat? = nil,
                preview: String? = nil, footerNote: LocalizedStringKey? = nil, saveTitle: LocalizedStringKey = "Save",
                canSave: Bool, onSave: @escaping () -> String?,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.width = width
        self.height = height
        self.preview = preview
        self.footerNote = footerNote
        self.saveTitle = saveTitle
        self.canSave = canSave
        self.onSave = onSave
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            TunnelHeading(title, subtitle: subtitle, icon: icon) { EmptyView() }
            if height != nil {
                ScrollView { fields }
            } else {
                fields
            }
            Divider().padding(.horizontal, TunnelDetailLayout.insets.leading)
            HStack(spacing: 8) {
                if let footerNote {
                    Text(footerNote).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saveTitle) {
                    saveError = onSave()
                    if saveError == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(.horizontal, TunnelDetailLayout.insets.leading)
            .padding(.vertical, 12)
        }
        .frame(width: width, height: height)
        .alert("Could Not Save Configuration", isPresented: Binding(get: { saveError != nil },
                                                  set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
            if let preview {
                DisclosureGroup("Command Preview") {
                    Text(preview).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textFieldStyle(.roundedBorder)
        .padding(TunnelDetailLayout.insets)
    }
}

public struct TunnelEditorField<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.medium)).accessibilityHidden(true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct TunnelSidebarLabel<Icon: View>: View {
    let title: String
    let subtitle: String?
    let icon: Icon

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon()
    }

    public var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

public struct TunnelMenuRow: View {
    let title: String
    let route: String
    let status: Text
    let color: Color
    let detail: String?
    let enabled: Binding<Bool>
    let disabled: Bool

    public init(_ title: String, route: String, status: Text, color: Color, detail: String? = nil,
                enabled: Binding<Bool>, disabled: Bool = false) {
        self.title = title
        self.route = route
        self.status = status
        self.color = color
        self.detail = detail
        self.enabled = enabled
        self.disabled = disabled
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
                .frame(width: 16).accessibilityLabel(status)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                if !route.isEmpty {
                    Text(route).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(color).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(disabled)
        }
        .padding(.vertical, 5)
        .modifier(MenuRowHover())
        .help(detail.map { Text($0) } ?? status)
    }
}

private enum MenuHoverSpace: Hashable {
    case menu
}

private struct MenuPointerKey: EnvironmentKey {
    static let defaultValue: CGPoint? = nil
}

private extension EnvironmentValues {
    var menuPointer: CGPoint? {
        get { self[MenuPointerKey.self] }
        set { self[MenuPointerKey.self] = newValue }
    }
}

public struct MenuHoverTracking: ViewModifier {
    @State private var pointer: CGPoint?

    public init() {}

    public func body(content: Content) -> some View {
        content
            .environment(\.menuPointer, pointer)
            .background(MenuPointerView { location in
                if pointer != location { pointer = location }
            })
            .coordinateSpace(name: MenuHoverSpace.menu)
            .onDisappear { pointer = nil }
    }
}

public struct MenuRowHover: ViewModifier {
    @Environment(\.menuPointer) private var pointer
    @State private var isHovered = false
    private let tracksInactiveWindow: Bool

    public init(tracksInactiveWindow: Bool = true) {
        self.tracksInactiveWindow = tracksInactiveWindow
    }

    public func body(content: Content) -> some View {
        let row = content
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
        Group {
            if tracksInactiveWindow {
                row.background {
                    GeometryReader { geometry in
                        highlight(containsPointer(in: geometry))
                    }
                    .allowsHitTesting(false)
                }
            } else {
                row.background { highlight(isHovered) }
                    .onHover { isHovered = $0 }
                    .onDisappear { isHovered = false }
            }
        }
        .padding(.horizontal, 5)
    }

    private func highlight(_ hovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.primary.opacity(hovered ? 0.09 : 0))
    }

    private func containsPointer(in geometry: GeometryProxy) -> Bool {
        guard let pointer else { return false }
        let bounds = CGRect(origin: .zero, size: geometry.size)
        let visibleBounds = geometry.bounds(of: .scrollView).map { bounds.intersection($0) } ?? bounds
        let origin = geometry.frame(in: .named(MenuHoverSpace.menu)).origin
        let localPointer = CGPoint(x: pointer.x - origin.x, y: pointer.y - origin.y)
        return visibleBounds.contains(localPointer)
    }
}

private struct MenuPointerView: NSViewRepresentable {
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: view, userInfo: nil)
        view.addTrackingArea(area)
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onMove = onMove
    }

    final class TrackingView: NSView {
        var onMove: ((CGPoint?) -> Void)?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.isVisible else { return }
                self.updatePointer(window.mouseLocationOutsideOfEventStream)
            }
        }

        override func mouseEntered(with event: NSEvent) { updatePointer(event.locationInWindow) }
        override func mouseMoved(with event: NSEvent) { updatePointer(event.locationInWindow) }
        override func mouseExited(with event: NSEvent) { onMove?(nil) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func updatePointer(_ location: NSPoint) {
            let point = convert(location, from: nil)
            onMove?(visibleRect.contains(point) ? point : nil)
        }
    }
}
