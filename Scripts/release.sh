#!/bin/zsh
# Release Atoll : build Release signé Developer ID → re-signature des binaires
# imbriqués Sparkle → notarisation → staple → DMG notarisé → appcast Sparkle.
# Voir docs/research/research-macos-app.md. Durci par revue adversariale :
#   - codesign -dvv (pas -dv : Authority= n'apparaît qu'en verbosité 2) ;
#   - refus si get-task-allow présent (l'action build l'injecterait sans
#     CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO → notarisation refusée) ;
#   - Autoupdate/Updater.app de Sparkle re-signés Developer ID (livrés adhoc) ;
#   - dossier d'archives PERSISTANT (dist/updates) : appcast multi-entrées et
#     deltas Sparkle possibles ; staging DMG hors iCloud (mktemp).
#
# Prérequis (une seule fois) :
#   - certificat « Developer ID Application » dans le Keychain ;
#   - xcrun notarytool store-credentials "atoll-notary" \
#       --apple-id <apple-id> --team-id X524H8XA4L ;
#   - clés Sparkle générées (generate_keys → clé privée dans le Keychain).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# DerivedData HORS du Bureau (iCloud tamponne des xattrs qui cassent CodeSign).
DD="$HOME/Library/Developer/Atoll-DerivedData"
PROFILE="atoll-notary"
IDENTITY="Developer ID Application"
cd "$ROOT"

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed 's/.*"\(.*\)".*/\1/')
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "✗ MARKETING_VERSION illisible dans project.yml : « $VERSION »"
  exit 1
fi
DIST="$ROOT/dist/$VERSION"
# PERSISTANT entre releases (jamais rm) : generate_appcast y retrouve les
# archives précédentes → appcast multi-entrées + deltas incrémentaux.
UPDATES="$ROOT/dist/updates"
rm -rf "$DIST"
mkdir -p "$DIST" "$UPDATES"

echo "── Atoll $VERSION — build Release signé"
xcodegen generate
xcodebuild -project Atoll.xcodeproj -scheme Atoll -configuration Release \
  -derivedDataPath "$DD" build | tail -3
APP="$DD/Build/Products/Release/Atoll.app"

echo "── Re-signature des binaires imbriqués Sparkle (livrés adhoc)"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
[ -e "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" ] && sign "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
[ -e "$SPARKLE/Versions/B/XPCServices/Installer.xpc" ] && sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
# La re-signature du framework invalide le sceau de l'app → re-signer l'app en
# dernier, avec SES entitlements (apple-events pour le jump-back AppleScript).
codesign --force --timestamp --options runtime \
  --entitlements "$ROOT/App/Atoll.entitlements" --sign "$IDENTITY" "$APP"

echo "── Vérification de signature"
codesign --verify --strict --deep "$APP"
# PAS de `codesign | grep -m1/-q` ici : sous pipefail, grep qui ferme le pipe
# envoie SIGPIPE à codesign → pipeline 141 → le script meurt (ou pire, un
# `if … grep -q` devient FAUX au moment précis où il matche). Variables + [[.
SIGN_INFO=$(codesign -dvv "$APP" 2>&1)
[[ "$SIGN_INFO" == *"Authority=Developer ID"* ]] \
  || { echo "✗ app pas signée Developer ID"; exit 1; }
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)
if [[ "$ENTITLEMENTS" == *"get-task-allow"* ]]; then
  echo "✗ get-task-allow présent dans les entitlements — notarisation vouée à l'échec"
  exit 1
fi
AUTOUPDATE_INFO=$(codesign -dvv "$SPARKLE/Versions/B/Autoupdate" 2>&1)
[[ "$AUTOUPDATE_INFO" == *"Authority=Developer ID"* ]] \
  || { echo "✗ Autoupdate (Sparkle) pas signé Developer ID"; exit 1; }
echo "✓ signatures Developer ID, sans get-task-allow"

echo "── Notarisation de l'app"
ZIP="$DIST/Atoll-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait | tee "$DIST/notary-app.log"
grep -q "status: Accepted" "$DIST/notary-app.log" || { echo "✗ notarisation refusée (voir notarytool log)"; exit 1; }
xcrun stapler staple "$APP"
# Re-zip de l'app STAPLÉE : c'est l'artefact de mise à jour Sparkle.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
cp "$ZIP" "$UPDATES/"

echo "── DMG (glisser vers Applications) — staging hors iCloud"
DMG="$DIST/Atoll-$VERSION.dmg"
STAGE="$(mktemp -d /tmp/atoll-dmg.XXXXXX)"
ditto "$APP" "$STAGE/Atoll.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Atoll $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | tee "$DIST/notary-dmg.log"
grep -q "status: Accepted" "$DIST/notary-dmg.log" || { echo "✗ notarisation du DMG refusée"; exit 1; }
xcrun stapler staple "$DMG"

echo "── Appcast Sparkle (signatures EdDSA depuis le Keychain)"
GENERATE_APPCAST=$(find "$DD/SourcePackages/artifacts" -name generate_appcast -type f -perm +111 2>/dev/null | head -1)
[ -n "$GENERATE_APPCAST" ] || { echo "✗ generate_appcast introuvable (build d'abord)"; exit 1; }
"$GENERATE_APPCAST" \
  --download-url-prefix "https://github.com/mehdi7129/atoll/releases/download/v$VERSION/" \
  "$UPDATES"
cp "$UPDATES/appcast.xml" "$ROOT/docs/appcast.xml"
# Deltas éventuels (dès la 2e release) : à joindre à la release GitHub.
DELTAS=("$UPDATES"/*.delta(N))

echo ""
echo "✓ Artefacts : $DMG"
echo "             $ZIP (artefact Sparkle)"
[ ${#DELTAS[@]} -gt 0 ] && echo "             deltas : ${DELTAS[@]}"
echo "             docs/appcast.xml (à committer/pousser — servi par GitHub Pages)"
echo ""
echo "Publier (dans CET ordre — la release avant l'appcast qui pointe dessus) :"
echo "  gh release create v$VERSION '$DMG' '$ZIP' ${DELTAS[@]:-} --title 'Atoll $VERSION' --notes '…'"
echo "  git add docs/appcast.xml && git commit -m 'Appcast v$VERSION' && git push"
