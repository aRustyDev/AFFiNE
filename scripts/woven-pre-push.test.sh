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
# Every fixture below asserts BOTH the exit code and the specific diagnostic
# message the hook is expected to print. An exit-code-only assertion cannot
# tell "the -x check refused this" from "sh failed to exec a missing file and
# the fallback branch refused it" — both are nonzero, only one is the check
# the fixture claims to cover, and a deleted check would leave every such
# fixture green.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HOOK="$REPO_ROOT/.husky/pre-push"
[ -f "$HOOK" ] || { echo "FATAL: $HOOK missing" >&2; exit 2; }

# Refuse to run on a dirty tree up front rather than repairing one. No
# fixture below edits a tracked file — everything that needs a git repo to
# poke at builds its own scratch one under TMPDIR_T — but a cleanup trap must
# only ever touch what it itself created, and the cheapest way to guarantee
# that is to never let this suite start against a tree it didn't create clean.
# THIS_HOOK and THIS_SUITE are excluded from that scan on purpose: the normal
# edit-hook / edit-fixture / re-run loop leaves exactly those two tracked
# files modified and nothing else, and refusing to let this suite verify its
# own pending edit is a usability bug, not a safety property — this check
# exists to protect a developer's UNRELATED uncommitted work, which by
# definition cannot live in the two files this suite is itself about.
dirty_status_precheck="$(git status --porcelain --untracked-files=no -- . ':(exclude).husky/pre-push' ':(exclude)scripts/woven-pre-push.test.sh')"; dirty_rc_precheck=$?
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
# Production is invoked by husky as `sh -e`; our own harness calls plain `sh`.
# That gap is exactly how a `set -e` abort (a plain assignment's command
# substitution failing) could go unnoticed here while still breaking the real
# hook — see the "-e parity" pass below, which runs a subset of the same
# fixtures through this instead.
run_hook_strict() { sh -e "$HOOK" "$1" "$2" >"$OUT" 2>&1 </dev/null; RC=$?; }
# Same, but with $2 entirely absent (as opposed to present-and-empty) and run
# from an arbitrary directory — used by the environment-error fixtures below,
# which need control over either argv or the invocation directory.
run_hook_argv() { ( cd "$1" && shift && sh "$HOOK" "$@" >"$OUT" 2>&1 </dev/null ); RC=$?; }
# For the branch-name-intent fixtures: $3 is synthetic "<local ref> <local
# sha> <remote ref> <remote sha>" ref-line content, exactly as git itself
# would put on stdin. It is written to a scratch file and fed in via `<`,
# NOT piped in — a shell function on the right end of a pipe runs in a
# subshell in bash, so the `RC=$?` below would update a copy that vanishes
# with the subshell instead of the caller's $RC (verified: piping into this
# function was tried first, and every fixture using it misreported rc=2
# regardless of the hook's actual, correctly-printed exit code).
# WOVEN_PRE_PUSH_STDIN_TIMEOUT overrides the hook's bounded-read timeout so
# the hang-prevention fixtures do not have to wait out the production
# default to prove they do not hang.
run_hook_stdin() {
  # printf '%s\n', not '%s': $3 arrives via a $(...) command substitution
  # (to build it with the shared printf format below), which strips its
  # trailing newline — so a naive '%s' would write a final ref line with NO
  # terminating newline, and the hook's `while read` loop silently skips a
  # final line that is not newline-terminated. Verified: that exact bug
  # made every branch-name fixture below pass or fail for the wrong reason
  # (the loop body never ran at all) before this fix.
  printf '%s\n' "$3" >"$TMPDIR_T/stdin_refs.txt"
  WOVEN_PRE_PUSH_STDIN_TIMEOUT="${WOVEN_PRE_PUSH_STDIN_TIMEOUT:-1}" sh "$HOOK" "$1" "$2" <"$TMPDIR_T/stdin_refs.txt" >"$OUT" 2>&1
  RC=$?
}
dump()     { sed 's/^/     | /' "$OUT" >&2; }
# Literal (-F) substring match against the last run's captured output — the
# thing that actually distinguishes "the check this fixture names fired" from
# "some other nonzero exit happened to occur".
has_msg()  { grep -qF "$1" "$OUT"; }

