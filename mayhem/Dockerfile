# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — RUST target (cargo / cargo-fuzz) for librsvg.
# Builds ON TOP of the org C/C++ base (ghcr.io/savantenvs/base), adding the C system
# libraries librsvg links against (cairo/glib/gio/pango/harfbuzz/freetype/fontconfig/
# libxml2) plus a pinned Rust nightly + cargo-fuzz under /opt/toolchains/rust, then
# runs the per-repo mayhem/build.sh.
#
# WHY a Rust-specific template (SPEC §6.2 items 8/9, §6.5):
#   The Rust toolchain + cargo registry are NOT in the base. We install them at a
#   FIXED, $HOME-independent prefix (/opt/toolchains/rust) with CARGO_HOME/RUSTUP_HOME
#   pinned there so (a) the task tier can lock the toolchain, and (b) the cargo
#   registry the FIRST (online) build populates is found again — by the SAME absolute
#   CARGO_HOME — when the PATCH RL tier re-runs build.sh OFFLINE.
#
# WHY the apt layer: librsvg is a Rust crate with a C ABI that renders SVG via cairo
#   and text via pango/harfbuzz. Its *-sys crates locate the C libs through pkg-config
#   at build time. These dev packages are baked into the image at build time (online),
#   so the air-gapped PATCH re-run needs no network for them either.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS

# ── librsvg's C system dependencies (pkg-config-discovered by the *-sys crates) ────
USER root
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libcairo2-dev \
        libglib2.0-dev \
        libgdk-pixbuf-2.0-dev \
        libpango1.0-dev \
        libxml2-dev \
        libfreetype-dev \
        libfontconfig-dev \
        libharfbuzz-dev \
 && rm -rf /var/lib/apt/lists/*

# ── Rust toolchain @ a FIXED, lockable, $HOME-independent prefix ───────────────
# librsvg HEAD declares rust-version = 1.92.0 + edition 2024 + resolver "3", so the
# nightly MUST report >= 1.92 (cargo hard-errors otherwise). nightly-2025-11-15 is
# rustc 1.93.0-nightly — satisfies the MSRV and provides -Zsanitizer=address.
ARG RUST_CHANNEL=nightly-2025-11-15
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rustup component add rust-src --toolchain "${RUST_CHANNEL}" \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must
 # read the toolchain and read/refresh the cargo registry cache, so hand the whole
 # prefix to 2000.
 && chown -R 2000:2000 /opt/toolchains/rust

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz target(s)
# plus the clean oracle probe + test suite.
RUN bash mayhem/build.sh

# Run the project's functional suite at build time (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
