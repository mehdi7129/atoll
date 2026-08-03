import Foundation

/// Découpe une ligne de shell en SEGMENTS de commande, en respectant les
/// guillemets et les échappements.
///
/// Appelant actuel : `SoundHookEditor`, qui ne doit parquer que les hooks jouant
/// UNIQUEMENT un son — couper au mauvais endroit lui ferait retirer un hook de
/// l'utilisateur qui fait autre chose, ou ignorer un hook sonore parfaitement
/// ordinaire. Ce sont les hooks de QUELQU'UN D'AUTRE : on ne se trompe pas.
///
/// Ce fichier est né de deux découpages maison, par remplacement de chaînes,
/// dont aucun ne voyait les guillemets : `git commit -m "a & b"` et
/// `afplay son.wav >/dev/null 2>&1 &` étaient lus comme des enchaînements
/// (revue des corrections, 2026-07-27). Le second appelant, `AutoAcceptPolicy`,
/// a été retiré le 2026-08-03 avec le niveau « Auto » — d'où
/// `ShellSplitterTests`, écrit AVANT cette suppression : les tests de la
/// politique étaient la seule couverture du splitter, et les retirer ensemble
/// aurait ôté la dernière preuve qu'un composant encore utilisé fonctionne.
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
            // `\r\n` est UN SEUL Character en Swift (groupe de graphèmes) : ne
            // tester que `\n` et `\r` le laissait passer pour du texte ordinaire,
            // et une commande à fins de ligne Windows n'était pas découpée du
            // tout (trouvé le 2026-08-03 par les premiers tests propres du
            // splitter — il n'en avait aucun).
            case "\n", "\r", "\r\n":
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