# Three-line stub guards for the WOVEN_GUARD testing seam (identical pattern
# to scripts/woven-upstream-branch.test.sh's STUB_RC1/STUB_RC2), covering all
# three points of the guard's own exit contract.
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

# rc=2 is the guard's OWN usage/environment error (unresolvable baseline, an
# unparseable manifest row) — distinct from rc=1, and the hook must not
# collapse the two into the same "FORK-LOCAL CORE PATCH" diagnosis.
STUB_ENV_ERROR="$TMPDIR_T/stub-guard-env-error.sh"
cat > "$STUB_ENV_ERROR" <<'EOF'
#!/usr/bin/env bash
echo "STUB GUARD: simulated usage/environment error (rc=2) for test purposes"
exit 2
EOF
chmod +x "$STUB_ENV_ERROR"

# Runtime capability probe, not an assumption: on some hosts (observed on this
# workstation's NTFS/MSYS git-bash) `chmod 644` does not clear `[ -x ]` for a
# freshly created file, so a fixture that relies on that to simulate "guard
# present but not executable" would be vacuous there while still being a real,
# meaningful check on a POSIX runner (this suite's CI home is ubuntu-latest).
# Decide by testing the actual filesystem instead of naming the workstation.
chmod_enforces_no_x() {
  local probe="$TMPDIR_T/.xprobe.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$probe"
  chmod 644 "$probe"
  if [ -x "$probe" ]; then
    rm -f "$probe"
    return 1
  fi
  rm -f "$probe"
  return 0
}

# Symmetric probe for the other direction: this workstation's tmp mount was
# observed, mid-session, to leave a freshly `chmod +x`'d file at `-rw-r--r--`
# (no error, bit simply does not take) — the opposite anomaly from the one
# chmod_enforces_no_x guards against, and just as capable of making a fixture
# that assumes chmod "works" pass or fail for the wrong reason. Verify instead
# of assume.
chmod_grants_x() {
  local probe="$TMPDIR_T/.xprobe2.sh"
  printf 'exit 0\n' > "$probe"
  chmod +x "$probe"
  if [ -x "$probe" ]; then
    rm -f "$probe"
    return 0
  fi
  rm -f "$probe"
  return 1
}

echo "== woven pre-push fixtures =="

echo "-- upstream destination + guard reports a violation: refused"
for url in "https://github.com/toeverything/AFFiNE.git" \
           "git@github.com:toeverything/AFFiNE.git" \
           "https://github.com/toeverything/AFFiNE" \
           "https://github.com/toeverything/AFFiNE.git/" \
           "https://github.com/toeverything/AFFiNE/"; do
  WOVEN_GUARD="$STUB_VIOLATION" run_hook "some-remote-name" "$url"
  if [ "$RC" -eq 1 ] && has_msg "FORK-LOCAL CORE PATCH"; then
    ok "refused $url"
  else
    bad "did not cleanly refuse $url (rc=$RC) — this is the leak"; dump
  fi
done

echo "-- upstream destination + guard reports clean: allowed"
WOVEN_GUARD="$STUB_CLEAN" run_hook "some-remote-name" "https://github.com/toeverything/AFFiNE.git"
if [ "$RC" -eq 0 ]; then ok "allowed when the guard reports clean"; else bad "refused a clean branch — false positive"; dump; fi

echo "-- upstream destination + guard cannot judge (rc=2): refused, but not misreported as a policy violation"
WOVEN_GUARD="$STUB_ENV_ERROR" run_hook "origin" "https://github.com/toeverything/AFFiNE.git"
if [ "$RC" -eq 2 ] && has_msg "the guard could not judge this branch" && ! has_msg "FORK-LOCAL CORE PATCH"; then
  ok "refused with the guard's own rc=2 diagnosis, not collapsed into a policy violation"
else
  bad "either allowed (rc=$RC), or misreported the guard's rc=2 as a FORK-LOCAL CORE PATCH violation"; dump
