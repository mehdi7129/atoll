import Foundation

/// Construction des messages utilisateur écrits sur le stdin d'un
/// `claude -p --input-format stream-json`. Une ligne NDJSON par message.
public enum ChatProtocol {
    /// Message utilisateur → ligne NDJSON (terminée par \n).
    public static func userMessage(_ text: String) -> Data {
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
            "parent_tool_use_id": NSNull(),
        ]
        var data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        data.append(0x0A) // \n
        return data
    }

    /// Arguments d'un `claude -p` en mode chat streaming persistant.
    /// - sessionID : pré-choisi pour pouvoir suivre le transcript immédiatement.
    /// - resume : reprise d'une session existante (depuis son cwd).
    public static func arguments(sessionID: String?, resume: String?) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        if let resume {
            // `--fork-session` OBLIGATOIRE : sans lui, `--resume` RÉUTILISE le
            // même session_id et écrit dans LE MÊME transcript que la session du
            // terminal (si elle est encore ouverte) → les deux flux s'entrelacent
            // et la corrompent, et nos hooks porteraient son id (le SessionStore
            // fusionnerait/tuerait la vraie session). Le fork repart d'une copie
            // avec un id NEUF (récupéré via l'événement init du flux).
            args += ["--resume", resume, "--fork-session"]
        } else if let sessionID {
            args += ["--session-id", sessionID]
        }
        return args
    }
}
