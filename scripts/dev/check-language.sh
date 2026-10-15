#!/usr/bin/env bash
# Find French prose where the repository says English is canonical.
#
# CLAUDE.md says "passer le détecteur" — and there was no detector, in either
# repository, which is why the 2026-07-28 switch left ~50 lines behind and a
# later audit still found seven whole files.
#
# Two things this gets right that the obvious version does not:
#
#   1. It does NOT key on accents. `preflight-quotas.py` says "DEPASSEMENT" and
#      two `ovh/*.tf` comments are accent-free French; an accent regex reports
#      them clean, which reads as "nothing there". Words, not diacritics.
#   2. It only reads prose — Markdown outside code fences, comment lines in
#      code, and the text of what a script PRINTS. A French word inside an
#      identifier or a non-printed literal is not a translation defect, and
#      flagging it would train people to ignore this.
#      The printed strings had to be added: on 2026-08-15 this file reported the
#      repository clean while a provisioner announced "▶ Purge du staging" to
#      every operator who built an Outscale image. A comment is read once; that
#      line is read every run.
#
# What it reads, beyond the above: inline `# ...` comments, the string literals
# and docstrings of Python (sys.exit, errors.append and raise are not "printed"
# lines, and a French usage error sat there unseen), YAML `readme:`,
# `description:`, `message:` and `summary:` values with their continuation lines
# (they reach a cluster), and *.example, *.hcl, *.json5, *.tpl, *.toml files. On top of the
# word list, any accented French letter in prose is reported: the word list is
# whack-a-mole, the accent rule catches what it has not met yet. (The accent
# rule alone would miss accent-free French, which is why neither replaces the
# other.) A `.languageignore` entry whose files scan clean is itself a failure:
# the list can only shrink.
#
# BLIND TO UNTRACKED FILES: it scans `git ls-files`, so a new script passes until
# it is committed. check-version-drift.sh was written, run clean, committed, and
# only then reported a French word in its own comment. Run this again after
# `git add`, not before.
#
# Usage: check-language.sh [path ...]        (defaults to the repository root)
#        check-language.sh --list            list the words it looks for
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Words chosen for one property: they are French and they are not English, not
# an identifier, and not a common abbreviation. That rules out the tempting ones
# — `son`, `car`, `pas`, `on`, `or`, `main`, `distinct` — every one of
# which is an ordinary English word or appears in code.
#
# The list is necessarily incomplete, and every widening has found real lines
# that the narrower one called clean: `et ne pourrait ni` contained none of the
# first set, and sixteen `# Groupe NN` headers survived the second. Widen it
# again when you meet French this misses — and check the new words against BOTH
# repositories before committing, which is what caught `distinct`.
# `sur` was excluded here for years; measured on 2026-10-14 over every prose
# line of this repository it matched 15 lines, all French, none English (the
# SANs acronym is case-sensitive and does not collide). Run the same count on
# the sibling repository before copying it there.
WORDS='le|la|les|des|une|dans|pour|avec|cette|être|est|sont|était|sera|qui|que|quand|ainsi|alors|aussi|avant|après|chaque|comme|depuis|donc|déjà|encore|entre|jamais|leur|mais|même|moins|notre|parce|peut|plutôt|puis|sans|sous|toujours|tout|toute|toutes|tous|très|vers|voici|voilà|faut|doit|doivent|ici|cela|ceci|celui|celle|nous|vous|elles|ils|du|au|aux|ni|elle|leurs|afin|lorsque|selon|plusieurs|ceux|celles|ensuite|enfin|pourrait|pourraient|publique|publiques|groupe|groupes|nom|noms|certificat|certificats|interne|internes|externe|externes|fichier|fichiers|exemple|exemples|attendu|attendue|ordinaire|ordinaires|racine|seule|seul|court|courte|observee|observée|valide|valider|ajoute|ajouter|affiche|utilise|supprime|renvoie|permet|sur|natif|veut|autoriser|stockage|cet|ces|ses|aucun|aucune|soit|fois|rien|manquant|vouliez|brique|briques|disponibles|existe|invalide|et|ou|ne|matchait|jetable|derrière|remplace|applicatif|fonctionne|fournie|gestion|trop|instancier'

