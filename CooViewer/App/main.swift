import AppKit

// EN: Program entry: install the app delegate before NSApplicationMain runs.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
