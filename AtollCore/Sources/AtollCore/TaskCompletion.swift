import Foundation

/// Mise en forme de l'annonce « ta tâche est finie ».
///
/// Le hook `Stop` porte `last_assistant_message` : le dernier message du modèle,
/// en Markdown, potentiellement très long et truffé de blocs de code. Une
/// notification macOS n'affiche que quelques dizaines de caractères sur deux
/// lignes — il faut en tirer UNE phrase lisible, ou rien.
public enum TaskCompletion {
    /// Longueur visée pour le corps de la notification (au-delà, macOS tronque
    /// lui-même, mais sans ménagement et au milieu d'un mot).
    public static let summaryLength = 160
    /// Au-delà, on ne lit même pas : un dernier message peut peser des dizaines
    /// de milliers de caractères, et les expressions régulières ci-dessous
    /// travaillent en O(k·n) — pas en O(n). C'est ce plafond, avec des
    /// quantificateurs bornés, qui garde le coût négligeable. La substance
    /// d'une conclusion est de toute façon au début.
    public static let inputCap = 20_000

    /// Résumé d'une ligne du dernier message de l'assistant.
    ///
    /// Rend `fallback` (le texte de la tâche) quand le message est absent, vide,
    /// ou entièrement composé de code — mieux vaut rappeler ce qui avait été
    /// demandé qu'afficher une notification muette.
    public static func summarize(lastAssistantMessage: String?,
                                 fallback: String,
                                 maxLength: Int = summaryLength) -> String {
        let cleaned = (lastAssistantMessage).flatMap { plainText($0, maxLength: maxLength) }
        return cleaned ?? truncate(collapse(fallback), maxLength: maxLength)
    }

    /// Markdown → texte nu sur une ligne. nil s'il ne reste rien de lisible.
    public static func plainText(_ markdown: String, maxLength: Int = summaryLength) -> String? {
        var text = String(markdown.prefix(inputCap))

        // 1. Blocs de code clôturés : illisibles en notification, et ils
        //    contiennent souvent l'essentiel du volume.
        text = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ",
                                         options: .regularExpression)
        // Bloc non clôturé (message coupé par `inputCap`) : on jette la fin.
        if let openFence = text.range(of: "```") {
            text = String(text[text.startIndex..<openFence.lowerBound])
        }
        // 2. Balises HTML éventuelles (le modèle en produit parfois).
        //
        //    On EXIGE une vraie forme de balise. Un motif « tout ce qui est
        //    entre deux chevrons » dévore la prose ordinaire d'un projet Swift :
        //    « la condition i < n && n > 0 » devenait « la condition i 0 », et
        //    « j'ai remplacé Array<String> par [String] » devenait « j'ai
        //    remplacé Array par [String] » — un résumé grammatical qui dit le
        //    CONTRAIRE du vrai. C'est pire que pas de résumé du tout.
        //    Nom de balise en MINUSCULES uniquement : c'est ce qui sépare une
        //    vraie balise (`<p>`, `<br/>`, `<div class="x">`) d'un générique
        //    Swift (`<String>`, `<Int>`), qui a la même forme. En cas de doute
        //    on GARDE le texte — perdre une balise est anodin, réécrire une
        //    phrase ne l'est pas.
        //    Reste, après cette règle, le cas « i<n et j>0 » : `<n et j>` a
        //    exactement la forme d'une balise à attributs. On EXIGE donc un
        //    `=` dans la partie attributs — une vraie balise en porte toujours
        //    un (`<div class="x">`), une comparaison en prose jamais. Sinon la
        //    condition disparaissait et la phrase disait le contraire du vrai,
        //    en notification macOS (audit du 2026-07-27).
        text = text.replacingOccurrences(
            of: "</?[a-z][a-z0-9-]{0,30}(?:\\s[^<>]{0,200}=[^<>]{0,200}|\\s*)/?>",
            with: " ", options: .regularExpression)
        // 3. Liens Markdown : garder le libellé, jeter l'URL.
        //    Quantificateurs BORNÉS : `[^\]]*` repartait de chaque `[` et
        //    balayait jusqu'au bout quand aucun `]` ne suivait — mesuré à
        //    3,2 s sur 20 000 crochets, sur le MainActor.
        text = text.replacingOccurrences(of: "\\[([^\\]\\n]{0,200})\\]\\([^)\\s]{0,500}\\)",
                                         with: "$1", options: .regularExpression)
        // 4. Traits horizontaux et bordures de tableaux. AVANT les puces : la
        //    règle des puces mangerait le premier tiret de `---`, et la ligne
        //    ne ressemblerait plus à un trait horizontal (vu en test : `--`
        //    survivait au milieu du résumé).
        text = text.replacingOccurrences(of: "(?m)^[ \\t]*[-=|:]{3,}[ \\t]*$", with: " ",
                                         options: .regularExpression)
        // 5. Marqueurs de début de ligne : titres, citations, puces, listes
        //    numérotées, cases à cocher.
        //
        //    Une puce EXIGE une espace après le marqueur (`- item`), sinon
        //    `**Terminé**` en tête de ligne perdrait son premier astérisque et
        //    ressortirait en `*Terminé` (vu en test).
        text = text.replacingOccurrences(
            of: "(?m)^[ \\t]*(?:[#>]+[ \\t]*|(?:[-*+]|\\d+[.)])[ \\t]+)(?:\\[[ xX]\\][ \\t]*)?",
            with: "", options: .regularExpression)
        // 6. Emphase et code en ligne. On retire `**`, `__` et les accents
        //    graves, mais PAS les `_` isolés : ils vivent dans les
        //    identifiants (`snake_case`) qu'on veut garder lisibles.
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "`", with: "")

        let flattened = collapse(text)
        guard !flattened.isEmpty else { return nil }
        return truncate(flattened, maxLength: maxLength)
    }

    /// Titre de la notification : le projet, pour distinguer deux tâches
    /// terminées à la même minute dans des dossiers différents.
    public static func notificationTitle(projectName: String) -> String {
        projectName.isEmpty ? "Tâche terminée" : "Tâche terminée · \(projectName)"
    }

    // MARK: - Outils

    /// Espaces, tabulations et retours à la ligne → une seule espace.
    private static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Coupe sur une frontière de mot quand c'est possible (une coupe au milieu
    /// d'un mot se remarque tout de suite dans une notification).
    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 1, text.count > maxLength else { return text }
        let hard = String(text.prefix(maxLength - 1))
        // Ne remonter au dernier espace que s'il ne coûte pas la moitié du texte.
        if let space = hard.lastIndex(of: " "),
           hard.distance(from: hard.startIndex, to: space) > maxLength / 2 {
            return String(hard[hard.startIndex..<space]) + "…"
        }
        return hard + "…"
    }
}
