#!/usr/bin/env bash
#
# mayhem/build.sh — build librsvg's cargo-fuzz target (render_document) as a
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
# exactly upstream's. The mayhemheroes-only "svg_loader" backport target (BACKPORT.md,
# formerly built from an additive mayhem/fuzz_svg_loader/ crate) is DROPPED: its
# original mayhemheroes run (target svg-loader, run 37, FUZZED 32f29f241905) found zero
# relevant (non-leak/non-OOM) defects — both defects were CWE-401 LeakSanitizer noise,
# one bottoming out in libxml2 with no source frame at all — so per BACKPORT.md step 3
# ("targets whose run at FUZZED found relevant bugs are the target set; the rest are
# dropped") it should never have been kept as a backport target.
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

# Leak detection off, preventively, at BUILD time only (docs/netnew-worker-prompt.md,
# "Disable LeakSanitizer by default"): -fsanitize=address always bundles LSan in with
# no flag to exclude just it, so compile a tiny TU defining __lsan_is_turned_off() and
# link it into the sanitized fuzz binary via RUSTFLAGS -C link-arg (upstream's fuzz/
# crate stays untouched — its Cargo.toml never needs a build.rs for this). ASan and
# UBSan stay fully active; only leak detection is affected. Skipped when the build is
# un-sanitized (no ASan to bundle LSan into).
LSAN_OFF_LINK_ARGS=""
if [ -n "${RUST_SAN}" ]; then
  clang++ ${SANITIZER_FLAGS} -c mayhem/lsan_off.cc -o "$SRC/mayhem/lsan_off.o"
  LSAN_OFF_LINK_ARGS="-Clink-arg=$SRC/mayhem/lsan_off.o"
  echo "built $SRC/mayhem/lsan_off.o (__lsan_is_turned_off hook, to be linked into the fuzz binary)"
fi

# Debug info (§6.2 item 10): the produced binary MUST carry DWARF < 4 (Mayhem triage
# can't read DWARF >= 4). rustc nightly defaults to DWARF-5, so pin -Zdwarf-version=3.
# The libfuzzer-sys cc shim is clang-compiled (DWARF-5 default) — pin its DWARF too.
# $RUST_DEBUG_FLAGS threads any extra base pins.
export RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing ${RUST_SAN} -Zdwarf-version=3 -Cdebuginfo=1 -Cforce-frame-pointers ${LSAN_OFF_LINK_ARGS}"
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
FUZZ_DIRS=("fuzz")

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

for FUZZ_DIR in "${FUZZ_DIRS[@]}"; do
  FUZZ_TARGETS=()
  for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
    FUZZ_TARGETS+=("$(basename "${f%.*}")")
  done
  [ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }
  echo "targets in $FUZZ_DIR: ${FUZZ_TARGETS[*]}"

  for t in "${FUZZ_TARGETS[@]}"; do
    echo "--- building fuzz target: $t ($FUZZ_DIR) ---"
    cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
    # Workspace-member fuzz crate (upstream's fuzz/) lands the binary in the ROOT target
    # dir; a standalone out-of-workspace crate would land it in its own target dir
    # instead. Check both candidate locations so a cargo-version change can't silently
    # break the copy.
    bin=""
    for cand in \
      "$SRC/target/$TRIPLE/release/$t" \
      "$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"; do
      [ -x "$cand" ] && { bin="$cand"; break; }
    done
    [ -n "$bin" ] || { echo "ERROR: fuzz binary for $t not found in root or $FUZZ_DIR/ target dir" >&2; exit 1; }
    cp "$bin" "/mayhem/$t"
    echo "built /mayhem/$t (from $bin)"
  done

  # Disk-space discipline: TWO independent dependency graphs (upstream's own fuzz/ and
  # mayhem/kat/ below) each compile the full librsvg tree from scratch into their OWN
  # target dir — several GB apiece. The binary is already copied out to /mayhem/, so
  # drop the build dir now rather than let both pile up in the image (and in the
  # disk-limited CI runner). A later offline
  # re-run of this script (§6.2 item 9 / item 16) just rebuilds from the still-cached
  # $CARGO_HOME registry — slower, not network-dependent. $SRC/target is safe to remove
  # here: the later clean (unsanitized) unit-test-suite build recreates it from scratch
  # regardless (different RUSTFLAGS fingerprint, so it shares nothing with this one).
  rm -rf "$SRC/target" "$SRC/$FUZZ_DIR/target"
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
rm -rf mayhem/kat/target   # binary already copied out; see the disk-space note above

echo "=== building librsvg unit-test suite (cargo test --no-run) ==="
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo test --no-run -p librsvg --lib

echo "build.sh complete"
