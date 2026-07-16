import Foundation
import RhythmCore

enum RCCLI {
    static func run(arguments: [String]) {
        guard let command = arguments.first else {
            printUsage()
            return
        }
        switch command {
        case "version":
            print("rc-cli 0.1.0")
        default:
            print("unknown command: \(command)")
            printUsage()
        }
    }

    static func printUsage() {
        print("""
        rc-cli — RhythmCoach headless audio harness
        usage: rc-cli <command>
          version   print version
        """)
    }
}
