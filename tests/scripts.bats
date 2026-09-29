#!/usr/bin/env bats
# Unit tests for scripts/. A fake `docker` on PATH records calls and answers
# "does this image exist?" from $FAKE_EXISTING, so the skip logic is tested
# without a daemon. tests/integration.sh covers the real registry path.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$ROOT/scripts"
  WORK="$(mktemp -d)"
  cd "$WORK"
  git init -q . && git config user.email t@t && git config user.name t
  mkdir -p src && echo 'package main' > src/main.go
  printf 'FROM alpine\nCOPY . .\n' > Dockerfile
  git add -A && git commit -qm init

  FAKEBIN="$WORK/.fakebin"; mkdir -p "$FAKEBIN"
  export DOCKER_LOG="$WORK/.docker.log" FAKE_EXISTING=""
  cat > "$FAKEBIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1 $2 $3" in
  "buildx imagetools inspect")
    for r in $FAKE_EXISTING; do
      if [ "$r" = "$4" ]; then
        [ "$5" = "--format" ] && printf '%s\n' "${FAKE_DIGEST:-sha256:aaaa}"
        exit 0
      fi
    done; exit 1 ;;
  "buildx inspect "*) echo "Driver: docker-container"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/docker"
  export PATH="$FAKEBIN:$PATH"
}

teardown() { rm -rf "$WORK"; }

# ---- hashing ---------------------------------------------------------------

@test "hash is stable and ignores untracked/ignored noise" {
  run "$S/build-image.sh" --image reg/x --dry-run
  h1="$(echo "$output" | sed -n 's/^hash=//p')"
  echo junk > untracked.txt
  mkdir -p node_modules && echo x > node_modules/y
  run "$S/build-image.sh" --image reg/x --dry-run
  h2="$(echo "$output" | sed -n 's/^hash=//p')"
  [ -n "$h1" ] && [ "$h1" = "$h2" ]
}

@test "hash changes when a tracked input changes" {
  run "$S/build-image.sh" --image reg/x --dry-run
  h1="$(echo "$output" | sed -n 's/^hash=//p')"
  echo '// edit' >> src/main.go
  run "$S/build-image.sh" --image reg/x --dry-run
  h2="$(echo "$output" | sed -n 's/^hash=//p')"
  [ "$h1" != "$h2" ]
}

@test "hash only covers --hash-path inputs" {
  run "$S/build-image.sh" --image reg/x --hash-path src --dry-run
  h1="$(echo "$output" | sed -n 's/^hash=//p')"
  echo notes > README.md && git add README.md && git commit -qm docs
  run "$S/build-image.sh" --image reg/x --hash-path src --dry-run
  h2="$(echo "$output" | sed -n 's/^hash=//p')"
  [ "$h1" = "$h2" ]
}

@test "build args and target are part of the hash" {
  a="$("$S/build-image.sh" --image reg/x --dry-run | sed -n 's/^hash=//p')"
  b="$("$S/build-image.sh" --image reg/x --build-arg V=2 --dry-run | sed -n 's/^hash=//p')"
  c="$("$S/build-image.sh" --image reg/x --target test --dry-run | sed -n 's/^hash=//p')"
  [ "$a" != "$b" ] && [ "$a" != "$c" ] && [ "$b" != "$c" ]
}

# ---- build-image skip logic ------------------------------------------------

@test "build-image skips the build when the tag exists" {
  ref="$("$S/build-image.sh" --image reg/x --dry-run | sed -n 's/^image=//p')"
  export FAKE_EXISTING="$ref"
  run "$S/build-image.sh" --image reg/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"built=false"* ]]
  [[ "$output" == *"image=$ref"* ]]
  ! grep -q "buildx build" "$DOCKER_LOG"
}

@test "build-image builds with a registry cache when the tag is missing" {
  run "$S/build-image.sh" --image reg/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"built=true"* ]]
  grep -q "buildx build" "$DOCKER_LOG"
  grep -q -- "--cache-to type=registry,ref=reg/x:buildcache,mode=max" "$DOCKER_LOG"
  grep -q -- "--push" "$DOCKER_LOG"
}

