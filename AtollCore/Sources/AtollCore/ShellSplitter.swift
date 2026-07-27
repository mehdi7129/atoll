import Foundation

/// Découpe une ligne de shell en SEGMENTS de commande, en respectant les
/// guillemets et les échappements.
///
/// Deux endroits en ont besoin, pour des raisons opposées et également
/// sérieuses :
/// - `AutoAcceptPolicy` doit examiner CHAQUE commande enchaînée : ne pas couper
///   sur `&` laissait `ls & <commande destructrice>` s'auto-approuver ;
/// - `SoundHookEditor` ne doit parquer que les hooks qui jouent UNIQUEMENT un
///   son : couper au mauvais endroit lui faisait retirer un hook qui fait autre
///   chose, ou ignorer un hook sonore parfaitement ordinaire.
///
/// Les deux avaient leur propre découpage, par remplacement de chaînes. Aucun
/// des deux ne voyait les guillemets, si bien que `git commit -m "a & b"` et
/// `afplay son.wav >/dev/null 2>&1 &` étaient traités comme des enchaînements
/// (revue des corrections, 2026-07-27). Une seule implémentation, ici, testée.
///
/// Ce n'est PAS un analyseur de shell complet — il n'en existe pas de simple —
/// mais il traite correctement ce qui décide : opérateurs hors chaîne,
/// redirections qui contiennent un `&` littéral (`2>&1`, `&>fichier`), et
/// échappement par `\`.
public enum ShellSplitter {

    /// Segments séparés par `&&`, `||`, `|`, `;`, `&` et, au choix, les retours
    /// à la ligne. Les segments VIDES sont conservés : l'appelant décide de leur
    /// sens (un `&` final produit un segment vide, et c'est une info utile).
    public static func segments(_ line: String, splitOnNewlines: Bool = true) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        let characters = Array(line)
        var index = 0

        func flush() {
            result.append(current)
            current = ""
        }

        while index < characters.count {
            let c = characters[index]
            if escaped {
                current.append(c); escaped = false; index += 1; continue
            }
            if c == "\\" {
                current.append(c); escaped = true; index += 1; continue
            }
            if let open = quote {
                current.append(c)
                if c == open { quote = nil }
                index += 1; continue
            }
            if c == "\"" || c == "'" {
                quote = c; current.append(c); index += 1; continue
            }

            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            switch c {
            case "&":
                // `&>` est une redirection, pas un enchaînement.
                if next == ">" { current.append(c); index += 1; continue }
                flush()
                index += (next == "&") ? 2 : 1
            case "|":
                flush()
                index += (next == "|") ? 2 : 1
            case ";":
                flush(); index += 1
            case ">":
                // `>&` : le `&` appartient à la redirection.
                current.append(c)
                if next == "&" { current.append("&"); index += 2 } else { index += 1 }
            case "\n", "\r":
                if splitOnNewlines { flush() } else { current.append(c) }
                index += 1
            default:
                current.append(c); index += 1
            }
        }
        flush()
        return result
    }

    /// Segments réellement porteurs d'une commande (blancs de bord retirés,
    /// vides écartés).
    public static func meaningfulSegments(_ line: String, splitOnNewlines: Bool = true) -> [String] {
        segments(line, splitOnNewlines: splitOnNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
