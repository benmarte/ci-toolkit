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
# Content hash of the given paths (names, contents and file modes), plus salts.
#
# Inside a git work tree a path hashes to git's own tree/blob id for it,
# computed from a throw-away copy of the index with the working tree's
# tracked changes applied (git add -u into a temp index, then write-tree).
# So: uncommitted edits, deletions, chmod +x and odd file names all count;
# untracked and ignored files (node_modules, build output, anything a CI step
# drops in the workspace) do not.
#
# Anything git cannot vouch for falls back to hashing every file under the
# path directly: a path outside git, a path with no tracked files (a
# gitignored dist/, a generated Dockerfile), or any git error. The fallback
# only ever includes MORE, so it can cost a cache hit but never cause a
# false one. Missing paths hash as "missing:<path>" so callers can list
# optional inputs.
hash_paths() {
  local salts=() paths=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; paths=("$@"); break; fi
    salts+=("$1"); shift
  done
  [ ${#paths[@]} -gt 0 ] || paths=(.)
  {
    printf 'ci-toolkit-hash-v2\n'
    local s p id
    for s in "${salts[@]+"${salts[@]}"}"; do printf 'salt:%s\n' "$s"; done
    for p in "${paths[@]}"; do
      if [ ! -e "$p" ] && [ ! -L "$p" ]; then printf 'missing:%s\n' "$p"; continue; fi
      if id="$(_git_path_id "$p")"; then
        printf 'git:%s:%s\n' "$p" "$id"
      else
        printf 'files:%s\n' "$p"
        _hash_files "$p"
      fi
    done
  } | sha256
}

# _git_path_id PATH — git object id of PATH as it is in the working tree
# (tracked files only). Fails when PATH is not in a work tree, has no
# tracked content, or git errors; the caller then hashes files directly.
_git_path_id() {
  local p="$1" dir base top prefix rel idx tmp tree id
  if [ -d "$p" ]; then dir="$p"; base=""; else dir="$(dirname "$p")"; base="$(basename "$p")"; fi
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  prefix="$(git -C "$dir" rev-parse --show-prefix 2>/dev/null)" || return 1
  rel="${prefix}${base}"; rel="${rel%/}"
  idx="$(git -C "$top" rev-parse --absolute-git-dir 2>/dev/null)/index" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/ci-toolkit-index.XXXXXX")" || return 1
  if [ -f "$idx" ]; then cp "$idx" "$tmp"; else rm -f "$tmp"; fi
  # add -u stages modifications and deletions of tracked files only.
  if GIT_INDEX_FILE="$tmp" git -C "$top" add -u -- "${rel:-.}" >/dev/null 2>&1 \
     && tree="$(GIT_INDEX_FILE="$tmp" git -C "$top" write-tree 2>/dev/null)"; then
    if [ -z "$rel" ]; then id="$tree"; else id="$(git -C "$top" rev-parse -q --verify "$tree:$rel" 2>/dev/null)" || id=""; fi
  fi
  rm -f "$tmp"
  [ -n "${id:-}" ] || return 1
  printf '%s' "$id"
}

# _hash_files PATH — "<sha256> <x|-> <path>" for every file under PATH,
# sorted. Newline-separated so busybox sort works; the exec bit stands in
# for the mode since stat(1) flags differ across platforms.
_hash_files() ( # subshell: the cd below must not leak to the caller
  f="" root="$1"
  # Paths are recorded relative to the hashed path, so the same content at
  # another location (a temp copy, another checkout dir) hashes the same.
  if [ -d "$root" ]; then cd "$root" || return 1; root="."; fi
  find "$root" \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then
      printf 'link %s %s\n' "$(readlink "$f")" "$f"
    else
      printf '%s %s %s\n' "$(sha256 < "$f")" "$([ -x "$f" ] && echo x || echo -)" "$f"
    fi
  done
)

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

# image_digest REF — the registry digest REF resolves to (sha256:...), or
# nothing when REF is not in a registry. No pull.
image_digest() {
  local d
  d="$(docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null)" || return 0
  case "$d" in sha256:*) printf '%s' "$d" ;; esac
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Lower-case, registry-safe slug.
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | sed 's/--*/-/g; s/^-//; s/-$//'; }
