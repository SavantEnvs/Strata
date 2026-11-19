#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

# Upstream's own CPU unit tests for the code the harnesses fuzz (built by mayhem/build.sh with normal flags).
# Each one asserts known answers (round-tripped session files against a golden size/hash, the GGUF reader's
# accept/refuse cases, the PLE reader's rows against its dequantizers, logit-bias parsing) and prints a
# verdict line; a test passes only if it exits 0 AND prints its pass line.
T="$SRC/build-test"
cd "$SRC/engine"   # upstream runs them from the engine source dir (CMake WORKING_DIRECTORY)
passed=0; failed=0
run_test() {   # <name> <pass regex> <cmd...>
  local name="$1" re="$2"; shift 2
  if [ ! -x "$1" ]; then echo "MISSING $1 (mayhem/build.sh should have built it)" >&2; failed=$((failed+1)); return; fi
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && grep -Eq "$re" <<<"$out"; then
    echo "PASS $name"; passed=$((passed+1))
  else
    echo "FAIL $name (rc=$rc)"; tail -20 <<<"$out"; failed=$((failed+1))
  fi
}
run_test conversation_file_test '^conversation_file_test: [0-9]+ checks passed$' "$T/conversation_file_test"
run_test gguf_reader_test '^gguf_reader_test: all passed$' "$T/gguf_reader_test"
run_test logit_bias_test '^logit_bias_test: passed' "$T/logit_bias_test"
run_test ple_reader_selftest 'ple formats, both readers vs their dequantizers: .*: OK' \
  "$T/ple_reader_test" --selftest --dir "${TMPDIR:-/tmp}"

emit_ctrf "strata-cpu-unit-tests" "$passed" "$failed" 0
