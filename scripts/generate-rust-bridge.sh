#!/usr/bin/env bash
#
# Regenerate the Flutter Rust Bridge bindings (rust/src/frb_generated.rs and
# lib/src/rust/**). This is the entry point: run it instead of calling
# `flutter_rust_bridge_codegen generate` directly, which fails. Run it from
# anywhere; it cd's to the project root itself, which is where FRB must run.
#
#   ./scripts/generate-rust-bridge.sh
#
# ---------------------------------------------------------------------------
# WHY THIS SHIM EXISTS
#
# FRB discovers the API by running `cargo expand` and parsing the result with
# `syn`. The syn pinned by flutter_rust_bridge_codegen 2.11.1 cannot parse
# `super let`, so the bare command dies with:
#
#     Error: unexpected token, expected `;`
#
# `super let` is not written anywhere in this project. It is how rustc 1.95.0
# (the current stable; this repository pins no toolchain, and cargokit builds
# with `stable` unless VIZOR_RUST_TOOLCHAIN names an exact release) desugars
# `std::pin::pin!`. As of zcash_voting 5.1.0 it reaches the expanded text
# exactly once, inside the body of `observe_helper_http`.
#
# So this script rewrites EXACTLY ONE construct, `super let` -> `let`, and only
# in the text `cargo expand` hands to FRB for inspection. Nothing else is
# touched. It is safe because:
#
#   * The real build never sees this. rustc compiles the original `pin!` macro
#     from the real source; only FRB's throwaway inspection copy is rewritten.
#   * The construct is inside a function body. FRB reads item signatures and
#     types, not bodies, so it cannot reach the generated API. Confirmed:
#     regenerating with this shim reproduces the committed frb_generated.rs and
#     lib/src/rust/** byte for byte.
#
# DO NOT also rewrite `#[unsafe(no_mangle)]`. It does appear in the expanded
# text (from frb_generated.rs and flutter_rust_bridge's
# frb_generated_boilerplate_io! macro), and it looks like the same class of
# problem, but syn parses it fine and codegen succeeds with it left alone. It
# has been checked; rewriting it would be noise.
#
# HOW TO REMOVE THIS SHIM
#
# It is removable as soon as FRB ships a syn that parses super-let expressions
# (i.e. a flutter_rust_bridge_codegen past 2.11.1 picking up a newer syn). To
# check, from the project root:
#
#     flutter_rust_bridge_codegen generate
#
# If that exits 0, delete this shim, replace it with a plain call to that
# command, and update README.md, CONTRIBUTING.md and AGENTS.md, which all point
# here. Downgrading rustc is not an alternative: builds follow `stable` (see
# above), so a local downgrade would only move the failure to the next machine.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
export VIZOR_CODEGEN_REAL_CARGO
VIZOR_CODEGEN_REAL_CARGO="$(command -v cargo)"
shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/vizor-frb-expand.XXXXXX")"
trap 'rm -rf "$shim_dir"' EXIT
cat > "$shim_dir/cargo" <<'PY'
#!/usr/bin/env python3
import os
import re
import subprocess
import sys

cargo = os.environ['VIZOR_CODEGEN_REAL_CARGO']
args = sys.argv[1:]
if args and args[0] == 'expand':
    result = subprocess.run([cargo, *args], stdout=subprocess.PIPE)
    # Parsing function bodies is incidental to FRB's API/type discovery.
    sys.stdout.buffer.write(re.sub(rb'\bsuper\s+let\b', b'let', result.stdout))
    sys.exit(result.returncode)
os.execv(cargo, [cargo, *args])
PY
chmod +x "$shim_dir/cargo"
PATH="$shim_dir:$PATH" flutter_rust_bridge_codegen generate "$@"
