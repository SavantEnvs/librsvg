#!/usr/bin/env bash
#
# mayhem/test.sh — the BEHAVIORAL oracle for librsvg (SPEC §6.3). RUNS what
# mayhem/build.sh already compiled; it does NOT compile.
#
# Two layers, both asserting VALUES through DYNAMICALLY-LINKED binaries so
# verify-repo's sabotage shim (which _exit(0)s every non-system executable) makes
# this FAIL when librsvg is neutered — i.e. the oracle is not reward-hackable:
#
#   1. KAT probe (mayhem/kat, built to /mayhem/kat_probe): loads a fixed solid-red
#      SVG through the SAME load+render pipeline the fuzz target uses and prints the
#      intrinsic size + the rendered centre pixel. We assert the exact values
#      (10 x 10 px, ARGB32 0xffff0000). A no-op/neutered librsvg cannot produce them.
#   2. librsvg's own unit-test suite (`cargo test -p librsvg --lib`): the crate's
#      real known-answer assertions over the parser/CSS/geometry code. Under sabotage
#      the cargo launcher itself is neutered, so zero results parse => FAIL.
#
# Emits a CTRF summary. Exit 0 iff failed==0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
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

KAT_PASS=0
KAT_FAIL=0
kat_assert() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "KAT ok: $1 = $3"; KAT_PASS=$((KAT_PASS+1))
  else echo "KAT FAIL: $1 expected [$2] got [$3]" >&2; KAT_FAIL=$((KAT_FAIL+1)); fi
}

# ── Layer 1: the KAT probe (unconditional — a missing binary is a FAILURE) ─────
PROBE=/mayhem/kat_probe
if [ ! -x "$PROBE" ]; then
  echo "ERROR: KAT probe $PROBE missing/not executable — build.sh must produce it" >&2
  emit_ctrf "librsvg-oracle" 0 1 0
  exit 1
fi
KOUT="$("$PROBE" 2>/dev/null || true)"
echo "--- kat_probe output ---"; printf '%s\n' "$KOUT"
kat_assert "intrinsic_width"  "KAT_WIDTH=10"        "$(printf '%s\n' "$KOUT" | grep -m1 '^KAT_WIDTH=')"
kat_assert "intrinsic_height" "KAT_HEIGHT=10"       "$(printf '%s\n' "$KOUT" | grep -m1 '^KAT_HEIGHT=')"
kat_assert "centre_pixel"     "KAT_PIXEL=ffff0000"  "$(printf '%s\n' "$KOUT" | grep -m1 '^KAT_PIXEL=')"

# ── Layer 2: librsvg's own unit-test suite (already compiled by build.sh) ──────
LOG="$(mktemp)"
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo test --no-fail-fast -p librsvg --lib 2>&1 | tee "$LOG"
UP=$(grep -hoE '[0-9]+ passed'  "$LOG" | awk '{s+=$1} END{print s+0}')
UF=$(grep -hoE '[0-9]+ failed'  "$LOG" | awk '{s+=$1} END{print s+0}')
US=$(grep -hoE '[0-9]+ ignored' "$LOG" | awk '{s+=$1} END{print s+0}')
rm -f "$LOG"

# The unit suite MUST have actually run (a neuter zeroes it out => hard fail).
if [ "$((UP + UF + US))" -eq 0 ]; then
  echo "ERROR: no libtest results parsed — the unit-test runner did not execute (neutered?)" >&2
  emit_ctrf "librsvg-oracle" "$KAT_PASS" "$((KAT_FAIL + 1))" 0
  exit 1
fi

PASSED=$(( KAT_PASS + UP ))
FAILED=$(( KAT_FAIL + UF ))
SKIPPED=$(( US ))
emit_ctrf "librsvg-oracle" "$PASSED" "$FAILED" "$SKIPPED"
