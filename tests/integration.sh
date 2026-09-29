#!/usr/bin/env bash
# Integration test against a real registry (registry:2 on localhost) and a
# real buildx builder. Proves the three properties the toolkit is for:
#   1. the first build pushes an image and a registry cache;
#   2. the same inputs again => no build at all (built=false);
#   3. a pass marker recorded once is found again (skip), and a changed
#      input misses it.
# Needs docker with buildx. Run: tests/integration.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts"
PORT="${REGISTRY_PORT:-5055}"
REG="localhost:$PORT"
WORK="$(mktemp -d)"
BUILDER="ci-toolkit-it-$$"

cleanup() {
  docker rm -f "ci-toolkit-registry-$$" >/dev/null 2>&1 || true
  docker buildx rm "$BUILDER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
out() { sed -n "s/^$1=//p"; }

docker run -d --rm --name "ci-toolkit-registry-$$" -p "$PORT:5000" registry:2 >/dev/null
# host networking lets the builder container reach the registry on localhost
docker buildx create --name "$BUILDER" --driver docker-container --driver-opt network=host --use >/dev/null
for _ in $(seq 1 30); do curl -fs "http://$REG/v2/" >/dev/null && break; sleep 1; done

cd "$WORK"
git init -q . && git config user.email t@t && git config user.name t
mkdir -p app
echo 'echo hello from the image' > app/run.sh
cat > Dockerfile <<'EOF'
FROM alpine:3.20
COPY app /app
CMD ["sh", "/app/run.sh"]
EOF
git add -A && git commit -qm init

echo "--- 1. first build pushes"
o1="$("$S/build-image.sh" --image "$REG/it/app" --hash-path app)"
[ "$(echo "$o1" | out built)" = true ] || fail "first build did not build"
ref="$(echo "$o1" | out image)"
docker buildx imagetools inspect "$ref" >/dev/null || fail "image not in registry: $ref"
docker buildx imagetools inspect "$REG/it/app:buildcache" >/dev/null || fail "registry cache not pushed"

echo "--- 2. same inputs: no build"
start=$(date +%s)
o2="$("$S/build-image.sh" --image "$REG/it/app" --hash-path app --extra-tag sha-test)"
[ "$(echo "$o2" | out built)" = false ] || fail "second build rebuilt"
[ "$(echo "$o2" | out image)" = "$ref" ] || fail "second run resolved a different ref"
docker buildx imagetools inspect "$REG/it/app:sha-test" >/dev/null || fail "extra tag not attached on cache hit"
echo "    skip took $(( $(date +%s) - start ))s"

echo "--- 2b. unrelated file: still no build"
echo docs > README.md && git add README.md && git commit -qm docs
o2b="$("$S/build-image.sh" --image "$REG/it/app" --hash-path app)"
[ "$(echo "$o2b" | out built)" = false ] || fail "README change triggered a build"

echo "--- 2c. input change: rebuild, from cache"
echo 'echo v2' > app/run.sh && git commit -qam v2
o3="$("$S/build-image.sh" --image "$REG/it/app" --hash-path app)"
[ "$(echo "$o3" | out built)" = true ] || fail "changed input did not rebuild"
[ "$(echo "$o3" | out image)" != "$ref" ] || fail "changed input kept the old ref"

echo "--- 3. run-tests uses the built image"
docker pull -q "$(echo "$o3" | out image)" >/dev/null
msg="$("$S/run-tests.sh" --image "$(echo "$o3" | out image)" --no-mount -- sh /app/run.sh)"
[ "$msg" = "v2" ] || fail "run-tests output: $msg"

echo "--- 4. pass-cache registry round trip"
key="$("$S/pass-cache.sh" key --name unit --path app | out key)"
[ "$("$S/pass-cache.sh" check --backend registry --ref "$REG/it/ci-pass" --key "$key" | out hit)" = false ] || fail "fresh key hit"
"$S/pass-cache.sh" save --backend registry --ref "$REG/it/ci-pass" --key "$key" >/dev/null
[ "$("$S/pass-cache.sh" check --backend registry --ref "$REG/it/ci-pass" --key "$key" | out hit)" = true ] || fail "saved key missed"
echo 'echo v3' > app/run.sh && git commit -qam v3
key2="$("$S/pass-cache.sh" key --name unit --path app | out key)"
[ "$("$S/pass-cache.sh" check --backend registry --ref "$REG/it/ci-pass" --key "$key2" | out hit)" = false ] || fail "changed input still hit"

echo "PASS: integration"
