import Foundation

// Headless harness for the audio stack; subcommands are registered as the
// modules they exercise come online.
let arguments = Array(CommandLine.arguments.dropFirst())
RCCLI.run(arguments: arguments)
