#!/usr/bin/env bash
#
# jsonparser/mayhem/test.sh — RUN jsonparser's OWN Go test suite and emit a CTRF summary.
# exit 0 iff no test failed.
#
# PATCH-grade oracle: jsonparser's suite (parser_test.go, bytes_test.go, escape_test.go,
# parser_error_test.go, deep_spec_test.go, set_spec_test.go, obligation_property_test.go, …)
# is a REAL known-answer suite — every case asserts exact parsed values/offsets/errors against
# golden expectations, so a no-op/exit(0) patch FAILS it.
#
# This script does NOT compile: mayhem/build.sh pre-built the runner (normal flags) at
# /mayhem/mayhem-build/jsonparser.test with -linkmode=external, so the binary is dynamically
# linked and the §6.3 LD_PRELOAD sabotage check can neuter it (a neutered runner emits no
# "--- PASS" lines -> 0 tests parsed -> this oracle FAILS -> not reward-hackable). A second
# behavioral probe runs the (also dynamically linked) fuzzdelete target single-shot on a seed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/mayhem-build/jsonparser.test"
if [ ! -x "$RUNNER" ]; then
  echo "test runner $RUNNER missing — mayhem/build.sh must pre-build it (do not compile here)" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

OUT="/tmp/jsonparser-test.out"
echo "=== running: $RUNNER -test.v (upstream suite, pre-built by build.sh) ==="
"$RUNNER" -test.v > "$OUT" 2>&1; rc=$?
tail -15 "$OUT"

# Count test-level results (subtests included — they are real asserted cases).
PASSED=$(grep -c -- '--- PASS: ' "$OUT" || true)
FAILED=$(grep -c -- '--- FAIL: ' "$OUT" || true)
SKIPPED=$(grep -c -- '--- SKIP: ' "$OUT" || true)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# A neutered/silent runner (or a crash before any test ran) parses as 0 events — fail honestly.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test results parsed from the runner output (exit $rc) — treating as failure" >&2
  emit_ctrf "go-test" 0 1 0; exit 1
fi
# Trust parsed failures; if the runner exited non-zero with 0 parsed failures, force one.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── Behavioral probe (§6.3): run the dynamically-linked fuzzdelete target single-shot on a
# committed seed and assert libFuzzer's "Executed" marker — proves the fuzz target actually
# drives jsonparser.Delete (and is neutered under the sabotage LD_PRELOAD -> probe fails).
PROBE_INPUT="$SRC/mayhem/fuzzdelete/testsuite/complex.json"
if [ -x /mayhem/fuzzdelete ] && [ -f "$PROBE_INPUT" ]; then
  echo "=== behavioral probe: fuzzdelete single-shot on seed ==="
  PROBE_OUT=$(/mayhem/fuzzdelete -runs=1 "$PROBE_INPUT" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: fuzzdelete executed the seed"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: fuzzdelete produced no 'Executed' output"; echo "$PROBE_OUT" | tail -5
    FAILED=$(( FAILED + 1 ))
  fi
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
