#!/usr/bin/env bash
# Bring this fork up to date with chainapsis/vizor-wallet (see FORK.md).
#
#   scripts/nyctis-sync-upstream.sh            # sync main, merge upstream into nyctis-poc, check
#   NO_PUSH=1 scripts/nyctis-sync-upstream.sh  # do everything locally, push nothing
#
# 1. `main` is a mirror: it is fast-forwarded to upstream `main` and pushed to `origin`. A `main`
#    that has diverged is refused, never force-pushed — it means a commit of ours landed there.
# 2. Upstream `main` is merged into the Nyctis branch with a merge commit (upstream reviews and
#    merges with merge commits too, so history stays comparable).
# 3. The two Flutter Rust Bridge files are generated from the Rust API, so a conflict in them is
#    resolved by regenerating them, never by hand. Any other conflict stops the script with the
#    merge left in place for a person to finish.
# 4. `cargo check` and `fvm flutter analyze` must pass before the merge is pushed.
set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/chainapsis/vizor-wallet.git}
BRANCH=${NYCTIS_BRANCH:-nyctis-poc}
GENERATED=(lib/src/rust/frb_generated.dart rust/src/frb_generated.rs)

step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "the working tree has changes; commit or stash them first"

step "fetch"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
git fetch --quiet upstream main
git fetch --quiet origin

step "main mirrors upstream"
if git merge-base --is-ancestor origin/main upstream/main; then
  git branch -f main upstream/main >/dev/null
  if [ "$(git rev-parse origin/main)" = "$(git rev-parse upstream/main)" ]; then
    echo "main is already upstream main ($(git rev-parse --short upstream/main))"
  elif [ -n "${NO_PUSH:-}" ]; then
    echo "would push main $(git rev-parse --short origin/main) -> $(git rev-parse --short upstream/main)"
  else
    git push --quiet origin upstream/main:refs/heads/main
    echo "main fast-forwarded to $(git rev-parse --short upstream/main)"
  fi
else
  fail "origin/main has commits upstream does not; main must stay a mirror — move them to $BRANCH"
fi

step "merge upstream into $BRANCH"
git checkout --quiet "$BRANCH"
git merge --quiet --ff-only "origin/$BRANCH" 2>/dev/null || true
BEHIND=$(git rev-list --count "HEAD..upstream/main")
if [ "$BEHIND" = 0 ]; then
  echo "$BRANCH already contains upstream main"
  exit 0
fi
echo "$BEHIND upstream commit(s) to merge"
if ! git -c commit.gpgsign=false merge --no-ff --no-edit upstream/main -m "Merge upstream main into $BRANCH"; then
  CONFLICTS=()
  while IFS= read -r f; do CONFLICTS+=("$f"); done < <(git diff --name-only --diff-filter=U)
  for f in "${CONFLICTS[@]}"; do
    [[ " ${GENERATED[*]} " == *" $f "* ]] || fail "conflict in $f — resolve it by hand, then: git commit && rerun this script's checks"
  done
  echo "only generated bridge files conflict: regenerating them"
  git checkout --theirs "${CONFLICTS[@]}"
  ./scripts/generate-rust-bridge.sh >/dev/null
  git add "${GENERATED[@]}"
  git -c commit.gpgsign=false commit --quiet --no-edit
fi

step "checks"
(cd rust && cargo check --quiet)
fvm flutter analyze --no-fatal-infos

if [ -n "${NO_PUSH:-}" ]; then
  echo "merged locally; not pushed (NO_PUSH)"
else
  git push --quiet origin "$BRANCH"
  echo "pushed $BRANCH"
fi
echo "next: run the test suites (rust: cargo test --lib; flutter: fvm flutter test) before relying on it"
