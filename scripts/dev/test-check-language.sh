#!/usr/bin/env bash
# Tests for check-language.sh: every kind of French it once missed must make it
# exit 1 on a scratch git repository, and the English twin of each must pass.
# A detector nobody has seen fail proves nothing; this one reported the
# repository clean while whole files, usage errors and a ConfigMap value were
# French.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

# case <label> <expected rc> <path> <content> [ignore-entry]
case_() {
  local label="$1" want="$2" path="$3" content="$4" ignore="${5:-}" r="$WORK/r"
  rm -rf "$r"; mkdir -p "$r/$(dirname "$path")"
  git -C "$r" init -q
  printf '%s\n' "$content" > "$r/$path"
  [ -z "$ignore" ] || printf '# reason\n%s\n' "$ignore" > "$r/.languageignore"
  git -C "$r" add -A
  local rc=0
  "$ROOT/scripts/dev/check-language.sh" "$r" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then echo "ok    $label"
  else echo "FAIL  $label: exit $rc, wanted $want"; fails=$((fails + 1)); fi
}

# French the word list alone used to miss, then English.
case_ "accent-free French YAML comment"        1 a.yaml  $'# autoriser explicitement le trafic\nkind: X'
case_ "English YAML comment"                   0 a.yaml  $'# explicitly allow the traffic\nkind: X'
case_ "second tier: pas/utiliser in a comment"    1 a.yaml  $'# utiliser fromEntities (pas fromEndpoints)\nkind: X'
case_ "second tier: vendu tel quel in a comment" 1 a.yaml $'# install.yaml upstream, vendu tel quel\nkind: X'
case_ "second tier: inline comment"            1 a.sh    $'x=1   # pas touche\n'
case_ "second tier: English comment, a variable named pas" 0 a.sh $'# the counter is only used when set\npas=1\necho "$pas"\nkind=X'
case_ "accented French comment, unknown word" 1 a.yaml  $'# deploye? non: déployé\nkind: X'
case_ "inline French comment"                  1 a.yaml  $'kind: X   # remplace la valeur\n'
case_ "French in a .example file"              1 a.yaml.example $'# Pour activer: copier le fichier\nkind: X'
case_ "English .example file"                  0 a.yaml.example $'# To enable: copy the file\nkind: X'
case_ "French YAML readme value"               1 a.yaml  $'data:\n  readme: "Instancier un cluster client"'
case_ "English YAML readme value"              0 a.yaml  $'data:\n  readme: "Instantiating a client cluster"'
case_ "French continuation of a description"   1 a.yaml  $'spec:\n  description: "webhook:\n    ingress sur le port 9443"'
case_ "French sys.exit string"                 1 a.py    $'import sys\nsys.exit("PyYAML manquant : installer")'
case_ "English sys.exit string"                0 a.py    $'import sys\nsys.exit("PyYAML missing: install it")'
case_ "French docstring"                       1 a.py    $'def f():\n    """Parse les fichiers."""\n    return 1'
case_ "French in markdown prose"               1 a.md    $'# Title\n\nCette brique est optionnelle.'
case_ "French inside a code fence is prose-free" 0 a.md  $'# Title\n\n```bash\necho "pour le test"\n```'
case_ "link to the French twin"                0 a.md    $'# Title\n\n[Version française](a.fr.md)'
# The name Cléa is not French; a French word beside it still is.
case_ "the name Cléa in an English comment"    0 a.yaml  $'# Cléa reports the pins that drifted\nkind: X'
case_ "French accent next to the name Cléa"    1 a.yaml  $'# Cléa a déployé le correctif\nkind: X'
# A French file is fine only while it is listed AND still French.
case_ "listed French file"                     0 a.md    $'# Titre\n\nCette brique est optionnelle.' a.md
case_ "stale ignore entry (file is English)"   1 a.md    $'# Title\n\nThis brick is optional.' a.md

[ "$fails" -eq 0 ] && echo "all language check tests passed" || { echo "$fails test(s) failed" >&2; exit 1; }
