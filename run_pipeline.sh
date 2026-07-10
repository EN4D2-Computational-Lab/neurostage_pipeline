#!/usr/bin/env bash
# =============================================================================
# run_pipeline.sh  — NeuroStage End-to-End Neuroimaging Pipeline
# (resilient edition — survives Ctrl+C, lost SSH sessions, kill, reboot/OOM)
#
# Usage:
#   ./run_pipeline.sh [OPTIONS]
#
# Options:
#   --dicom      Override DICOM_INPUT from .env
#   --subject    Override SUBJECT_ID from .env
#   --output     Override OUTPUT_BASE from .env (where derivatives are written;
#                defaults to PIPELINE_BASE if neither is set — fully optional)
#   --from       Resume from step: bids|mriqc|freesurfer|hcp|qsiprep|fmriprep|aslprep
#   --only       Run one step only: bids|mriqc|freesurfer|hcp|qsiprep|fmriprep|aslprep
#   --dry-run    Print which steps would run (no execution)
#   --preflight  Validate all enabled steps are ready to run (no execution)
#   --status     Show true state of every step for this subject and exit
#   --force      Force re-run of a step even if marked done/running (use with --only)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Help — checked before ANYTHING else, so it works with no .env, no
# installed dependencies, nothing. Someone just wants to see the flags.
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        cat <<'EOF'
NeuroStage End-to-End Neuroimaging Pipeline

Usage:
  ./run_pipeline.sh [OPTIONS]

Options:
  --dicom <path>     Override DICOM_INPUT from .env
  --subject <id>     Override SUBJECT_ID from .env
  --output <path>    Override OUTPUT_BASE from .env (where derivatives are
                      written; defaults to PIPELINE_BASE if unset)
  --from <step>      Resume from step: bids|mriqc|freesurfer|hcp|qsiprep|fmriprep|aslprep
  --only <step>      Run one step only: bids|mriqc|freesurfer|hcp|qsiprep|fmriprep|aslprep
  --dry-run          Print which steps would run (no execution)
  --preflight        Validate all enabled steps are ready to run (no execution)
  --status           Show true state of every step for this subject and exit
  --force            Force re-run of a step even if marked done/running
                      (use with --only)
  -h, --help         Show this help message and exit

Examples:
  ./run_pipeline.sh
  ./run_pipeline.sh --subject 1004 --dicom /data/raw/1004
  ./run_pipeline.sh --only freesurfer --force
  ./run_pipeline.sh --from qsiprep
  ./run_pipeline.sh --status
EOF
        exit 0
    fi
done

# ── Load env first (needed before anything else) ──────────────────────────────
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  SETUP INCOMPLETE — .env file not found"
    echo "════════════════════════════════════════════════════════════════"
    echo "  NeuroStage needs a .env file with your paths and settings before"
    echo "  it can run. To create one:"
    echo "    1. Copy the template:   cp .env.template .env"
    echo "    2. Open .env in a text editor and fill in the paths"
    echo "    3. Run ./run_pipeline.sh again"
    echo "════════════════════════════════════════════════════════════════"
    exit 1
fi
source "$SCRIPT_DIR/.env"

# ── Fast bootstrap check — runs BEFORE any heavy work (dependency downloads,
# FreeSurfer env sourcing) and BEFORE strict mode, on purpose. Confirms basic
# tools, Docker, Python, disk space, and .env sanity up front so a first-time
# user finds out about a problem in seconds, not after a 20-minute download.
source "$SCRIPT_DIR/scripts/bootstrap_check.sh"
_bootstrap_check_fast

# ── Source FreeSurfer env (must happen before set -euo pipefail) ──────────────
unset SUBJECTS_DIR SESSIONS_DIR FSFAST_HOME MNI_DIR FIX_VERTEX_AREA
export FS_FREESURFERENV_NO_OUTPUT=""
export FMRI_ANALYSIS_DIR=""
source "$FREESURFER_HOME/SetUpFreeSurfer.sh" 2>/dev/null || true

# Re-source .env to restore anything FreeSurfer clobbered
source "$SCRIPT_DIR/.env"

if ! "${SCRIPT_DIR}/install_dependencies.sh"; then
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  SETUP INCOMPLETE — install_dependencies.sh failed"
    echo "════════════════════════════════════════════════════════════════"
    echo "  Scroll up for the specific error above, fix it, then run"
    echo "  ./run_pipeline.sh again. Nothing has been processed yet."
    echo "════════════════════════════════════════════════════════════════"
    exit 1
fi

# ── Full bootstrap check — runs after dependencies are installed. Verifies
# the tool folders actually landed, the FreeSurfer license, required Python
# packages, and required Docker images are all in place, printing exact fix
# instructions for anything missing. See scripts/bootstrap_check.sh.
_bootstrap_check

# ── NOW enable strict mode ────────────────────────────────────────────────────
set -euo pipefail

# ── Parse CLI args ────────────────────────────────────────────────────────────
FROM_STEP=""
ONLY_STEP=""
DRY_RUN=0
PREFLIGHT=0
STATUS_ONLY=0
FORCE=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --dicom)     DICOM_INPUT="$2"; shift 2 ;;
        --subject)   SUBJECT_ID="$2";  shift 2 ;;
        --output)    OUTPUT_BASE="$2"; shift 2 ;;
        --from)      FROM_STEP="$2";   shift 2 ;;
        --only)      ONLY_STEP="$2";   shift 2 ;;
        --dry-run)   DRY_RUN=1;        shift   ;;
        --preflight) PREFLIGHT=1;      shift   ;;
        --status)    STATUS_ONLY=1;    shift   ;;
        --force)     FORCE=1;          shift   ;;
        *) echo "ERROR: Unknown argument: $1"; exit 1 ;;
    esac
done

VALID_STEPS="bids mriqc freesurfer hcp qsiprep fmriprep aslprep"
if [[ -n "$ONLY_STEP" ]] && ! echo "$VALID_STEPS" | grep -qw "$ONLY_STEP"; then
    echo "ERROR: --only '$ONLY_STEP' is not valid. Choose from: $VALID_STEPS"
    exit 1
fi
if [[ -n "$FROM_STEP" ]] && ! echo "$VALID_STEPS" | grep -qw "$FROM_STEP"; then
    echo "ERROR: --from '$FROM_STEP' is not valid. Choose from: $VALID_STEPS"
    exit 1
fi
if [[ -n "$ONLY_STEP" && -n "$FROM_STEP" ]]; then
    echo "ERROR: --only and --from cannot be used together."
    exit 1
fi

# ── Derived paths ─────────────────────────────────────────────────────────────
SUB_LABEL="sub-${SUBJECT_ID}"

