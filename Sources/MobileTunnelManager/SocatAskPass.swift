import AppKit

enum SocatAskPass {
    private static let mode = "UTM_SOCAT_ASKPASS"

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment[mode] == "1"
    }

    static func environment() throws -> [String: String] {
        guard let executable = Bundle.main.executableURL else {
            throw CommandError(message: L10n.text("Could not locate the sudo password prompt."))
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SUDO_ASKPASS"] = executable.path
        environment[mode] = "1"
        return environment
    }

    @MainActor
    static func prompt() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        password.placeholderString = L10n.text("Password")
        let alert = NSAlert()
        alert.messageText = L10n.text("Run socat with sudo")
        alert.informativeText = L10n.text("Enter your Mac account password to start this socat profile with administrator privileges.")
        alert.accessoryView = password
        alert.addButton(withTitle: L10n.text("Run"))
        alert.addButton(withTitle: L10n.text("Cancel")).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = password
        app.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
        let value = password.stringValue
        guard !value.contains("\n"), !value.contains("\0") else { exit(1) }

        // sudo provides a private stdout pipe for askpass.
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
        exit(0)
    }
}