@test "a cache hit still attaches extra tags without building" {
  ref="$("$S/build-image.sh" --image reg/x --dry-run | sed -n 's/^image=//p')"
  export FAKE_EXISTING="$ref"
  run "$S/build-image.sh" --image reg/x --extra-tag sha-abc
  [ "$status" -eq 0 ]
  grep -q "imagetools create --tag reg/x:sha-abc $ref" "$DOCKER_LOG"
  ! grep -q "buildx build" "$DOCKER_LOG"
}

@test "build-image writes outputs to CI_TOOLKIT_OUTPUT" {
  export CI_TOOLKIT_OUTPUT="$WORK/out"
  "$S/build-image.sh" --image reg/x --dry-run >/dev/null
  grep -q '^image=reg/x:in-' "$WORK/out"
  grep -q '^exists=false' "$WORK/out"
}

@test "build-image rejects an image with a tag but allows a registry port" {
  run "$S/build-image.sh" --image reg/x:latest --dry-run
  [ "$status" -eq 2 ]
  run "$S/build-image.sh" --image localhost:5000/x --dry-run
  [ "$status" -eq 0 ]
}

# ---- pass-cache ------------------------------------------------------------

@test "pass-cache key is stable, name-scoped and input-sensitive" {
  k1="$("$S/pass-cache.sh" key --name unit --path src | sed -n 's/^key=//p')"
  k2="$("$S/pass-cache.sh" key --name unit --path src | sed -n 's/^key=//p')"
  k3="$("$S/pass-cache.sh" key --name lint --path src | sed -n 's/^key=//p')"
  [[ "$k1" == pass-unit-* ]] && [ "$k1" = "$k2" ] && [ "$k1" != "$k3" ]
  echo '// x' >> src/main.go
  k4="$("$S/pass-cache.sh" key --name unit --path src | sed -n 's/^key=//p')"
  [ "$k1" != "$k4" ]
}

@test "pass-cache dir backend round-trips" {
  run "$S/pass-cache.sh" check --backend dir --ref "$WORK/m" --key pass-unit-abc
  [[ "$output" == *"hit=false"* ]]
  "$S/pass-cache.sh" save --backend dir --ref "$WORK/m" --key pass-unit-abc >/dev/null
  run "$S/pass-cache.sh" check --backend dir --ref "$WORK/m" --key pass-unit-abc
  [[ "$output" == *"hit=true"* ]]
}

@test "pass-cache rejects unsafe keys" {
  run "$S/pass-cache.sh" check --backend dir --ref "$WORK/m" --key '../../etc'
  [ "$status" -eq 2 ]
}

# ---- shard -----------------------------------------------------------------

@test "shard --matrix prints a JSON array" {
  run "$S/shard.sh" --matrix 3
  [ "$output" = "[1,2,3]" ]
}

@test "shard runner mode prints the native flag" {
  run "$S/shard.sh" --total 4 --index 2
  [ "$output" = "--shard=2/4" ]
}

@test "shard files mode partitions every file exactly once" {
  mkdir -p e2e && for i in 1 2 3 4 5 6 7; do echo x > "e2e/t$i.spec.ts"; done
  git add -A && git commit -qm specs
  all=""; for i in 1 2 3; do all+="$("$S/shard.sh" --total 3 --index $i --mode files --glob 'e2e/*.spec.ts')"$'\n'; done
  [ "$(printf '%s' "$all" | grep -c .)" -eq 7 ]
  [ "$(printf '%s' "$all" | grep . | sort -u | wc -l | tr -d ' ')" -eq 7 ]
}

@test "shard files mode balances by timings" {
  mkdir -p e2e && for i in 1 2 3 4; do echo x > "e2e/t$i.spec.ts"; done
  git add -A && git commit -qm specs
  printf '100 e2e/t1.spec.ts\n10 e2e/t2.spec.ts\n10 e2e/t3.spec.ts\n10 e2e/t4.spec.ts\n' > timings.txt
  run "$S/shard.sh" --total 2 --index 1 --mode files --glob 'e2e/*.spec.ts' --timings timings.txt
  [ "$output" = "e2e/t1.spec.ts" ]
}