fi

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
if [ "$RC" -eq 1 ] && has_msg "FORK-LOCAL CORE PATCH"; then
  ok "refused notoeverything/AFFiNE (guard was invoked and reported a violation)"
else
  bad "allowed, or refused for a different reason — the substring match got loosened, or the guard was skipped"; dump
fi

# The remote's NAME must carry no weight either way.
echo "-- the remote NAME is not the signal"
WOVEN_GUARD="$STUB_VIOLATION" run_hook "upstream" "git@github.com:aRustyDev/AFFiNE.git"
if [ "$RC" -eq 0 ]; then ok "a remote NAMED upstream pointing at the fork is allowed"; else bad "keyed on the name, not the URL"; dump; fi

WOVEN_GUARD="$STUB_VIOLATION" run_hook "origin" "git@github.com:toeverything/AFFiNE.git"
if [ "$RC" -eq 1 ] && has_msg "FORK-LOCAL CORE PATCH"; then
  ok "a remote NAMED origin pointing at upstream is still refused"
else
  bad "keyed on the name — an innocuous name let an upstream push skip the check"; dump
fi

echo
echo "-- fail-closed: an empty or missing destination URL refuses rather than allows"
run_hook "origin" ""
if [ "$RC" -eq 2 ] && has_msg "no remote URL supplied"; then
  ok "refused an empty \$2"
else
  bad "did not cleanly refuse an empty \$2 (rc=$RC) — absence read as success"; dump
fi

run_hook_argv "$REPO_ROOT" "origin"
if [ "$RC" -eq 2 ] && has_msg "no remote URL supplied"; then
  ok "refused a missing \$2 (only \$1 supplied)"
else
  bad "did not cleanly refuse a missing \$2 (rc=$RC) — absence read as success"; dump
fi

echo "-- fail-closed: an unresolvable repo root refuses rather than allows"
NOT_A_REPO="$TMPDIR_T/not-a-repo"
mkdir -p "$NOT_A_REPO"
run_hook_argv "$NOT_A_REPO" "origin" "https://github.com/aRustyDev/AFFiNE.git"
if [ "$RC" -eq 2 ] && has_msg "could not resolve the repository root"; then
  ok "refused when git rev-parse --show-toplevel fails"
else
  bad "did not cleanly refuse outside any git repo (rc=$RC) — absence read as success"; dump
fi

echo "-- fail-closed: a missing baseline file refuses even a fork-bound push"
SCRATCH_NOBASELINE="$TMPDIR_T/scratch-nobaseline"
mkdir -p "$SCRATCH_NOBASELINE"
( cd "$SCRATCH_NOBASELINE" && git init -q )
run_hook_argv "$SCRATCH_NOBASELINE" "origin" "https://github.com/aRustyDev/AFFiNE.git"
if [ "$RC" -eq 2 ] && has_msg "baseline file missing"; then
  ok "refused with no scripts/woven-upstream-baseline present"
else
  bad "did not cleanly refuse with no baseline file (rc=$RC) — cannot have ruled out upstream without it"; dump
fi

echo "-- fail-closed: a baseline with no UPSTREAM_REPO line refuses"
SCRATCH_NOREPO="$TMPDIR_T/scratch-norepo"
mkdir -p "$SCRATCH_NOREPO/scripts"
( cd "$SCRATCH_NOREPO" && git init -q )
printf 'UPSTREAM_COMMIT=deadbeef\n' > "$SCRATCH_NOREPO/scripts/woven-upstream-baseline"
run_hook_argv "$SCRATCH_NOREPO" "origin" "https://github.com/aRustyDev/AFFiNE.git"
if [ "$RC" -eq 2 ] && has_msg "UPSTREAM_REPO not found or empty"; then
  ok "refused with UPSTREAM_REPO absent from the baseline"
else
  bad "did not cleanly refuse with UPSTREAM_REPO unreadable (rc=$RC) — cannot have ruled out upstream without it"; dump
fi

