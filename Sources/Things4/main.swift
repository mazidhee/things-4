import AppKit

// `Things4 --mcp` and `Things4 --cli …` run headless as clients of the running app.
if CommandLine.arguments.dropFirst().first == "--mcp" {
    AgentBridge.runMCP()
}
if CommandLine.arguments.dropFirst().first == "--cli" {
    AgentBridge.runCLI(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}
if CommandLine.arguments.contains("--bench") {
    Bench.run()
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
Preferences.apply()
application.run()
