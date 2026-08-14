import Foundation

/// Nom affichable d'un projet à partir de son chemin.
///
/// Le dernier composant suffit d'ordinaire (`~/Desktop/Dynamic_Island` →
/// « Dynamic_Island »). Il ne dit RIEN dans deux cas, tous deux vécus :
/// - le dossier s'appelle littéralement `claude` (le projet drones de
///   l'utilisateur) — l'îlot affichait « claude · 2 », ce qui ressemble à un
///   regroupement technique et n'identifie aucun projet ;
/// - deux projets ouverts en même temps portent le même dernier composant.
///
/// On montre alors les DEUX derniers composants (« Blender/claude »).
///
/// Cette règle vivait en double : `SessionStore.uiSessions` l'appliquait aux
/// lignes de session, l'en-tête de dossier projet de l'îlot (v0.9.1) ne
/// l'appliquait pas — la même session portait donc deux noms différents selon
/// le mode d'affichage (audit du 2026-07-27). Elle est ici, pure et testée, et
/// les deux appelants s'en servent.
public enum ProjectNaming {

    /// Dernier composant d'un chemin, vide si le chemin l'est.
    public static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Ce dernier composant identifie-t-il quoi que ce soit ?
    static func isGeneric(_ component: String) -> Bool {
        component == "claude"
    }

    /// Nom d'affichage de `path`, sachant les chemins voisins affichés en même
    /// temps (`siblings` peut contenir `path` lui-même).
    public static func displayName(for path: String, siblings: [String]) -> String {
        let base = lastComponent(path)
        guard !base.isEmpty else { return path }
        // Chemins DISTINCTS, pas occurrences : `siblings` reçoit une entrée par
        // SESSION (`SessionStore` construit `sorted.map { $0.cwd }`), donc deux
        // sessions ouvertes dans le MÊME projet — le cas ordinaire ici — se
        // comptaient comme deux projets homonymes. Le nom s'allongeait alors en
        // « Desktop/Dynamic_Island » sans qu'aucune ambiguïté n'existe, et il
        // rallongeait dès qu'on ouvrait une seconde session.
        let duplicated = Set(siblings.filter { lastComponent($0) == base }).count > 1
        guard isGeneric(base) || duplicated else { return base }
        let components = (path as NSString).pathComponents.filter { $0 != "/" }.suffix(2)
        return components.count == 2 ? components.joined(separator: "/") : base
    }

    /// Version en lot : chaque chemin reçoit son nom, la duplication étant
    /// évaluée sur l'ensemble fourni.
    public static func displayNames(for paths: [String]) -> [String] {
        paths.map { displayName(for: $0, siblings: paths) }
    }
}
