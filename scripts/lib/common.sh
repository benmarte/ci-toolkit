#!/usr/bin/env bash
# Shared helpers for the ci-toolkit scripts. Sourced, never executed.
# Everything here is platform-agnostic: no GitHub/GitLab/Azure variables.

# shellcheck disable=SC2034 # read by the scripts that source this file
CI_TOOLKIT_VERSION="1.0.0"

log() { printf '[ci-toolkit] %s\n' "$*" >&2; }
die() { printf '[ci-toolkit] error: %s\n' "$*" >&2; exit "${2:-1}"; }

# sha256 of stdin, hex only. macOS ships shasum, Linux sha256sum.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# hash_paths [salt...] -- path...
# Content hash of every file under the given paths. Inside a git work tree
# only TRACKED files count (their working-tree content, so uncommitted edits
# do count), so node_modules, build output, caches and anything a CI step
# drops into the workspace never change the hash; outside git every regular
# file counts. A new file must be `git add`ed to affect the hash.
# The hash covers file paths and contents, so a rename changes it too.
# Missing paths are hashed as "missing:<path>" rather than failing, so a
# caller can list optional inputs.
hash_paths() {
  local salts=() paths=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; paths=("$@"); break; fi
    salts+=("$1"); shift
  done
  [ ${#paths[@]} -gt 0 ] || paths=(.)
  {
    printf 'ci-toolkit-hash-v1\n'
    local s
    for s in "${salts[@]+"${salts[@]}"}"; do printf 'salt:%s\n' "$s"; done
    local p
    for p in "${paths[@]}"; do
      if [ ! -e "$p" ]; then printf 'missing:%s\n' "$p"; continue; fi
      if git -C "$(dirname "$p")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # The index already holds every tracked file's blob hash, so a clean
        # tree costs one git call however large the repo. Files edited since
        # the index was written are re-hashed from the working tree in one
        # batch; deleted ones are dropped.
        local modified
        modified="$(git ls-files -m -- "$p")"
        {
          git ls-files -s -- "$p" | awk -F'\t' '{ split($1, m, " "); print m[2] " " $2 }'
          if [ -n "$modified" ]; then
            printf '%s\n' "$modified" | while IFS= read -r f; do
              if [ -f "$f" ]; then printf 'M %s\n' "$f"; else printf 'D %s\n' "$f"; fi
            done
          fi
        } | awk -v hashes="$(printf '%s\n' "$modified" | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done | git hash-object --stdin-paths 2>/dev/null | tr '\n' ' ')" '
          BEGIN { n = split(hashes, h, " ") }
          $1 == "M" { sub(/^M /, ""); fresh[$0] = h[++i]; next }
          $1 == "D" { sub(/^D /, ""); gone[$0] = 1; next }
          { blob = $1; sub(/^[^ ]+ /, ""); order[++k] = $0; idx[$0] = blob }
          END { for (j = 1; j <= k; j++) { f = order[j]; if (f in gone) continue; print ((f in fresh) ? fresh[f] : idx[f]) " " f } }
        ' | LC_ALL=C sort -k2
      else
        find "$p" -type f -print0 2>/dev/null | LC_ALL=C sort -z \
          | while IFS= read -r -d '' f; do
              printf '%s %s\n' "$(sha256 < "$f")" "$f"
            done
      fi
    done
  } | sha256
}

# emit KEY VALUE: write one output as KEY=VALUE to stdout and, when
# CI_TOOLKIT_OUTPUT names a file, append it there too. That file format
# (KEY=VALUE, or KEY<<DELIM for multi-line) is what GitHub's $GITHUB_OUTPUT
# expects and is trivial to source or parse on GitLab/Azure.
emit() {
  local key="$1" value="$2"
  if [[ "$value" == *$'\n'* ]]; then
    local delim="CI_TOOLKIT_EOF_$RANDOM$RANDOM"
    printf '%s<<%s\n%s\n%s\n' "$key" "$delim" "$value" "$delim"
    if [ -n "${CI_TOOLKIT_OUTPUT:-}" ]; then
      printf '%s<<%s\n%s\n%s\n' "$key" "$delim" "$value" "$delim" >> "$CI_TOOLKIT_OUTPUT"
    fi
  else
    printf '%s=%s\n' "$key" "$value"
    if [ -n "${CI_TOOLKIT_OUTPUT:-}" ]; then
      printf '%s=%s\n' "$key" "$value" >> "$CI_TOOLKIT_OUTPUT"
    fi
  fi
}

# Lower-case, registry-safe slug.
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | sed 's/--*/-/g; s/^-//; s/-$//'; }
