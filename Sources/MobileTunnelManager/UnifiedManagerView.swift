import SwiftUI
import TunnelUI
import UniformTypeIdentifiers

enum TunnelSelection: Hashable {
    case profile(TunnelRule.Key)
    case group(UUID?)
}

struct UnifiedManagerView: View {
    let controller: TunnelController
    @Binding var selection: TunnelSelection?
    let newRequest: Int

    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var editor: Editor?
    @State private var pendingDelete: TunnelRule?
    @State private var pendingGroup: ProfileGroup?
    @State private var showNew = false
    @State private var collapsedGroups: Set<UUID?> = []
    @State private var showDevices = false
    @State private var showPreferences = false
    @State private var loginItemIssue: PreferencesView.LoginItemIssue?
    @State private var showImport = false
    @State private var importMessage: String?
    @State private var showExport = false
    @State private var exportDocument: ConfigurationExportDocument?
    @State private var exportError: String?
    @State private var sidebarFrame: CGRect = .null
    @State private var sidebarFooterFrame: CGRect = .null
    @State private var dropFrames: [DropRow: CGRect] = [:]
    @GestureState private var drag: SidebarDrag? = nil

    private enum DropRow: Hashable {
        case group(UUID?)
        case profile(TunnelRule.Key)

        var selection: TunnelSelection {
            switch self {
            case .group(let id): .group(id)
            case .profile(let key): .profile(key)
            }
        }
    }

    private struct DropPosition: Equatable {
        let row: DropRow
        let edge: VerticalEdge?
    }

    private enum SidebarDrop {
        case profile(DropPosition)
        case group(before: UUID?, indicator: DropPosition)

        var indicator: DropPosition {
            switch self {
            case .profile(let position), .group(_, let position): position
            }
        }
    }

    private struct SidebarDrag {
        let source: DropRow
        let location: CGPoint
        let indicator: DropPosition?
    }

    private enum Editor: Identifiable {
        case device(EditorRequest, UUID?)
        case ssh(SSHTunnel, UUID?)
        case socat(SocatProfile, UUID?)
        case group(ProfileGroup)

        var id: TunnelSelection {
            switch self {
            case .device(let request, _): .profile(.init(type: .device, id: request.id))
            case .ssh(let tunnel, _): .profile(TunnelRule.ssh(tunnel).key)
            case .socat(let session, _): .profile(TunnelRule.socat(session).key)
            case .group(let group): .group(group.id)
            }
        }
    }

