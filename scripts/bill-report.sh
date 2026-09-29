#!/usr/bin/env bash
# bill-report.sh — what did CI actually cost? Billed minutes per job and run.
#
# GitHub bills each hosted job rounded UP to the whole minute, so ten
# 10-second jobs cost ten minutes. Self-hosted jobs cost nothing but are
# reported (as "would bill") so you can price a move to hosted runners.
#
# Usage:
#   bill-report.sh --repo OWNER/REPO --run RUN_ID [--run RUN_ID]...
#   bill-report.sh --repo OWNER/REPO --since 2026-09-01 [--workflow ci.yml] [--limit 100]
#   add --per-job for one line per job; --rate USD to price (default 0.006, Linux 2-core)
#
# Platforms: github (needs the gh CLI, authenticated). gitlab/azure: TODO.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

platform="github" repo="" since="" workflow="" limit=100 per_job=false rate="0.006"
runs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --run) runs+=("$2"); shift 2 ;;
    --since) since="$2"; shift 2 ;;
    --workflow) workflow="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    --per-job) per_job=true; shift ;;
    --rate) rate="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
done
[ "$platform" = github ] || die "only --platform github is implemented" 2
[ -n "$repo" ] || die "--repo is required" 2
command -v gh >/dev/null || die "gh CLI not found" 2

if [ ${#runs[@]} -eq 0 ]; then
  [ -n "$since" ] || die "give --run or --since" 2
  path="repos/$repo/actions/runs"
  [ -n "$workflow" ] && path="repos/$repo/actions/workflows/$workflow/runs"
  while IFS= read -r id; do runs+=("$id"); done < <(
    gh api "$path?per_page=100&created=>=$since" --paginate --jq '.workflow_runs[].id' | head -n "$limit")
fi
[ ${#runs[@]} -gt 0 ] || { log "no runs found"; exit 0; }

# One TSV line per completed, non-skipped job:
# run_id  workflow  event  job  seconds  hosted(1|0)
for id in "${runs[@]}"; do
  meta="$(gh api "repos/$repo/actions/runs/$id" --jq '[.name, .event] | @tsv')"
  gh api "repos/$repo/actions/runs/$id/jobs?per_page=100" --paginate --jq \
    '.jobs[] | select(.conclusion != "skipped" and .completed_at != null and .started_at != null)
     | [.name, ((.completed_at | fromdate) - (.started_at | fromdate)),
        (if ((.labels // []) | index("self-hosted")) then 0 else 1 end)] | @tsv' \
    | while IFS=$'\t' read -r job secs hosted; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$meta" "$job" "$secs" "$hosted"
      done
done | awk -F'\t' -v per_job="$per_job" -v rate="$rate" '
  function ceilmin(s) { return (s <= 0) ? 0 : int((s + 59) / 60) }
  {
    run = $1; wf = $2; job = $4; s = $5; hosted = $6
    b = ceilmin(s)
    if (per_job == "true") printf "%-12s %-28s %6.1f min  billed %3d%s\n", run, substr(job, 1, 28), s / 60, b, hosted ? "" : "  (self-hosted: would bill)"
    rb[run] += b; rs[run] += s; rw[run] = wf " / " $3; nj[run]++
    if (hosted) hb += b; else sb += b
    tb += b; ts += s; tj++
  }
  END {
    print ""
    printf "%-12s %-40s %5s %9s %8s\n", "run", "workflow / event", "jobs", "wall(min)", "billed"
    for (r in rb) printf "%-12s %-40s %5d %9.1f %8d\n", r, substr(rw[r], 1, 40), nj[r], rs[r] / 60, rb[r]
    print ""
    printf "jobs=%d  job-minutes=%.1f  billed-minutes=%d (hosted %d, self-hosted would-bill %d)\n", tj, ts / 60, tb, hb, sb
    printf "rounding overhead=%.1f min (%.0f%%)  cost at $%s/min: hosted $%.2f, all-hosted $%.2f\n", tb - ts / 60, (tb > 0) ? 100 * (tb - ts / 60) / tb : 0, rate, hb * rate, tb * rate
  }'