# OUTPUT_BASE controls where ALL derivatives (FreeSurfer, MRIQC, QSIPrep,
# fMRIPrep, ASLPrep, logs, working dirs) are written. It is fully optional —
# if unset (in .env or via --output), it defaults to PIPELINE_BASE, which is
# the original behavior. This lets someone keep bundled tools + BIDS input on
# one disk and point large derivative output at a separate disk/array without
# touching anything else.
OUTPUT_BASE="${OUTPUT_BASE:-$PIPELINE_BASE}"
[[ "$OUTPUT_BASE" == /* ]] || { echo "ERROR: OUTPUT_BASE must be an absolute path (got: $OUTPUT_BASE)"; exit 1; }
mkdir -p "$OUTPUT_BASE" 2>/dev/null || { echo "ERROR: Cannot create/write to OUTPUT_BASE: $OUTPUT_BASE"; exit 1; }

BIDS_DIR="$OUTPUT_BASE"
SUB_BIDS_DIR="$BIDS_DIR/$SUB_LABEL"

WORK_DIR="$OUTPUT_BASE/${SUBJECT_ID}Processing"
FS_OUTPUT_DIR="$WORK_DIR/freesurfer"
HCP_OUTPUT_DIR="$WORK_DIR/hcp_processing"
MRIQC_OUT="$WORK_DIR/mriqc"
QSIPREP_OUT="$WORK_DIR/qsiprep"
FMRIPREP_OUT="$WORK_DIR/fmriprep"
ASLPREP_OUT="$WORK_DIR/aslprep"
WORKING_DIR="$WORK_DIR/working"
LOG_DIR="$WORK_DIR/logs"
STATE_DIR="$WORK_DIR/.state"
MAIN_LOG="$LOG_DIR/pipeline_${SUBJECT_ID}_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="$STATE_DIR/pipeline.lock"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$FS_OUTPUT_DIR" "$HCP_OUTPUT_DIR" "$MRIQC_OUT" \
         "$QSIPREP_OUT" "$FMRIPREP_OUT" "$ASLPREP_OUT" "$WORKING_DIR"

# =============================================================================
# ── Logging helpers ───────────────────────────────────────────────────────────
# =============================================================================
_banner() {
    local msg="$1"
    local line="════════════════════════════════════════════════════════════════"
    echo "" | tee -a "$MAIN_LOG"
    echo "$line" | tee -a "$MAIN_LOG"
    printf "  %-60s\n" "$msg" | tee -a "$MAIN_LOG"
    echo "$line" | tee -a "$MAIN_LOG"
    echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$MAIN_LOG"
    echo "$line" | tee -a "$MAIN_LOG"
}

_info()    { echo "  [INFO]  $*" | tee -a "$MAIN_LOG"; }
_ok()      { echo "  [✓ OK]  $*" | tee -a "$MAIN_LOG"; }
_warn()    { echo "  [WARN]  $*" | tee -a "$MAIN_LOG"; }
_error()   { echo "  [ERROR] $*" | tee -a "$MAIN_LOG"; exit 1; }
_skip()    { echo "  [SKIP]  $*" | tee -a "$MAIN_LOG"; }
_elapsed() {
    local s=$1
    printf "  Elapsed: %02dh %02dm %02ds\n" $((s/3600)) $((s%3600/60)) $((s%60)) | tee -a "$MAIN_LOG"
}

# =============================================================================
# ── STATE TRACKING ────────────────────────────────────────────────────────────
# One state file per step: $STATE_DIR/<step>.state  (plain key=value, easy to
# grep/cat by hand if something is ever unclear). Status values:
#   pending | running | done | failed | interrupted
#
# "running" + a stale heartbeat + a dead PID is how we detect interruption on
# the NEXT run — that combination can only mean the previous process never
# got to write done/failed, i.e. it was killed, the session dropped, the box
# rebooted, or the OOM-killer took it.
# =============================================================================
_state_file() { echo "$STATE_DIR/${1}.state"; }

_state_write() {
    # _state_write <step> <status> [exit_code] [container]
    local step="$1" status="$2" exit_code="${3:-}" container="${4:-}"
    local f; f=$(_state_file "$step")
    {
        echo "step=$step"
        echo "status=$status"
        echo "pid=${BASHPID:-$$}"
        echo "container=$container"
        echo "exit_code=$exit_code"
        echo "updated=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "updated_epoch=$(date +%s)"
    } > "$f"
}

_state_heartbeat() {
    # Refresh just the timestamp + pid, called periodically while a step runs.
    local step="$1"
    local f; f=$(_state_file "$step")
    [[ -f "$f" ]] || return 0
    sed -i \
        -e "s/^pid=.*/pid=${BASHPID:-$$}/" \
        -e "s/^updated=.*/updated=$(date '+%Y-%m-%d %H:%M:%S')/" \
        -e "s/^updated_epoch=.*/updated_epoch=$(date +%s)/" \
        "$f"
}

_state_get() {
    # _state_get <step> <field>
    local step="$1" field="$2" f
    f=$(_state_file "$step")
    [[ -f "$f" ]] || { echo ""; return; }
    awk -F= -v k="$field" '$1==k{print substr($0, length(k)+2)}' "$f"
}

# Decide the TRUE status of a step, reconciling stale "running" states left
# behind by a crash/kill/disconnect. This is the function that answers your
# "what was done, what wasn't, where did it die" requirement.
_true_status() {
    local step="$1"
    local f; f=$(_state_file "$step")
    [[ -f "$f" ]] || { echo "pending"; return; }

    local status pid container updated_epoch now stale_secs=180
    status=$(_state_get "$step" status)
    pid=$(_state_get "$step" pid)
    container=$(_state_get "$step" container)
    updated_epoch=$(_state_get "$step" updated_epoch)
    now=$(date +%s)

    if [[ "$status" == "running" ]]; then
        local pid_alive=0 container_alive=0
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && pid_alive=1
        if [[ -n "$container" ]]; then
            docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container" && container_alive=1
        fi
        local age=$(( now - ${updated_epoch:-0} ))

        if [[ $pid_alive -eq 1 ]]; then
            echo "running"            # genuinely still going (this is a status check, not a crash)
        elif [[ $container_alive -eq 1 ]]; then
            echo "orphaned_container"  # driver script died but docker container is still alive
        elif [[ $age -gt $stale_secs ]]; then
            echo "interrupted"        # process gone, heartbeat stale -> killed/crashed/rebooted
        else
            echo "running"            # just started, heartbeat hasn't gone stale yet
        fi
    else
        echo "$status"
    fi
}

_status_line() {
    local step="$1" s
    s=$(_true_status "$step")
    case "$s" in
        done)               printf "%-12s ✓ DONE\n" "$step" ;;
        failed)             printf "%-12s ✗ FAILED   (exit %s) — %s\n" "$step" "$(_state_get "$step" exit_code)" "$(_state_get "$step" updated)" ;;
        interrupted)        printf "%-12s ⚠ INTERRUPTED — died without exiting cleanly, last seen %s\n" "$step" "$(_state_get "$step" updated)" ;;
        orphaned_container) printf "%-12s ⚠ ORPHANED — driver dead, docker container '%s' still running\n" "$step" "$(_state_get "$step" container)" ;;
        running)            printf "%-12s ⟳ RUNNING  (pid %s, last heartbeat %s)\n" "$step" "$(_state_get "$step" pid)" "$(_state_get "$step" updated)" ;;
        pending|*)          printf "%-12s · PENDING\n" "$step" ;;
    esac
}