    private var store: TunnelStore { controller.store }
    private var groups: [ProfileGroup] { store.configuration.groups }
    private var availableSelections: [TunnelSelection] {
        store.profileSections.flatMap { group in
            [.group(group.id)] + group.profiles.map { .profile($0.key) }
        }
    }
    private var targetGroup: UUID? {
        switch selection {
        case .profile(let key): store.group(for: key)?.id
        case .group(let id): id
        case nil: nil
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar.navigationSplitViewColumnWidth(min: 205, ideal: 226, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.primary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(TunnelDetailLayout.insets)
                        .background(.orange.opacity(0.12))
                }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea(.container, edges: visibility == .detailOnly ? [] : .top)
        }
        .overlay {
            if let drag { dragPreview(drag) }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: availableSelections, initial: true) { before, after in
            if let selection, after.contains(selection) { return }
            if let selection, let index = before.firstIndex(of: selection), !after.isEmpty {
                self.selection = after[min(index, after.count - 1)]
            } else {
                selection = after.first
            }
        }
        .onChange(of: newRequest) { _, _ in presentNew() }
        .sheet(item: $editor) { request in
            editorView(request).environment(\.locale, L10n.locale)
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json], onCompletion: importFile)
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .json,
                      defaultFilename: "utm-tunnels") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Could Not Export Configuration", isPresented: Binding(get: { exportError != nil },
                                                   set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .alert("Import Configuration", isPresented: Binding(get: { importMessage != nil },
                                               set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importMessage ?? "") }
        .alert("Delete profile?", isPresented: Binding(get: { pendingDelete != nil },
                                                      set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { profile in
            Button("Delete", role: .destructive) { controller.delete(profile) }
            Button("Cancel", role: .cancel) {}
        } message: { profile in Text(profile.name) }
        .alert("Delete group?", isPresented: Binding(get: { pendingGroup != nil },
                                                set: { if !$0 { pendingGroup = nil } }),
               presenting: pendingGroup) { group in
            Button("Delete Group", role: .destructive) { store.deleteGroup(group.id) }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text("Profiles in “\(group.displayName)” will move to Ungrouped.")
        }
    }

    private var sidebar: some View {
        let showUngroupedDropTarget = drag.map { needsUngroupedDropTarget(for: $0.source) } ?? false
        return VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.profileSections) { group in
                    Section {
                        groupRow(group)
                        if !collapsedGroups.contains(group.id) {
                            profileRows(group.profiles, groupID: group.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sidebarFrame = $0 }

            Divider()
            HStack(spacing: 12) {
                Button(action: presentNew) { Label("New", systemImage: "plus") }
                    .disabled(!store.canEdit)
                    .popover(isPresented: $showNew, arrowEdge: .top) {
                        newProfileChoices.environment(\.locale, L10n.locale)
                    }
                Spacer(minLength: 0)
                Button { showDevices.toggle() } label: {
                    Label("Device Status", systemImage: "iphone").labelStyle(.iconOnly)
                }
                .help("Device Status")
                .popover(isPresented: $showDevices, arrowEdge: .top) {
                    deviceStatus.environment(\.locale, L10n.locale)
                }
                Button { showPreferences.toggle() } label: {
                    Label("Preferences", systemImage: "gearshape").labelStyle(.iconOnly)
                }
                .help("Preferences")
                .keyboardShortcut(",")
                .popover(isPresented: $showPreferences, arrowEdge: .top) {
                    PreferencesView(controller: controller, loginItemIssue: $loginItemIssue)
                        .environment(\.locale, L10n.locale)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .opacity(showUngroupedDropTarget ? 0 : 1)
            .overlay {
                if showUngroupedDropTarget { ungroupedDropTarget }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sidebarFooterFrame = $0 }
        }
    }

    private var ungroupedDropTarget: some View {
        let targeted = drag?.indicator == DropPosition(row: .group(nil), edge: nil)
        return Label("Move to Ungrouped", systemImage: "tray")
            .font(.callout)
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(targeted ? 0.16 : 0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .allowsHitTesting(false)
    }

    private func needsUngroupedDropTarget(for source: DropRow) -> Bool {
        guard case .profile(let key) = source, store.group(for: key) != nil else { return false }
        return dropFrames[.group(nil)]?.intersects(sidebarFrame) != true
    }

    private func groupRow(_ group: ProfileGroupSection) -> some View {
        let row = DropRow.group(group.id)
        let collapsed = collapsedGroups.contains(group.id)
        return dropRow(row) {
            HStack(spacing: 6) {
                groupLabel(group.displayName, icon: group.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .simultaneousGesture(sidebarInteraction(row))
                Button {
                    if collapsed {
                        collapsedGroups.remove(group.id)
                    } else {
                        collapsedGroups.insert(group.id)
                        if case .profile(let key) = selection, group.profiles.contains(where: { $0.key == key }) {
                            selection = .group(group.id)
                        }
                    }
                } label: {
                    Label(collapsed ? L10n.text("Expand Group") : L10n.text("Collapse Group"),
                          systemImage: collapsed ? "chevron.right" : "chevron.down")
                        .labelStyle(.iconOnly).font(.caption2.weight(.semibold)).frame(width: 12)
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .tag(row.selection)
        .contextMenu {
            if let group = group.group { groupActions(group) }
        }
    }

    private func profileRows(_ profiles: [TunnelRule], groupID: UUID?) -> some View {
        ForEach(profiles, id: \.key) { profile in
            let row = DropRow.profile(profile.key)
            let status = controller.status(profile)
            dropRow(row) {
                profileLabel(profile, status: status)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .simultaneousGesture(sidebarInteraction(row))
            }
            .tag(row.selection)
            .help(status.detail.map { Text($0) } ?? status.title)
            .contextMenu { profileActions(profile, among: profiles, groupID: groupID) }
        }
    }

    private func profileLabel(_ profile: TunnelRule, status: ProfileStatus) -> some View {
        TunnelSidebarLabel(profile.name, subtitle: "\(profile.kind.title) · \(profile.route)") {
            Circle().fill(status.color).frame(width: 8, height: 8)
        }
    }

    private func groupLabel(_ name: String, icon: String) -> some View {
        TunnelSidebarLabel(name) {
            Image(systemName: icon).foregroundStyle(.secondary)
        }
    }

    private func dragPreview(_ drag: SidebarDrag) -> some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .global).origin
            let cursor = CGPoint(x: drag.location.x - origin.x, y: drag.location.y - origin.y)
            let width = min(max(sidebarFrame.width - 20, 160), 240)
            let height: CGFloat = switch drag.source {
            case .profile: 44
            case .group: 32
            }
            let gap: CGFloat = 12
            let offsetX = gap + width / 2
            let offsetY = gap + height / 2
            let x = cursor.x + (cursor.x + gap + width <= geometry.size.width ? offsetX : -offsetX)
            let y = cursor.y + (cursor.y + gap + height <= geometry.size.height ? offsetY : -offsetY)

            dragLabel(drag.source)
                .padding(.horizontal, 8)
                .frame(width: width, height: height, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65))
                }
                .shadow(color: .black.opacity(0.18), radius: 7, x: 0, y: 3)
                .position(x: x, y: y)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func dragLabel(_ row: DropRow) -> some View {
        switch row {
        case .profile(let key):
            if let profile = store.configuration.rules.first(where: { $0.key == key }) {
                profileLabel(profile, status: controller.status(profile))
            }
        case .group(let id):
            if let group = groups.first(where: { $0.id == id }) {
                groupLabel(group.displayName, icon: "folder")
            }
        }
    }

    private func dropRow<Content: View>(_ row: DropRow, @ViewBuilder content: () -> Content) -> some View {
        let destination = drag?.indicator
        return content()
            .opacity(drag?.source == row ? 0.55 : 1)
            .background {
                if destination == DropPosition(row: row, edge: nil) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18))
                }
            }
            .overlay(alignment: destination?.edge == .bottom ? .bottom : .top) {
                if destination?.row == row, destination?.edge != nil {
                    Capsule().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dropFrames[row] = $0 }
            .onDisappear { dropFrames.removeValue(forKey: row) }
    }

    private func sidebarInteraction(_ row: DropRow) -> some Gesture {
        let reorder = DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($drag) { value, state, _ in
                guard store.canEdit, row != .group(nil) else { return }
                state = SidebarDrag(source: row, location: value.location,
                                    indicator: sidebarDrop(for: row, at: value.location)?.indicator)
            }
            .onEnded { value in
                guard store.canEdit, let drop = sidebarDrop(for: row, at: value.location) else { return }
                switch (row, drop) {
                case (.profile(let key), .profile(let position)):
                    dropProfile(key, at: position)
                case (.group(let id?), .group(let next, _)):
                    store.moveGroup(id, before: next)
                default:
                    break
                }
            }
        return reorder.exclusively(before: TapGesture().onEnded {
            selection = row.selection
        })
    }

    private func sidebarDrop(for source: DropRow, at point: CGPoint) -> SidebarDrop? {
        if sidebarFooterFrame.contains(point), needsUngroupedDropTarget(for: source) {
            return .profile(DropPosition(row: .group(nil), edge: nil))
        }
        guard source != .group(nil), sidebarFrame.contains(point) else { return nil }
        func distance(to frame: CGRect) -> CGFloat {
            max(frame.minY - point.y, point.y - frame.maxY, 0)
        }
        let visible = dropFrames.filter { $0.value.intersects(sidebarFrame) }
        guard let (row, frame) = visible.min(by: { distance(to: $0.value) < distance(to: $1.value) }) else { return nil }
        let upperHalf = point.y < frame.midY
        switch source {
        case .profile:
            guard distance(to: frame) <= 8 else { return nil }
            let edge: VerticalEdge?
            if case .profile = row { edge = upperHalf ? .top : .bottom } else { edge = nil }
            return .profile(DropPosition(row: row, edge: edge))
        case .group:
            return groupDrop(near: row, upperHalf: upperHalf, visible: visible)
        }
    }

    private func groupDrop(near row: DropRow, upperHalf: Bool, visible: [DropRow: CGRect]) -> SidebarDrop {
        let sectionID: UUID?
        let insertAbove: Bool
        switch row {
        case .group(let id):
            sectionID = id
            insertAbove = upperHalf
        case .profile(let key):
            sectionID = store.group(for: key)?.id
            insertAbove = false
        }

        let next: UUID?
        if let index = groups.firstIndex(where: { $0.id == sectionID }) {
            next = groups.dropFirst(insertAbove ? index : index + 1).first?.id
        } else {
            next = groups.first?.id
        }
        if let next, visible[.group(next)] != nil {
            return .group(before: next, indicator: DropPosition(row: .group(next), edge: .top))
        }

        let members = groups.first(where: { $0.id == sectionID })?.profiles
            ?? store.ungrouped.map(\.key)
        let last = members.reversed().map(DropRow.profile).first { visible[$0] != nil }
        return .group(before: next, indicator: DropPosition(row: last ?? .group(sectionID), edge: .bottom))
    }

    private func dropProfile(_ key: TunnelRule.Key, at position: DropPosition) {
        switch position.row {
        case .group(let id):
            moveProfile(key, to: id)
        case .profile(let neighbor):
            let group = store.group(for: neighbor)
            let keys = group?.profiles ?? store.ungrouped.map(\.key)
            guard let index = keys.firstIndex(of: neighbor) else { return }
            let next = position.edge == .top ? neighbor : keys.dropFirst(index + 1).first
            moveProfile(key, to: group?.id, before: next)
        }
    }

    @ViewBuilder private func profileActions(_ profile: TunnelRule, among profiles: [TunnelRule], groupID: UUID?) -> some View {
        Button("Edit…") { edit(profile) }.disabled(!controller.canEdit(profile))
        Button("Duplicate Profile") {
            if let key = controller.duplicate(profile) { selection = .profile(key) }
        }
        .disabled(!store.canEdit || isLegacyDevice(profile))
        Menu("Move to Group") {
            Button("Ungrouped") { moveProfile(profile.key, to: nil) }.disabled(groupID == nil)
            ForEach(groups) { group in
                Button(group.displayName) { moveProfile(profile.key, to: group.id) }
                    .disabled(group.id == groupID)
            }
        }
        .disabled(groups.isEmpty || !store.canEdit)
        if let index = profiles.firstIndex(where: { $0.key == profile.key }) {
            Button("Move Up") { reorder(profiles, index, offset: -1, groupID: groupID) }.disabled(index == 0)
            Button("Move Down") { reorder(profiles, index, offset: 1, groupID: groupID) }
                .disabled(index == profiles.count - 1)
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = profile }
            .disabled(!controller.canEdit(profile))
    }

    private func moveProfile(_ key: TunnelRule.Key, to groupID: UUID?, before next: TunnelRule.Key? = nil) {
        guard store.move(key, to: groupID, before: next) else { return }
        collapsedGroups.remove(groupID)
    }

    @ViewBuilder private func groupActions(_ group: ProfileGroup) -> some View {
        Button("Rename…") { editor = .group(group) }
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            Button("Move Group Up") { store.moveGroup(group.id, offset: -1) }.disabled(index == 0)
            Button("Move Group Down") { store.moveGroup(group.id, offset: 1) }.disabled(index == groups.count - 1)
        }
        Divider()
        Button("Delete Group…", role: .destructive) { pendingGroup = group }
    }

    private var newProfileChoices: some View {
        VStack(alignment: .leading, spacing: 2) {
            if selection != nil, let group = store.profileSections.first(where: { $0.id == targetGroup }) {
                Text("Add to \(group.displayName)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            newProfileAction("Device Profile", icon: TunnelRule.Kind.device.icon) {
                launchEditor(.device(EditorRequest(), targetGroup))
            }
            newProfileAction("SSH Profile", icon: TunnelRule.Kind.ssh.icon) {
                launchEditor(.ssh(SSHTunnel(name: "SSH"), targetGroup))
            }
            newProfileAction("socat Profile", icon: TunnelRule.Kind.socat.icon) {
                launchEditor(.socat(SocatProfile(form: SocatForm()), targetGroup))
            }
            Divider().padding(.horizontal, 12).padding(.vertical, 2)
            newProfileAction("New Group…", icon: "folder.badge.plus") {
                launchEditor(.group(ProfileGroup(title: "")))
            }
            newProfileAction("Import Configuration…", icon: "square.and.arrow.down") {
                showNew = false
                showImport = true
            }
            newProfileAction("Export Configuration…", icon: "square.and.arrow.up") {
                exportFile()
            }
        }
        .padding(.vertical, 6)
        .frame(width: 214, alignment: .leading)
    }

    private func newProfileAction(_ title: LocalizedStringKey, icon: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .frame(width: 19, height: 18)
                    .accessibilityHidden(true)
                Text(title).font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .modifier(MenuRowHover(tracksInactiveWindow: false))
        }
        .buttonStyle(.plain)
    }

    private var deviceStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Device Status").font(.headline)
                Spacer()
                Button(action: controller.devices.checkNow) {
                    Label("Refresh Devices", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless).keyboardShortcut("r")
            }
            if controller.devices.devices.isEmpty { Text("No devices connected").foregroundStyle(.secondary) }
            ForEach(controller.devices.devices) { device in
                Label("\(device.name) · \(device.connection)", systemImage: device.id.platform.icon)
            }
            ForEach(Platform.allCases, id: \.self) { platform in
                if let error = controller.devices.discoveryErrors[platform] {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(14).frame(width: 285, alignment: .leading)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .profile(let key):
            if let profile = store.configuration.rules.first(where: { $0.key == key }) {
                ProfileDetail(controller: controller, profile: profile, edit: { edit(profile) },
                              delete: { pendingDelete = profile })
                    .id(key)
            }
        case .group(let id):
            if let group = store.profileSections.first(where: { $0.id == id }) {
                ProfileGroupDetail(controller: controller, section: group,
                                   select: {
                                       collapsedGroups.remove(id)
                                       selection = .profile($0)
                                   },
                                   edit: { editor = .group($0) },
                                   delete: { pendingGroup = $0 },
                                   add: presentNew)
                    .id(id)
            }
        case nil:
            ContentUnavailableView {
                Label("No profiles yet", systemImage: "arrow.left.arrow.right")
            } actions: {
                Button("New Profile", action: presentNew).disabled(!store.canEdit)
            }
        }
    }

    @ViewBuilder private func editorView(_ request: Editor) -> some View {
        switch request {
        case .device(let device, let groupID):
            TunnelEditor(request: device, manager: controller.devices) { tunnel in
                let profile = TunnelRule.device(tunnel, enabled: false)
                return finishSaving(profile, success: controller.devices.addOrUpdate(tunnel, in: groupID))
            }
        case .ssh(let tunnel, let groupID):
            SSHTunnelEditor(tunnel: tunnel) { updated in
                finishSaving(.ssh(updated), success: controller.ssh.save(updated, in: groupID))
            }
            .environment(controller.ssh)
        case .socat(let profile, let groupID):
            SocatEditor(profile: profile) { updated in
                finishSaving(.socat(updated), success: controller.socat.save(updated, in: groupID))
            }
        case .group(let group):
            ProfileGroupEditor(group: group) { updated in
                guard store.saveGroup(updated) else { return store.error ?? L10n.text("Could not save the group.") }
                selection = .group(updated.id)
                return nil
            }
        }
    }

    private func presentNew() {
        guard store.canEdit, editor == nil else { return }
        visibility = .all
        showNew = true
    }

    private func launchEditor(_ request: Editor) {
        showNew = false
        editor = request
    }

    private func edit(_ profile: TunnelRule) {
        switch profile {
        case .device(let tunnel, _):
            if let device = controller.devices.listedDevices.first(where: { $0.id == tunnel.device }) {
                editor = .device(EditorRequest(device: device, tunnel: tunnel), nil)
            }
        case .ssh(let tunnel): editor = .ssh(tunnel, nil)
        case .socat(let session): editor = .socat(session, nil)
        }
    }

    private func finishSaving(_ profile: TunnelRule, success: Bool) -> String? {
        guard success else { return store.error ?? L10n.text("This profile cannot be edited right now. Check whether it is running.") }
        collapsedGroups.remove(store.group(for: profile.key)?.id)
        selection = .profile(profile.key)
        return nil
    }

    private func reorder(_ profiles: [TunnelRule], _ index: Int, offset: Int, groupID: UUID?) {
        var keys = profiles.map(\.key)
        guard keys.indices.contains(index + offset) else { return }
        keys.swapAt(index, index + offset)
        store.reorder(keys, in: groupID)
    }

    private func isLegacyDevice(_ profile: TunnelRule) -> Bool {
        if case .device(let tunnel, _) = profile { return tunnel.device.isAndroidEndpoint }
        return false
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let count = try store.importRules(from: url)
            importMessage = count == 0 ? L10n.text("There are no new profiles or groups to import.") : L10n.text("Imported \(count) items. Review the configuration before starting any forwards.")
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func exportFile() {
        showNew = false
        do {
            exportDocument = ConfigurationExportDocument(data: try store.exportData())
            showExport = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct ConfigurationExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data
    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.init(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
