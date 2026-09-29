#!/usr/bin/env bash
# run-tests.sh — run a command inside a given image, with the workspace
# mounted, so every job reuses the one image build-image.sh produced instead
# of rebuilding or reinstalling toolchains.
#
# Usage:
#   run-tests.sh --image REF [options] -- <command> [args...]
#   run-tests.sh --image REF [options] --cmd '<shell string>'
#
# Options:
#   --image REF        image to run (required); pulled if not present
#   --workdir DIR      working directory inside the container (default: /work)
#   --workspace DIR    host directory mounted at --workdir (default: $PWD)
#   --no-mount         do not mount the workspace (image already has the code)
#   --env K[=V]        environment variable (repeatable; K alone passes it through)
#   --env-file FILE    docker --env-file
#   --volume H:C       extra bind mount or named volume (repeatable), e.g. a
#                      restored cache directory: "$HOME/.cache/go-build:/root/.cache/go-build"
#   --network NAME     docker network (e.g. a compose project's network)
#   --user UID:GID     run as this user (default: the image's user). Use
#                      "host" for the current uid:gid so mounted files stay writable.
#   --entrypoint EP    override the image entrypoint
#   --pull POLICY      missing (default) | always | never
#
# Exit status is the command's exit status.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

image="" workdir="/work" workspace="$PWD" mount=true network="" user="" entrypoint="" pull="missing" cmd=""
envs=() env_files=() volumes=()

while [ $# -gt 0 ]; do
  case "$1" in
    --image) image="$2"; shift 2 ;;
    --workdir) workdir="$2"; shift 2 ;;
    --workspace) workspace="$2"; shift 2 ;;
    --no-mount) mount=false; shift ;;
    --env) envs+=("$2"); shift 2 ;;
    --env-file) env_files+=("$2"); shift 2 ;;
    --volume) volumes+=("$2"); shift 2 ;;
    --network) network="$2"; shift 2 ;;
    --user) user="$2"; shift 2 ;;
    --entrypoint) entrypoint="$2"; shift 2 ;;
    --pull) pull="$2"; shift 2 ;;
    --cmd) cmd="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (put the command after --)" 2 ;;
  esac
done

[ -n "$image" ] || die "--image is required" 2
[ -n "$cmd" ] || [ $# -gt 0 ] || die "no command given (use -- <command> or --cmd)" 2

args=(run --rm --pull "$pull")
# A TTY only when there is one; CI has none and -t would fail there.
[ -t 0 ] && [ -t 1 ] && args+=(-it)
if $mount; then args+=(--volume "$(cd "$workspace" && pwd):$workdir"); fi
args+=(--workdir "$workdir")
for e in "${envs[@]+"${envs[@]}"}"; do args+=(--env "$e"); done
for f in "${env_files[@]+"${env_files[@]}"}"; do args+=(--env-file "$f"); done
for v in "${volumes[@]+"${volumes[@]}"}"; do args+=(--volume "$v"); done
[ -n "$network" ] && args+=(--network "$network")
if [ "$user" = "host" ]; then args+=(--user "$(id -u):$(id -g)"); elif [ -n "$user" ]; then args+=(--user "$user"); fi
[ -n "$entrypoint" ] && args+=(--entrypoint "$entrypoint")
args+=("$image")
if [ -n "$cmd" ]; then args+=(sh -c "$cmd"); else args+=("$@"); fi

log "running in $image"
exec docker "${args[@]}"
