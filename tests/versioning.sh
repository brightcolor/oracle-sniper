#!/usr/bin/env bash
# Prüft die Versionsvergabe der CI: bin/next-version, bin/base-version und bin/write-version.
#
#   bash tests/versioning.sh
#
# Die Fälle laufen in einem frischen Git-Repository im Temp-Verzeichnis, auch mit anderen Einstellungen als den
# Vorgaben aus bin/versioning.env. Rückgabewert 0 heißt: alle Fälle bestanden.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEXT="$ROOT/bin/next-version"
BASE="$ROOT/bin/base-version"
WRITE="$ROOT/bin/write-version"

passed=0
failed=0

ok()   { passed=$((passed + 1)); printf 'ok    %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FEHLT %s\n      %s\n' "$1" "$2"; }

expect() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then ok "$name"; else fail "$name" "erwartet \"$expected\", erhalten \"$actual\""; fi
}

expect_failure() {
  local name="$1" pattern="$2"; shift 2
  local output code
  output="$("$@" 2>&1 >/dev/null)"; code=$?
  if [ "$code" -ne 0 ] && printf '%s' "$output" | grep -qF -- "$pattern"; then
    ok "$name"
  else
    fail "$name" "erwartet Abbruch mit \"$pattern\", erhalten Rückgabewert $code und \"$output\""
  fi
}

