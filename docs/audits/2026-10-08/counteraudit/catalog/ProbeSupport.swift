import Foundation
import AtollCore

// Storage partagé reproduisant uniquement la sémantique des State conservés
// lorsque SwiftUI reconstitue un View de même identité. Aucun rendu GUI.
@propertyWrapper struct ProbeState<Value> {
    final class Box { var value: Value; init(_ value: Value) { self.value = value } }
    private var box: Box
    init(wrappedValue: Value) { box = Box(wrappedValue) }
    var wrappedValue: Value { get { box.value } nonmutating set { box.value = newValue } }
}
enum CodexPreview { static let enabled = false }
enum CodexPaths { static var homeURL = URL(fileURLWithPath: "/fixture/home-a") }
enum CodexExecutable {
    static let notFoundMessage = "fixture executable missing"
    static func resolve(overridePath: String) async -> String? { overridePath }
}
enum CodexReadClient {
    enum Request { case skills(cwd: String), plugins(cwd: String) }
    enum Outcome { case available(Data), unavailable(String) }
    static let gate = DispatchSemaphore(value: 0)
    static let lock = NSLock()
    static var started = false
    static func reset() { lock.lock(); started = false; lock.unlock() }
    static func hasStarted() -> Bool { lock.lock(); defer { lock.unlock() }; return started }
    static func read(_ request: Request, executable: URL, home: URL) -> Outcome {
        switch request {
        case .skills(let cwd):
            lock.lock(); started = true; lock.unlock()
            precondition(gate.wait(timeout: .now() + 5) == .success)
            let value: [String: Any] = ["data": [["cwd": cwd, "skills": [["name": "skill-from-project-a", "description": "using \(executable.path)", "path": "\(cwd)/.agents/skills/example/SKILL.md", "scope": "REPO", "enabled": true]], "errors": []]]]
            return .available(try! JSONSerialization.data(withJSONObject: value))
        case .plugins(let cwd): return .unavailable("plugins from \(cwd) using \(executable.path)")
        }
    }
}
