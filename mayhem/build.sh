#!/usr/bin/env bash
#
# jsonparser/mayhem/build.sh — build ALL of jsonparser's OSS-Fuzz go-fuzz harnesses (fuzz.go,
# legacy `func FuzzX(data []byte) int` form) as sanitized libFuzzer binaries, replicating
# OSS-Fuzz's compile_go_fuzzer (projects/jsonparser/build.sh -> oss-fuzz-build.sh):
#   go-fuzz-build -libfuzzer -func FuzzX -o fuzzx.a . ; clang -fsanitize=address,fuzzer fuzzx.a
#
# 14 targets (all of upstream's fuzz.go entry points, = the OSS-Fuzz target set; the old fork
# integration shipped only fuzzdelete — its target name is preserved):
#   fuzzparsestring fuzzeachkey fuzzdelete fuzzset fuzzobjecteach fuzzparsefloat fuzzparseint
#   fuzzparsebool fuzztokenstart fuzzgetstring fuzzgetfloat fuzzgetint fuzzgetboolean
#   fuzzgetunsafestring
#
# Also pre-builds the project's own test suite runner (normal flags, external linkmode so the
# binary is dynamically linked) to /mayhem/mayhem-build/jsonparser.test — mayhem/test.sh RUNS it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASan-only (no UBSan in the Go libFuzzer link). An explicit empty
# --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the CGO shim compiles and
# the final clang link. Go's gc compiler always emits DWARF4+ and has no version knob; the C shims
# compiled by clang (libFuzzer entry wrapper) are forced to DWARF3, so the FIRST CU in the binary
# is DWARF3 and the DWARF<4 triage gate passes.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Go env: toolchain pinned under /opt/toolchains (SPEC §6.2 item 8) — $HOME-independent, so the
# module/build caches survive the PATCH re-run under a different identity.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE. The module cache
# doubles as a file proxy at $GOMODCACHE/cache/download — file proxy FIRST, network LAST, so the
# offline re-run resolves entirely from the cache and the network only fills cache-misses on the
# first (online) build. GOPROXY=off is NOT enough — it blocks reading the cache's version list.
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

cd "$SRC"
go version

# go-fuzz-build needs go-fuzz-dep on the module graph. With -mod=mod + the file-proxy GOPROXY
# this resolves from the in-image cache offline (no-op if already present).
go get github.com/dvyukov/go-fuzz/go-fuzz-dep

mkdir -p "$SRC/mayhem-build"

# target-binary-name -> harness func in fuzz.go (upstream's full OSS-Fuzz set)
TARGETS="
fuzzparsestring:FuzzParseString
fuzzeachkey:FuzzEachKey
fuzzdelete:FuzzDelete
fuzzset:FuzzSet
fuzzobjecteach:FuzzObjectEach
fuzzparsefloat:FuzzParseFloat
fuzzparseint:FuzzParseInt
fuzzparsebool:FuzzParseBool
fuzztokenstart:FuzzTokenStart
fuzzgetstring:FuzzGetString
fuzzgetfloat:FuzzGetFloat
fuzzgetint:FuzzGetInt
fuzzgetboolean:FuzzGetBoolean
fuzzgetunsafestring:FuzzGetUnsafeString
"

for entry in $TARGETS; do
  tgt="${entry%%:*}"; fn="${entry##*:}"
  echo "=== building $tgt (go-fuzz-build -libfuzzer -func $fn) ==="
  go-fuzz-build -libfuzzer -func "$fn" -o "$SRC/mayhem-build/$tgt.a" .
  # Link the go-fuzz archive into a libFuzzer binary with clang (ASan). $GO_DEBUG_FLAGS keeps the
  # first (C shim) CU at DWARF3.
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/$tgt.a" -o "/mayhem/$tgt"
  echo "built /mayhem/$tgt"
done

# ── Pre-build the project's own test suite (NORMAL flags — functional oracle, not a triage
# artifact). -linkmode=external makes the test binary DYNAMICALLY linked (pure-Go test binaries
# are static, which would make it invisible to LD_PRELOAD-based behavioral checks).
echo "=== building test runner (go test -c, normal flags) ==="
CGO_ENABLED=1 go test -c -ldflags '-linkmode=external' -o "$SRC/mayhem-build/jsonparser.test" .

echo "build.sh complete:"
ls -la /mayhem/fuzz* "$SRC/mayhem-build/jsonparser.test"
