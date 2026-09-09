import XCTest
@testable import AtollCore

final class ModelNameTests: XCTestCase {
    func testPrettifiesRawIDs() {
        XCTAssertEqual(ModelName.display("claude-fable-5"), "Fable 5")
        XCTAssertEqual(ModelName.display("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelName.display("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ModelName.display("claude-haiku-4-5-20251001"), "Haiku 4.5")
    }

    func testStripsContextSuffix() {
        XCTAssertEqual(ModelName.display("claude-fable-5[1m]"), "Fable 5")
    }

    func testPassesThroughDisplayNames() {
        // Déjà propre (statusline) → inchangé.
        XCTAssertEqual(ModelName.display("Opus 4.8"), "Opus 4.8")
        XCTAssertEqual(ModelName.display("Fable 5"), "Fable 5")
    }

    func testHandlesUnknownGracefully() {
        // `gpt-4o` servait ici d'exemple de modèle INCONNU et rendait « Gpt 4o ».
        // Il ne l'est plus depuis que la famille GPT est reconnue (2026-09-09) :
        // l'attente est mise à jour, mais l'intention du test — un nom qu'on ne
        // connaît pas ne casse rien — est préservée par les cas qui suivent.
        XCTAssertEqual(ModelName.display("gpt-4o"), "GPT-4o")
        XCTAssertEqual(ModelName.display("mistral-large-2"), "Mistral large.2")
        XCTAssertEqual(ModelName.display("zzz"), "Zzz")
        XCTAssertEqual(ModelName.display(""), "")
    }
}

/// Format arrêté avec Codex le 2026-09-09, sur son propre fournisseur : le
/// formatage générique rendait « Gpt 6.astra » — marque décapitalisée, variante
/// recollée au numéro comme une sous-version.
extension ModelNameTests {
    func testGPTFamilyKeepsItsBrandAndSeparatesTheVariant() {
        XCTAssertEqual(ModelName.display("gpt-6-astra"), "GPT-6 Astra")
        XCTAssertEqual(ModelName.display("gpt-5.6-sol"), "GPT-5.6 Sol")
        XCTAssertEqual(ModelName.display("gpt-5-codex"), "GPT-5 Codex")
    }

    func testGPTWithoutVariantOrVersionDegradesCleanly() {
        XCTAssertEqual(ModelName.display("gpt-5"), "GPT-5")
        XCTAssertEqual(ModelName.display("gpt"), "GPT")
    }

    /// La branche GPT ne doit RIEN changer aux modèles Anthropic.
    func testAnthropicNamesAreUntouchedByTheGPTBranch() {
        XCTAssertEqual(ModelName.display("opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelName.display("claude-fable-5"), "Fable 5")
    }
}
