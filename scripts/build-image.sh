#!/usr/bin/env bash
# build-image.sh — build a Docker image at most once per set of inputs.
#
# The tag is a content hash of the build inputs (Dockerfile, target, build
# args, platforms and every --hash-path). If that tag already exists in the
# registry the build is skipped entirely; otherwise the image is built with
# buildx against a shared registry cache (mode=max) and pushed.
#
# Usage:
#   build-image.sh --image ghcr.io/org/repo/api [options]
#
# Options:
#   --image REF          registry/repository to push to (required, no tag)
#   --file PATH          Dockerfile (default: <context>/Dockerfile)
#   --context DIR        build context (default: .)
#   --target NAME        multi-stage target
#   --hash-path PATH     input that affects the image (repeatable). Default:
#                        the whole context. The Dockerfile is always included.
#   --build-arg K=V      build argument (repeatable, part of the hash)
#   --platform LIST      e.g. linux/amd64 or linux/amd64,linux/arm64
#   --tag-prefix STR     prefix of the hash tag (default: in-)
#   --extra-tag TAG      additional tag to push, e.g. the commit sha (repeatable)
#   --cache-backend B    registry (default) | gha | local | none
#   --cache-ref REF      registry cache ref (default: <image>:buildcache[-<target>])
#   --cache-dir DIR      directory for --cache-backend local
#   --load               build into the local daemon instead of pushing
#                        (existence is then checked locally)
#   --force              build even if the tag exists
#   --dry-run            print the resolved tag and whether it exists; no build
#
# Outputs (stdout, and appended to $CI_TOOLKIT_OUTPUT when set):
#   image=<ref:tag>  hash=<hash>  tag=<tag>  built=true|false
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

image="" file="" context="." target="" platform="" tag_prefix="in-"
cache_backend="registry" cache_ref="" cache_dir="" load=false force=false dry_run=false
hash_paths_in=() build_args=() extra_tags=()

while [ $# -gt 0 ]; do
  case "$1" in
    --image) image="$2"; shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --context) context="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    --hash-path) hash_paths_in+=("$2"); shift 2 ;;
    --build-arg) build_args+=("$2"); shift 2 ;;
    --platform) platform="$2"; shift 2 ;;
    --tag-prefix) tag_prefix="$2"; shift 2 ;;
    --extra-tag) extra_tags+=("$2"); shift 2 ;;
    --cache-backend) cache_backend="$2"; shift 2 ;;
    --cache-ref) cache_ref="$2"; shift 2 ;;
    --cache-dir) cache_dir="$2"; shift 2 ;;
    --load) load=true; shift ;;
    --force) force=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
done

[ -n "$image" ] || die "--image is required" 2
# A registry port (localhost:5000/x) is fine; a tag or digest on the last
# path component is not — the tag is ours to compute.
case "${image##*/}" in *:*|*@*) die "--image must not carry a tag or digest: $image" 2 ;; esac
image="$(printf '%s' "$image" | tr '[:upper:]' '[:lower:]')"
[ -n "$file" ] || file="$context/Dockerfile"
[ -f "$file" ] || die "Dockerfile not found: $file" 2
[ ${#hash_paths_in[@]} -gt 0 ] || hash_paths_in=("$context")

# Build args and platforms change the image, so they are part of the key.
salts=("file=$file" "target=$target" "platform=$platform")
for a in "${build_args[@]+"${build_args[@]}"}"; do salts+=("arg=$a"); done
hash="$(hash_paths "${salts[@]}" -- "$file" "${hash_paths_in[@]}")"
tag="${tag_prefix}${hash:0:20}"
ref="${image}:${tag}"

exists() {
  if $load; then
    docker image inspect "$1" >/dev/null 2>&1
  else
    docker buildx imagetools inspect "$1" >/dev/null 2>&1
  fi
}

found=false
if exists "$ref"; then found=true; fi

if $dry_run; then
  emit image "$ref"; emit hash "$hash"; emit tag "$tag"; emit exists "$found"
  exit 0
fi

if $found && ! $force; then
  log "cache hit: $ref already exists — skipping build"
  # Extra tags (e.g. the commit sha) still get attached, registry-side, with
  # no rebuild and no layer transfer.
  if ! $load; then
    for t in "${extra_tags[@]+"${extra_tags[@]}"}"; do
      docker buildx imagetools create --tag "${image}:${t}" "$ref" >&2
    done
  else
    for t in "${extra_tags[@]+"${extra_tags[@]}"}"; do docker tag "$ref" "${image}:${t}"; done
  fi
  emit image "$ref"; emit hash "$hash"; emit tag "$tag"; emit built false
  exit 0
fi

# buildx needs a docker-container builder for registry/gha cache export; the
# default "docker" driver cannot export cache. Reuse ours if it exists.
# Read the whole output (no early exit): stopping the pipe early can SIGPIPE
# docker, and pipefail would then abort the script.
driver="$(docker buildx inspect 2>/dev/null | awk '/^Driver:/ && !d { d = $2 } END { print d }' || true)"
if [ "$cache_backend" != "none" ] && [ "$driver" = "docker" ]; then
  docker buildx inspect ci-toolkit >/dev/null 2>&1 \
    || docker buildx create --name ci-toolkit --driver docker-container >/dev/null
  builder=(--builder ci-toolkit)
else
  builder=()
fi

cache_args=()
case "$cache_backend" in
  registry)
    [ -n "$cache_ref" ] || cache_ref="${image}:buildcache${target:+-$target}"
    cache_args=(--cache-from "type=registry,ref=$cache_ref")
    # --load builds have nowhere authorised to push, so they only read the cache.
    $load || cache_args+=(--cache-to "type=registry,ref=$cache_ref,mode=max,image-manifest=true,oci-mediatypes=true,ignore-error=true")
    ;;
  gha)
    scope="$(slug "${image##*/}${target:+-$target}")"
    cache_args=(--cache-from "type=gha,scope=$scope" --cache-to "type=gha,scope=$scope,mode=max,ignore-error=true")
    ;;
  local)
    [ -n "$cache_dir" ] || die "--cache-backend local needs --cache-dir" 2
    cache_args=(--cache-from "type=local,src=$cache_dir" --cache-to "type=local,dest=$cache_dir.new,mode=max")
    ;;
  none) ;;
  *) die "unknown --cache-backend: $cache_backend" 2 ;;
esac

args=(buildx build "${builder[@]+"${builder[@]}"}" --file "$file" --tag "$ref" --label "org.opencontainers.image.revision=${CI_COMMIT_SHA:-${GITHUB_SHA:-${BUILD_SOURCEVERSION:-}}}" --label "dev.ci-toolkit.input-hash=$hash")
for t in "${extra_tags[@]+"${extra_tags[@]}"}"; do args+=(--tag "${image}:${t}"); done
[ -n "$target" ] && args+=(--target "$target")
[ -n "$platform" ] && args+=(--platform "$platform")
for a in "${build_args[@]+"${build_args[@]}"}"; do args+=(--build-arg "$a"); done
args+=("${cache_args[@]+"${cache_args[@]}"}")
if $load; then args+=(--load); else args+=(--push); fi
args+=("$context")

log "building $ref"
docker "${args[@]}" >&2

# Rotate the local cache so it does not grow without bound (buildx docs).
if [ "$cache_backend" = "local" ] && [ -d "$cache_dir.new" ]; then
  rm -rf "$cache_dir"; mv "$cache_dir.new" "$cache_dir"
fi

emit image "$ref"; emit hash "$hash"; emit tag "$tag"; emit built true
