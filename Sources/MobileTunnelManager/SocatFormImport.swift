import Foundation

struct SocatFormImport {
    let form: SocatForm
    let executable: String?
    let runsWithSudo: Bool
    let arguments: [String]

    init(_ input: String, format: SocatProfile.ArgumentFormat, pastedCommand: Bool = false) throws {
        let text = pastedCommand ? input.replacingOccurrences(of: "\r\n", with: "\n") : input
        var arguments = try format.parse(text)[...]
        runsWithSudo = arguments.first == "sudo" || arguments.first == "/usr/bin/sudo"
        if runsWithSudo {
            arguments.removeFirst()
            if arguments.first == "-n" { arguments.removeFirst() }
            if arguments.first == "--" { arguments.removeFirst() }
        }
        if arguments.first == "socat" {
            executable = ""
            arguments.removeFirst()
        } else if let first = arguments.first, first.hasPrefix("/"), (first as NSString).lastPathComponent == "socat" {
            executable = first
            arguments.removeFirst()
        } else {
            executable = nil
        }
        if runsWithSudo && executable == nil {
            throw CommandError(message: L10n.text("Use sudo before the socat command. Set its arguments after socat."))
        }
        if format == .commandLine && (pastedCommand || executable != nil) {
            _ = try ShellArguments.parse(text, rejectingShellSyntax: true)
        }
        self.arguments = Array(arguments)

        let optionsWithValue: Set = ["-b", "-t", "-T", "-r", "-R", "-lf", "-lp", "-S", "-L", "-W", "-P"]
        var form = SocatForm()
        var flags: [String] = []
        var directionIndices: [Int] = []
        while let option = arguments.first, option.hasPrefix("-"), !SocatAddress.isAddressArgument(option) {
            arguments.removeFirst()
            if option == "-u" || option == "-U" {
                let direction: SocatForm.Direction = option == "-u" ? .leftToRight : .rightToLeft
                guard form.direction == .bidirectional || form.direction == direction else {
                    throw CommandError(message: L10n.text("The socat options -u and -U cannot be used together."))
                }
                form.direction = direction
                directionIndices.append(flags.count + directionIndices.count)
            } else {
                flags.append(option)
                if optionsWithValue.contains(option) {
                    guard let value = arguments.popFirst() else {
                        throw CommandError(message: L10n.text("Option \(option) requires an argument."))
                    }
                    flags.append(value)
                }
            }
        }
        guard arguments.count == 2, arguments.allSatisfy(SocatAddress.isAddressArgument) else {
            throw CommandError(message: L10n.text("Enter socat options and two addresses. The leading socat command is optional."))
        }
        form.flags = ShellArguments.command(flags)
        if !directionIndices.isEmpty {
            form.importedDirection = .init(indices: directionIndices, flags: form.flags)
        }
        form.left = SocatAddress.importing(arguments[arguments.startIndex])
        form.right = SocatAddress.importing(arguments[arguments.startIndex + 1])
        guard (try? form.argumentsForLaunch()) == self.arguments else {
            throw CommandError(message: L10n.text("This command cannot be converted without changes. Use raw arguments."))
        }
        self.form = form
    }
}
