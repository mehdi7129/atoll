extension CodexCatalogSection {
    // Copie du View avec nouveaux inputs, en conservant ses emplacements State.
    fileprivate func rebuilt(project: String, executable: String) -> Self {
        var next = Self(projectPath: project, executableOverride: executable, chooseProject: {})
        next._skills = _skills; next._plugins = _plugins; next._reading = _reading
        next._message = _message; next._query = _query; next._issues = _issues
        return next
    }
}
@main struct Probe {
    @MainActor static func main() async throws {
        var results: [[String: Any]] = []
        for scenario in ["control", "project_changed", "executable_changed", "home_changed_inflight"] {
            CodexReadClient.reset()
            CodexPaths.homeURL = URL(fileURLWithPath: "/fixture/home-a")
            let old = CodexCatalogSection(projectPath: "/fixture/project-a", executableOverride: "/fixture/cli-a", chooseProject: {})
            old.refresh()
            while !CodexReadClient.hasStarted() { try await Task.sleep(for: .milliseconds(5)) }
            let current = old.rebuilt(project: scenario == "project_changed" ? "/fixture/project-b" : old.projectPath,
                                      executable: scenario == "executable_changed" ? "/fixture/cli-b" : old.executableOverride)
            if scenario == "project_changed" || scenario == "executable_changed" { current.invalidate() }
            if scenario == "home_changed_inflight" { CodexPaths.homeURL = URL(fileURLWithPath: "/fixture/home-b") }
            CodexReadClient.gate.signal()
            while current.reading { try await Task.sleep(for: .milliseconds(5)) }
            results.append(["scenario": scenario, "displayed_project": current.projectPath,
                            "displayed_executable": current.executableOverride, "issues": current.issues,
                            "skill_paths": current.skills.map { $0.path.path }, "skill_descriptions": current.skills.map { $0.description }])
            if scenario == "home_changed_inflight" { precondition(current.issues.isEmpty && current.skills.isEmpty) }
            else { precondition(current.skills.first?.path.path == "/fixture/project-a/.agents/skills/example/SKILL.md")
                   precondition(current.skills.first?.description == "using /fixture/cli-a") }
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