@test "shard rejects an index above the total" {
  run "$S/shard.sh" --total 2 --index 3
  [ "$status" -eq 2 ]
}

# ---- detect-cache ----------------------------------------------------------

@test "detect-cache finds go and bun and keys on lockfiles" {
  printf 'module x\n' > go.mod; : > go.sum
  mkdir -p web && echo '{}' > web/bun.lock
  git add -A && git commit -qm deps
  run "$S/detect-cache.sh" --os linux
  [ "$status" -eq 0 ]
  [[ "$output" == *"managers=bun go"* ]]
  [[ "$output" == *"key=ci-toolkit-linux-bun-go-"* ]]
  [[ "$output" == *".bun/install/cache"* ]]
  k1="$(echo "$output" | sed -n 's/^key=//p')"
  echo '{"a":1}' > web/bun.lock
  k2="$("$S/detect-cache.sh" --os linux | sed -n 's/^key=//p')"
  [ "$k1" != "$k2" ]
}

@test "detect-cache --manager restricts detection" {
  printf 'module x\n' > go.mod; : > go.sum; echo '{}' > bun.lock
  git add -A && git commit -qm deps
  run "$S/detect-cache.sh" --os linux --manager go
  [[ "$output" == *"managers=go"* ]]
  [[ "$output" != *"bun"* ]]
}

@test "detect-cache with nothing to cache emits empty outputs" {
  run "$S/detect-cache.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"key="* ]]
}

# ---- run-tests -------------------------------------------------------------

@test "run-tests mounts the workspace and passes env and volumes" {
  run "$S/run-tests.sh" --image img:1 --env A=1 --volume /c:/root/.cache --network net1 -- go test ./...
  [ "$status" -eq 0 ]
  line="$(grep '^run ' "$DOCKER_LOG")"
  [[ "$line" == *"--volume $WORK:/work"* ]]
  [[ "$line" == *"--env A=1"* ]]
  [[ "$line" == *"--volume /c:/root/.cache"* ]]
  [[ "$line" == *"--network net1"* ]]
  [[ "$line" == *"img:1 go test ./..."* ]]
}

@test "run-tests --cmd runs through sh -c" {
  "$S/run-tests.sh" --image img:1 --cmd 'echo hi && true'
  grep -q "img:1 sh -c echo hi && true" "$DOCKER_LOG"
}

@test "run-tests requires a command" {
  run "$S/run-tests.sh" --image img:1
  [ "$status" -eq 2 ]
}

# ---- hashing: review regressions (false-skip classes) -----------------------

h() { bash -c '. "$1/lib/common.sh"; shift; hash_paths -- "$@"' _ "$S" "$@"; }

@test "an ignored directory is hashed by content, not skipped" {
  echo 'dist/' > .gitignore && git add .gitignore && git commit -qm ig
  mkdir -p dist && echo v1 > dist/app.js
  a="$(h dist)"; echo v2 > dist/app.js; b="$(h dist)"
  [ "$a" != "$b" ]
}

@test "chmod +x changes the hash" {
  a="$(h src)"; chmod +x src/main.go; b="$(h src)"
  [ "$a" != "$b" ]
}

@test "an edited file with a non-ASCII name changes the hash (not treated as deleted)" {
  echo a > "src/é.txt" && git add -A && git commit -qm u
  a="$(h src)"; echo b > "src/é.txt"; b="$(h src)"
  rm "src/é.txt"; c="$(h src)"
  [ "$a" != "$b" ] && [ "$b" != "$c" ] && [ "$a" != "$c" ]
}

@test "hashing from a cwd outside the repo sees the real content" {
  a="$(h "$WORK/src")"
  b="$(cd / && h "$WORK/src")"
  echo '// y' >> src/main.go
  c="$(cd / && h "$WORK/src")"
  [ "$a" = "$b" ] && [ "$b" != "$c" ]
}

@test "hashing never touches the real index" {
  echo '// z' >> src/main.go
  before="$(git diff --cached --name-only)"
  h src >/dev/null
  [ "$(git diff --cached --name-only)" = "$before" ]
}