_print_status_table() {
    _banner "Pipeline Status — $SUBJECT_ID"
    for s in bids mriqc freesurfer hcp qsiprep fmriprep aslprep; do
        _status_line "$s"
    done | tee -a "$MAIN_LOG"
    echo "" | tee -a "$MAIN_LOG"
    _info "State files: $STATE_DIR"
    _info "Logs:        $LOG_DIR"
}

if [[ "$STATUS_ONLY" == "1" ]]; then
    _print_status_table
    exit 0
fi

# =============================================================================
# ── LOCK FILE — prevent two invocations from touching the same subject ───────
# =============================================================================
_acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            _error "Another pipeline run is already active for $SUBJECT_ID (pid $lock_pid). Refusing to start a second one. If that process is actually dead, remove $LOCK_FILE manually."
        else
            _warn "Found stale lock file (pid $lock_pid is not running). Removing it and continuing."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo "$$" > "$LOCK_FILE"
}
_release_lock() { rm -f "$LOCK_FILE" 2>/dev/null || true; }

# =============================================================================
# ── TRAP / CLEANUP — this is the core of "survive everything" ────────────────
# Covers: Ctrl+C (INT), terminal/session close (HUP), kill (TERM), normal exit
# (EXIT). EXIT fires in ALL cases including the others, so it's the single
# place cleanup logic lives; the others just make sure EXIT is reached instead
# of bash dying silently with no trap at all.
# =============================================================================
CURRENT_STEP=""
CURRENT_CONTAINER=""
CURRENT_CHILD_PID=""
CURRENT_CHILD_PGID=""
_INTERRUPTED=0

_cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP QUIT   # avoid re-entrancy if cleanup itself errors

    if [[ -n "$CURRENT_STEP" ]]; then
        if [[ $_INTERRUPTED -eq 1 || $rc -ne 0 ]]; then
            # Mark exactly where we were so resume can report it accurately.
            local existing_status
            existing_status=$(_state_get "$CURRENT_STEP" status)
            if [[ "$existing_status" == "running" ]]; then
                _state_write "$CURRENT_STEP" "interrupted" "$rc" "$CURRENT_CONTAINER"
            fi
            echo "" | tee -a "$MAIN_LOG" 2>/dev/null || true
            _warn "Pipeline interrupted while running step: $CURRENT_STEP (signal/exit code $rc)" 2>/dev/null || true

            # Kill the actual step process AND its process group so a
            # Ctrl+C doesn't leave the underlying script/docker-launch
            # running unattended in the background. The backgrounded step
            # job is its own process group leader, so `kill -TERM -PGID`
            # (negative PID) reaches it plus any children it spawned —
            # a single positive-PID kill would only hit the immediate
            # process and leave grandchildren (e.g. a `docker run` the
            # step script launched) orphaned under PID 1.
            if [[ -n "$CURRENT_CHILD_PID" ]] && kill -0 "$CURRENT_CHILD_PID" 2>/dev/null; then
                _warn "Stopping in-flight step process (pid $CURRENT_CHILD_PID)" 2>/dev/null || true
                kill -TERM "-$CURRENT_CHILD_PGID" 2>/dev/null || kill -TERM "$CURRENT_CHILD_PID" 2>/dev/null || true
                sleep 2
                kill -0 "$CURRENT_CHILD_PID" 2>/dev/null && { kill -KILL "-$CURRENT_CHILD_PGID" 2>/dev/null || kill -KILL "$CURRENT_CHILD_PID" 2>/dev/null; } || true
            fi
            if [[ -n "$CURRENT_CONTAINER" ]]; then
                if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CURRENT_CONTAINER"; then
                    _warn "Stopping in-flight container: $CURRENT_CONTAINER" 2>/dev/null || true
                    docker stop -t 30 "$CURRENT_CONTAINER" &>/dev/null || true
                fi
            fi
            _info "Re-run the same command to resume. Use --status to see exact state first." 2>/dev/null || true
        fi
    fi

    _release_lock
    exit "$rc"
}

_on_signal() {
    _INTERRUPTED=1
    # Falls through to EXIT trap, which does the actual work — this just
    # records that the cause was a signal, not a normal nonzero exit.
}

trap _cleanup EXIT
trap '_on_signal' INT TERM HUP QUIT

_acquire_lock

