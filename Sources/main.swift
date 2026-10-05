import AppKit

let cliCommands: Set<String> = ["send", "text", "peers", "key", "diag", "help", "-h", "--help"]
let arguments = Array(CommandLine.arguments.dropFirst())

if let cmd = arguments.first, cliCommands.contains(cmd) {
    Task {
        exit(await CLI.run(arguments))
    }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