# Second tier: words that are French but also plausible in code (`pas`, `tel`), so they only count inside COMMENT lines and inline
# comments, which are prose. Measured: "utiliser fromEntities: cluster (pas fromEndpoints...)" and "vendu tel quel" passed the first tier.
WORDS_COMMENT='pas|utiliser|utilisé|vendu|tel|tels|quel|quelle|lequel|laquelle'

usage() { sed -n '2,12p' "$0" | sed 's/^# \?//'; }
case "${1:-}" in
  --list) printf '%s\n' "$WORDS" | tr '|' '\n'; exit 0 ;;
  -h|--help) usage; exit 0 ;;
esac

# .languageignore, if present, lists path prefixes this repository has decided
# are French on purpose — with the reason on the line above. It is an allowlist,
# not a silencer: everything not named in it is checked.
# NO_IGNORE=1 turns it off (the stale-entry check scans the listed files bare);
# ONLY=<glob> restricts a scan to the paths matching it.
ignored() {
  local repo="$1" path="$2" pattern
  # This file, always and without an entry anywhere. It necessarily contains the
  # words it hunts — the list itself, and the sentence explaining `sans` versus
  # the SANs acronym. Relying on each repository to remember an allowlist line
  # meant the copy in the sibling repository failed its own CI on first run.
  # Its test holds French fixtures on purpose, for the same reason.
  case "$path" in scripts/dev/check-language.sh|scripts/dev/test-check-language.sh) return 0 ;; esac
  if [ -n "${ONLY:-}" ]; then
    # shellcheck disable=SC2254
    case "$path" in $ONLY) ;; *) return 0 ;; esac
  fi
  [ -z "${NO_IGNORE:-}" ] || return 1
  [ -f "$repo/.languageignore" ] || return 1
  while read -r pattern; do
    case "$pattern" in ''|\#*) continue ;; esac
    # Globbing is the point: an entry like `apps/base/*/README.md` must match.
    # shellcheck disable=SC2254
    case "$path" in $pattern) return 0 ;; esac
  done < "$repo/.languageignore"
  return 1
}

# Markdown: every .md that is not a .fr.md, minus vendored and generated trees.
md_files() {
  git -C "$1" ls-files '*.md' \
    | grep -v '\.fr\.md$' \
    | grep -vE '^(CHANGELOG\.fr|.*/vendor/|.*/node_modules/)'
}

# Code: the comment line of the languages this repository writes. `.example`
# and the config dialects were outside this list, which is how a whole French
# example file was never read.
code_files() {
  git -C "$1" ls-files '*.tf' '*.tftpl' '*.yaml' '*.yml' '*.sh' '*.py' '*.example' '*.hcl' '*.json5' '*.tpl' '*.toml'
}