# ---- build-image trust (attestation) ------------------------------------------

@test "an existing tag is reused when the trust file holds its digest" {
  ref="$("$S/build-image.sh" --image reg/x --dry-run | sed -n 's/^image=//p')"
  export FAKE_EXISTING="$ref" FAKE_DIGEST="sha256:aaaa"
  printf 'sha256:aaaa' > trust
  run "$S/build-image.sh" --image reg/x --trust-file trust --attest-out new
  [[ "$output" == *"built=false"* ]]
  ! grep -q "buildx build" "$DOCKER_LOG"
  [ "$(cat new)" = "sha256:aaaa" ]
}

@test "an existing tag with a different digest than attested is rebuilt" {
  ref="$("$S/build-image.sh" --image reg/x --dry-run | sed -n 's/^image=//p')"
  export FAKE_EXISTING="$ref" FAKE_DIGEST="sha256:forged"
  printf 'sha256:aaaa' > trust
  run "$S/build-image.sh" --image reg/x --trust-file trust
  [[ "$output" == *"built=true"* ]]
  grep -q "buildx build" "$DOCKER_LOG"
}

@test "an existing tag with no attestation in scope is rebuilt" {
  ref="$("$S/build-image.sh" --image reg/x --dry-run | sed -n 's/^image=//p')"
  export FAKE_EXISTING="$ref"
  : > trust
  run "$S/build-image.sh" --image reg/x --trust-file trust
  [[ "$output" == *"built=true"* ]]
}

@test "provenance and sbom are off by default (no untagged children to prune)" {
  "$S/build-image.sh" --image reg/x >/dev/null
  grep -q -- "--provenance=false --sbom=false" "$DOCKER_LOG"
}

@test "the context is part of the image hash" {
  mkdir -p other && cp Dockerfile other/ && git add -A && git commit -qm o
  a="$("$S/build-image.sh" --image reg/x --file Dockerfile --context . --hash-path src --dry-run | sed -n 's/^hash=//p')"
  b="$("$S/build-image.sh" --image reg/x --file Dockerfile --context other --hash-path src --dry-run | sed -n 's/^hash=//p')"
  [ "$a" != "$b" ]
}

@test "pass-cache keys change when the toolkit scripts change" {
  k1="$("$S/pass-cache.sh" key --name unit --path src | sed -n 's/^key=//p')"
  cp -R "$ROOT/scripts" "$WORK/tk"
  echo '# edit' >> "$WORK/tk/run-tests.sh"
  k2="$("$WORK/tk/pass-cache.sh" key --name unit --path src | sed -n 's/^key=//p')"
  [ "$k1" != "$k2" ]
}

@test "the file-hash fallback is location-independent and keeps cwd" {
  mkdir -p "$WORK/a/x" "$WORK/b/x"; echo same > "$WORK/a/x/f"; echo same > "$WORK/b/x/f"
  a="$(cd "$WORK/a" && bash -c '. "$1/lib/common.sh"; hash_paths -- x' _ "$S")"
  b="$(cd "$WORK/b" && bash -c '. "$1/lib/common.sh"; hash_paths -- x' _ "$S")"
  [ "$a" = "$b" ]
  # two relative non-git paths in one call: the second must still resolve
  c="$(cd "$WORK/a" && bash -c '. "$1/lib/common.sh"; hash_paths -- x x' _ "$S")"
  echo diff > "$WORK/a/x/f"
  d="$(cd "$WORK/a" && bash -c '. "$1/lib/common.sh"; hash_paths -- x x' _ "$S")"
  [ "$c" != "$d" ]
}

@test "pass-cache keys are the same for a copy of the toolkit elsewhere" {
  k1="$("$S/pass-cache.sh" key --name unit --path src | sed -n 's/^key=//p')"
  cp -R "$ROOT/scripts" "$WORK/tk-copy-$$"
  k2="$("$WORK/tk-copy-$$/pass-cache.sh" key --name unit --path src | sed -n 's/^key=//p')"
  [ "$k1" = "$k2" ]
}
