#!/usr/bin/env bash
# pass-cache.sh — skip a job whose exact inputs already passed.
#
# A job's result depends only on its inputs: the source it tests, the
# lockfiles, the image, the CI definition. Hash those, and if a "passed"
# marker for that hash exists, the job does not need to run again. This is
# what makes re-pushes, rebases, docs-only commits and the post-merge push
# to the default branch nearly free.
#
# Usage:
#   pass-cache.sh key   --name JOB --path P [--path P]... [--salt S]...
#       Print key=pass-<job>-<hash>. Pure computation — the platform wrapper
#       looks the key up in its native cache (GitHub/GitLab cache) and saves
#       a marker after the job succeeds.
#   pass-cache.sh check --key KEY --backend registry --ref REGISTRY/REPO
#   pass-cache.sh save  --key KEY --backend registry --ref REGISTRY/REPO
#       For platforms without a usable cache: the marker is an empty image
#       tagged KEY in a registry repository. check prints hit=true|false.
#   pass-cache.sh check|save --key KEY --backend dir --ref DIR
#       Marker files in a directory (a mounted volume or a persistent runner).
#
# Put everything that can change the outcome into --path/--salt: the
# workflow file, the toolkit version (added automatically), tool versions,
# and any env that alters behaviour. A missing input means a false skip.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

sub="${1:-}"; [ $# -gt 0 ] && shift
name="" key="" backend="" ref=""
paths=() salts=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --path) paths+=("$2"); shift 2 ;;
    --salt) salts+=("$2"); shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --backend) backend="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
done

need_key() { [ -n "$key" ] || die "--key is required" 2; [[ "$key" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid key: $key" 2; }

case "$sub" in
  key)
    [ -n "$name" ] || die "--name is required" 2
    [ ${#paths[@]} -gt 0 ] || die "at least one --path is required" 2
    # The toolkit's own scripts are an input too: a fixed bug here must not
    # leave markers recorded by the buggy version in force.
    self="$(hash_paths -- "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"
    h="$(hash_paths "toolkit=$CI_TOOLKIT_VERSION" "toolkit-scripts=$self" "name=$name" "${salts[@]+"${salts[@]}"}" -- "${paths[@]}")"
    emit key "pass-$(slug "$name")-${h:0:24}"
    ;;
  check|save)
    need_key
    [ -n "$ref" ] || die "--ref is required" 2
    case "$backend" in
      dir)
        if [ "$sub" = check ]; then
          if [ -f "$ref/$key" ]; then emit hit true; else emit hit false; fi
        else
          mkdir -p "$ref"; date -u +%Y-%m-%dT%H:%M:%SZ > "$ref/$key"; emit saved true
        fi
        ;;
      registry)
        target="$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]'):$key"
        if [ "$sub" = check ]; then
          if docker buildx imagetools inspect "$target" >/dev/null 2>&1; then emit hit true; else emit hit false; fi
        else
          # An empty image: a manifest and a config, no layers — bytes, not MBs.
          printf 'FROM scratch\nLABEL dev.ci-toolkit.pass=%s\n' "$key" \
            | docker buildx build --quiet --push --tag "$target" - >/dev/null
          emit saved true
        fi
        ;;
      *) die "--backend must be registry or dir" 2 ;;
    esac
    ;;
  *) die "usage: pass-cache.sh key|check|save [options] (see --help)" 2 ;;
esac
