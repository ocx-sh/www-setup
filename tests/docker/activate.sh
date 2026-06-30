#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# SC2016: the per-shell probe snippets are intentionally single-quoted so they
# are interpreted by the TARGET shell (bash/zsh/fish/nu/elvish), not the outer
# POSIX sh. Expansion in the outer shell would be a bug.
# shellcheck disable=SC2016

set -eu

SHELL_UNDER_TEST="${1:?activate.sh: shell required (bash|dash|zsh|ksh|fish|nu|elvish|pwsh)}"
VERSION="${2:-latest}"

# Canonical real-CLI bin dir relative to OCX_HOME (audit ground truth).
OCX_BIN_SUBPATH="symlinks/ocx.sh/ocx/cli/current/content/bin"

# --- Resolve a writable HOME + per-user OCX_HOME ---
# Profile modification needs a writable HOME. When run as 'tester', HOME should
# already be /home/tester; fall back defensively.
if [ -z "${HOME:-}" ] || [ ! -w "${HOME:-/nonexistent}" ]; then
    HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
    [ -n "$HOME" ] || HOME="/tmp/ocx-activate-home"
    export HOME
fi
mkdir -p "$HOME"

# Per-user OCX_HOME so generated env files + the binary land under the tester's
# home. run.sh passes --env OCX_HOME=/home/tester/.ocx; honor an inherited,
# writable, home-scoped OCX_HOME, but ignore the container's baked root smoke
# path (/work/.ocx) which the 'tester' user cannot write to.
case "${OCX_HOME:-}" in
    "$HOME"/*) ;; # inherited per-user value — keep it
    *) OCX_HOME="$HOME/.ocx" ;;
esac
export OCX_HOME
mkdir -p "$OCX_HOME"

OCX_BIN_DIR="${OCX_HOME}/${OCX_BIN_SUBPATH}"
OCX_BIN="${OCX_BIN_DIR}/ocx"

# Profile modification MUST be enabled for this test. Defensively clear the
# skip knobs the smoke containers may set in the environment. (Activation in the
# thin model is performed by `ocx self setup`, which the installer invokes; it
# requires a REAL ocx binary, so this path is exercised with OCX_TEST_BINARY.)
unset OCX_NO_MODIFY_PATH 2>/dev/null || :
unset OCX_INSTALL_NO_SETUP 2>/dev/null || :

log() { echo ">>> [activate] $*"; }
fail() {
    _code="$1"
    shift
    echo "!!! [activate] $*" >&2
    exit "$_code"
}

distro_desc() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || uname -a
    else
        uname -a
    fi
}

log "distro:  $(distro_desc)"
log "arch:    $(uname -m)"
log "user:    $(id -un) (HOME=$HOME)"
log "shell:   $SHELL_UNDER_TEST"
log "version: $VERSION"
log "OCX_HOME: $OCX_HOME"

# --- Map shell name -> the SHELL value install.sh keys profile detection off ---
# install.sh's detect_profile / modify_shell_profile branch on basename($SHELL).
# nushell must present as 'nu' (install.sh matches the literal 'nu').
resolve_shell_bin() {
    case "$1" in
        nu | nushell) command -v nu ;;
        pwsh | powershell) command -v pwsh ;;
        *) command -v "$1" ;;
    esac
}

SHELL_BIN=$(resolve_shell_bin "$SHELL_UNDER_TEST" 2>/dev/null || true)
if [ -z "$SHELL_BIN" ]; then
    fail 2 "shell '$SHELL_UNDER_TEST' is not installed in this image (run install-shells.sh)"
fi

# The installer uses basename($SHELL); set SHELL so profile/autoload detection
# targets the shell under test. Use 'nu' as the basename for nushell.
case "$SHELL_UNDER_TEST" in
    nu | nushell)
        _nu_dir=$(dirname "$SHELL_BIN")
        SHELL="$_nu_dir/nu"
        ;;
    *)
        SHELL="$SHELL_BIN"
        ;;
esac
export SHELL

# --- Step (a): run the installer with profile modification ENABLED ---
# When a binary is injected via __OCX_TESTING_INSTALL_BINARY, the installer
# takes its network-free path: it copies that binary to the canonical bin dir,
# derives the version from it, skips download/checksum/extract/bootstrap, and
# still generates the env shims + profile edits (so activation + completion can
# be exercised). The --version flag is irrelevant on that path.
log "running installer (profile modification enabled)..."
if [ -n "${__OCX_TESTING_INSTALL_BINARY:-}" ]; then
    log "injection: __OCX_TESTING_INSTALL_BINARY=${__OCX_TESTING_INSTALL_BINARY}"
    [ -f "${__OCX_TESTING_INSTALL_BINARY}" ] ||
        fail 2 "__OCX_TESTING_INSTALL_BINARY does not point to a file: ${__OCX_TESTING_INSTALL_BINARY}"
    sh /work/install.sh
elif [ "$VERSION" = "latest" ]; then
    sh /work/install.sh
else
    sh /work/install.sh --version "$VERSION"
fi

# Sanity: the installer must have placed a runnable binary at the canonical path.
if [ ! -x "$OCX_BIN" ]; then
    ls -la "$OCX_BIN_DIR" >&2 2>/dev/null || :
    fail 3 "installer did not place an executable ocx at $OCX_BIN (install failed)"
fi
log "binary present at $OCX_BIN"

# Expected absolute target the activated PATH must resolve 'ocx' to.
EXPECTED="$OCX_BIN"

# --- Step (b): launch the target shell and assert activation happened ---
# Each branch launches a login/interactive shell so the profile / autoload is
# sourced, then resolves 'ocx' and runs it. The probe prints the resolved path
# on stdout so we can distinguish:
#   - resolved + runs    -> PASS
#   - not resolved       -> exit 8 (activation did not happen)
#   - resolved but fails -> exit 9 (binary broken)
#
# The probe writes a sentinel "OCX_RESOLVED=<path>" line we grep for.

run_probe() {
    # run_probe captures combined output; sets PROBE_OUT / PROBE_RC.
    PROBE_OUT="$("$@" 2>&1)" && PROBE_RC=0 || PROBE_RC=$?
}

case "$SHELL_UNDER_TEST" in
    bash)
        # Completion introspection: `complete -p ocx` prints the registered
        # completion spec for ocx (e.g. "complete -F _ocx ocx"); it fails / is
        # empty when nothing is registered. Run it AFTER the shim has sourced so
        # the `complete -F _ocx ocx` line the installer's shim emits has taken.
        run_probe bash -lic '
            p="$(command -v ocx || true)"
            echo "OCX_RESOLVED=${p}"
            if [ -n "$p" ]; then ocx about >/dev/null 2>&1 || ocx version >/dev/null 2>&1; fi
            c="$(complete -p ocx 2>/dev/null || true)"
            echo "OCX_COMPLETION=${c}"
        '
        ;;
    zsh)
        # Completion introspection: zsh registers completers in the $_comps
        # associative array. The ocx activation block (sourced from the profile by
        # `zsh -lic`) ALREADY initializes the completion system — it runs
        # `compinit -C` itself when `compdef` is not yet defined — and registers
        # the ocx completer at runtime via `compdef`. We therefore do NOT run
        # `compinit` again here: a second `compinit` rebuilds $_comps from fpath
        # completion FILES and so WIPES the runtime `compdef` registration (the ocx
        # completer is registered at runtime, not shipped as an fpath file),
        # yielding a false "no completion" negative (exit 10). Just read the key
        # after the profile has sourced.
        run_probe zsh -lic '
            p="$(command -v ocx || true)"
            echo "OCX_RESOLVED=${p}"
            if [ -n "$p" ]; then ocx about >/dev/null 2>&1 || ocx version >/dev/null 2>&1; fi
            c="$(print -l ${(k)_comps[ocx]} 2>/dev/null || true)"
            echo "OCX_COMPLETION=${c}"
        '
        ;;
    dash | ksh)
        # No -lic equivalent that reliably sources ~/.profile across dash/ksh in
        # a non-interactive container; emulate a login shell by sourcing
        # ~/.profile explicitly, which is exactly what install.sh edits for
        # these (detect_profile default branch -> ~/.profile).
        run_probe "$SHELL_BIN" -c '
            [ -f "$HOME/.profile" ] && . "$HOME/.profile"
            p="$(command -v ocx || true)"
            echo "OCX_RESOLVED=${p}"
            if [ -n "$p" ]; then ocx about >/dev/null 2>&1 || ocx version >/dev/null 2>&1; fi
        '
        ;;
    fish)
        # Completion introspection: `complete -C 'ocx '` asks fish to produce
        # the completion candidates for the partial command line "ocx " using
        # whatever completer is registered. Non-empty output means ocx
        # completion is wired up. Join the (possibly multi-line) candidate list
        # into a single sentinel value with `string join`.
        run_probe fish -lc '
            set -l p (command -v ocx; or true)
            echo "OCX_RESOLVED=$p"
            if test -n "$p"
                ocx about >/dev/null 2>&1; or ocx version >/dev/null 2>&1
            end
            set -l c (complete -C "ocx " 2>/dev/null | string join "|"; or true)
            echo "OCX_COMPLETION=$c"
        '
        ;;
    nu | nushell)
        # nushell loads the installer's shim through its vendor autoload dir
        # ($XDG_DATA_HOME/nushell/vendor/autoload/ocx.nu -> env.nu). BUT vendor
        # autoload ONLY fires in an interactive REPL, which nushell refuses to
        # start without a TTY ("launched as a REPL, but STDIN is not a TTY") — so
        # we cannot drive it over stdin like elvish. And `nu -c` does NOT load
        # vendor autoload at all. So, exactly as the dash/ksh probes source
        # ~/.profile explicitly to emulate a login shell, source the installer's
        # autoload entry explicitly to emulate the interactive autoload, then
        # resolve ocx IN THE SAME invocation (env mutations from `source` only
        # persist within the one nu process). This still exercises the real
        # chain ocx.nu -> env.nu -> PATH prepend the installer wrote.
        #
        # `which ocx` returns a (possibly empty) table; extract the path column
        # defensively so a version drift in column shape degrades to an empty
        # path (-> exit 8) rather than a parse error.
        # Completion is BEST-EFFORT for nushell: nushell has NO clap_complete
        # backend, so the shim activates with --no-completion and the binary
        # emits no completer. We therefore only assert: shim sources cleanly +
        # ocx on PATH. The OCX_COMPLETION sentinel is emitted empty (the shared
        # evaluator does not require completion for nushell).
        _nu_autoload="${XDG_DATA_HOME:-$HOME/.local/share}/nushell/vendor/autoload/ocx.nu"
        run_probe nu -c "
            source \"${_nu_autoload}\"
            let t = (which ocx)
            let p = (try { if ((\$t | length) > 0) { \$t | get 0 | get path } else { \"\" } } catch { \"\" })
            print \$\"OCX_RESOLVED=(\$p)\"
            if (\$p | is-not-empty) { try { ocx about | ignore } }
            print \"OCX_COMPLETION=\"
        "
        ;;
    elvish)
        # rc.elv sources env.elv via the BEGIN/END block, BUT `elvish -c <code>`
        # does NOT source rc.elv (only an INTERACTIVE elvish does). Feeding the
        # probe to interactive elvish over stdin makes it source rc.elv (so the
        # ocx activation block runs) AND provides the `edit:` namespace that the
        # `self activate --shell=elvish` completion block references (that var
        # only exists in interactive mode). Use the builtin search-external (no
        # /usr/bin/which dependency) guarded by has-external so a missing ocx
        # degrades to an empty path (-> exit 8) rather than an exception.
        # Completion introspection is BEST-EFFORT for elvish: the real
        # `self activate --shell=elvish --completion` block sets
        # edit:completion:arg-completer[ocx], which only exists in INTERACTIVE
        # elvish. We probe for it but never fail on its absence (the shared
        # evaluator treats elvish completion as best-effort). The load-bearing
        # assertion for elvish remains: shim sourced cleanly + ocx on PATH.
        _elv_probe='
            var p = ""
            if (has-external ocx) {
                set p = (search-external ocx)
            }
            echo "OCX_RESOLVED="$p
            if (not-eq $p "") {
                try { ocx about > /dev/null 2>&1 } catch e { }
            }
            var c = ""
            try {
                if (has-key $edit:completion:arg-completer ocx) {
                    set c = "registered"
                }
            } catch e { }
            echo "OCX_COMPLETION="$c
        '
        run_probe sh -c 'printf "%s\nexit\n" "$1" | "$2" -i 2>/dev/null' \
            _ "$_elv_probe" "$SHELL_BIN"
        ;;
    pwsh | powershell)
        # BEST-EFFORT. install.sh has no powershell profile hook on Linux, so a
        # fresh pwsh login shell may NOT auto-activate. We first try a normal
        # login shell; if that does not pick up ocx, we explicitly source the
        # generated env.ps1 and report "binary-on-PATH via env.ps1, no
        # auto-profile" instead of failing the whole matrix.
        ENV_PS1="$OCX_HOME/env.ps1"
        run_probe pwsh -NoLogo -Command '
            $p = (Get-Command ocx -ErrorAction SilentlyContinue).Source
            Write-Output ("OCX_RESOLVED=" + $p)
            if ($p) { & ocx about | Out-Null }
        '
        if ! printf '%s' "$PROBE_OUT" | grep -q 'OCX_RESOLVED=..*'; then
            log "pwsh login shell did not auto-activate (expected — no profile hook)"
            if [ -f "$ENV_PS1" ]; then
                log "sourcing env.ps1 explicitly (best-effort)..."
                run_probe pwsh -NoLogo -Command "
                    . '$ENV_PS1'
                    \$p = (Get-Command ocx -ErrorAction SilentlyContinue).Source
                    Write-Output ('OCX_RESOLVED=' + \$p)
                    if (\$p) { & ocx about | Out-Null }
                "
                if printf '%s' "$PROBE_OUT" | grep -q "OCX_RESOLVED=${EXPECTED}"; then
                    log "PASS (best-effort): binary-on-PATH via env.ps1, no auto-profile"
                    exit 0
                fi
            fi
            fail 8 "pwsh: ocx not on PATH via login profile NOR via env.ps1"
        fi
        ;;
    *)
        fail 2 "unknown shell '$SHELL_UNDER_TEST'"
        ;;
esac

# --- Evaluate the probe result (shared by all non-pwsh branches) ---
log "probe output:"
printf '%s\n' "$PROBE_OUT" | sed 's/^/    /' >&2

RESOLVED=$(printf '%s\n' "$PROBE_OUT" | sed -n 's/^OCX_RESOLVED=//p' | head -n1)

if [ -z "$RESOLVED" ]; then
    fail 8 "$SHELL_UNDER_TEST started but ocx is NOT on PATH — activation did NOT happen (shim/profile not sourced)"
fi

# Activation happened: the resolved path must be the canonical OCX bin (allow a
# trailing symlink resolution, but the directory must match).
case "$RESOLVED" in
    "$EXPECTED") : ;;
    "$OCX_BIN_DIR"/ocx) : ;;
    *)
        # Resolved to *some* ocx but not ours — flag it (PATH shadow) but only if
        # it is outside our OCX_HOME.
        case "$RESOLVED" in
            "$OCX_HOME"/*) : ;;
            *) fail 8 "$SHELL_UNDER_TEST resolved ocx to '$RESOLVED', not the installed $EXPECTED (PATH shadow / wrong activation)" ;;
        esac
        ;;
esac

if [ "$PROBE_RC" -ne 0 ]; then
    fail 9 "$SHELL_UNDER_TEST: ocx is on PATH at '$RESOLVED' but failed to run (exit $PROBE_RC) — binary broken, not an activation problem"
fi

# --- Step (c): completion-table introspection (shared) ---
# For completion-CAPABLE shells (bash, zsh, fish) the installer's shim must
# register an ocx completer; an empty completion table means the shim passed the
# wrong --shell/--completion or the completer failed to register -> exit 10.
# elvish + nushell completion is BEST-EFFORT (interactive-only / no backend), so
# an empty value there is logged but never fails the test. dash/ksh have no
# completion model at all and emit no sentinel.
completion_required() {
    case "$1" in
        bash | zsh | fish) return 0 ;;
        *) return 1 ;;
    esac
}

# Only shells whose probe emits an OCX_COMPLETION sentinel are evaluated.
if printf '%s\n' "$PROBE_OUT" | grep -q '^OCX_COMPLETION='; then
    COMPLETION=$(printf '%s\n' "$PROBE_OUT" | sed -n 's/^OCX_COMPLETION=//p' | head -n1)
    if [ -n "$COMPLETION" ]; then
        log "completion registered for $SHELL_UNDER_TEST: $COMPLETION"
    elif completion_required "$SHELL_UNDER_TEST"; then
        fail 10 "$SHELL_UNDER_TEST: ocx is on PATH and runs, but NO completion is registered (shim passed wrong --shell/--completion or completer did not register)"
    else
        log "completion not registered for $SHELL_UNDER_TEST (best-effort shell — OK)"
    fi
fi

log "PASS: $SHELL_UNDER_TEST activates ocx at $RESOLVED and 'ocx about' runs"
