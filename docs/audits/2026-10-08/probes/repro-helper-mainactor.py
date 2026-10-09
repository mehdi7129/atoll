#!/usr/bin/env python3
"""Mesure l'attente UI du vrai HookInstaller avec un helper synthétique lent."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1]).resolve()
build = Path(subprocess.check_output(["swift", "build", "--build-system", "native", "--package-path",
    str(repo / "AtollCore"), "--show-bin-path"], text=True).strip())
with tempfile.TemporaryDirectory(prefix="atoll-helper-audit-") as directory:
    root = Path(directory)
    source = root / "Probe.swift"
    source.write_text((repo / "App/HookInstaller.swift").read_text() + r'''
private enum CodexPreview { static let enabled = false }
private enum CodexPaths {
    static var configurationError: String? { nil }
    static let homeURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_AUDIT_ROOT"]!)
}
@MainActor private final class SoundCenter {
    static let shared = SoundCenter()
    func restoreUserSoundHooks() throws {}
}
@main struct HelperMainActorProbe {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_AUDIT_ROOT"]!)
        // Le bundle CLI est dans notre dossier temporaire; aucun helper installé touché.
        let helper = HookInstaller.helperURL
        guard helper.path.hasPrefix(root.path + "/") else { fatalError("helper hors fixture") }
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n/bin/sleep 0.6\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let started = DispatchTime.now().uptimeNanoseconds
        var heartbeatDelay = 0.0
        let heartbeat = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            heartbeatDelay = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        }
        // Laisse le heartbeat commencer son attente, puis bloque via méthode réelle.
        await Task.yield()
        try HookInstaller.install()
        let helperDelay = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        await heartbeat.value
        print("helper_seconds=\(helperDelay)")
        print("mainactor_heartbeat_requested_seconds=0.02 observed_seconds=\(heartbeatDelay)")
    }
}
''')
    binary = root / "probe"
    command = ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(build / "Modules"),
               "-lsqlite3", str(source)]
    command += [str(path) for path in sorted((build / "AtollCore.build").glob("*.o"))]
    subprocess.run(command + ["-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], env=dict(os.environ, ATOLL_AUDIT_ROOT=str(root),
        CFFIXED_USER_HOME=str(root / "home")), capture_output=True, text=True, timeout=10)
    print(result.stdout, end="")
    if result.returncode: raise RuntimeError(result.stderr)
