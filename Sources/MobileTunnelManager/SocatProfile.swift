import Foundation

struct SocatProfile: Identifiable, Codable, Equatable {
    enum Destination: String, CaseIterable, Identifiable, Codable {
        case local, ssh
        var id: Self { self }
        var title: String { self == .local ? L10n.text("Local") : L10n.text("Over SSH") }
    }

    enum ArgumentFormat: String, CaseIterable, Identifiable, Codable {
        case commandLine, arguments
        var id: Self { self }
        var title: String { self == .commandLine ? L10n.text("Command Line Syntax") : L10n.text("One Argument per Line") }

        func parse(_ text: String) throws -> [String] {
            switch self {
            case .commandLine:
                return try ShellArguments.parse(text)
            case .arguments:
                guard !text.contains("\0") else { throw CommandError(message: L10n.text("Arguments cannot contain NUL.")) }
                return text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init)
            }
        }
    }

    enum Input: String, CaseIterable, Identifiable, Codable {
        case closed, interactive, file
        var id: Self { self }
        var title: String {
            switch self {
            case .closed: L10n.text("No Input")
            case .interactive: L10n.text("Manual Input")
            case .file: L10n.text("Input File")
            }
        }

    }

    var id = UUID()
    var name = "socat"
    var destination = Destination.local
    var executable = ""
    var host = ""
    var sshOptions = ""
    var arguments = ""
    var argumentFormat = ArgumentFormat.commandLine
    var form: SocatForm? = nil
    var input = Input.closed
    var inputFile = ""
    var outputFile = ""
    var sshTTY = false
    var sudo: Bool? = nil
    var autoStart = false
    var restartOnFailure = false
    var hooks: TunnelHooks? = nil

    var runsWithSudo: Bool {
        get { sudo == true }
        set { sudo = newValue ? true : nil }
    }

    var displayLocation: String { destination == .local ? L10n.text("Local") : host }
    var routeSummary: String {
        guard let form else { return displayLocation }
        return "\(displayLocation) · \(form.route)"
    }

    func argumentsForLaunch() throws -> [String] {
        if let form { return try form.argumentsForLaunch() }
        return try argumentFormat.parse(arguments)
    }

    var preview: String? {
        guard let arguments = try? argumentsForLaunch(), !arguments.isEmpty else { return nil }
        let executable = self.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = [executable.isEmpty ? "socat" : executable] + arguments
        return ShellArguments.command(runsWithSudo ? ["sudo", "--"] + command : command)
    }
}

enum ShellArguments {
    static func parse(_ text: String, rejectingShellSyntax: Bool = false) throws -> [String] {
        guard !text.contains("\0") else { throw CommandError(message: L10n.text("Arguments cannot contain NUL.")) }
        var result: [String] = []
        var word = ""
        var quote: Character?
        var started = false
        var escaped = false
        for character in text {
            if escaped {
                if quote == "\"" && !["\"", "\\", "$", "\u{0060}", "\n"].contains(character) {
                    word.append("\\")
                }
                if character != "\n" {
                    started = true
                    word.append(character)
                }
                escaped = false
            } else if let delimiter = quote {
                if character == delimiter { quote = nil }
                else if delimiter == "\"" && character == "\\" { escaped = true }
                else if rejectingShellSyntax && delimiter == "\"" && "$`".contains(character) {
                    throw CommandError(message: L10n.text("Replace variables and command substitutions with literal values before importing."))
                }
                else { word.append(character) }
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" || character == "'" {
                started = true
                quote = character
            } else if character.isWhitespace {
                if started {
                    result.append(word)
                    word = ""
                    started = false
                }
            } else if rejectingShellSyntax && "|&;<>`$".contains(character) {
                throw CommandError(message: L10n.text("Enter one socat command. Quote special characters that should be passed as arguments."))
            } else {
                word.append(character)
                started = true
            }
        }
        guard quote == nil && !escaped else { throw CommandError(message: L10n.text("Complete the quotation or trailing backslash.")) }
        if started { result.append(word) }
        return result
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }
}
