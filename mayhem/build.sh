#!/usr/bin/env bash
#
# mayhem/build.sh — build librsvg's OWN cargo-fuzz target (render_document) as a
# sanitized libFuzzer binary (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS),
# then build the clean oracle probe + the crate's test suite for mayhem/test.sh to RUN.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache (the runtime exports
#     CARGO_NET_OFFLINE=true), so we do NOT hard-code `--offline` here. librsvg ships
#     a committed root Cargo.lock, so the fuzz build needs no lock generation at all;
#     the KAT probe is a standalone crate whose own committed Cargo.lock pins its tree.
#
# We REUSE librsvg's own in-workspace fuzz/ crate (target "render_document") — the
# same harness OSS-Fuzz builds — so target parity holds and the fuzzed pipeline is
# exactly upstream's. Upstream files are untouched (additive integration only).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Sanitizers (§6.1): the base provides clang $SANITIZER_FLAGS (ASan+UBSan, halting).
# rustc can't consume those clang flags, but we honor the KNOB: a non-empty
# $SANITIZER_FLAGS instruments the Rust build with ASan (the OSS-Fuzz Rust path); an
# explicit empty `--build-arg SANITIZER_FLAGS=` yields an un-sanitized build.
RUST_SAN=""
if [ -n "${SANITIZER_FLAGS:-}" ]; then
  RUST_SAN="-Zsanitizer=address"
fi

# Debug info (§6.2 item 10): the produced binary MUST carry DWARF < 4 (Mayhem triage
# can't read DWARF >= 4). rustc nightly defaults to DWARF-5, so pin -Zdwarf-version=3.
# The libfuzzer-sys cc shim is clang-compiled (DWARF-5 default) — pin its DWARF too.
# $RUST_DEBUG_FLAGS threads any extra base pins.
export RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing ${RUST_SAN} -Zdwarf-version=3 -Cdebuginfo=1 -Cforce-frame-pointers"
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# The bundled ASan runtime archive that `-Zsanitizer=address` links is precompiled
# with clang (DWARF-5) and ships with full debug info, which would otherwise land a
# DWARF-5 compile unit as the binary's FIRST CU and fail the DWARF < 4 gate. Strip
# the debug info from that runtime archive (a toolchain artifact, NOT project code).
# Idempotent: --strip-debug on an already-stripped archive is a no-op (offline-safe).
if [ -n "${RUST_SAN}" ]; then
  RT_LIB_DIR="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/lib"
  for asan in "$RT_LIB_DIR"/librustc-*_rt.asan.a; do
    [ -f "$asan" ] || continue
    if [ -w "$asan" ]; then
      objcopy --strip-debug "$asan" "$asan.stripped" && mv "$asan.stripped" "$asan"
      echo "stripped debug info from bundled ASan runtime: $asan"
    fi
  done
fi

TRIPLE="x86_64-unknown-linux-gnu"

# librsvg's fuzz/ is a MEMBER of the root workspace (its [workspace] table is
# commented out), so cargo-fuzz builds it into the ROOT target dir, not fuzz/target.
FUZZ_DIR="fuzz"
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  # Workspace-member fuzz crate => binary lands in the ROOT target dir. Check both
  # candidate locations so a cargo-version change can't silently break the copy.
  bin=""
  for cand in \
    "$SRC/target/$TRIPLE/release/$t" \
    "$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"; do
    [ -x "$cand" ] && { bin="$cand"; break; }
  done
  [ -n "$bin" ] || { echo "ERROR: fuzz binary for $t not found in root or fuzz/ target dir" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t (from $bin)"
done

# ── Clean oracle build (NO sanitizer, NO forced DWARF) ─────────────────────────
# The KAT probe + the librsvg unit-test suite are the behavioral oracle (mayhem/test.sh
# only RUNS them). Build them with the project's NORMAL flags — clearing RUSTFLAGS/
# CFLAGS/CXXFLAGS so they are an HONEST, un-instrumented reference.

echo "=== building KAT probe (clean, dynamically linked) ==="
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS \
  cargo build --release --manifest-path mayhem/kat/Cargo.toml --bin kat_probe
KAT_BIN="$SRC/mayhem/kat/target/release/kat_probe"
[ -x "$KAT_BIN" ] || { echo "ERROR: KAT probe binary not found at $KAT_BIN" >&2; exit 1; }
cp "$KAT_BIN" /mayhem/kat_probe
# Regression guard: the sabotage oracle only bites if the probe is dynamically linked.
if ! file /mayhem/kat_probe | grep -q 'dynamically linked'; then
  echo "ERROR: KAT probe is not dynamically linked — the sabotage oracle would not neuter it" >&2
  file /mayhem/kat_probe >&2
  exit 1
fi
echo "built /mayhem/kat_probe (dynamically linked)"

echo "=== building librsvg unit-test suite (cargo test --no-run) ==="
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo test --no-run -p librsvg --lib

echo "build.sh complete"
