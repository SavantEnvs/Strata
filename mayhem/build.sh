#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Strata's engine is C++20/CUDA; the parts that read untrusted files (the PLE table reader, the GGUF readers, the
# session-file reader, the image text-encoder tokenizer) are host-only C++ that upstream's CMake only builds inside
# its GPU libraries.  So the fuzzed sources are compiled directly here, with the sanitizers, into build-fuzz/
# (gitignored by upstream's `build*/`), and upstream's CPU unit tests into build-test/ with normal flags.
E="$SRC/engine"
FZ="$SRC/build-fuzz"
TS="$SRC/build-test"
mkdir -p "$FZ/obj" "$TS"
CXXSTD="-std=c++20 -pthread"
FUZZ_CXXFLAGS="$CXXSTD $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -I$E/include -I$SRC/mayhem/harnesses"

# 1) The project sources the harnesses reach, sanitized, compiled twice: with SanitizerCoverage for the libFuzzer
#    binaries (obj-fuzz/) and without it for the -standalone reproducers (obj-standalone/), so a reproducer links
#    with no fuzzer runtime even when SANITIZER_FLAGS is empty.
#    conversation_file.cpp hashes empty arrays with memcpy(dst, nullptr, 0) (SessionHasher::update), which UBSan's
#    nonnull-attribute check flags on every valid file with an empty array; that one check is relaxed for that
#    one file only - ASan and the rest of UBSan stay on and halting.
declare -A SRCS=(
  [ngram]="$E/src/kernels/ngram.cpp"
  [ple_reader]="$E/src/ngram/ple_reader.cpp"
  [direct_file]="$E/src/platform/direct_file.cpp"
  [memory]="$E/src/platform/memory.cpp"
  [io_priority]="$E/src/platform/io_priority.cpp"
  [conversation_file]="$E/src/core/conversation_file.cpp"
  [qwen2_tok]="$E/src/image/te/qwen2_tok.cpp"
  [split_gguf]="$E/src/split/src/gguf.cpp"
  [quant_dequant]="$E/src/quant/dequant.cpp"
  [quant_types]="$E/src/quant/types.cpp"
)
extra_flags() {   # per-source extra flags
  case "$1" in
    conversation_file) echo "-fno-sanitize=nonnull-attribute" ;;
    split_gguf|fuzz_split_gguf) echo "-DFNX_27B=1 -I$E/src/split/src" ;;
  esac
}
COV_FLAGS="-fsanitize=fuzzer-no-link"
mkdir -p "$FZ/obj-fuzz" "$FZ/obj-standalone"
pids=()
for o in "${!SRCS[@]}"; do
  $CXX $FUZZ_CXXFLAGS $COV_FLAGS $(extra_flags "$o") -c "${SRCS[$o]}" -o "$FZ/obj-fuzz/$o.o" & pids+=($!)
  $CXX $FUZZ_CXXFLAGS $(extra_flags "$o") -c "${SRCS[$o]}" -o "$FZ/obj-standalone/$o.o" & pids+=($!)
done
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FZ/obj/lsan_off.o" & pids+=($!)
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FZ/obj/standalone_main.o" & pids+=($!)
for p in "${pids[@]}"; do wait "$p"; done

# 2) Each harness twice: the libFuzzer binary and the run-once -standalone reproducer.
link_harness() {   # <name> <project objects (basenames)...>
  local name="$1"; shift
  local fo=() so=() o
  for o in "$@"; do fo+=("$FZ/obj-fuzz/$o.o"); so+=("$FZ/obj-standalone/$o.o"); done
  $CXX $FUZZ_CXXFLAGS $COV_FLAGS $(extra_flags "$name") -c "$SRC/mayhem/harnesses/$name.cpp" -o "$FZ/obj-fuzz/$name.o"
  $CXX $FUZZ_CXXFLAGS $(extra_flags "$name") -c "$SRC/mayhem/harnesses/$name.cpp" -o "$FZ/obj-standalone/$name.o"
  $CXX $FUZZ_CXXFLAGS $LIB_FUZZING_ENGINE "$FZ/obj-fuzz/$name.o" "${fo[@]}" "$FZ/obj/lsan_off.o" -o "$FZ/$name"
  $CXX $FUZZ_CXXFLAGS "$FZ/obj-standalone/$name.o" "$FZ/obj/standalone_main.o" "${so[@]}" "$FZ/obj/lsan_off.o" \
    -o "$FZ/$name-standalone"
}
pids=()
link_harness fuzz_ple_table ngram ple_reader direct_file memory io_priority & pids+=($!)
link_harness fuzz_gguf_model & pids+=($!)
link_harness fuzz_session_file conversation_file & pids+=($!)
link_harness fuzz_qwen2_prompt qwen2_tok & pids+=($!)
link_harness fuzz_qwen2_tok_gguf qwen2_tok & pids+=($!)
link_harness fuzz_split_gguf split_gguf & pids+=($!)
link_harness fuzz_quant_dequant quant_dequant quant_types & pids+=($!)
for p in "${pids[@]}"; do wait "$p"; done

# 3) Upstream's own CPU unit tests for the same code, with normal flags (no sanitizers) - mayhem/test.sh runs them.
TEST_CXXFLAGS="$CXXSTD -O1 -g -I$E/include $COVERAGE_FLAGS"
pids=()
$CXX $TEST_CXXFLAGS "$E/src/core/conversation_file_test.cpp" "$E/src/core/conversation_file.cpp" -o "$TS/conversation_file_test" & pids+=($!)
$CXX $TEST_CXXFLAGS "$E/src/artifact/gguf_reader_test.cpp" -o "$TS/gguf_reader_test" & pids+=($!)
$CXX $TEST_CXXFLAGS "$E/src/core/logit_bias_test.cpp" -o "$TS/logit_bias_test" & pids+=($!)
$CXX $TEST_CXXFLAGS "$E/src/ngram/ple_reader_test.cpp" "$E/src/kernels/ngram.cpp" "$E/src/ngram/ple_reader.cpp" \
  "$E/src/platform/direct_file.cpp" "$E/src/platform/memory.cpp" "$E/src/platform/io_priority.cpp" \
  -o "$TS/ple_reader_test" & pids+=($!)
for p in "${pids[@]}"; do wait "$p"; done
echo "build.sh: done"
