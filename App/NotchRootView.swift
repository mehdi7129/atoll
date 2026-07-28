import SwiftUI
import AtollCore

/// Vue racine de la fenêtre d'îlot : occupe toute la fenêtre transparente,
/// dessine l'îlot en haut au centre et anime ses transitions d'état.
struct NotchRootView: View {
    let viewModel: NotchViewModel

    @AppStorage("paletteID") private var paletteID = Palette.monoOrange.id
    @AppStorage("hoverDelay") private var hoverDelay = 0.15
    @AppStorage(VisualEffects.enabledKey) private var visualEffects = true
    @AppStorage(VisualEffects.glassIntensityKey) private var glassIntensity = VisualEffects.defaultGlassIntensity
    /// Rockstar élargit l'îlot même sans session : voir `islandSize(rockstar:)`.
    @AppStorage(InteractionCenter.autonomyKey) private var autonomyRaw = AutonomyLevel.manual.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Rejoue l'onde d'expansion : incrémenté à chaque passage → étendu.
    @State private var rippleTrigger = 0
    /// Dévoilement du verre : 0 = fond PLEIN, 1 = l'intensité réglée par
    /// l'utilisateur. Voir `IslandBackground` et `onChange(of: state)`.
    @State private var glassReveal: Double = 0
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    private var colors: ThemeColors {
        ThemeColors(paletteID: paletteID, scheme: colorScheme)
    }

    /// Sur un écran à encoche, l'îlot compact prolonge le notch physique : il doit
    /// rester noir quel que soit le thème (le matériel, lui, ne change pas de couleur).
    /// Ses textes utilisent donc toujours la variante sombre de la palette.
    private var capColors: ThemeColors {
        viewModel.hasNotch ? ThemeColors(variant: Palette.named(paletteID).dark) : colors
    }

    private var rockstar: Bool { AutonomyLevel(rawValue: autonomyRaw) == .rockstar }

    private var isCompactCap: Bool {
        viewModel.hasNotch && viewModel.state == .compact
    }

    /// Rayon des coins BAS (les coins hauts sont droits, cf. `NotchShape`).
    ///
    /// Valeurs relevées AU PIXEL sur cette machine (macOS 26.5.2), par
    /// ajustement en sous-pixel du contour de vraies surfaces système : un menu
    /// `NSMenu` donne r = 12,90 pt en courbure continue, une fenêtre 15,5 pt.
    /// Apple fait croître le rayon avec la surface (12,9 sur 141 pt de large,
    /// 15,5 sur 500) — notre panneau en fait 600 sur 340, d'où **18**, un cran
    /// au-dessus de la fenêtre. Le premier jet était à 26 : deux fois la
    /// référence, et ça se voyait, le coin mangeait la ligne du quota.
    /// 12 pt en compact, le rayon des coins de l'encoche physique.
    private var bottomRadius: CGFloat {
        viewModel.state == .expanded ? 18 : 12
    }

    /// Retrait des flancs — cf. `NotchShape.sideInset`. Uniquement en compact sur
    /// un écran à ENCOCHE, où la forme longe une découpe physique dont on ne
    /// connaît que la boîte englobante. Sur un écran sans encoche la pilule est
    /// une vraie surface visible : elle occupe sa frame.
    private var sideInset: CGFloat {
        viewModel.hasNotch && viewModel.state == .compact ? 6 : 0
    }

