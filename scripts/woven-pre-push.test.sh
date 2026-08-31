#!/usr/bin/env bash
#
# woven-pre-push.test.sh — fixtures for the outbound pre-push hook.
#
# Invokes the hook directly with synthetic argv, so both directions are
# asserted without performing a real push. git passes the remote NAME as $1
# and the remote URL as $2; the hook must key on the URL, because a remote
# called "upstream" proves nothing.
#
# The guard-outcome fixtures below go through the WOVEN_GUARD testing seam
# (three-line stub scripts, same pattern as
# scripts/woven-upstream-branch.test.sh) rather than relying on whatever the
# current branch happens to carry. A fixture that asserted "refused" only
# because HEAD presently carries the oidc.ts patch would rot the moment that
# patch lands upstream and the manifest row is removed — the stub makes the
# guard's answer a fact this file controls, not a fact it happens to inherit.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HOOK="$REPO_ROOT/.husky/pre-push"
[ -f "$HOOK" ] || { echo "FATAL: $HOOK missing" >&2; exit 2; }

# Refuse to run on a dirty tree up front rather than repairing one. No
# fixture below edits a tracked file, but several change directory into a
# scratch git repo and a stray `git checkout --` in a shared trap has bitten
# this exact plan before (woven-upstream-branch.test.sh) — refusing on a
# dirty tree costs nothing here and rules the whole class out.
dirty_status_precheck="$(git status --porcelain --untracked-files=no)"; dirty_rc_precheck=$?
if [ "$dirty_rc_precheck" -ne 0 ] || [ -n "$dirty_status_precheck" ]; then
  echo "FATAL: working tree is dirty — commit or stash your changes before running this suite." >&2
  [ -n "$dirty_status_precheck" ] && printf '%s\n' "$dirty_status_precheck" >&2
  exit 2
fi

PASS=0; FAIL=0
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_rst=$'\033[0m'
ok()  { printf '%s\n' "${c_grn}  ✔${c_rst} $*"; PASS=$((PASS+1)); }
bad() { printf '%s\n' "${c_red}  ✗${c_rst} $*" >&2; FAIL=$((FAIL+1)); }

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
OUT="$TMPDIR_T/out.txt"; RC=0

# </dev/null: the hook must not depend on the stdin ref list, which is empty
# for a branch the remote has not seen.
run_hook() { sh "$HOOK" "$1" "$2" >"$OUT" 2>&1 </dev/null; RC=$?; }
# Same, but with $2 entirely absent (as opposed to present-and-empty) and run
# from an arbitrary directory — used by the environment-error fixtures below,
# which need control over either argv or the invocation directory.
run_hook_argv() { ( cd "$1" && shift && sh "$HOOK" "$@" >"$OUT" 2>&1 </dev/null ); RC=$?; }
dump()     { sed 's/^/     | /' "$OUT" >&2; }

# Three-line stub guards for the WOVEN_GUARD testing seam (identical pattern
# to scripts/woven-upstream-branch.test.sh's STUB_RC1/STUB_RC2).
STUB_VIOLATION="$TMPDIR_T/stub-guard-violation.sh"
cat > "$STUB_VIOLATION" <<'EOF'
#!/usr/bin/env bash
echo "STUB GUARD: simulated FORK-LOCAL CORE PATCH refusal (rc=1) for test purposes"
exit 1
EOF
chmod +x "$STUB_VIOLATION"

STUB_CLEAN="$TMPDIR_T/stub-guard-clean.sh"
cat > "$STUB_CLEAN" <<'EOF'
#!/usr/bin/env bash
echo "STUB GUARD: simulated clean result (rc=0) for test purposes"
exit 0
EOF
chmod +x "$STUB_CLEAN"

echo "== woven pre-push fixtures =="

echo "-- upstream destination + guard reports a violation: refused"
for url in "https://github.com/toeverything/AFFiNE.git" \
           "git@github.com:toeverything/AFFiNE.git" \
           "https://github.com/toeverything/AFFiNE" \
           "https://github.com/toeverything/AFFiNE.git/" \
           "https://github.com/toeverything/AFFiNE/"; do
  WOVEN_GUARD="$STUB_VIOLATION" run_hook "some-remote-name" "$url"
  if [ "$RC" -ne 0 ]; then ok "refused $url"; else bad "ALLOWED $url — this is the leak"; dump; fi
done

echo "-- upstream destination + guard reports clean: allowed"
WOVEN_GUARD="$STUB_CLEAN" run_hook "some-remote-name" "https://github.com/toeverything/AFFiNE.git"
if [ "$RC" -eq 0 ]; then ok "allowed when the guard reports clean"; else bad "refused a clean branch — false positive"; dump; fi

echo "-- fork destination: allowed, even though the (stubbed) guard would refuse"
for url in "git@github.com:aRustyDev/AFFiNE.git" \
           "https://github.com/aRustyDev/AFFiNE.git" \
           "github-kapiraman:aRustyDev/AFFiNE.git"; do
  WOVEN_GUARD="$STUB_VIOLATION" run_hook "origin" "$url"
  if [ "$RC" -eq 0 ]; then ok "allowed $url"; else bad "refused $url — false positive"; dump; fi
done

