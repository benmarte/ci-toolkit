#!/usr/bin/env bash
# detect-cache.sh — detect the package managers in a repo and print the
# directories worth caching plus a cache key derived from their lockfiles.
#
# Usage:
#   detect-cache.sh [--dir DIR] [--manager NAME]... [--prefix STR] [--os NAME]
#
#   --dir DIR        repo root to inspect (default: .)
#   --manager NAME   restrict to these managers (repeatable). Known:
#                    go bun npm pnpm yarn pip poetry uv cargo
#   --prefix STR     key prefix (default: ci-toolkit)
#   --os NAME        OS component of the key (default: uname -s, lower-cased)
#
# Outputs (stdout, and appended to $CI_TOOLKIT_OUTPUT when set):
#   managers=<space-separated list>
#   key=<prefix>-<os>-<managers>-<lockfile hash>
#   restore-keys=<prefix>-<os>-<managers>-    (a prefix: any older cache for
#                                             the same managers is a good start)
#   paths=<one directory per line>
#
# Nothing is created or restored; the platform wrapper does that.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

dir="." prefix="ci-toolkit" os="$(uname -s | tr '[:upper:]' '[:lower:]')"
only=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --manager) only+=("$2"); shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --os) os="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
done
cd "$dir"

wanted() {
  [ ${#only[@]} -eq 0 ] && return 0
  local m; for m in "${only[@]}"; do [ "$m" = "$1" ] && return 0; done; return 1
}

# find_files NAME... — tracked files with these basenames anywhere in the
# repo (vendored node_modules excluded); falls back to find outside git.
find_files() {
  local pats=() n
  for n in "$@"; do pats+=("$n" "**/$n"); done
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -- "${pats[@]}" | grep -v '/node_modules/' || true
  else
    local args=() first=true
    for n in "$@"; do $first || args+=(-o); args+=(-name "$n"); first=false; done
    find . -path ./node_modules -prune -o -path '*/node_modules' -prune -o \( "${args[@]}" \) -type f -print | sed 's#^\./##'
  fi
}

managers=() lockfiles=() paths=()
add() { # add MANAGER "lockfile..." "path..."
  local m="$1"; shift
  managers+=("$m")
  local l; for l in $1; do lockfiles+=("$l"); done
  shift
  local p; for p in "$@"; do paths+=("$p"); done
}

# Resolve a tool's own cache location when the tool is installed, since users
# and images relocate them; otherwise fall back to the documented default.
goenv() { if command -v go >/dev/null 2>&1; then go env "$1" 2>/dev/null || true; fi; }

if wanted go; then
  lf="$(find_files go.sum | tr '\n' ' ')"
  [ -z "$lf" ] && [ -n "$(find_files go.mod)" ] && lf="$(find_files go.mod | tr '\n' ' ')"
  if [ -n "$lf" ]; then
    modcache="$(goenv GOMODCACHE)"; gocache="$(goenv GOCACHE)"
    [ -n "$modcache" ] || modcache="$HOME/go/pkg/mod"
    if [ -z "$gocache" ]; then
      if [ "$os" = "darwin" ]; then gocache="$HOME/Library/Caches/go-build"; else gocache="$HOME/.cache/go-build"; fi
    fi
    add go "$lf" "$modcache" "$gocache"
  fi
fi
if wanted bun; then
  lf="$(find_files bun.lock bun.lockb | tr '\n' ' ')"
  [ -n "$lf" ] && add bun "$lf" "${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
fi
if wanted pnpm; then
  lf="$(find_files pnpm-lock.yaml | tr '\n' ' ')"
  if [ -n "$lf" ]; then
    store=""; if command -v pnpm >/dev/null 2>&1; then store="$(pnpm store path 2>/dev/null || true)"; fi
    add pnpm "$lf" "${store:-$HOME/.local/share/pnpm/store}"
  fi
fi
if wanted yarn; then
  lf="$(find_files yarn.lock | tr '\n' ' ')"
  if [ -n "$lf" ]; then
    ydir=""; if command -v yarn >/dev/null 2>&1; then ydir="$( (yarn config get cacheFolder 2>/dev/null || yarn cache dir 2>/dev/null) | tail -1)"; fi
    add yarn "$lf" "${ydir:-$HOME/.cache/yarn}"
  fi
fi
if wanted npm; then
  lf="$(find_files package-lock.json npm-shrinkwrap.json | tr '\n' ' ')"
  [ -n "$lf" ] && add npm "$lf" "${npm_config_cache:-$HOME/.npm}"
fi
if wanted uv; then
  lf="$(find_files uv.lock | tr '\n' ' ')"
  [ -n "$lf" ] && add uv "$lf" "${UV_CACHE_DIR:-$HOME/.cache/uv}"
fi
if wanted poetry; then
  lf="$(find_files poetry.lock | tr '\n' ' ')"
  [ -n "$lf" ] && add poetry "$lf" "$HOME/.cache/pypoetry"
fi
if wanted pip; then
  lf="$(find_files requirements.txt 'requirements*.txt' Pipfile.lock | tr '\n' ' ')"
  [ -n "$lf" ] && add pip "$lf" "${PIP_CACHE_DIR:-$HOME/.cache/pip}"
fi
if wanted cargo; then
  lf="$(find_files Cargo.lock | tr '\n' ' ')"
  [ -n "$lf" ] && add cargo "$lf" "${CARGO_HOME:-$HOME/.cargo}/registry" "${CARGO_HOME:-$HOME/.cargo}/git"
fi

if [ ${#managers[@]} -eq 0 ]; then
  log "no known package manager found in $(pwd)"
  emit managers ""; emit key ""; emit restore-keys ""; emit paths ""
  exit 0
fi

mlist="$(printf '%s\n' "${managers[@]}" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
mslug="$(printf '%s' "$mlist" | tr ' ' '-')"
lhash="$(hash_paths "managers=$mlist" -- "${lockfiles[@]}")"
plist="$(printf '%s\n' "${paths[@]}" | awk '!seen[$0]++')"

emit managers "$mlist"
emit key "${prefix}-${os}-${mslug}-${lhash:0:20}"
emit restore-keys "${prefix}-${os}-${mslug}-"
emit paths "$plist"