# The mutation this fixture exists to catch: a NAIVE `-z` check on the parsed
# value treats "toeverything/AFFiNE " (one trailing space) as a valid,
# non-empty needle. It IS non-empty — it simply then matches no real URL, so
# an actual push to actual upstream falls through to the default case and
# exits 0 with no output at all. Verified BEFORE the trim/validate fix landed:
# this exact fixture failed (rc=0, empty $OUT) against that version of the
# hook.
echo "-- fail-closed: a trailing space in UPSTREAM_REPO no longer disables the match"
SCRATCH_TRAILSPACE="$TMPDIR_T/scratch-trailspace"
mkdir -p "$SCRATCH_TRAILSPACE/scripts"
( cd "$SCRATCH_TRAILSPACE" && git init -q )
printf 'UPSTREAM_COMMIT=deadbeef\nUPSTREAM_REPO=toeverything/AFFiNE \n' > "$SCRATCH_TRAILSPACE/scripts/woven-upstream-baseline"
WOVEN_GUARD="$STUB_VIOLATION" run_hook_argv "$SCRATCH_TRAILSPACE" "origin" "https://github.com/toeverything/AFFiNE.git"
if [ "$RC" -eq 1 ] && has_msg "FORK-LOCAL CORE PATCH"; then
  ok "a trailing space on the UPSTREAM_REPO line still matches upstream and is refused"
else
  bad "a trailing space silently disabled the match (rc=$RC) — this is the leak the review caught"; dump
fi

echo "-- fail-closed: a malformed (non owner/repo) UPSTREAM_REPO value refuses rather than guessing"
for bad_value in "toeverything" "toeverything/AFFiNE/extra" "toeverything AFFiNE" ""; do
  SCRATCH_MALFORMED="$TMPDIR_T/scratch-malformed-$(printf '%s' "$bad_value" | tr -c 'A-Za-z0-9' '_')"
  mkdir -p "$SCRATCH_MALFORMED/scripts"
  ( cd "$SCRATCH_MALFORMED" && git init -q )
  printf 'UPSTREAM_COMMIT=deadbeef\nUPSTREAM_REPO=%s\n' "$bad_value" > "$SCRATCH_MALFORMED/scripts/woven-upstream-baseline"
  run_hook_argv "$SCRATCH_MALFORMED" "origin" "https://github.com/toeverything/AFFiNE.git"
  if [ "$RC" -eq 2 ] && { has_msg "does not look like owner/repo" || has_msg "UPSTREAM_REPO not found or empty"; }; then
    ok "refused UPSTREAM_REPO='$bad_value'"
  else
    bad "did not cleanly refuse UPSTREAM_REPO='$bad_value' (rc=$RC)"; dump
  fi
done

echo "-- fail-closed: a destination URL that normalises to nothing refuses rather than guessing"
run_hook "origin" ".git"
if [ "$RC" -eq 2 ] && has_msg "could not normalise the destination URL"; then
  ok "refused a URL that strips down to an empty haystack"
else
  bad "did not cleanly refuse an unnormalisable URL (rc=$RC)"; dump
fi

echo "-- fail-closed: a missing guard refuses an upstream-bound push"
WOVEN_GUARD="$TMPDIR_T/does-not-exist.sh" run_hook "origin" "https://github.com/toeverything/AFFiNE.git"
if [ "$RC" -eq 2 ] && has_msg "guard not found or not executable"; then
  ok "refused when the guard binary is missing"
else
  bad "did not cleanly refuse with no guard to check it (rc=$RC) — absence read as success"; dump
fi

echo "-- fail-closed: a present but non-executable guard refuses an upstream-bound push"
if chmod_enforces_no_x; then
  NONEXEC_GUARD="$TMPDIR_T/nonexec-guard.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$NONEXEC_GUARD"
  chmod 644 "$NONEXEC_GUARD"
  WOVEN_GUARD="$NONEXEC_GUARD" run_hook "origin" "https://github.com/toeverything/AFFiNE.git"
  if [ "$RC" -eq 2 ] && has_msg "guard not found or not executable"; then
    ok "refused via the -x check when the guard lacks the execute bit"
  else
    bad "did not refuse via the -x check for a non-executable guard (rc=$RC)"; dump
  fi
