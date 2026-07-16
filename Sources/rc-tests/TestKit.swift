import Foundation

/// Minimal hermetic test harness (Command Line Tools ship a broken
/// swift-testing runner, so we run our own).
@MainActor
enum TestKit {
    static var currentTest = ""
    static var testsRun = 0
    static var testsFailed = 0
    static var failuresInCurrentTest = 0
}

@MainActor
func expect(_ condition: @autoclosure () -> Bool,
            _ message: @autoclosure () -> String = "",
            file: StaticString = #filePath, line: UInt = #line) {
    guard !condition() else { return }
    TestKit.failuresInCurrentTest += 1
    let fileName = URL(fileURLWithPath: "\(file)").lastPathComponent
    print("  FAIL \(TestKit.currentTest): \(message()) [\(fileName):\(line)]")
}

@MainActor
func recordIssue(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    expect(false, message, file: file, line: line)
}

@MainActor
func runTest(_ name: String, _ body: @MainActor () throws -> Void) {
    TestKit.currentTest = name
    TestKit.testsRun += 1
    TestKit.failuresInCurrentTest = 0
    let start = Date()
    do {
        try body()
    } catch {
        recordIssue("threw \(error)")
    }
    let elapsed = String(format: "%.2fs", -start.timeIntervalSinceNow)
    if TestKit.failuresInCurrentTest == 0 {
        print("  ok   \(name) (\(elapsed))")
    } else {
        TestKit.testsFailed += 1
        print("  FAIL \(name) — \(TestKit.failuresInCurrentTest) assertion(s) (\(elapsed))")
    }
}

@MainActor
func runTest(_ name: String, _ body: @MainActor () async throws -> Void) async {
    TestKit.currentTest = name
    TestKit.testsRun += 1
    TestKit.failuresInCurrentTest = 0
    let start = Date()
    do {
        try await body()
    } catch {
        recordIssue("threw \(error)")
    }
    let elapsed = String(format: "%.2fs", -start.timeIntervalSinceNow)
    if TestKit.failuresInCurrentTest == 0 {
        print("  ok   \(name) (\(elapsed))")
    } else {
        TestKit.testsFailed += 1
        print("  FAIL \(name) — \(TestKit.failuresInCurrentTest) assertion(s) (\(elapsed))")
    }
}

@MainActor
func suite(_ name: String) {
    print("\n== \(name)")
}

@MainActor
func finishTests() -> Never {
    print("\n\(TestKit.testsRun) tests, \(TestKit.testsFailed) failed")
    exit(TestKit.testsFailed == 0 ? 0 : 1)
}