# Shared by both awk programs: is this prose line French? Word list (case-sensitive,
# see above) or any accented French letter. Alternation, not a bracket expression:
# mawk is byte-oriented and a bracket of multibyte letters matches stray bytes of
# em dashes and arrows.
AWK_FRENCH='
function french(text,    n, i, w, cap) {
  # Cléa is the name of the dependency watcher (OpenAether-infra), not a French word. Only the name
  # is neutralised: an accented French word beside it is still caught.
  gsub(/Cléa/, "Clea", text)
  if (text ~ /(é|è|ê|ë|à|â|ç|î|ï|ô|ù|û|ü|œ|É|È|À|Ç)/) return 1
  # French elision (l-apostrophe-admin, d-apostrophe-un, n-apostrophe-est): a short
  # letter group, an apostrophe and a letter, after a non-word character. English
  # contractions put the apostrophe AFTER a word (dont, its), so they do not match.
  # (No apostrophes in this comment: the awk program is single-quoted.)
  if (text ~ ("(^|[^[:alnum:]_])(l|d|qu|n|s|j|c|m|t)" sprintf("%c", 39) "[[:alpha:]]")) return 1
  n = split(words, w, "|")
  for (i = 1; i <= n; i++) {
    cap = toupper(substr(w[i], 1, 1)) substr(w[i], 2)
    # Case-SENSITIVE, deliberately: `sans` is French, `SANs` is the
    # certificate acronym, and a case-insensitive match calls the second
    # one a translation defect on every TLS comment in the repository.
    # A leading hyphen means a flag, not a word: `-le 15`, `-la`, `-du` are
    # shell test operators and CLI switches. No French word in this repository
    # follows a hyphen directly.
    if (text ~ ("(^|[^[:alnum:]_-])(" w[i] "|" cap ")([^[:alnum:]_]|$)")) return 1
  }
  return 0
}
function french_comment(text,    n, i, w, cap) {
  n = split(wordsc, w, "|")
  for (i = 1; i <= n; i++) {
    cap = toupper(substr(w[i], 1, 1)) substr(w[i], 2)
    if (text ~ ("(^|[^[:alnum:]_-])(" w[i] "|" cap "|" toupper(w[i]) ")([^[:alnum:]_]|$)")) return 1
  }
  return 0
}'

hits=0