else
  echo "   (skipped: this filesystem does not clear [ -x ] via chmod 644 — verified at runtime; ubuntu-latest CI does not skip this)"
fi

# A guard that IS reported executable by `[ -x ]` but fails when actually run
# (garbage content, no valid shebang) must land in the guard_rc dispatch's
# fallback branch, not be misreported as a FORK-LOCAL CORE PATCH. Gated on
# chmod_grants_x for the same reason the fixture above is gated on
# chmod_enforces_no_x: without a working +x, this file never gets past the
# hook's own -x check, and the fixture would then be asserting the WRONG
# check fired instead of testing what it names.
echo "-- fail-closed: a guard that exists, passes -x, but cannot actually run"
if chmod_grants_x; then
  UNRUNNABLE_GUARD="$TMPDIR_T/unrunnable-guard.sh"
  printf 'this is not a valid shebang or script\n' > "$UNRUNNABLE_GUARD"
  chmod +x "$UNRUNNABLE_GUARD"
  WOVEN_GUARD="$UNRUNNABLE_GUARD" run_hook "origin" "https://github.com/toeverything/AFFiNE.git"
  if [ "$RC" -eq 2 ] && has_msg "the guard could not judge this branch" && ! has_msg "FORK-LOCAL CORE PATCH"; then
    ok "refused via the guard_rc dispatch fallback, not misreported as a policy violation"
  else
    bad "did not cleanly refuse a guard that cannot run (rc=$RC)"; dump
  fi
else
  echo "   (skipped: this filesystem did not honor chmod +x for a fresh file — verified at runtime; ubuntu-latest CI does not skip this)"
fi

echo
echo "== branch-name intent: upstream/** guards the push regardless of destination =="
SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"
ZERO_SHA="0000000000000000000000000000000000000000"
FORK_URL="https://github.com/aRustyDev/AFFiNE.git"

echo "-- an upstream/** branch pushed to the FORK is still guarded (this is the gap the review found)"
WOVEN_GUARD="$STUB_VIOLATION" run_hook_stdin "origin" "$FORK_URL" \
  "$(printf 'refs/heads/upstream/oidc-fix %s refs/heads/upstream/oidc-fix %s\n' "$SHA_A" "$ZERO_SHA")"
if [ "$RC" -eq 1 ] && has_msg "FORK-LOCAL CORE PATCH" && has_msg "pushing a branch named upstream/**"; then
  ok "refused an upstream/** branch pushed to the fork, keyed on the branch name alone"
else
  bad "did not refuse an upstream/** branch pushed to the fork (rc=$RC)"; dump
fi

echo "-- an upstream/** branch pushed to the FORK, guard reports clean: allowed"
WOVEN_GUARD="$STUB_CLEAN" run_hook_stdin "origin" "$FORK_URL" \
  "$(printf 'refs/heads/upstream/build-test %s refs/heads/upstream/build-test %s\n' "$SHA_A" "$ZERO_SHA")"
if [ "$RC" -eq 0 ]; then
  ok "allowed an upstream/** branch pushed to the fork when the guard reports clean"
else
  bad "refused a clean upstream/** branch — false positive"; dump
fi

echo "-- an ORDINARY branch pushed to the fork is not guarded by name (would be refused if it were)"
WOVEN_GUARD="$STUB_VIOLATION" run_hook_stdin "origin" "$FORK_URL" \
  "$(printf 'refs/heads/feature/widgets %s refs/heads/feature/widgets %s\n' "$SHA_A" "$ZERO_SHA")"
if [ "$RC" -eq 0 ] && [ ! -s "$OUT" ]; then
  ok "an ordinary branch name to the fork stays silent and exit 0, even though the stubbed guard would refuse"
else
  bad "an ordinary branch to the fork was not silently allowed (rc=$RC)"; dump
fi

echo "-- deleting an upstream/** ref does not trigger the guard (nothing is actually being sent)"
WOVEN_GUARD="$STUB_VIOLATION" run_hook_stdin "origin" "$FORK_URL" \
  "$(printf '(delete) %s refs/heads/upstream/oidc-fix %s\n' "$ZERO_SHA" "$SHA_B")"