# =============================================================================
# ── _run_step — now state-aware instead of just .done/.failed flag files ────
# =============================================================================
_run_step() {
    local flag="$1" name="$2" script="$3"

    if [[ -n "$ONLY_STEP" ]]; then
        if [[ "$name" != "$ONLY_STEP" ]]; then _skip "$name (--only $ONLY_STEP)"; return; fi
    fi

    if [[ -n "$FROM_STEP" ]]; then
        if [[ "$FROM_STEP" == "$name" ]]; then FROM_STEP=""; fi
        if [[ -n "$FROM_STEP" ]]; then _skip "$name (before --from point)"; return; fi
    fi

    if [[ -z "$ONLY_STEP" ]]; then
        local flag_val="${!flag:-0}"
        if [[ "$flag_val" != "1" ]]; then _skip "$name (disabled in .env)"; return; fi
    fi

    local step_log="$LOG_DIR/${name}_${SUBJECT_ID}_$(date +%Y%m%d_%H%M%S).log"
    local container_name="ns_${SUBJECT_ID}_${name}"
    local true_status
    true_status=$(_true_status "$name")

    # ── Resolve prior state before doing anything ────────────────────────────
    case "$true_status" in
        done)
            if [[ "$FORCE" == "1" && -n "$ONLY_STEP" ]]; then
                _warn "$name — already done, but --force given with --only. Re-running."
            else
                _skip "$name — already completed ($(_state_get "$name" updated)). Use --force --only $name to redo."
                return 0
            fi
            ;;
        running)
            _error "$name appears to still be ACTIVELY running (pid $(_state_get "$name" pid)). If that's wrong, run --status to confirm, then check 'ps' / 'docker ps' before retrying."
            ;;
        orphaned_container)
            _warn "$name — previous driver process died but container '$container_name' is still running. Stopping it before retrying."
            docker stop -t 30 "$container_name" &>/dev/null || true
            ;;
        interrupted)
            _warn "$name — previous attempt was INTERRUPTED (killed / disconnected / crashed) at $(_state_get "$name" updated). Re-running from scratch for this step."
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container_name"; then
                _warn "Found a still-running orphaned container '$container_name' — stopping it first."
                docker stop -t 30 "$container_name" &>/dev/null || true
            fi
            ;;
        failed)
            _warn "$name — previous attempt FAILED (exit $(_state_get "$name" exit_code)) at $(_state_get "$name" updated). Re-running..."
            ;;
        pending) : ;;
    esac

    _banner "STEP: $name"
    if [[ "$DRY_RUN" == "1" ]]; then _info "DRY RUN — would execute: $script"; return; fi

    CURRENT_STEP="$name"
    CURRENT_CONTAINER="$container_name"
    export NS_CONTAINER_NAME="$container_name"   # step scripts should `docker run --name "$NS_CONTAINER_NAME"`

    _state_write "$name" "running" "" "$container_name"

    local t0=$SECONDS
    set +e

    # IMPORTANT: do NOT run the step as a foreground `cmd | tee | tee` pipe.
    # Bash only checks/dispatches caught signals (INT/TERM/HUP) when control
    # returns to the main loop — while bash is blocked as a member of a
    # foreground pipeline, a trapped signal is queued but NOT acted on until
    # the whole pipeline finishes. That means Ctrl+C / a killed SSH session /
    # `kill` would NOT interrupt cleanly here; the step would run to
    # completion (or hang) regardless of the signal. Running the step as a
    # background job and using `wait` instead is interruptible immediately,
    # because `wait` IS a signal-checking point.
    : > "$step_log"
    ( tail -n +1 -f "$step_log" --pid="$$" 2>/dev/null | tee -a "$MAIN_LOG" ) &
    local tail_pid=$!

    # Launched under `setsid` so the step gets its OWN process group (a
    # plain `&` background job in a non-interactive script shares the
    # orchestrator's process group, NOT its own — verified: without setsid,
    # `kill -TERM -<pgid>` would hit the orchestrator itself too). With its
    # own group, `kill -TERM -<pgid>` on interrupt reaches the step process
    # AND any subprocesses it spawns (e.g. `docker run`) without touching us.
    setsid bash "$SCRIPT_DIR/scripts/$script" >> "$step_log" 2>&1 &
    local step_pid=$!
    CURRENT_CHILD_PID="$step_pid"
    CURRENT_CHILD_PGID="$step_pid"   # setsid's child is its own group leader

    # Heartbeat in the background so a stale "running" state can be told
    # apart from a genuinely-still-going one on the NEXT invocation.
    ( while true; do sleep 20; _state_heartbeat "$name" 2>/dev/null || exit 0; done ) &
    local hb_pid=$!

    local rc=0
    wait "$step_pid" || rc=$?

    kill "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null || true
    sleep 1   # let tail -f catch the last lines before we kill it
    kill "$tail_pid" 2>/dev/null; wait "$tail_pid" 2>/dev/null || true
    set -e

    # If a signal (Ctrl+C, kill, dropped session) arrived while we were in
    # `wait`, the `|| rc=$?` form above captures it as just a nonzero exit
    # status and execution continues normally here — `wait` does NOT abort
    # the script the way it would with a bare `wait` under `set -e`. Without
    # this check, an interrupted run would get misfiled as a plain "failed"
    # step instead of "interrupted", which matters because the messaging,
    # and whether the .failed semantics ("ran and was rejected by the tool")
    # vs interrupted semantics ("never got to finish") apply, are different.
    #
    # IMPORTANT: CURRENT_CHILD_PID/PGID must stay set until AFTER this check
    # so _cleanup (invoked by `exit` below) can still see and kill them —
    # clearing them first would leave the step's actual child process
    # (and any docker container it launched) orphaned under PID 1.
    if [[ "$_INTERRUPTED" == "1" ]]; then
        _state_write "$name" "interrupted" "$rc" "$CURRENT_CONTAINER"
        exit "$rc"   # _cleanup (EXIT trap) does the process/container teardown
    fi

    CURRENT_CHILD_PID=""
    CURRENT_CHILD_PGID=""
    _elapsed $((SECONDS - t0))

    if [[ $rc -ne 0 ]]; then
        _state_write "$name" "failed" "$rc" "$container_name"
        CURRENT_STEP=""; CURRENT_CONTAINER=""
        _error "$name FAILED (exit $rc) — see $step_log"
    else
        _state_write "$name" "done" "0" ""
        CURRENT_STEP=""; CURRENT_CONTAINER=""
        _ok "$name completed successfully."
    fi
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
_banner "NeuroStage Pipeline — Pre-flight"
_info "Subject:      $SUBJECT_ID"
_info "DICOM input:  $DICOM_INPUT"
_info "Pipeline dir: $PIPELINE_BASE"
_info "Output dir:   $WORK_DIR"
_info "Log file:     $MAIN_LOG"
[[ -n "$ONLY_STEP" ]] && _info "Mode:         --only $ONLY_STEP"
[[ -n "$FROM_STEP"  ]] && _info "Mode:         --from $FROM_STEP"
[[ "$PREFLIGHT" == "1" ]] && _info "Mode:         --preflight (validation only, no execution)"

# Note: DICOM_INPUT / FS_LICENSE / DCM2BIDS_CONFIG / docker presence were
# already validated by _bootstrap_check above with friendlier messaging.
# Re-checked here too in case .env was edited between bootstrap and this
# point (e.g. via --dicom override below would not apply yet at this line,
# so this remains a real safety net, not pure redundancy).
[[ -e "$DICOM_INPUT" ]]     || _error "DICOM_INPUT not found: $DICOM_INPUT"
[[ -f "$FS_LICENSE" ]]      || _error "FreeSurfer license not found: $FS_LICENSE"
[[ -f "$DCM2BIDS_CONFIG" ]] || _error "dcm2bids config not found: $DCM2BIDS_CONFIG"

# Show resumed-state summary up front, every run, so you never have to ask
# "what happened last time" — it's just printed.
_banner "Resume Check — prior state for this subject"
ANY_PRIOR=0
for s in bids mriqc freesurfer hcp qsiprep fmriprep aslprep; do
    st=$(_true_status "$s")
    [[ "$st" != "pending" ]] && ANY_PRIOR=1
    _status_line "$s" | sed 's/^/  /' | tee -a "$MAIN_LOG"
done
[[ $ANY_PRIOR -eq 0 ]] && _info "No prior state found — this is a fresh run."

