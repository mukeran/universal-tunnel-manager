import AppKit
import SwiftUI
import TunnelUI

struct SocatDetail: View {
    let profile: SocatProfile
    let manager: SocatManager
    @State private var logText = ""
    @State private var input = ""
    @State private var portConflicts: [Int] = []
    @State private var showCommand = false

    private var canEdit: Bool { !manager.isEnabled(profile) && !manager.isStopping(profile) }
    private var localPorts: [Int] {
        guard canEdit, profile.destination == .local, let form = profile.form, form.flags.isEmpty else { return [] }
        return form.loopbackTCPPorts
    }

    var body: some View {
        ScrollView {
            details.padding(TunnelDetailLayout.insets)
        }
        .task(id: localPorts) { inspectPorts() }
        .task(id: manager.logs[profile.id].map(ObjectIdentifier.init)) {
            logText = ""
            guard let log = manager.logs[profile.id] else { return }
            var revision = -1
            while !Task.isCancelled {
                if let (next, text) = log.read(after: revision) {
                    revision = next
                    logText = text
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let form = profile.form {
                TunnelDetailSection("Forwarding Addresses") {
                    if form.direction == .rightToLeft {
                        TunnelRoute(form.right.summary, to: form.left.summary)
                    } else {
                        TunnelRoute(form.left.summary, to: form.right.summary, bidirectional: form.direction == .bidirectional)
                    }
                }
            }
            ForEach(portConflicts, id: \.self) { port in
                HStack {
                    Label("Mac TCP port \(String(port)) is in use", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    MacPortOwnersButton(port: port, onRelease: inspectPorts)
                }
            }
            TunnelDetailSection("Output") {
                Button("socat Help") { manager.start(profile, help: true) }.disabled(!canEdit)
            } content: {
                if logText.isEmpty {
                    Text("No output yet").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextEditor(text: .constant(logText))
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(height: 170)
                        .accessibilityLabel("socat Output")
                }
            }

            if let preview = profile.preview {
                DisclosureGroup("Run Command", isExpanded: $showCommand) {
                    Text(preview).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }

            if profile.input == .interactive && manager.isEnabled(profile) && manager.status(profile) == .running {
                HStack {
                    TextField("Line to send to stdin", text: $input).onSubmit(send)
                    Button("Send", action: send)
                    Button("Send EOF") { manager.closeInput(profile) }
                }
            }
        }
    }

    private func send() {
        manager.send(input, to: profile)
        input = ""
    }

    private func inspectPorts() {
        portConflicts = localPorts.filter { port in
            do {
                try MacListener.checkAvailability(port: port)
                return false
            } catch {
                return error is PortConflict
            }
        }
    }
}

struct SocatEditor: View {
    @State private var profile: SocatProfile
    @State private var form: SocatForm
    @State private var useForm: Bool
    @State private var showAliases = false
    @State private var showCommandImport = false
    @State private var conversionError: String?
    let onSave: (SocatProfile) -> String?

    init(profile: SocatProfile, onSave: @escaping (SocatProfile) -> String?) {
        _profile = State(initialValue: profile)
        _form = State(initialValue: profile.form ?? SocatForm())
        _useForm = State(initialValue: profile.form != nil)
        self.onSave = onSave
    }

    var body: some View {
        TunnelProfileEditor(L10n.text("socat Settings"), subtitle: profile.name, icon: TunnelRule.Kind.socat.icon,
                            height: 500, preview: configuration.preview, canSave: isValid,
                            onSave: { onSave(configuration) }) {
            HStack(alignment: .top, spacing: 12) {
                TunnelEditorField("Name") { TextField("Name", text: $profile.name) }
                TunnelEditorField("Run On") {
                    Picker("Run On", selection: $profile.destination) {
                        ForEach(SocatProfile.Destination.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                .frame(width: 112)
            }
            if profile.destination == .ssh {
                TunnelEditorField("SSH Host") {
                    HStack(spacing: 6) {
                        TextField("SSH Host", text: $profile.host, prompt: Text("SSH alias or user@host"))
                        Button { showAliases = true } label: {
                            Label("Choose SSH Alias", systemImage: "chevron.up.chevron.down").labelStyle(.iconOnly)
                        }
                        .help("Choose an alias from SSH configuration")
                        .popover(isPresented: $showAliases) {
                            SSHConfigAliasPicker(selectedAlias: $profile.host, isPresented: $showAliases)
                                .environment(\.locale, L10n.locale)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Picker("Configuration Mode", selection: $useForm) {
                    Text("Form").tag(true)
                    Text("Raw Arguments").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if useForm {
                    Button("Import Command…") { showCommandImport = true }
                } else {
                    Button("Convert to Form") {
                        conversionError = importForm(profile.arguments, format: profile.argumentFormat)
                    }
                    .disabled(profile.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if useForm {
                TunnelEditorField("Transfer Direction") {
                    Picker("Transfer Direction", selection: $form.direction) {
                        ForEach(SocatForm.Direction.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                HStack(alignment: .top, spacing: 16) {
                    TunnelEditorField("Address 1") { SocatAddressFields(address: $form.left) }
                    TunnelEditorField("Address 2") { SocatAddressFields(address: $form.right) }
                }
            } else {
                TunnelEditorField("Argument Format") {
                    Picker("Argument Format", selection: $profile.argumentFormat) {
                        ForEach(SocatProfile.ArgumentFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                TextEditor(text: $profile.arguments)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 94)
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary) }
                    .accessibilityLabel("socat Arguments")
                Text("Enter options and addresses without the leading socat command. In one-argument-per-line mode, each line is passed as written.")
                    .font(.caption).foregroundStyle(.secondary)
                if let conversionError {
                    Text(conversionError).font(.caption).foregroundStyle(.red)
                }
            }

            Divider()
            TunnelHookFields(hooks: $profile.hooks, supportsRemote: profile.destination == .ssh)
            DisclosureGroup("Advanced Settings") { advancedSettings.padding(.top, 8) }
        }
        .onChange(of: profile.arguments) { _, _ in conversionError = nil }
        .onChange(of: profile.argumentFormat) { _, _ in conversionError = nil }
        .sheet(isPresented: $showCommandImport) {
            SocatCommandImportView { command in
                importForm(command, format: .commandLine, pastedCommand: true)
            }
            .environment(\.locale, L10n.locale)
        }
    }

    private func importForm(_ text: String, format: SocatProfile.ArgumentFormat,
                            pastedCommand: Bool = false) -> String? {
        do {
            let imported = try SocatFormImport(text, format: format, pastedCommand: pastedCommand)
            form = imported.form
            if let executable = imported.executable {
                profile.executable = executable
            }
            if imported.runsWithSudo { profile.runsWithSudo = true }
            if pastedCommand || imported.executable != nil {
                profile.arguments = ShellArguments.command(imported.arguments)
                profile.argumentFormat = .commandLine
            }
            useForm = true
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            if useForm {
                TunnelEditorField("Global Options") {
                    TextField("socat Options", text: $form.flags, prompt: Text("-d -d -T 30"))
                }
                Button("Convert Form to Raw Arguments") {
                    guard let arguments = try? form.argumentsForLaunch() else { return }
                    profile.argumentFormat = .commandLine
                    profile.arguments = ShellArguments.command(arguments)
                    useForm = false
                }
                .disabled((try? form.argumentsForLaunch()) == nil)
            }
            TunnelEditorField("socat Executable") {
                TextField("socat Executable", text: $profile.executable, prompt: Text("Find socat automatically"))
            }
            if profile.destination == .ssh {
                TunnelEditorField("SSH Options") {
                    TextField("SSH Options", text: $profile.sshOptions, prompt: Text("-p 2222 -J bastion"))
                }
                Toggle("Allocate an SSH terminal", isOn: $profile.sshTTY)
            }
            Toggle("Run with sudo", isOn: $profile.runsWithSudo)
            if profile.runsWithSudo {
                Text(profile.destination == .local
                     ? L10n.text("Starting manually can prompt for your Mac password. Automatic starts and retries use non-interactive sudo.")
                     : L10n.text("The SSH host must allow sudo to run socat without prompting."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Standard Input", selection: $profile.input) {
                ForEach(SocatProfile.Input.allCases) { Text($0.title).tag($0) }
            }
            if profile.input == .file {
                TunnelEditorField("Mac Input File") { TextField("Mac Input File", text: $profile.inputFile) }
            }
            TunnelEditorField("Append to Mac Output File") {
                TextField("Append to Mac Output File", text: $profile.outputFile, prompt: Text("Leave blank to show output in the log"))
            }
            Toggle("Start when the app opens", isOn: $profile.autoStart)
            Toggle("Retry after an unexpected exit", isOn: $profile.restartOnFailure)
        }
    }

    private var configuration: SocatProfile {
        var result = profile
        result.form = useForm ? form : nil
        return result
    }

    private var isValid: Bool {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              configuration.preview != nil else { return false }
        if profile.destination == .local { return true }
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !host.isEmpty && !host.hasPrefix("-") && !host.contains(where: \.isWhitespace)
            && !host.contains("\0") && (try? ShellArguments.parse(profile.sshOptions)) != nil
    }
}

private struct SocatCommandImportView: View {
    @State private var command = ""
    let onImport: (String) -> String?

    var body: some View {
        TunnelProfileEditor(L10n.text("Import socat Command"), subtitle: L10n.text("Paste a complete command or its options and addresses"), icon: "terminal",
                            width: 500, saveTitle: "Fill Form",
                            canSave: !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            onSave: { onImport(command) }) {
            TextEditor(text: $command)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 116)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary) }
                .accessibilityLabel("socat Command")
        }
    }
}

private struct SocatAddressFields: View {
    @Binding var address: SocatAddress
    @State private var showOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Address Type", selection: $address.kind) {
                ForEach(SocatAddress.Kind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            if address.kind == .custom {
                TunnelEditorField("Full Address") {
                    TextField("Full Address", text: $address.custom, prompt: Text("PTY,link=/tmp/serial"))
                        .font(.system(.callout, design: .monospaced))
                }
            } else {
                if address.kind.usesPort {
                    HStack(alignment: .top, spacing: 8) {
                        if address.kind.bindsPort {
                            TunnelEditorField("Bind Address") {
                                TextField("Bind Address", text: $address.bind, prompt: Text("All Addresses"))
                            }
                        } else {
                            TunnelEditorField("Target Host") { TextField("Target Host", text: $address.host) }
                        }
                        TunnelEditorField("Port") { TextField("Port", text: $address.port).monospacedDigit() }
                            .frame(width: 64)
                    }
                }
                if address.kind.usesPath {
                    TunnelEditorField("Path") {
                        TextField("Path", text: $address.path, prompt: Text("/path/to/file"))
                    }
                }
                DisclosureGroup("Address Options", isExpanded: $showOptions) {
                    VStack(alignment: .leading, spacing: 8) {
                        if address.kind.acceptsFork { Toggle("Fork for each connection or datagram", isOn: $address.fork) }
                        if address.kind.acceptsReuseAddress { Toggle("Allow address reuse", isOn: $address.reuseAddress) }
                        if address.kind.usesTLS {
                            TunnelEditorField("Certificate") { TextField("Certificate", text: $address.certificate) }
                            TunnelEditorField("Private Key") { TextField("Private Key", text: $address.key) }
                            TunnelEditorField("CA File") { TextField("CA File", text: $address.caFile) }
                        }
                        TunnelEditorField("Additional Options") {
                            TextField("Additional Options", text: $address.options, prompt: Text("connect-timeout=5"))
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
            }
        }
    }
}