# github.com/notoeverything/AFFiNE contains "toeverything/AFFiNE" as a literal
# suffix of the owner name, so the substring match treats it as an upstream
# destination and runs the guard against it — a false positive on WHICH repo
# this is, not on whether it's safe. With the stub reporting a violation this
# manifests as a refusal for a genuinely unrelated repo: a false positive, but
# a harmless, fail-closed one (it over-blocks, it never under-blocks).
# Asserted here so nobody "fixes" the match into something looser later.
echo "-- an unrelated owner containing the needle as a substring: still routed through the guard (fail-closed, harmless)"
WOVEN_GUARD="$STUB_VIOLATION" run_hook "origin" "https://github.com/notoeverything/AFFiNE.git"
if [ "$RC" -ne 0 ]; then ok "refused notoeverything/AFFiNE (guard was invoked and reported a violation)"; else bad "allowed — the substring match got loosened, or the guard was skipped"; dump; fi

# The remote's NAME must carry no weight either way.
echo "-- the remote NAME is not the signal"
WOVEN_GUARD="$STUB_VIOLATION" run_hook "upstream" "git@github.com:aRustyDev/AFFiNE.git"
if [ "$RC" -eq 0 ]; then ok "a remote NAMED upstream pointing at the fork is allowed"; else bad "keyed on the name, not the URL"; dump; fi

WOVEN_GUARD="$STUB_VIOLATION" run_hook "origin" "git@github.com:toeverything/AFFiNE.git"
if [ "$RC" -ne 0 ]; then ok "a remote NAMED origin pointing at upstream is still refused"; else bad "keyed on the name — an innocuous name let an upstream push skip the check"; dump; fi

echo
echo "-- fail-closed: an empty or missing destination URL refuses rather than allows"
run_hook "origin" ""
if [ "$RC" -ne 0 ]; then ok "refused an empty \$2"; else bad "ALLOWED an empty destination — absence read as success"; dump; fi

run_hook_argv "$REPO_ROOT" "origin"
if [ "$RC" -ne 0 ]; then ok "refused a missing \$2 (only \$1 supplied)"; else bad "ALLOWED a missing \$2 — absence read as success"; dump; fi

echo "-- fail-closed: an unresolvable repo root refuses rather than allows"
NOT_A_REPO="$TMPDIR_T/not-a-repo"
mkdir -p "$NOT_A_REPO"
run_hook_argv "$NOT_A_REPO" "origin" "https://github.com/aRustyDev/AFFiNE.git"
if [ "$RC" -ne 0 ]; then ok "refused when git rev-parse --show-toplevel fails"; else bad "ALLOWED outside any git repo — absence read as success"; dump; fi

echo "-- fail-closed: a missing baseline file refuses even a fork-bound push"
SCRATCH_NOBASELINE="$TMPDIR_T/scratch-nobaseline"
mkdir -p "$SCRATCH_NOBASELINE"
( cd "$SCRATCH_NOBASELINE" && git init -q )
run_hook_argv "$SCRATCH_NOBASELINE" "origin" "https://github.com/aRustyDev/AFFiNE.git"
if [ "$RC" -ne 0 ]; then
  ok "refused with no scripts/woven-upstream-baseline present"
else
  bad "ALLOWED with no baseline file — cannot have ruled out upstream without it"; dump
fi

echo "-- fail-closed: a baseline with no UPSTREAM_REPO line refuses"
SCRATCH_NOREPO="$TMPDIR_T/scratch-norepo"
mkdir -p "$SCRATCH_NOREPO/scripts"
( cd "$SCRATCH_NOREPO" && git init -q )
printf 'UPSTREAM_COMMIT=deadbeef\n' > "$SCRATCH_NOREPO/scripts/woven-upstream-baseline"
run_hook_argv "$SCRATCH_NOREPO" "origin" "https://github.com/aRustyDev/AFFiNE.git"
if [ "$RC" -ne 0 ]; then
  ok "refused with UPSTREAM_REPO absent from the baseline"
else
  bad "ALLOWED with UPSTREAM_REPO unreadable — cannot have ruled out upstream without it"; dump
fi

echo "-- fail-closed: a missing/non-executable guard refuses an upstream-bound push"
WOVEN_GUARD="$TMPDIR_T/does-not-exist.sh" run_hook "origin" "https://github.com/toeverything/AFFiNE.git"
if [ "$RC" -ne 0 ]; then
  ok "refused when the guard binary is missing"
else
  bad "ALLOWED an upstream push with no guard to check it — absence read as success"; dump
fi

# A guard path that exists but is not a runnable program: on this host,
# creating a file without the execute bit is not reliable (NTFS/MSYS report
# nearly everything as "executable" regardless of chmod — verified by hand),
# so this exercises the same fail-closed outcome from the other direction: a
# guard the hook cannot successfully run must still refuse, whether the `-x`
# pre-check catches it or the invocation itself fails.
UNRUNNABLE_GUARD="$TMPDIR_T/unrunnable-guard.sh"
printf 'this is not a valid shebang or script\n' > "$UNRUNNABLE_GUARD"
WOVEN_GUARD="$UNRUNNABLE_GUARD" run_hook "origin" "https://github.com/toeverything/AFFiNE.git"
if [ "$RC" -ne 0 ]; then
  ok "refused when the guard exists but cannot be run"
else
  bad "ALLOWED an upstream push with a guard that cannot actually run"; dump
fi

echo
printf '%s\n' "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