    /// Le CONTOUR : trait sombre d'un pixel physique, posé AU bord, uniforme.
    ///
    /// Mesuré sur un vrai menu macOS 26 au-dessus d'un fond gris contrôlé, en
    /// capture compositeur 2× : la structure est identique sur les quatre côtés
    /// — 1 px à luminance 18-21, puis 2 px à 128 et 115. Autrement dit Apple
    /// pose DEUX traits, pas un : un contour sombre qui détache la surface de ce
    /// qu'il y a derrière, et un liseré clair juste à l'intérieur qui lui donne
    /// son épaisseur. Un trait unique, quel qu'il soit, ne rend ni l'un ni
    /// l'autre. Le contour ne DÉGRADE pas : même valeur partout.
    private var contourColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.70 : 0.45)
    }

    /// Le LISERÉ : deux pixels physiques, juste à l'intérieur du contour.
    ///
    /// Lui seul est dégradé — Apple simule une lumière rasante venant du haut,
    /// mesurée sur une fenêtre système dans un rapport haut/bas de **1 → 0,7**.
    /// Le premier jet tombait à 1 → 0,2 : trois fois trop, l'arête basse
    /// disparaissait et le panneau semblait fondre dans le bureau.
    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color.white.opacity(0.35), Color.white.opacity(0.24)]
                : [Color.white.opacity(0.60), Color.white.opacity(0.42)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Le bord complet — contour + liseré — dont les deux extrémités hautes
    /// s'éteignent en fondu au ras de l'écran.
    ///
    /// L'arête HAUTE n'est pas dessinée : elle est confondue avec le bord de
    /// l'écran, un liseré y tracerait une ligne claire en travers de la barre
    /// des menus, sur un bord qui n'existe pas. Une coupure nette laisserait
    /// deux bouts de trait visibles tout en haut ; le fondu les efface.
    @ViewBuilder
    private func islandBorder(_ shape: NotchShape, height: CGFloat) -> some View {
        let hairline = viewModel.hairline
        let span = max(height, 1)
        // Coupe FRANCHE d'abord, fondu ensuite.
        //
        // Un simple dégradé partant de `.clear` à y = 0 ne suffit pas : le trait
        // occupe les 1,5 premiers points (contour + liseré), et à y = 0,5 pt un
        // dégradé étalé sur 2 pt vaut déjà 0,26 — soit un quart du liseré, EN
        // PERMANENCE, en travers du haut de la pilule compacte d'un écran sans
        // encoche (elle est dessinée en continu et son bord n'est jamais éteint).
        // On masque donc d'abord tout le trait, et on ne fait le fondu qu'après.
        let hardCut = min(hairline * 3, span * 0.5)
        // Le fondu couvre 16 pt sur le panneau déployé (~372 pt) mais seulement
        // ~2 pt sur l'îlot compact : une longueur FIXE y mangerait la moitié
        // d'un bord de 26 pt de haut.
        let fade = min(16, max(2, span * 0.05))
        ZStack {
            shape.strokeBorder(contourColor, lineWidth: hairline)
            shape.inset(by: hairline)
                .strokeBorder(borderGradient, lineWidth: hairline * 2)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: hardCut / span),
                    .init(color: .black, location: min((hardCut + fade) / span, 1)),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .opacity(borderStrength)
    }

    /// Force du bord selon l'état — interpolée, donc animée par le ressort.
    ///
    /// Sur un écran SANS encoche, `isCompactCap` est toujours faux : la pilule
    /// compacte porte donc ce bord EN PERMANENCE, sans qu'aucune session ne
    /// tourne. Au calibrage Apple (liseré blanc à 0,35) elle deviendrait un
    /// petit rectangle lumineux à demeure en haut de l'écran. Elle garde un bord,
    /// mais à voix basse.
    private var borderStrength: Double {
        if isCompactCap { return 0 }   // encoche : fusion invisible avec le notch
        return viewModel.state == .expanded ? 1 : 0.55
    }

    private var pendingCount: Int {
        InteractionCenter.shared.pending.count
    }

    /// L'îlot doit-il rester ouvert + prendre le clavier ? (carte en attente).
    private var wantsFocus: Bool {
        pendingCount > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(
            width: IslandGeometry.windowSize.width,
            height: IslandGeometry.windowSize.height,
            alignment: .top
        )
        #if DEBUG
        // Ouverture scriptée des Réglages (captures) : openSettings est
        // l'action SwiftUI fiable, contrairement à showSettingsWindow: routé
        // depuis un handler de fond. AppDelegate relaie la notif Darwin.
        .onReceive(NotificationCenter.default.publisher(for: .atollDebugOpenSettings)) { _ in
            if viewModel.isPrimary {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }
        #endif
        .onChange(of: wantsFocus) { oldValue, newValue in
            // Carte en attente → l'îlot s'ouvre tout seul (écran principal) et
            // prend le clavier ; plus rien → il se replie et rend le focus au
            // terminal.
            viewModel.syncInteractionState(pendingCount: newValue ? 1 : 0,
                                           previousCount: oldValue ? 1 : 0)
        }
        .onChange(of: viewModel.state) { _, newState in
            // Le focus clavier suit l'état visible : replié → rendu au terminal,
            // déployé avec carte → repris.
            viewModel.onKeyFocusRequest?(viewModel.isPrimary && newState == .expanded && wantsFocus)
            // Rejoue l'onde à chaque ouverture (débordement volontairement ignoré).
            if newState == .expanded {
                rippleTrigger &+= 1
                // Le panneau s'ouvre PLEIN, puis le verre se dévoile.
                //
                // SECONDE cause de l'ouverture ratée (la première est le contour
                // conditionnel, voir l'overlay plus bas). Mesuré au ralenti
                // (60 i/s, écran externe) : à 100 % de Liquid Glass, la luminance
                // intérieure du panneau monte de 9 à 30 en ~250 ms, pendant que
                // la géométrie, elle, est déjà à 66 % de sa largeur finale dès la
                // première image visible. Le fond arrive donc APRÈS le bord :
                // pendant ~150 ms l'îlot est un contour presque vide qui grandit.
                // Le même relevé avec le verre à 0 donne une luminance constante
                // (9,0) — ce défaut-là vient bien du verre, pas du ressort.
                //
                // On ne peut pas accélérer la matérialisation du verre (elle
                // appartient au système). On la RECOUVRE : le fond est plein
                // pendant la croissance, et ne s'efface qu'ensuite. Le verre a
                // le temps de s'établir sous un aplat, personne ne le voit
                // arriver.
                // Cette durée n'est PAS un choix esthétique : elle doit couvrir
                // les ~250 ms que le système met à matérialiser le verre. Elle
                // ne suit donc pas « Réduire les animations » — un fondu n'est
                // pas du mouvement, et le raccourcir rouvrirait exactement le
                // défaut qu'il colmate. (Essayé, mesuré : à 0,12 s l'aplat s'en
                // va avant que le verre soit là, et le contour redevient vide.
                // Reduce Motion est ACTIF sur la machine de dev, ça s'est vu
                // tout de suite.)
                withAnimation(.easeOut(duration: 0.30).delay(0.10)) {
                    glassReveal = 1
                }
            } else {
                // Le panneau se replie : retour à l'aplat SANS animation.
                //
                // Sans `Transaction(animation: nil)`, cette remise à zéro se
                // ferait au rythme du ressort de fermeture (0,45 s) — et une
                // réouverture au survol dans cet intervalle repartirait d'un
                // aplat à ~0,7 au lieu de 1, laissant réapparaître le verre
                // pendant la croissance. « L'aplat est opaque au début de chaque
                // croissance » doit être un INVARIANT, pas le résultat d'une
                // course entre deux ressorts.
                withTransaction(Transaction(animation: nil)) {
                    glassReveal = 0
                }
            }
        }
        .onAppear {
            // L'état est lu AVANT d'ouvrir quoi que ce soit.
            //
            // Le rattrapage ci-dessous existe pour le cas « la vue réapparaît
            // alors que l'îlot était DÉJÀ déployé » : `glassReveal` repart à 0
            // (c'est un `@State`) et seule une TRANSITION vers `.expanded` le
            // remonte — le panneau resterait en fond plein pour toujours.
            // Mais `syncInteractionState` juste en dessous APPELLE `open()` :
            // le lire après, c'est voir `.expanded` sur le chemin d'une carte
            // qui vient de s'ouvrir, poser `glassReveal = 1` séance tenante, et
            // annuler précisément le dévoilement qu'on voulait protéger.
            let wasExpanded = viewModel.state == .expanded

            // Fenêtre reconstruite pendant une carte active : réappliquer.
            if wantsFocus {
                viewModel.syncInteractionState(pendingCount: 1, previousCount: 0)
            }
            if wasExpanded {
                glassReveal = 1
            }
        }
    }

    @ViewBuilder
    private var island: some View {
        let size = viewModel.islandSize(rockstar: rockstar)
        let shape = NotchShape(bottomRadius: bottomRadius, sideInset: sideInset)

        ZStack(alignment: .top) {
            IslandBackground(
                shape: shape,
                colors: colors,
                isCompactCap: isCompactCap,
                isExpanded: viewModel.state == .expanded,
                effectsEnabled: visualEffects,
                glassIntensity: glassIntensity,
                glassReveal: glassReveal
            )

            // Étendu sur écran à encoche : bandeau noir en haut, à hauteur du notch
            // physique, pour que l'encoche reste visuellement intégrée même en clair.
            if viewModel.hasNotch, viewModel.state == .expanded, let notch = viewModel.notchSize {
                Rectangle()
                    .fill(Color.black)
                    .frame(height: notch.height)
            }

            content
                .expansionRipple(trigger: rippleTrigger,
                                 active: visualEffects && !reduceMotion)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            // Le bord est TOUJOURS PRÉSENT, seule son opacité change.
            //
            // C'est la correction du défaut décrit par Mehdi, et c'est la cause
            // qui ne se voit QUE sur l'écran à encoche : le trait était un
            // enfant CONDITIONNEL (`if !isCompactCap`), donc absent en compact.
            // À l'ouverture SwiftUI ne l'interpolait pas — il l'INSÉRAIT, et une
            // vue insérée naît à sa géométrie FINALE, avec un simple fondu.
            // On voyait donc le contour du panneau déployé pendant que le corps,
            // lui, mettait ~0,25 s à grandir jusqu'à lui : « d'abord le contour,
            // ensuite la fenêtre qui vient s'y coller ». En gardant l'identité
            // de la vue, sa géométrie est interpolée comme le reste.
            //
            // `strokeBorder` (et non `.stroke`) : le trait tombe ENTIÈREMENT
            // dans la forme, il ne se fait donc pas rogner par le clip — un
            // trait centré y perd sa moitié extérieure et rend deux fois trop
            // fin, crénelé.
            islandBorder(shape, height: size.height)
        }
        .contentShape(shape)
        .onHover { hovering in
            viewModel.hoverChanged(hovering, openDelay: hoverDelay)
        }
        .onTapGesture {
            viewModel.togglePinned()
        }
        // L'ombre est tirée d'UNE silhouette aplatie, pas de chaque couche :
        // sans cela le halo se calcule aussi sur le liseré et le fond, et
        // s'épaissit là où ils se superposent.
        .compositingGroup()
        // DEUX ombres, comme Apple : une courte qui pose l'arête sur le fond,
        // une longue et diffuse qui donne l'altitude. Une seule ombre moyenne
        // ne fait ni l'un ni l'autre — elle floute le bord sans soulever le
        // panneau.
        //
        // Le décalage vertical est CALÉ sur une mesure : l'ombre d'une vraie
        // fenêtre macOS 26 sur fond gris moyen donne α = 0,344 juste sous le
        // bord, 0,195 à 10 pt, 0,070 à 20 pt, et 0,234 sur les flancs. Un y de
        // 10 pt vidait les flancs pour tout accumuler dessous ; 5 pt retombe
        // sur les valeurs mesurées.
        .shadow(color: .black.opacity(viewModel.state == .expanded ? 0.26 : 0),
                radius: 3, y: 1)
        .shadow(color: .black.opacity(viewModel.state == .expanded ? 0.26 : 0),
                radius: 22, y: 5)
        // Pas de .animation(value:) ici : les springs (ouverture/fermeture distinctes)
        // sont posés par withAnimation dans le view model.
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .compact:
            CompactView(viewModel: viewModel, colors: capColors)
        case .expanded:
            ExpandedView(viewModel: viewModel, colors: colors)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }
}