# ── Preflight validation ───────────────────────────────────────────────────────
_pf_ok()   { echo "  [✓]  $*" | tee -a "$MAIN_LOG"; }
_pf_fail() { echo "  [✗]  $*" | tee -a "$MAIN_LOG"; PF_ERRORS=$((PF_ERRORS+1)); }
_pf_warn() { echo "  [!]  $*" | tee -a "$MAIN_LOG"; }

_run_preflight() {
    PF_ERRORS=0
    _banner "Preflight Checks"

    declare -A WILL_RUN
    for s in bids mriqc freesurfer hcp qsiprep fmriprep aslprep; do
        WILL_RUN[$s]=0
    done
    [[ "${RUN_DCM2BIDS:-0}"   == "1" ]] && WILL_RUN[bids]=1
    [[ "${RUN_MRIQC:-0}"      == "1" ]] && WILL_RUN[mriqc]=1
    [[ "${RUN_FREESURFER:-0}" == "1" ]] && WILL_RUN[freesurfer]=1
    [[ "${RUN_HCP:-0}"        == "1" ]] && WILL_RUN[hcp]=1
    [[ "${RUN_QSIPREP:-0}"    == "1" ]] && WILL_RUN[qsiprep]=1
    [[ "${RUN_FMRIPREP:-0}"   == "1" ]] && WILL_RUN[fmriprep]=1
    [[ "${RUN_ASLPREP:-0}"    == "1" ]] && WILL_RUN[aslprep]=1
    if [[ -n "$ONLY_STEP" ]]; then
        for s in bids mriqc freesurfer hcp qsiprep fmriprep aslprep; do WILL_RUN[$s]=0; done
        WILL_RUN[$ONLY_STEP]=1
    fi

    _info "Steps that will run:"
    for s in bids mriqc freesurfer hcp qsiprep fmriprep aslprep; do
        [[ "${WILL_RUN[$s]}" == "1" ]] && echo "    ENABLED  $s" | tee -a "$MAIN_LOG" || echo "    skipped  $s" | tee -a "$MAIN_LOG"
    done

    _banner "Preflight: System Tools"
    command -v docker    &>/dev/null && _pf_ok  "docker found" || _pf_fail "docker NOT found"
    command -v python3   &>/dev/null && _pf_ok  "python3 found" || _pf_fail "python3 NOT found"
    command -v dcm2bids  &>/dev/null && _pf_ok  "dcm2bids found" || { [[ "${WILL_RUN[bids]}" == "1" ]] && _pf_fail "dcm2bids NOT found (needed for bids step)" || _pf_warn "dcm2bids not found (bids step disabled)"; }
    python3 -c "import nibabel" 2>/dev/null && _pf_ok "nibabel found" || _pf_fail "nibabel NOT found (pip install nibabel)"

    _banner "Preflight: Files & Paths"
    [[ -e "$DICOM_INPUT" ]]     && _pf_ok  "DICOM_INPUT exists: $DICOM_INPUT" || _pf_fail "DICOM_INPUT not found: $DICOM_INPUT"
    [[ -f "$FS_LICENSE" ]]      && _pf_ok  "FreeSurfer license found" || _pf_fail "FS_LICENSE not found: $FS_LICENSE"
    [[ -f "$DCM2BIDS_CONFIG" ]] && _pf_ok  "dcm2bids config found" || _pf_fail "DCM2BIDS_CONFIG not found: $DCM2BIDS_CONFIG"

    _banner "Preflight: Docker Images"
    _check_docker_image() {
        local img="$1" step="$2"
        if [[ "${WILL_RUN[$step]:-0}" == "1" ]]; then
            docker image inspect "$img" &>/dev/null && _pf_ok  "Image pulled: $img" || _pf_fail "Image NOT pulled: $img  (run: docker pull $img)"
        else
            docker image inspect "$img" &>/dev/null && _pf_ok  "Image pulled: $img (step disabled but image present)" || _pf_warn "Image not pulled: $img (step disabled — OK)"
        fi
    }
    _check_docker_image "$MRIQC_IMAGE"    "mriqc"
    _check_docker_image "${FREESURFER_IMAGE:-freesurfer/freesurfer:7.4.1}" "freesurfer"
    _check_docker_image "$QSIPREP_IMAGE"  "qsiprep"
    _check_docker_image "$FMRIPREP_IMAGE" "fmriprep"
    _check_docker_image "$ASLPREP_IMAGE"  "aslprep"

    _banner "Preflight: BIDS Data"
    if [[ "${WILL_RUN[bids]}" == "0" ]]; then
        [[ -d "$SUB_BIDS_DIR" ]] && _pf_ok  "BIDS subject dir found: $SUB_BIDS_DIR" || _pf_fail "BIDS subject dir not found: $SUB_BIDS_DIR"
        T1W=$(find "$SUB_BIDS_DIR" -name "*_T1w.nii.gz" 2>/dev/null | head -1)
        [[ -n "$T1W" ]] && _pf_ok "T1w found: $T1W" || _pf_fail "No T1w found under $SUB_BIDS_DIR"
        DWI=$(find "$SUB_BIDS_DIR" -name "*_dwi.nii.gz" 2>/dev/null | head -1)
        [[ -n "$DWI" ]] && _pf_ok "DWI found" || { [[ "${WILL_RUN[qsiprep]}" == "1" ]] && _pf_fail "No DWI found — QSIPrep is enabled" || _pf_warn "No DWI found (QSIPrep disabled — OK)"; }
        BOLD=$(find "$SUB_BIDS_DIR" -name "*_bold.nii.gz" 2>/dev/null | head -1)
        [[ -n "$BOLD" ]] && _pf_ok "BOLD found" || { [[ "${WILL_RUN[fmriprep]}" == "1" ]] && _pf_warn "No BOLD found — fMRIPrep may fail" || _pf_warn "No BOLD found (fMRIPrep disabled — OK)"; }
        ASL=$(find "$SUB_BIDS_DIR" -name "*_asl.nii.gz" 2>/dev/null | head -1)
        [[ -n "$ASL" ]] && _pf_ok "ASL found" || { [[ "${WILL_RUN[aslprep]}" == "1" ]] && _pf_warn "No ASL found — ASLPrep will auto-skip" || _pf_warn "No ASL found (ASLPrep disabled — OK)"; }
    else
        _pf_ok "bids step enabled — BIDS dir will be created"
    fi

    _banner "Preflight: FreeSurfer Output"
    FS_DONE="$FS_OUTPUT_DIR/$SUB_LABEL/scripts/recon-all.done"
    if [[ -f "$FS_DONE" ]]; then
        _pf_ok "FreeSurfer output complete: $FS_OUTPUT_DIR/$SUB_LABEL"
    elif [[ "${WILL_RUN[freesurfer]}" == "1" ]]; then
        _pf_ok "FreeSurfer not yet run — will be created by freesurfer step"
    else
        [[ "${WILL_RUN[fmriprep]}" == "1" || "${WILL_RUN[aslprep]}" == "1" ]] && _pf_warn "FreeSurfer output not found and freesurfer step disabled — fMRIPrep/ASLPrep will run their own recon (slower)" || _pf_ok "FreeSurfer not needed for enabled steps"
    fi

    if [[ "${WILL_RUN[hcp]}" == "1" ]]; then
        _banner "Preflight: HCP"
        HCPPIPEDIR="$PIPELINE_BASE/HCPpipelines"
        [[ -d "$HCPPIPEDIR" ]] && _pf_ok "HCPpipelines dir found" || _pf_fail "HCPpipelines not found at $HCPPIPEDIR"
        [[ -d "${FREESURFER_HOME:-}" ]] && _pf_ok "FREESURFER_HOME found: $FREESURFER_HOME" || _pf_fail "FREESURFER_HOME not set or not found"
        [[ -d "${FSLDIR:-}" ]] && _pf_ok "FSLDIR found: $FSLDIR" || _pf_fail "FSLDIR not set or not found"
    fi

    if [[ "${WILL_RUN[qsiprep]}" == "1" && "${EDDY_GPU:-AUTO}" != "OFF" ]]; then
        _banner "Preflight: GPU"
        if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
            GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
            _pf_ok "GPU detected: $GPU — eddy_cuda will be used"
        else
            [[ "${EDDY_GPU:-AUTO}" == "ON" ]] && _pf_fail "EDDY_GPU=ON but no GPU detected" || _pf_warn "No GPU detected — will fall back to CPU eddy (EDDY_GPU=AUTO)"
        fi
    fi

    _banner "Preflight: Disk Space"
    AVAIL_GB=$(df -BG "$OUTPUT_BASE" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' || echo 0)
    if [[ "$AVAIL_GB" -lt 200 ]]; then
        _pf_warn "Only ${AVAIL_GB}GB available at $OUTPUT_BASE (derivatives) — recommended ≥200GB per subject"
    else
        _pf_ok "${AVAIL_GB}GB available at $OUTPUT_BASE (derivatives)"
    fi
    if [[ "$OUTPUT_BASE" != "$PIPELINE_BASE" ]]; then
        AVAIL_GB_IN=$(df -BG "$PIPELINE_BASE" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' || echo 0)
        if [[ "$AVAIL_GB_IN" -lt 20 ]]; then
            _pf_warn "Only ${AVAIL_GB_IN}GB available at $PIPELINE_BASE (BIDS input) — recommended ≥20GB"
        else
            _pf_ok "${AVAIL_GB_IN}GB available at $PIPELINE_BASE (BIDS input)"
        fi
    fi

    _banner "Preflight: System Resources"
    TOTAL_THREADS=$(nproc)
    REC_THREADS=$((TOTAL_THREADS * 3 / 4))
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
    _pf_ok "Total CPU threads: $TOTAL_THREADS (Recommend using up to $REC_THREADS for parallel tasks)"
    _pf_ok "Total system RAM: ${TOTAL_RAM_GB}GB"
    if [[ "$TOTAL_RAM_GB" -lt 16 ]]; then
        _pf_warn "Low memory detected (${TOTAL_RAM_GB}GB). Processing may be slow or unstable if < 16GB."
    fi

    _banner "Preflight Summary"
    if [[ $PF_ERRORS -eq 0 ]]; then
        _ok "All checks passed. Ready to run."
    else
        _error "$PF_ERRORS check(s) failed. Fix the issues above before running."
    fi
}

# Export everything scripts need
export SUBJECT_ID SUB_LABEL BIDS_DIR SUB_BIDS_DIR MATLAB_COMPILER_RUNTIME ASL_LABELING_TYPE
export WORK_DIR FS_OUTPUT_DIR HCP_OUTPUT_DIR MRIQC_OUT QSIPREP_OUT FMRIPREP_OUT ASLPREP_OUT WORKING_DIR
export DICOM_INPUT DCM2BIDS_CONFIG FS_LICENSE
export FREESURFER_HOME FSLDIR MSMBINDIR CARET7DIR LD_LIBRARY_PATH BLAS ATLAS
export MRIQC_IMAGE QSIPREP_IMAGE FMRIPREP_IMAGE ASLPREP_IMAGE FREESURFER_IMAGE
export N_THREADS MEM_GB OUTPUT_RESOLUTION SESSION_ID
export LOG_DIR MAIN_LOG SCRIPT_DIR PIPELINE_BASE OUTPUT_BASE
export STATE_DIR

# echo "--- Verifying Exported Variables ---"
# for var in SUBJECT_ID SUB_LABEL MATLAB_COMPILER_RUNTIME ASL_LABELING_TYPE BIDS_DIR SUB_BIDS_DIR WORK_DIR FS_OUTPUT_DIR \
#            HCP_OUTPUT_DIR MRIQC_OUT QSIPREP_OUT FMRIPREP_OUT ASLPREP_OUT \
#            WORKING_DIR DICOM_INPUT DCM2BIDS_CONFIG FS_LICENSE FREESURFER_HOME \
#            FSLDIR MSMBINDIR CARET7DIR LD_LIBRARY_PATH BLAS ATLAS MRIQC_IMAGE \
#            QSIPREP_IMAGE FMRIPREP_IMAGE ASLPREP_IMAGE N_THREADS MEM_GB \
#            OUTPUT_RESOLUTION SESSION_ID LOG_DIR MAIN_LOG SCRIPT_DIR PIPELINE_BASE OUTPUT_BASE STATE_DIR; do
#     # ${!var:-} (not ${!var}) so a variable that's merely unset (vs empty)
#     # doesn't trip `set -u` here. Pre-existing risk in the original script
#     # if any of these are ever left undeclared in .env.
#     printf "%-20s = %s\n" "$var" "${!var:-}"
# done
# echo "------------------------------------"

[[ "$PREFLIGHT" == "1" ]] && _run_preflight && exit 0

export EDDY_GPU="${EDDY_GPU:-AUTO}"

# =============================================================================
# ── Parallel helper — now state-aware the same way _run_step is ─────────────
# =============================================================================
_run_parallel() {
    local n_total=0
    local TF_PIDS TF_NAMES TF_LOGS TF_STARTS
    TF_PIDS=$(mktemp); TF_NAMES=$(mktemp); TF_LOGS=$(mktemp); TF_STARTS=$(mktemp)

    local pids=() names=() logs=() t_starts=() containers=() pgids=()

    while [[ $# -ge 3 ]]; do
        local flag="$1" name="$2" script="$3"; shift 3
        local container_name="ns_${SUBJECT_ID}_${name}"
        local true_status; true_status=$(_true_status "$name")

        case "$true_status" in
            done) _skip "$name — already completed. Skipping."; continue ;;
            running) _error "$name appears to still be ACTIVELY running (pid $(_state_get "$name" pid)). Check --status before retrying." ;;
            orphaned_container)
                _warn "$name — driver died, container '$container_name' still alive. Stopping it."
                docker stop -t 30 "$container_name" &>/dev/null || true ;;
            interrupted)
                _warn "$name — previous attempt was INTERRUPTED at $(_state_get "$name" updated). Re-running."
                docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container_name" && docker stop -t 30 "$container_name" &>/dev/null || true ;;
            failed) _warn "$name — previous attempt FAILED. Re-running..." ;;
        esac

        local flag_val="${!flag:-0}"
        if [[ "$flag_val" != "1" ]]; then _skip "$name (disabled in .env)"; continue; fi
        _banner "STEP: $name (parallel)"
        if [[ "$DRY_RUN" == "1" ]]; then _info "DRY RUN — would execute: $script"; continue; fi

        local step_log="$LOG_DIR/${name}_${SUBJECT_ID}_$(date +%Y%m%d_%H%M%S).log"
        : > "$step_log"
        _state_write "$name" "running" "" "$container_name"

        # setsid so this job's whole subtree (including any docker run it
        # launches) lives in its own process group — same reasoning as in
        # _run_step: a plain `&` subshell shares the orchestrator's group,
        # so a targeted `kill -TERM -<pgid>` on interrupt would otherwise
        # either miss grandchildren or hit the orchestrator itself.
        # Functions are passed via `export -f` (not string-embedded) so the
        # function bodies stay the single source of truth.
        export -f _state_write _state_heartbeat _state_get _state_file
        setsid bash -c '
            set +e
            export NS_CONTAINER_NAME="$1"; name="$2"; script="$3"; step_log="$4"
            ( while true; do sleep 20; _state_heartbeat "$name" 2>/dev/null || exit 0; done ) &
            hb_pid=$!
            bash "'"$SCRIPT_DIR"'/scripts/$script" >> "$step_log" 2>&1
            rc=$?
            kill "$hb_pid" 2>/dev/null
            if [[ $rc -ne 0 ]]; then
                _state_write "$name" "failed" "$rc" "$1"
            else
                _state_write "$name" "done" "0" ""
            fi
            exit $rc
        ' _ "$container_name" "$name" "$script" "$step_log" &
        local pid=$!
        pids+=($pid); names+=("$name"); logs+=("$step_log"); t_starts+=($SECONDS); containers+=("$container_name"); pgids+=($pid)
        echo "$pid"       >> "$TF_PIDS"
        echo "$name"      >> "$TF_NAMES"
        echo "$step_log"  >> "$TF_LOGS"
        echo "$SECONDS"   >> "$TF_STARTS"
        n_total=$((n_total + 1))
    done

    [[ $n_total -eq 0 ]] && { rm -f "$TF_PIDS" "$TF_NAMES" "$TF_LOGS" "$TF_STARTS"; return 0; }

    # If the orchestrator itself gets killed while jobs run in this function,
    # the top-level trap fires (CURRENT_STEP is empty here on purpose — there
    # isn't one "current" step in parallel mode). So we register the full
    # set here and reconcile state + kill process groups + stop containers
    # directly, mirroring what _cleanup does for the sequential path.
    PARALLEL_NAMES=("${names[@]}")
    PARALLEL_PGIDS=("${pgids[@]}")
    PARALLEL_CONTAINERS=("${containers[@]}")
    _stop_parallel_jobs() {
        local i name pgid c
        for i in "${!PARALLEL_NAMES[@]}"; do
            name="${PARALLEL_NAMES[$i]}"; pgid="${PARALLEL_PGIDS[$i]}"; c="${PARALLEL_CONTAINERS[$i]}"
            local st; st=$(_state_get "$name" status)
            if [[ "$st" == "running" ]]; then
                _state_write "$name" "interrupted" "143" "$c"
            fi
            kill -0 "$pgid" 2>/dev/null && kill -TERM "-$pgid" 2>/dev/null || true
            docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c" && docker stop -t 30 "$c" &>/dev/null || true
        done
        _release_lock
    }
    trap '_stop_parallel_jobs; exit 143' INT TERM HUP QUIT

    (
        local SEP="  ────────────────────────────────────────────────────────────────"
        local n="$n_total"
        while true; do
            sleep 30
            mapfile -t _pids   < "$TF_PIDS"
            mapfile -t _names  < "$TF_NAMES"
            mapfile -t _logs   < "$TF_LOGS"
            mapfile -t _starts < "$TF_STARTS"
            local now=$SECONDS
            local n_done=0 all_done=1

            echo "" | tee -a "$MAIN_LOG"
            echo "$SEP" | tee -a "$MAIN_LOG"
            printf "  %-14s  %-10s  %-9s  %s\n" "STEP" "STATUS" "ELAPSED" "LAST LOG LINE" | tee -a "$MAIN_LOG"
            echo "$SEP" | tee -a "$MAIN_LOG"

            for i in "${!_pids[@]}"; do
                local pid="${_pids[$i]}"
                local elapsed=$(( now - _starts[$i] ))
                local efmt
                printf -v efmt "%02dh%02dm%02ds" $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60))
                if kill -0 "$pid" 2>/dev/null; then
                    all_done=0
                    local last
                    last=$(grep -v "^[[:space:]]*$" "${_logs[$i]}" 2>/dev/null | tail -1 | cut -c1-45 || echo "...")
                    printf "  %-14s  %-10s  %-9s  %s\n" "${_names[$i]}" "⟳ RUNNING" "$efmt" "$last" | tee -a "$MAIN_LOG"
                else
                    n_done=$((n_done+1))
                    local st; st=$(_true_status "${_names[$i]}")
                    case "$st" in
                        failed)  printf "  %-14s  %-10s  %-9s  %s\n" "${_names[$i]}" "✗ FAILED" "$efmt" "logs/${_names[$i]}_${SUBJECT_ID}.log" | tee -a "$MAIN_LOG" ;;
                        done)    printf "  %-14s  %-10s  %-9s  %s\n" "${_names[$i]}" "✓ OK"     "$efmt" "logs/${_names[$i]}_${SUBJECT_ID}.log" | tee -a "$MAIN_LOG" ;;
                        *)       printf "  %-14s  %-10s  %-9s  %s\n" "${_names[$i]}" "? $st"    "$efmt" "logs/${_names[$i]}_${SUBJECT_ID}.log" | tee -a "$MAIN_LOG" ;;
                    esac
                fi
            done

            local filled=$(( n_done * 20 / n ))
            local bar="" b
            for ((b=0; b<20; b++)); do [[ $b -lt $filled ]] && bar+="█" || bar+="░"; done
            local pct=$(( n_done * 100 / n ))
            echo "$SEP" | tee -a "$MAIN_LOG"
            printf "  Progress: [%s] %d/%d (%d%%)\n" "$bar" "$n_done" "$n" "$pct" | tee -a "$MAIN_LOG"
            echo "$SEP" | tee -a "$MAIN_LOG"

            [[ $all_done -eq 1 ]] && break
        done
        rm -f "$TF_PIDS" "$TF_NAMES" "$TF_LOGS" "$TF_STARTS"
    ) &
    local monitor_pid=$!

    local failed=0
    local failed_names=() failed_logs=()
    for i in "${!pids[@]}"; do
        local rc=0
        wait "${pids[$i]}" || rc=$?
        if [[ $rc -ne 0 ]]; then
            failed=1
            failed_names+=("${names[$i]}")
            failed_logs+=("${logs[$i]}")
        fi
    done

    # Back to the normal top-level trap now that parallel jobs finished cleanly
    trap '_on_signal' INT TERM HUP QUIT

    sleep 2
    kill "$monitor_pid" 2>/dev/null; wait "$monitor_pid" 2>/dev/null || true
    rm -f "$TF_PIDS" "$TF_NAMES" "$TF_LOGS" "$TF_STARTS"

    local SEP="  ────────────────────────────────────────────────────────────────"
    local n_ok=$(( n_total - ${#failed_names[@]} ))
    local filled=$(( n_ok * 20 / n_total ))
    local bar="" b
    for ((b=0; b<20; b++)); do [[ $b -lt $filled ]] && bar+="█" || bar+="░"; done

    echo "" | tee -a "$MAIN_LOG"
    echo "$SEP" | tee -a "$MAIN_LOG"
    printf "  %-14s  %-10s  %-9s\n" "STEP" "RESULT" "ELAPSED" | tee -a "$MAIN_LOG"
    echo "$SEP" | tee -a "$MAIN_LOG"
    for i in "${!names[@]}"; do
        local elapsed=$(( SECONDS - t_starts[$i] ))
        local efmt
        printf -v efmt "%02dh%02dm%02ds" $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60))
        local is_failed=0
        for fn in "${failed_names[@]:-}"; do [[ "$fn" == "${names[$i]}" ]] && is_failed=1; done
        if [[ $is_failed -eq 1 ]]; then
            printf "  %-14s  %-10s  %-9s  <- %s\n" "${names[$i]}" "X FAILED" "$efmt" "$(basename "${logs[$i]}")" | tee -a "$MAIN_LOG"
        else
            printf "  %-14s  %-10s  %-9s\n" "${names[$i]}" "OK" "$efmt" | tee -a "$MAIN_LOG"
        fi
    done
    echo "$SEP" | tee -a "$MAIN_LOG"
    printf "  Final:    [%s] %d/%d (%d%%)\n" "$bar" "$n_ok" "$n_total" "$(( n_ok * 100 / n_total ))" | tee -a "$MAIN_LOG"
    echo "$SEP" | tee -a "$MAIN_LOG"

    if [[ $failed -ne 0 ]]; then
        echo "" | tee -a "$MAIN_LOG"
        for i in "${!failed_names[@]}"; do
            echo "  [ERROR] ${failed_names[$i]} FAILED — last 5 lines of $(basename "${failed_logs[$i]}"):" | tee -a "$MAIN_LOG"
            tail -5 "${failed_logs[$i]}" | sed 's/^/    /' | tee -a "$MAIN_LOG"
        done
        return 1     # was: exit 1 — exit kills the whole orchestrator process,
                     # since this function runs in the main shell, not a subshell.
                     # That's why stage 2 (qsiprep/fmriprep/aslprep) never ran.
    fi
}

