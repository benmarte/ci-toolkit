#!/usr/bin/env bash
# prune-images.sh — delete image versions nothing needs any more, so registry
# storage stays inside its budget. Content-addressed tags (in-<hash>) pile up
# one per input change; only the recent ones are ever reused.
#
# Keeps, per package:
#   - the newest --keep versions (by last update),
#   - anything updated within --keep-days,
#   - any version with a tag matching --protect (extended regex).
# Deletes everything else, including untagged versions left behind when a
# tag moved (past --untagged-hours).
#
# Usage:
#   prune-images.sh --registry ghcr --owner RIZQ-TECH --package dycotomic-platform/test \
#     [--owner-type auto|org|user] [--keep 5] [--keep-days 7] [--untagged-hours 6] \
#     [--protect '^(latest|v[0-9].*|buildcache.*)$'] [--keep-untagged] [--dry-run]
#   --package may be repeated; --all-packages prunes every container package of the owner
#   whose name starts with --prefix (e.g. the repo name).
#
# Registries: ghcr (gh CLI; token needs delete rights on the package — a
# workflow GITHUB_TOKEN with packages:write has them for packages its repo
# published). Others: TODO (acr: az acr repository delete; gitlab: cleanup policies).
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

registry="ghcr" owner="" owner_type="auto" keep=5 keep_days=7 untagged_hours=6 dry_run=false all=false prefix="" keep_untagged=false
protect='^(latest|v[0-9].*|buildcache.*)$'
packages=()
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) registry="$2"; shift 2 ;;
    --owner) owner="$2"; shift 2 ;;
    --owner-type) owner_type="$2"; shift 2 ;;
    --package) packages+=("$2"); shift 2 ;;
    --all-packages) all=true; shift ;;
    --prefix) prefix="$2"; shift 2 ;;
    --keep) keep="$2"; shift 2 ;;
    --keep-days) keep_days="$2"; shift 2 ;;
    --untagged-hours) untagged_hours="$2"; shift 2 ;;
    --protect) protect="$2"; shift 2 ;;
    --keep-untagged) keep_untagged=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
done
[ "$registry" = ghcr ] || die "only --registry ghcr is implemented" 2
[ -n "$owner" ] || die "--owner is required" 2
command -v gh >/dev/null || die "gh CLI not found" 2
if [ "$owner_type" = auto ]; then
  case "$(gh api "users/$owner" --jq .type 2>/dev/null)" in Organization) owner_type=org ;; *) owner_type=user ;; esac
fi
case "$owner_type" in org) base="orgs/$owner" ;; user) base="users/$owner" ;; *) die "--owner-type org|user" 2 ;; esac
[[ "$keep" =~ ^[0-9]+$ && "$keep_days" =~ ^[0-9]+$ && "$untagged_hours" =~ ^[0-9]+$ ]] || die "numeric options must be integers" 2

if $all; then
  while IFS= read -r p; do packages+=("$p"); done < <(
    gh api "$base/packages?package_type=container&per_page=100" --paginate --jq '.[].name' \
      | { if [ -n "$prefix" ]; then grep -E "^${prefix}(/|$)" || true; else cat; fi; })
fi
[ ${#packages[@]} -gt 0 ] || { log "no packages to prune"; exit 0; }

now="$(date -u +%s)"
total_deleted=0
for pkg in "${packages[@]}"; do
  enc="$(printf '%s' "$pkg" | sed 's#/#%2F#g')"
  # id <TAB> updated epoch <TAB> comma-joined tags; newest first.
  versions="$(gh api "$base/packages/container/$enc/versions?per_page=100" --paginate \
    --jq '.[] | [.id, (.updated_at | fromdate), ((.metadata.container.tags // []) | join(","))] | @tsv' \
    | sort -t$'\t' -k2,2nr)" || { log "cannot list $pkg (missing or no access) — skipped"; continue; }
  [ -n "$versions" ] || continue

  rank=0 deleted=0
  while IFS=$'\t' read -r id updated tags; do
    age=$(( now - updated ))
    if [ -z "$tags" ]; then
      # Untagged: an old copy of a moved tag (e.g. a rewritten registry cache).
      # For MULTI-PLATFORM images the per-platform manifests are untagged too
      # and deleting them breaks the tagged index — pass --keep-untagged for
      # those packages. build-image.sh builds single-platform images without
      # provenance/SBOM children by default, so they have none.
      $keep_untagged && continue
      [ "$age" -lt $(( untagged_hours * 3600 )) ] && continue
    else
      rank=$((rank + 1))
      if printf '%s' "$tags" | tr ',' '\n' | grep -Eq "$protect"; then continue; fi
      [ "$rank" -le "$keep" ] && continue
      [ "$age" -lt $(( keep_days * 86400 )) ] && continue
    fi
    if $dry_run; then
      log "would delete $pkg version $id (${tags:-untagged}, $((age / 3600))h old)"
    else
      if gh api -X DELETE "$base/packages/container/$enc/versions/$id" >/dev/null; then
        log "deleted $pkg version $id (${tags:-untagged})"
      else
        log "could not delete $pkg version $id — skipped"
      fi
    fi
    deleted=$((deleted + 1))
  done <<< "$versions"
  verb="deleted"; if $dry_run; then verb="would be deleted"; fi
  log "$pkg: $deleted version(s) $verb"
  total_deleted=$((total_deleted + deleted))
done
emit deleted "$total_deleted"
