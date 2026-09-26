// Build-time LeakSanitizer-off hook (docs/netnew-worker-prompt.md, "Disable LeakSanitizer by
// default"). ASan's memory-corruption checks and UBSan stay fully active; only leak detection
// is disabled. Compiled with $SANITIZER_FLAGS and linked into the sanitized fuzz binary via
// build.sh (-C link-arg on the cargo-fuzz build) — never a runtime disable/enable toggle or a
// baked-in default-options override, both of which verify-repo.sh FAILs on.
extern "C" int __lsan_is_turned_off() { return 1; }