_check_ram() {
    local needed_gb=$1 label=$2
    local avail_gb
    avail_gb=$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "$avail_gb" -gt 0 && "$avail_gb" -lt "$needed_gb" ]]; then
        _warn "Parallel $label needs ~${needed_gb}GB RAM. Only ${avail_gb}GB available. Proceeding anyway — reduce N_THREADS if jobs crash."
    else
        _info "RAM check OK: ${avail_gb}GB available for parallel $label."
    fi
}

# ── Steps ─────────────────────────────────────────────────────────────────────
TOTAL_T0=$SECONDS
PARALLEL_STAGE1="${PARALLEL_STAGE1:-0}"
PARALLEL_STAGE2="${PARALLEL_STAGE2:-0}"

_run_step RUN_DCM2BIDS "bids" "01_dicom_to_bids.sh"

if [[ -n "$ONLY_STEP" || -n "$FROM_STEP" || "$PARALLEL_STAGE1" == "0" ]]; then
    _run_step RUN_MRIQC      "mriqc"      "02_mriqc.sh"
    _run_step RUN_FREESURFER "freesurfer" "03_freesurfer.sh"
    _run_step RUN_HCP        "hcp"        "04_hcp_preproc.sh"
else
    _check_ram 60 "Stage 1 (MRIQC + FreeSurfer + HCP)"
    _info "Stage 1 running in PARALLEL"
    _run_parallel \
        RUN_MRIQC      "mriqc"      "02_mriqc.sh" \
        RUN_FREESURFER "freesurfer" "03_freesurfer.sh" \
        RUN_HCP        "hcp"        "04_hcp_preproc.sh" \
        || _warn "Stage 1 had one or more failures — continuing to Stage 2 anyway. Re-run with --only <step> --force afterward to redo failed steps."
fi

if [[ -n "$ONLY_STEP" || -n "$FROM_STEP" || "$PARALLEL_STAGE2" == "0" ]]; then
    _run_step RUN_QSIPREP  "qsiprep"  "05_qsiprep.sh"
    _run_step RUN_FMRIPREP "fmriprep" "06_fmriprep.sh"
    _run_step RUN_ASLPREP  "aslprep"  "07_aslprep.sh"
else
    _check_ram 100 "Stage 2 (QSIPrep + fMRIPrep + ASLPrep)"
    _info "Stage 2 running in PARALLEL"
    _run_parallel \
        RUN_QSIPREP  "qsiprep"  "05_qsiprep.sh" \
        RUN_FMRIPREP "fmriprep" "06_fmriprep.sh" \
        RUN_ASLPREP  "aslprep"  "07_aslprep.sh"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
_banner "Pipeline Complete"
_elapsed $((SECONDS - TOTAL_T0))
_info "All logs saved to: $LOG_DIR"
echo "" | tee -a "$MAIN_LOG"