scan_markdown() {
  local repo="$1" f
  while read -r f; do
    [ -n "$f" ] || continue
    ignored "$repo" "$f" && continue
    # awk rather than grep: a fenced block has to be skipped, and a French word
    # inside a shell example is not prose.
    awk -v words="$WORDS" -v file="$f" "$AWK_FRENCH"'
      /^[[:space:]]*```/ { fence = !fence; next }
      fence { next }
      /\.fr\.md/ { next }   # the link to the French twin is allowed to say so
      french($0) { printf "%s:%d: %s\n", file, NR, $0 }' "$repo/$f"
  done < <(md_files "$repo")
}

scan_code() {
  local repo="$1" f
  while read -r f; do
    [ -n "$f" ] || continue
    ignored "$repo" "$f" && continue
    awk -v words="$WORDS" -v wordsc="$WORDS_COMMENT" -v file="$f" "$AWK_FRENCH"'
      # Prose in code, by kind:
      #  - comment lines (# for yaml/sh/py/tf, // and * for the hcl/go style);
      #  - the text a script shows its user. `help=` and `description=` count even
      #    though nothing prints them in the source: argparse does, on every
      #    --help (the 2026-07-29 half-translated block);
      #  - heredoc bodies: an HCL `description = <<-EOT` and a bare `cat <<EOT`
      #    (the text `tofu` and fleet-down.sh print), narrowed to `cat` so that
      #    `cat > file <<EOF` and piped heredocs stay out;
      #  - inline `# comment` after code;
      #  - YAML `readme:`, `description:`, `message:`, `summary:` values and the
      #    continuation lines of a multi-line one: they reach a cluster;
      #  - in Python, docstrings and every string literal (sys.exit, errors.append
      #    and raise are not "printed" lines, and a usage error in French sat in
      #    scripts/pick.py for months).
      BEGIN { py = (file ~ /\.py$/) }
      /description[[:space:]]*=[[:space:]]*<<-?[A-Za-z_]+/ || /^[[:space:]]*cat([[:space:]]+>&[0-9])?[[:space:]]*<<-?[A-Za-z_]+/ {
        match($0, /<<-?[A-Za-z_]+/)
        term = substr($0, RSTART, RLENGTH)
        sub(/^<<-?/, "", term)
        in_doc = 1
      }
      in_doc && $0 ~ ("^[[:space:]]*" term "[[:space:]]*$") { in_doc = 0; next }
      {
        line = $0
        text = ""
        comment = (line ~ /^[[:space:]]*(#|\/\/|\*)/)
        printed = (!comment && line ~ /((echo|print|printf|puts)[[:space:](]|(help|description)=)/)
        if (comment || in_doc) text = line
        else if (printed) {
          # A substitution is code, not prose: `du -h "$SNAP"` inside an
          # otherwise English message is the `du` command.
          text = line
          gsub(/\$\([^)]*\)/, " ", text); gsub(/\$\{[^}]*\}/, " ", text)
        }
        # Python docstrings: a line is inside while an odd number of triple quotes
        # has been seen; the opening and closing lines count too.
        if (py) {
          q = line; nq = gsub(/"""/, "", q)
          if (in_py || nq > 0) text = text " " line
          if (nq % 2 == 1) in_py = !in_py
          else if (!in_py && !comment && nq == 0) {
            lit = ""; rest = line
            while (match(rest, /"[^"]*"|\047[^\047]*\047/)) {
              lit = lit " " substr(rest, RSTART + 1, RLENGTH - 2)
              gsub(/\\n/, " ", lit)   # a leading \n would hide the first word
              rest = substr(rest, RSTART + RLENGTH)
            }
            text = text " " lit
          }
        }
        # YAML prose values.
        match(line, /^[[:space:]]*/); ind = RLENGTH
        if (in_str && line !~ /^[[:space:]]*$/ && ind > str_ind) text = text " " line
        else in_str = 0
        if (line ~ /^[[:space:]-]*(readme|description|message|summary):[[:space:]]*[^[:space:]]/) {
          in_str = 1; str_ind = ind; text = text " " line
        }
        # Inline comment after code (needs whitespace on both sides of the hash).
        if (!comment && match(line, /[[:space:]]#[[:space:]].*/)) text = text " " substr(line, RSTART)
        ctext = ""
        if (comment) ctext = line
        else if (match(line, /[[:space:]]#[[:space:]].*/)) ctext = substr(line, RSTART)
        if ((text != "" && french(text)) || (ctext != "" && french_comment(ctext))) printf "%s:%d: %s\n", file, NR, $0
      }' "$repo/$f"
  done < <(code_files "$repo")
}

# A `.languageignore` entry whose files scan clean is a stale silencer: the file
# was translated and the line stayed. Nothing else would ever remove it.
stale_entries() {
  local repo="$1" pattern out n=0
  [ -f "$repo/.languageignore" ] || return 0
  while read -r pattern; do
    case "$pattern" in ''|\#*) continue ;; esac
    out="$( { NO_IGNORE=1 ONLY="$pattern" scan_markdown "$repo"; NO_IGNORE=1 ONLY="$pattern" scan_code "$repo"; } || true )"
    if [ -z "$out" ]; then
      echo ".languageignore: '$pattern' scans clean, remove the entry" >&2
      n=$((n + 1))
    fi
  done < "$repo/.languageignore"
  return "$n"
}

repos=("${@:-$ROOT}")
stale=0
for repo in "${repos[@]}"; do
  repo="$(cd "$repo" && pwd)"
  out="$( { scan_markdown "$repo"; scan_code "$repo"; } || true )"
  stale_entries "$repo" || stale=$((stale + $?))
  if [ -n "$out" ]; then
    # Prefix only when several repositories are in play: with one, it turns a
    # real path into one that does not exist.
    if [ "${#repos[@]}" -gt 1 ]; then
      # shellcheck disable=SC2001  # a per-line prefix, not a single substitution
      out="$(echo "$out" | sed "s|^|$(basename "$repo")/|")"
    fi
    echo "$out"
    hits=$(( hits + $(echo "$out" | wc -l) ))
  fi
done

if [ "$hits" -gt 0 ] || [ "$stale" -gt 0 ]; then
  echo
  [ "$hits" -eq 0 ] || echo "✗ $hits line(s) of French where English is canonical." >&2
  [ "$stale" -eq 0 ] || echo "✗ $stale stale .languageignore entr(y/ies)." >&2
  echo "  Translate them, or move the file to <name>.fr.md and write the English one." >&2
  exit 1
fi
echo "✓ no French found outside *.fr.md"