if [ "$RC" -eq 0 ] && [ ! -s "$OUT" ]; then
  ok "a pure deletion of an upstream/** ref is not treated as a push of one"
else
  bad "a deletion of an upstream/** ref was treated as a push (rc=$RC) — nothing was actually sent"; dump
fi

echo "-- a destination match still fires (and is reported) even when the branch name would not have"
WOVEN_GUARD="$STUB_VIOLATION" run_hook_stdin "origin" "https://github.com/toeverything/AFFiNE.git" \
  "$(printf 'refs/heads/feature/widgets %s refs/heads/feature/widgets %s\n' "$SHA_A" "$ZERO_SHA")"
if [ "$RC" -eq 1 ] && has_msg "FORK-LOCAL CORE PATCH" && has_msg "destination is UPSTREAM"; then
  ok "an upstream destination is refused via the destination message, not the branch-name one"
else
  bad "destination-triggered refusal regressed (rc=$RC)"; dump
fi

echo
echo "== branch-name intent: reading stdin for it must never hang =="
echo "-- no stdin redirect at all does not hang"
timeout 5 sh "$HOOK" "origin" "$FORK_URL" >"$OUT" 2>&1
RC=$?
if [ "$RC" -ne 124 ]; then
  ok "completed without an explicit stdin redirect (rc=$RC, not killed by the outer timeout)"
else
  bad "hung with no stdin redirect at all — killed by the outer timeout"; dump
fi

echo "-- a writer that holds the pipe open without ever closing it does not hang"
FIFO="$TMPDIR_T/held-open.fifo"
mkfifo "$FIFO"
( exec 3>"$FIFO"; sleep 30; exec 3>&- ) &
holder_pid=$!
WOVEN_PRE_PUSH_STDIN_TIMEOUT=1 timeout 10 sh "$HOOK" "origin" "$FORK_URL" <"$FIFO" >"$OUT" 2>&1
RC=$?
kill "$holder_pid" 2>/dev/null
wait "$holder_pid" 2>/dev/null
rm -f "$FIFO"
if [ "$RC" -ne 124 ]; then
  ok "completed while a writer held the pipe open without closing it (rc=$RC, not killed by the outer timeout)"
else
  bad "hung on a pipe held open by another process — killed by the outer timeout"; dump
fi

echo
echo "-- -e parity: husky invokes this hook as \`sh -e\` — the same cases must behave identically under it"
STRICT_FAIL=0
for url in "https://github.com/toeverything/AFFiNE.git" "https://github.com/toeverything/AFFiNE.git/"; do
  WOVEN_GUARD="$STUB_VIOLATION" run_hook_strict "origin" "$url"
  if [ "$RC" -eq 1 ] && has_msg "FORK-LOCAL CORE PATCH"; then :; else STRICT_FAIL=1; bad "sh -e: $url not refused correctly (rc=$RC)"; dump; fi
done
for url in "https://github.com/aRustyDev/AFFiNE.git"; do
  WOVEN_GUARD="$STUB_VIOLATION" run_hook_strict "origin" "$url"
  if [ "$RC" -eq 0 ]; then :; else STRICT_FAIL=1; bad "sh -e: $url not allowed correctly (rc=$RC)"; dump; fi
done
run_hook_strict "origin" ""
if [ "$RC" -eq 2 ] && has_msg "no remote URL supplied"; then :; else STRICT_FAIL=1; bad "sh -e: empty \$2 not refused correctly (rc=$RC)"; dump; fi
( cd "$NOT_A_REPO" && sh -e "$HOOK" "origin" "https://github.com/aRustyDev/AFFiNE.git" >"$OUT" 2>&1 </dev/null ); RC=$?
if [ "$RC" -eq 2 ] && has_msg "could not resolve the repository root"; then :; else STRICT_FAIL=1; bad "sh -e: unresolvable repo root not refused correctly (rc=$RC)"; dump; fi
if [ "$STRICT_FAIL" -eq 0 ]; then ok "all of the above behave identically under sh -e"; fi

echo
printf '%s\n' "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