git_quiet() { git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@" >/dev/null 2>&1; }

new_repo() {
  local dir
  dir="$(mktemp -d)"
  git_quiet -C "$dir" init -b main
  printf '#!/usr/bin/env bash\nVERSION="%s"\necho hi\n' "$1" > "$dir/tool"
  printf '#!/usr/bin/env bash\nset -u\nVERSION="%s"\n' "$1" > "$dir/setup.sh"
  printf 'Seit Version @@VERSION@@ neu.\n' > "$dir/README.md"
  mkdir -p "$dir/docs"
  printf 'Stand: @@VERSION@@, noch einmal @@VERSION@@.\n' > "$dir/docs/notes.md"
  printf 'Kein Text: @@VERSION@@\n' > "$dir/script.sh"
  git_quiet -C "$dir" add -A
  git_quiet -C "$dir" commit -m start
  printf '%s' "$dir"
}

cleanup=()
trap 'rm -rf "${cleanup[@]}"' EXIT

# ---------------------------------------------------------------- next-version ---

expect "ohne Label gilt patch"              "1.3.1"  "$("$NEXT" 1.3.0 '')"
expect "Labels sind optional"               "1.3.1"  "$("$NEXT" 1.3.0)"
expect "patch"                              "1.3.1"  "$("$NEXT" 1.3.0 patch)"
expect "minor setzt patch auf 0"            "1.4.0"  "$("$NEXT" 1.3.7 minor)"
expect "major setzt minor und patch auf 0"  "2.0.0"  "$("$NEXT" 1.3.7 major)"
expect "major ab 0"                         "1.0.0"  "$("$NEXT" 0.114.7 major)"
expect "andere Labels zählen nicht"         "1.3.1"  "$("$NEXT" 1.3.0 'bug,enhancement')"
expect "mehrere Stufen: major gewinnt"      "2.0.0"  "$("$NEXT" 1.3.0 'patch,minor,major')"
expect "mehrere Stufen: minor vor patch"    "1.4.0"  "$("$NEXT" 1.3.3 'patch,minor')"
expect "Groß-/Kleinschreibung, Leerzeichen" "1.4.0"  "$("$NEXT" 1.3.0 'bug, Minor ')"
expect "mehrstellige Zahlen"                "0.99.100" "$("$NEXT" 0.99.99 patch)"
expect "führende Null wird dezimal gelesen" "1.8.10" "$("$NEXT" 1.08.09 patch)"

for bad in '' '1.3' '1.3.0.1' 'v1.3.0' 'neu' '1.3.0-rc1'; do
  expect_failure "ungültige Version \"$bad\" bricht mit Meldung ab" "hat nicht die Form MAJOR.MINOR.PATCH" "$NEXT" "$bad" patch
done

# ---------------------------------------------------------------- base-version ---

repo="$(new_repo 1.3.0)"; cleanup+=("$repo")
cd "$repo" || exit 1
export VERSION_FILES="tool setup.sh"

expect "ohne Tag zählt die Datei" "1.3.0" "$("$BASE")"

git_quiet tag -a v1.2.9 -m alt
expect "älteres Tag zählt nicht" "1.3.0" "$("$BASE")"

git_quiet tag -a v1.3.1 -m "Release des vorigen Pull Requests"
expect "neueres Tag zählt: zweiter Merge kurz nach dem ersten" "1.3.1" "$("$BASE")"
expect "zweiter Merge bekommt die nächste freie Nummer" "1.3.2" "$("$NEXT" "$("$BASE")" patch)"

git_quiet tag -a v1.10.0 -m "zweistellig"
expect "Tags werden als Versionen sortiert" "1.10.0" "$("$BASE")"

git_quiet tag -a v2.0.0-rc1 -m "Vorabversion"
git_quiet tag -a release-9.0.0 -m "fremdes Schema"
expect "Tags mit anderem Schema zählen nicht" "1.10.0" "$("$BASE")"

expect "andere Vorsilbe für Tags" "9.0.0" "$(VERSION_TAG_PREFIX=release- "$BASE")"

sed -i 's/^VERSION="1.3.0"/VERSION="3.0.0"/' tool
git_quiet commit -am "Version von Hand angehoben"
expect "höhere Version in der Datei schlägt das Tag" "3.0.0" "$("$BASE" 2>/dev/null)"
expect "ein älterer Stand lässt sich angeben" "1.10.0" "$("$BASE" HEAD^1)"

hint="$("$BASE" 2>&1 >/dev/null)"
if printf '%s' "$hint" | grep -qF 'setup.sh trägt die Version "1.3.0"'; then ok "abweichende Dateien geben einen Hinweis"; else fail "abweichende Dateien geben einen Hinweis" "$hint"; fi

expect_failure "fehlende Quelldatei bricht mit Meldung ab" "gibt es am Stand" env VERSION_FILES="fehlt.sh" "$BASE"
printf 'echo ohne Version\n' > leer.sh; git_quiet add leer.sh; git_quiet commit -m leer
expect_failure "Quelle ohne VERSION-Zeile bricht mit Meldung ab" "keine Zeile VERSION=" env VERSION_FILES="leer.sh" "$BASE"
expect_failure "leere Einstellung VERSION_FILES bricht mit Meldung ab" "VERSION_FILES ist leer" env VERSION_FILES=" " "$BASE"

# --------------------------------------------------------------- write-version ---

repo="$(new_repo 1.3.0)"; cleanup+=("$repo")
cd "$repo" || exit 1
export VERSION_FILES="tool setup.sh"

changed="$("$WRITE" 1.4.0 | sort | tr '\n' ' ')"
expect "geänderte Dateien werden ausgegeben" "README.md docs/notes.md setup.sh tool " "$changed"
expect "VERSION in der ersten Datei"   'VERSION="1.4.0"' "$(grep '^VERSION=' tool)"
expect "VERSION in der zweiten Datei"  'VERSION="1.4.0"' "$(grep '^VERSION=' setup.sh)"
expect "übriger Inhalt bleibt"         "echo hi" "$(tail -1 tool)"
expect "Platzhalter in README.md"      "Seit Version 1.4.0 neu." "$(cat README.md)"
expect "Platzhalter mehrfach, Unterordner" "Stand: 1.4.0, noch einmal 1.4.0." "$(cat docs/notes.md)"
expect "Dateien außerhalb des Musters bleiben" "Kein Text: @@VERSION@@" "$(cat script.sh)"

printf 'neu: @@VERSION@@\n' > untracked.md
"$WRITE" 1.4.1 >/dev/null
expect "unversionierte Texte bleiben" "neu: @@VERSION@@" "$(cat untracked.md)"
rm untracked.md

repo="$(new_repo 1.3.0)"; cleanup+=("$repo")
cd "$repo" || exit 1
printf 'Build [[ver]] und @@VERSION@@\n' > docs/notes.md
VERSION_FILES="setup.sh" VERSION_PLACEHOLDER="[[ver]]" VERSION_PLACEHOLDER_FILES="docs/*.md *.sh" "$WRITE" 2.0.0 >/dev/null
expect "andere Datei-Liste: nur setup.sh" 'VERSION="1.3.0"' "$(grep '^VERSION=' tool)"
expect "andere Datei-Liste: setup.sh gesetzt" 'VERSION="2.0.0"' "$(grep '^VERSION=' setup.sh)"
expect "anderer Platzhalter mit Sonderzeichen" "Build 2.0.0 und @@VERSION@@" "$(cat docs/notes.md)"
expect "anderes Muster: README.md bleibt" "Seit Version @@VERSION@@ neu." "$(cat README.md)"

printf 'VERSION="1.0.0"\r\nweiter\r\n' > crlf.sh
VERSION_FILES="crlf.sh" VERSION_PLACEHOLDER_FILES="none" "$WRITE" 1.0.1 >/dev/null
expect "Zeilenende CRLF bleibt erhalten" "2" "$(grep -c $'\r$' crlf.sh)"
expect "Zeilenende CRLF: Nummer gesetzt" "1" "$(grep -c '^VERSION="1.0.1"' crlf.sh)"

export VERSION_FILES="tool setup.sh"
expect_failure "ungültige Version bricht mit Meldung ab" "hat nicht die Form MAJOR.MINOR.PATCH" "$WRITE" 1.4
expect_failure "fehlende Datei bricht mit Meldung ab" "Die Datei fehlt.sh fehlt" env VERSION_FILES="tool fehlt.sh" "$WRITE" 1.4.0
printf 'VERSION="1.0.0"\nVERSION="1.0.0"\n' > doppelt.sh
expect_failure "doppelte VERSION-Zeile bricht mit Meldung ab" "2-mal, erwartet ist genau eine" env VERSION_FILES="doppelt.sh" "$WRITE" 1.4.0

# ------------------------------------------------------------- Ablauf im Ganzen ---

repo="$(new_repo 1.3.0)"; cleanup+=("$repo")
cd "$repo" || exit 1
export VERSION_FILES="tool setup.sh"
git_quiet tag -a v1.3.0 -m "1.3.0"
git_quiet switch -c feature
printf 'Neu seit @@VERSION@@.\n' >> README.md
git_quiet commit -am "Funktion"
git_quiet switch main
git_quiet merge --squash feature
git_quiet commit -m "Funktion (#2)"
merge="$(git rev-parse HEAD)"
new="$("$NEXT" "$("$BASE" "$merge^1")" minor)"
"$WRITE" "$new" >/dev/null
expect "Ablauf: minor nach 1.3.0" "1.4.0" "$new"
expect "Ablauf: Text bekommt die Nummer" "Neu seit 1.4.0." "$(tail -1 README.md)"

# ------------------------------------------------------------------ Ergebnis ---

printf '\n%d bestanden, %d fehlgeschlagen\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
