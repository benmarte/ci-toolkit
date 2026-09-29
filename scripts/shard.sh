#!/usr/bin/env bash
# shard.sh — split a test run into N shards.
#
# Sharding cuts wall-clock time, not billed minutes: every extra shard pays
# its own runner start-up, checkout and image pull. Use it when the suite is
# long enough that start-up is small next to it.
#
# Usage:
#   shard.sh --matrix N
#       Print a JSON array [1,2,...,N] for a CI matrix.
#   shard.sh --total N --index I --mode runner
#       Print the runner's native flag: --shard=I/N (Playwright, Vitest, Jest).
#   shard.sh --total N --index I --mode files --glob 'e2e/**/*.spec.ts' [--timings FILE]
#       Print this shard's files, one per line. Without timings files are
#       dealt round-robin in sorted order; with a timings file ("<seconds> <path>"
#       per line) they are bin-packed longest-first so shards finish together.
#
# I is 1-based. Output is deterministic for the same inputs.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

total="" index="" mode="runner" timings="" matrix=""
globs=()

while [ $# -gt 0 ]; do
  case "$1" in
    --total) total="$2"; shift 2 ;;
    --index) index="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --glob) globs+=("$2"); shift 2 ;;
    --timings) timings="$2"; shift 2 ;;
    --matrix) matrix="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
done

is_pos_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

if [ -n "$matrix" ]; then
  is_pos_int "$matrix" || die "--matrix must be a positive integer" 2
  out="["
  for ((i = 1; i <= matrix; i++)); do out+="$i"; [ "$i" -lt "$matrix" ] && out+=","; done
  printf '%s]\n' "$out"
  exit 0
fi

is_pos_int "$total" || die "--total must be a positive integer" 2
is_pos_int "$index" || die "--index must be a positive integer" 2
[ "$index" -le "$total" ] || die "--index $index is greater than --total $total" 2

case "$mode" in
  runner) printf -- '--shard=%s/%s\n' "$index" "$total" ;;
  files)
    [ ${#globs[@]} -gt 0 ] || die "--mode files needs at least one --glob" 2
    files=()
    while IFS= read -r f; do files+=("$f"); done < <(
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git ls-files -- "${globs[@]}"
      else
        # Outside git: let bash expand the globs (globstar for **).
        shopt -s globstar nullglob
        for g in "${globs[@]}"; do for f in $g; do [ -f "$f" ] && printf '%s\n' "$f"; done; done
      fi | LC_ALL=C sort -u)
    [ ${#files[@]} -gt 0 ] || { log "no files matched: ${globs[*]}"; exit 0; }

    if [ -z "$timings" ]; then
      i=0
      for f in "${files[@]}"; do
        [ $((i % total + 1)) -eq "$index" ] && printf '%s\n' "$f"
        i=$((i + 1))
      done
    else
      [ -f "$timings" ] || die "timings file not found: $timings" 2
      # Greedy longest-processing-time: assign each file (heaviest first) to
      # the currently lightest shard. Unknown files get the median weight.
      printf '%s\n' "${files[@]}" | awk -v total="$total" -v want="$index" '
        NR == FNR { t[$2] = $1; next }
        { f[++n] = $0 }
        END {
          m = 0; for (k in t) v[++m] = t[k]
          # median of known timings (1 when none)
          for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (v[j] < v[i]) { x = v[i]; v[i] = v[j]; v[j] = x }
          med = (m > 0) ? v[int((m + 1) / 2)] : 1
          for (i = 1; i <= n; i++) w[i] = (f[i] in t) ? t[f[i]] : med
          # order by weight desc, then path asc (deterministic)
          for (i = 1; i <= n; i++) o[i] = i
          for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
            if (w[o[j]] > w[o[i]] || (w[o[j]] == w[o[i]] && f[o[j]] < f[o[i]])) { x = o[i]; o[i] = o[j]; o[j] = x }
          for (s = 1; s <= total; s++) load[s] = 0
          for (i = 1; i <= n; i++) {
            best = 1; for (s = 2; s <= total; s++) if (load[s] < load[best]) best = s
            load[best] += w[o[i]]; owner[o[i]] = best
          }
          for (i = 1; i <= n; i++) if (owner[i] == want) print f[i]
        }' "$timings" -
    fi
    ;;
  *) die "unknown --mode: $mode (runner|files)" 2 ;;
esac
