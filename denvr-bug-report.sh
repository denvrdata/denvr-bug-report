#!/usr/bin/env bash
# ==============================================================================
# denvr-bug-report.sh
#
# Collects GPU diagnostics from a bare-metal node and builds a single,
# self-contained, offline HTML report (TSR-style navigation) plus a .tar.gz
# archive that can be attached to a Denvr support ticket.
#
# Default collection:
#   1. nvidia-smi -q
#   2. dmesg -T
#   3. nvidia-bug-report.sh   (runs last, with a timeout)
# Opt-in (--thermal):
#   4. OEM Master GPU Thermal Script (GPU stress test, 15-30 min)
#
# Requirements: bash 4+, coreutils, awk, sed, grep, tar, gzip. No network, no
# Python. Run as root (sudo) for complete data.
#
# Findings are indicators derived from simple pattern checks. They are not a
# diagnosis; confirm against NVIDIA/OEM documentation.
# ==============================================================================

set -u
export LC_ALL=C

VERSION="0.1.0"
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)"

# ---------------------------------------------------------------- defaults ---
OUT_BASE="$(pwd)"
BUGREPORT_TIMEOUT=1200
BUGREPORT_TIMEOUT_SET=0
THERMAL_TIMEOUT=1200
THERMAL_TIMEOUT_SET=0
MAX_EMBED_KB=4096
SKIP_BUGREPORT=0
NO_ARCHIVE=0
ASSUME_YES=0
DO_THERMAL=0
THERMAL_PLATFORM=""
THERMAL_SCRIPT=""
THERMAL_CSV_IN=""

TICK_PID=""

# ----------------------------------------------------------------- helpers ---
have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf "ERROR: %s\n" "$1" >&2; exit "${2:-1}"; }

cleanup() {
  if [ -n "$TICK_PID" ]; then
    kill "$TICK_PID" 2>/dev/null
    wait "$TICK_PID" 2>/dev/null
    TICK_PID=""
  fi
}
trap cleanup EXIT
trap 'cleanup; printf "\nInterrupted.\n" >&2; exit 130' INT TERM

usage() {
  cat <<EOF
denvr-bug-report.sh $VERSION - collect GPU diagnostics into an offline HTML report

Usage: $0 [options]

Default run: nvidia-smi -q, dmesg -T, nvidia-bug-report.sh

Options:
  -o, --output-dir DIR        Where to create the report (default: current dir)
      --skip-bugreport        Do not run nvidia-bug-report.sh (faster)
      --bugreport-timeout S   Timeout for nvidia-bug-report.sh in seconds
                              (default: $BUGREPORT_TIMEOUT; asked interactively in
                              minutes if omitted and run from a terminal)
      --max-embed-kb N        Max KB of each raw output embedded in the HTML
                              (default: $MAX_EMBED_KB; full files stay in the archive)
      --no-archive            Do not create the .tar.gz
  -y, --yes                   Do not ask for confirmation (needed for --thermal
                              when not run from a terminal); also skips the
                              interactive timeout prompts and uses the defaults

Thermal test (opt-in, loads the GPUs for roughly 15 min on Hopper / 30 min on
Blackwell; needs ipmitool and DCGM):
      --thermal               Run the bundled OEM thermal test
      --thermal-platform P    hopper | blackwell (asked interactively if omitted)
      --thermal-script PATH   Use this thermal script instead of the bundled one
      --thermal-timeout S     Timeout for the thermal test in seconds
                              (default: $THERMAL_TIMEOUT; asked interactively in
                              minutes if omitted and run from a terminal)
      --thermal-csv FILE      Do not run the test; analyse an existing thermal CSV

This script must be run as root (sudo); it exits immediately otherwise.

  -V, --version               Print version
  -h, --help                  Show this help
EOF
}

need_arg() { [ -n "${2:-}" ] || die "Option $1 requires a value" 1; }

# ------------------------------------------------------------------- args ---
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output-dir)        need_arg "$1" "${2:-}"; OUT_BASE="$2"; shift 2 ;;
    --skip-bugreport)       SKIP_BUGREPORT=1; shift ;;
    --bugreport-timeout)    need_arg "$1" "${2:-}"; BUGREPORT_TIMEOUT="$2"; BUGREPORT_TIMEOUT_SET=1; shift 2 ;;
    --max-embed-kb)         need_arg "$1" "${2:-}"; MAX_EMBED_KB="$2"; shift 2 ;;
    --no-archive)           NO_ARCHIVE=1; shift ;;
    -y|--yes)               ASSUME_YES=1; shift ;;
    --thermal)              DO_THERMAL=1; shift ;;
    --thermal-platform)     need_arg "$1" "${2:-}"; THERMAL_PLATFORM="$2"; shift 2 ;;
    --thermal-script)       need_arg "$1" "${2:-}"; THERMAL_SCRIPT="$2"; shift 2 ;;
    --thermal-timeout)      need_arg "$1" "${2:-}"; THERMAL_TIMEOUT="$2"; THERMAL_TIMEOUT_SET=1; shift 2 ;;
    --thermal-csv)          need_arg "$1" "${2:-}"; THERMAL_CSV_IN="$2"; shift 2 ;;
    -V|--version)           echo "$VERSION"; exit 0 ;;
    -h|--help)              usage; exit 0 ;;
    *)                      usage >&2; die "Unknown option: $1" 1 ;;
  esac
done

case "$BUGREPORT_TIMEOUT" in ''|*[!0-9]*) die "--bugreport-timeout must be a number of seconds" 1 ;; esac
case "$THERMAL_TIMEOUT"   in ''|*[!0-9]*) die "--thermal-timeout must be a number of seconds" 1 ;; esac
case "$MAX_EMBED_KB"      in ''|*[!0-9]*) die "--max-embed-kb must be a number" 1 ;; esac
if [ -n "$THERMAL_PLATFORM" ]; then
  case "$(printf '%s' "$THERMAL_PLATFORM" | tr 'A-Z' 'a-z')" in
    hopper) THERMAL_PLATFORM="hopper" ;;
    blackwell) THERMAL_PLATFORM="blackwell" ;;
    *) die "--thermal-platform must be 'hopper' or 'blackwell'" 1 ;;
  esac
fi
if [ -n "$THERMAL_CSV_IN" ]; then
  [ -r "$THERMAL_CSV_IN" ] || die "Cannot read thermal CSV: $THERMAL_CSV_IN" 1
fi
if [ "$DO_THERMAL" -eq 1 ] && [ -n "$THERMAL_CSV_IN" ]; then
  die "Use either --thermal (run the test) or --thermal-csv (analyse a CSV), not both" 1
fi

# ------------------------------------------------------------- root check ---
# dmesg -T and nvidia-bug-report.sh produce incomplete data otherwise, so this
# is a hard requirement rather than a warning.
[ "$(id -u 2>/dev/null)" = "0" ] || die "This script must be run as root. Re-run with sudo." 1

# --------------------------------------------------------------- preflight ---
missing=""
for t in awk sed grep tar gzip tr head tail wc sort date hostname uname; do
  have "$t" || missing="$missing $t"
done
[ -z "$missing" ] || die "Required tools missing:$missing" 2

mkdir -p "$OUT_BASE" 2>/dev/null || die "Cannot create output directory: $OUT_BASE" 2
OUT_BASE="$(cd "$OUT_BASE" && pwd)"

HOST="$(hostname 2>/dev/null || echo unknown-host)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_NAME="denvr-bug-report-${HOST}-${STAMP}"
RUN_DIR="$OUT_BASE/$RUN_NAME"
RAW="$RUN_DIR/raw"
PARSED="$RUN_DIR/.work"
mkdir -p "$RAW" "$PARSED" || die "Cannot create $RUN_DIR" 2

MANIFEST="$PARSED/manifest.tsv"
FINDINGS="$PARSED/findings.tsv"
: > "$MANIFEST"
: > "$FINDINGS"

IS_ROOT=1   # enforced above; kept so the rest of the script can still check it
HAVE_SMI=0; have nvidia-smi && HAVE_SMI=1
RUN_START_HUMAN="$(date '+%Y-%m-%d %H:%M:%S %Z')"

log "denvr-bug-report $VERSION on $HOST"
log "Output: $RUN_DIR"
if [ "$HAVE_SMI" -eq 0 ]; then
  warn "nvidia-smi not found: the NVIDIA driver may not be installed or loaded. GPU steps will be skipped."
fi

# ------------------------------------------------------------- step runner ---
# record_step NAME COMMAND RC SECONDS FILE NOTE
record_step() {
  local name="$1" cmd="$2" rc="$3" secs="$4" file="$5" note="$6" size=0 status
  [ -n "$file" ] && [ -e "$file" ] && size="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
  case "$rc" in
    0)   status="ok" ;;
    124) status="timeout" ;;
    skipped) status="skipped" ;;
    *)   status="failed" ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$cmd" "$status" "$rc" "$secs" "$size" "$note" >> "$MANIFEST"
}

# add_finding SEVERITY PAGE SCOPE TITLE DETAIL
add_finding() {
  local sev="$1" page="$2" scope="$3" title="$4" detail="$5"
  detail="$(printf '%s' "$detail" | tr '\t' ' ')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$sev" "$page" "$scope" "$title" "$detail" | tr -d '\r' >> "$FINDINGS"
}

# run_cmd TIMEOUT OUTFILE ERRFILE -- CMD...
run_cmd() {
  local to="$1" out="$2" err="$3" rc
  shift 4
  if [ "$to" -gt 0 ] && have timeout; then
    timeout "$to" "$@" > "$out" 2> "$err"; rc=$?
  else
    "$@" > "$out" 2> "$err"; rc=$?
  fi
  return "$rc"
}

# prompt_timeout_minutes LABEL DEFAULT_SECS VARNAME FLAG
# Asks for a timeout in minutes (easier for a human than seconds) and stores
# the converted value, in seconds, into VARNAME. No-op when non-interactive
# or --yes was given: the existing default/CLI value in VARNAME is kept.
prompt_timeout_minutes() {
  local label="$1" default_secs="$2" varname="$3" flag="$4" def_min ans ans_read
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || { warn "Not a terminal; using default $label timeout (${default_secs}s). Use $flag or -y to silence this."; return 0; }
  def_min=$(( (default_secs + 59) / 60 ))
  printf '%s timeout in minutes [default %s]: ' "$label" "$def_min"
  ans_read=""
  read -r ans_read
  ans="${ans_read:-$def_min}"
  case "$ans" in
    ''|*[!0-9]*) warn "Invalid number; using default ($def_min min)."; return 0 ;;
  esac
  [ "$ans" -gt 0 ] || { warn "Timeout must be greater than 0; using default ($def_min min)."; return 0; }
  printf -v "$varname" '%s' "$((ans * 60))"
}

# start_ticker / stop_ticker: print a dot every 30 s during long steps
start_ticker() {
  ( while sleep 30; do printf '.'; done ) &
  TICK_PID=$!
}
stop_ticker() {
  if [ -n "$TICK_PID" ]; then
    kill "$TICK_PID" 2>/dev/null
    wait "$TICK_PID" 2>/dev/null
    TICK_PID=""
    printf '\n'
  fi
}

# ------------------------------------------------------------ collection ---
collect_system() {
  log "Collecting system information"
  local f="$RAW/system.txt"
  {
    echo "### date";            date
    echo "### hostname";        hostname
    echo "### uname -a";        uname -a
    echo "### /etc/os-release"; cat /etc/os-release 2>&1
    echo "### uptime";          uptime 2>&1
    echo "### id";              id 2>&1
    echo "### /proc/driver/nvidia/version"; cat /proc/driver/nvidia/version 2>&1
    echo "### lsmod | grep -i nvidia"; { lsmod 2>&1 | grep -i nvidia; } || echo "(no nvidia modules listed)"
    echo "### free -m";         free -m 2>&1
  } > "$f" 2>&1
  record_step "System info" "date; uname; os-release; uptime; id; /proc/driver/nvidia/version; lsmod; free" 0 0 "$f" ""
}

collect_smi() {
  [ "$HAVE_SMI" -eq 1 ] || { record_step "nvidia-smi -q" "nvidia-smi -q" skipped 0 "" "nvidia-smi not found"; return; }
  log "Running nvidia-smi -q"
  local s=$SECONDS rc
  run_cmd 180 "$RAW/nvidia-smi-q.txt" "$RAW/nvidia-smi-q.stderr" -- nvidia-smi -q; rc=$?
  record_step "nvidia-smi -q" "nvidia-smi -q" "$rc" $((SECONDS - s)) "$RAW/nvidia-smi-q.txt" ""
  [ "$rc" -eq 0 ] || warn "nvidia-smi -q exited with $rc (see raw/nvidia-smi-q.stderr)"
  s=$SECONDS
  run_cmd 60 "$RAW/nvidia-smi-L.txt" "$RAW/nvidia-smi-L.stderr" -- nvidia-smi -L; rc=$?
  record_step "nvidia-smi -L" "nvidia-smi -L" "$rc" $((SECONDS - s)) "$RAW/nvidia-smi-L.txt" "GPU list, used to cross-check the GPU count"
}

collect_dmesg() {
  if ! have dmesg; then
    record_step "dmesg -T" "dmesg -T" skipped 0 "" "dmesg not found"; return
  fi
  log "Running dmesg -T"
  local s=$SECONDS rc
  run_cmd 60 "$RAW/dmesg-T.txt" "$RAW/dmesg-T.stderr" -- dmesg -T; rc=$?
  record_step "dmesg -T" "dmesg -T" "$rc" $((SECONDS - s)) "$RAW/dmesg-T.txt" ""
  [ "$rc" -eq 0 ] || warn "dmesg -T exited with $rc (see raw/dmesg-T.stderr); try running with sudo"
}

collect_bugreport() {
  if [ "$SKIP_BUGREPORT" -eq 1 ]; then
    record_step "nvidia-bug-report.sh" "nvidia-bug-report.sh" skipped 0 "" "skipped by --skip-bugreport"; return
  fi
  if ! have nvidia-bug-report.sh; then
    record_step "nvidia-bug-report.sh" "nvidia-bug-report.sh" skipped 0 "" "nvidia-bug-report.sh not found in PATH"; return
  fi
  local out="$RAW/nvidia-bug-report.log.gz" s=$SECONDS rc
  log "Running nvidia-bug-report.sh (timeout ${BUGREPORT_TIMEOUT}s; this can take several minutes)"
  have timeout || warn "'timeout' not available: nvidia-bug-report.sh will run without a time limit"
  start_ticker
  ( cd "$RAW" && run_cmd "$BUGREPORT_TIMEOUT" "$RAW/nvidia-bug-report.stdout" "$RAW/nvidia-bug-report.stderr" -- \
      nvidia-bug-report.sh --output-file "$out" ); rc=$?
  stop_ticker
  # Some versions ignore --output-file and write to the current directory.
  if [ ! -s "$out" ]; then
    local alt
    alt="$(ls -1 "$RAW"/nvidia-bug-report.log* 2>/dev/null | head -n1)"
    [ -n "$alt" ] && [ "$alt" != "$out" ] && out="$alt"
  fi
  record_step "nvidia-bug-report.sh" "nvidia-bug-report.sh --output-file ..." "$rc" $((SECONDS - s)) "$out" ""
  BUGREPORT_FILE="$out"; BUGREPORT_RC="$rc"
}
BUGREPORT_FILE=""; BUGREPORT_RC=""

collect_thermal() {
  [ "$DO_THERMAL" -eq 1 ] || [ -n "$THERMAL_CSV_IN" ] || return 0
  mkdir -p "$RAW/thermal"
  if [ -n "$THERMAL_CSV_IN" ]; then
    cp "$THERMAL_CSV_IN" "$RAW/thermal/" && THERMAL_CSV="$RAW/thermal/$(basename "$THERMAL_CSV_IN")"
    record_step "Thermal CSV (supplied)" "--thermal-csv $THERMAL_CSV_IN" 0 0 "$THERMAL_CSV" "analysed only; test not run here"
    return 0
  fi

  local script="$THERMAL_SCRIPT"
  if [ -z "$script" ]; then
    for c in "$SCRIPT_DIR/vendor/Master_GPU_Thermal_Script/master_thermal_test.sh" "$SCRIPT_DIR/master_thermal_test.sh"; do
      [ -r "$c" ] && { script="$c"; break; }
    done
  fi
  if [ -z "$script" ] || [ ! -r "$script" ]; then
    warn "Thermal script not found. Use --thermal-script PATH or place it under vendor/."
    record_step "Thermal test" "master_thermal_test.sh" skipped 0 "" "thermal script not found"
    return 0
  fi
  if [ "$HAVE_SMI" -eq 0 ]; then
    record_step "Thermal test" "$script" skipped 0 "" "nvidia-smi not found"; return 0
  fi

  # Platform selection
  if [ -z "$THERMAL_PLATFORM" ]; then
    if [ -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
      local ans=""
      printf 'Thermal test platform: 1) Hopper (H100/H200)  2) Blackwell (B200) [1-2]: '
      read -r ans
      case "$ans" in 1) THERMAL_PLATFORM=hopper ;; 2) THERMAL_PLATFORM=blackwell ;; esac
    fi
    if [ -z "$THERMAL_PLATFORM" ]; then
      warn "No valid --thermal-platform given; skipping the thermal test."
      record_step "Thermal test" "$script" skipped 0 "" "platform not specified"; return 0
    fi
  fi

  # Prerequisites (the OEM script checks these too; failing early is clearer)
  local pre_missing=""
  have ipmitool || pre_missing="$pre_missing ipmitool"
  if [ "$IS_ROOT" -eq 0 ] && ! have sudo; then pre_missing="$pre_missing sudo"; fi
  if [ "$THERMAL_PLATFORM" = "hopper" ]; then
    { have dcgmproftester12 || have dcgmproftester13; } || pre_missing="$pre_missing dcgmproftester12/13"
  else
    have dcgmi || pre_missing="$pre_missing dcgmi"
  fi
  if [ -n "$pre_missing" ]; then
    warn "Thermal test prerequisites missing:$pre_missing (see the thermal script README). Skipping."
    record_step "Thermal test" "$script" skipped 0 "" "missing:$pre_missing"; return 0
  fi

  have sudo || warn "'sudo' not found: the OEM script calls 'sudo ipmitool', so the BMC inlet temperature column may be empty."
  local mins=15; [ "$THERMAL_PLATFORM" = "blackwell" ] && mins=30
  if [ "$ASSUME_YES" -eq 0 ]; then
    if [ -t 0 ]; then
      printf 'The thermal test runs a GPU stress workload for about %s minutes on %s (killed after %s min if it has not finished). Do not run it on a node serving production workloads. Continue? [y/N] ' "$mins" "$HOST" "$((THERMAL_TIMEOUT / 60))"
      local yn=""; read -r yn
      case "$yn" in y|Y|yes|YES) ;; *) log "Thermal test cancelled."; record_step "Thermal test" "$script" skipped 0 "" "declined at prompt"; return 0 ;; esac
    else
      warn "Not a terminal; add --yes to confirm the thermal test. Skipping."
      record_step "Thermal test" "$script" skipped 0 "" "needs --yes when not interactive"; return 0
    fi
  fi

  have timeout || warn "'timeout' not available: the thermal test will run without a time limit"
  local choice=1; [ "$THERMAL_PLATFORM" = "blackwell" ] && choice=2
  local s=$SECONDS rc
  log "Running thermal test ($THERMAL_PLATFORM, about $mins min, timeout ${THERMAL_TIMEOUT}s). Progress dots appear every 30 s."
  start_ticker
  if [ "$THERMAL_TIMEOUT" -gt 0 ] && have timeout; then
    ( cd "$RAW/thermal" && printf '%s\n' "$choice" | timeout "$THERMAL_TIMEOUT" bash "$script" > "$RAW/thermal/thermal-run.log" 2>&1 ); rc=$?
  else
    ( cd "$RAW/thermal" && printf '%s\n' "$choice" | bash "$script" > "$RAW/thermal/thermal-run.log" 2>&1 ); rc=$?
  fi
  stop_ticker
  THERMAL_CSV="$(ls -1t "$RAW"/thermal/thermal_results.*.csv 2>/dev/null | head -n1)"
  record_step "Thermal test" "master_thermal_test.sh ($THERMAL_PLATFORM)" "$rc" $((SECONDS - s)) "${THERMAL_CSV:-$RAW/thermal/thermal-run.log}" ""
  case "$rc" in
    0)   ;;
    124) warn "Thermal script timed out after ${THERMAL_TIMEOUT}s (see raw/thermal/thermal-run.log); try --thermal-timeout with a larger value." ;;
    *)   warn "Thermal script exited with $rc (see raw/thermal/thermal-run.log)" ;;
  esac
}
THERMAL_CSV=""

# --------------------------------------------------------------- analysis ---
# nvidia-smi -q is flattened to TSV: GPU-index <TAB> path <TAB> value
flatten_smi() {
  tr -d '\000-\010\013-\037' < "$1" | awk '
    BEGIN { gpu = "global"; gi = -1 }
    /^=+NVSMI LOG=+/ { next }
    /^[[:space:]]*$/ { next }
    {
      line = $0
      match(line, /^ */); ind = RLENGTH
      depth = int(ind / 4)
      txt = substr(line, ind + 1)
      if (ind == 0 && txt ~ /^GPU [0-9A-Fa-f]+:[0-9A-Fa-f]+:[0-9A-Fa-f]+\.[0-9A-Fa-f]/) {
        gi++; gpu = gi
        printf "%s\t_busid\t%s\n", gpu, substr(txt, 5)
        next
      }
      p = index(txt, " : ")
      if (p > 0) { key = substr(txt, 1, p - 1); val = substr(txt, p + 3) }
      else if (txt ~ /:$/) { key = substr(txt, 1, length(txt) - 1); val = "" }
      else { key = txt; val = "" }
      gsub(/^ +| +$/, "", key); gsub(/^ +| +$/, "", val)
      base = (gpu == "global") ? 0 : 1
      lvl = depth - base; if (lvl < 0) lvl = 0
      stack[lvl] = key
      path = stack[0]
      for (i = 1; i <= lvl; i++) path = path "/" stack[i]
      if (val != "") printf "%s\t%s\t%s\n", gpu, path, val
    }'
}

analyze_smi() {
  local f="$RAW/nvidia-smi-q.txt" flat="$PARSED/smi.tsv"
  : > "$flat"
  if [ ! -e "$f" ]; then
    add_finding info smi - "nvidia-smi -q was not run" "nvidia-smi is not available on this node, or the step was skipped."
    return
  fi
  if [ ! -s "$f" ]; then
    local why; why="$(head -n 3 "$RAW/nvidia-smi-q.stderr" 2>/dev/null | tr '\n' ' ')"
    add_finding crit smi - "nvidia-smi -q produced no output" "${why:-No error text captured.} The driver may not be loaded or the GPUs may be unreachable."
    return
  fi
  flatten_smi "$f" > "$flat"
  if ! grep -q '_busid' "$flat"; then
    add_finding crit smi - "No GPUs found in nvidia-smi -q output" "First line: $(head -n 1 "$f" | cut -c1-200). The driver may have failed to communicate with the GPUs."
    return
  fi

  awk -F'\t' '
    function isnum(v) { return (v ~ /^-?[0-9]+(\.[0-9]+)?$/) }
    function lead(v,  t) { t = v; sub(/[^0-9.\-].*$/, "", t); return t }
    function lab(g) { return "GPU " g " (" busid[g] ")" }
    function emit(sev, g, title, detail) {
      gsub(/\t/, " ", detail)
      printf "%s\tsmi\t%s\t%s\t%s\n", sev, lab(g), title, detail
    }
    BEGIN { maxg = -1 }
    $1 == "global" {
      if ($2 == "Attached GPUs") attached = $3
      next
    }
    $2 == "_busid" { busid[$1] = $3; if ($1 + 0 > maxg) maxg = $1 + 0; ngpu++; next }
    {
      g = $1; p = $2; v = $3

      if (p ~ /Remapped Rows\/Remapping Failure Occurred$/) {
        seen_rf = 1
        if (v ~ /^Yes/) { bad_rf++; emit("crit", g, "Row remapping failure reported", "nvidia-smi -q: " p " = " v ". Commonly treated as a GPU memory hardware-fault indicator; confirm with NVIDIA/OEM guidance.") }
      }
      if (p ~ /Remapped Rows\/Pending$/) {
        seen_rp = 1
        if (v ~ /^Yes/) { bad_rp++; emit("warn", g, "Row remap pending", "nvidia-smi -q: " p " = " v ". A GPU reset or node power-cycle is typically needed before the remap takes effect.") }
      }
      if (p ~ /Remapped Rows\/Uncorrectable Error$/ && isnum(lead(v)) && lead(v) + 0 > 0) {
        emit("warn", g, "Rows remapped after uncorrectable errors", "nvidia-smi -q: " p " = " v)
      }
      if (p ~ /Remapped Rows\/Correctable Error$/ && isnum(lead(v)) && lead(v) + 0 > 0) {
        emit("info", g, "Rows remapped after correctable errors", "nvidia-smi -q: " p " = " v)
      }
      if (p ~ /Bank Remap Availability Histogram\/None$/ && isnum(lead(v)) && lead(v) + 0 > 0) {
        emit("warn", g, "Memory banks with no remaps left", "nvidia-smi -q: " p " = " v ". Spare rows may be exhausted on these banks.")
      }

      if (p ~ /^ECC Errors\// && v ~ /^[0-9]/) {
        seen_ecc = 1
        n = lead(v) + 0
        if (n > 0) {
          if (p ~ /Uncorrectable|Double Bit/) {
            if (p ~ /\/Volatile\//) { bad_ecc++; emit("crit", g, "Uncorrectable ECC errors (since last reset/driver load)", "nvidia-smi -q: " p " = " v) }
            else { bad_ecc++; emit("warn", g, "Uncorrectable ECC errors (lifetime counter)", "nvidia-smi -q: " p " = " v) }
          } else if (p ~ /Correctable|Single Bit/) {
            emit("info", g, "Correctable ECC errors recorded", "nvidia-smi -q: " p " = " v ". Low counts are common; a rapidly rising count is worth reporting.")
          }
        }
      }
      if (p ~ /^ECC Mode\/Current$/) {
        seen_mode = 1
        if (v ~ /^Disabled/) { bad_mode++; emit("warn", g, "ECC mode is disabled", "nvidia-smi -q: " p " = " v ". Unexpected on most data-center GPUs; confirm whether this was intentional.") }
      }
      if (p ~ /^Retired Pages\/Pending Page Blacklist$/) {
        seen_ret = 1
        if (v ~ /^Yes/) { bad_ret++; emit("warn", g, "Retired page pending", "nvidia-smi -q: " p " = " v ". A GPU reset or power-cycle is typically needed to apply it.") }
      }
      if (p ~ /Reset Status\/(Reset Required|Drain and Reset Recommended)$/) {
        seen_rst = 1
        if (v ~ /^Yes/) { bad_rst++; emit("warn", g, "GPU reports a reset is required/recommended", "nvidia-smi -q: " p " = " v) }
      }

      if (p == "Temperature/GPU Current Temp")     cur[g]  = lead(v)
      if (p == "Temperature/GPU Slowdown Temp")    slow[g] = lead(v)
      if (p == "Temperature/GPU Shutdown Temp")    shut[g] = lead(v)
      if (p == "Temperature/GPU T.Limit Temp")     tlim[g] = lead(v)

      if (p ~ /^Clocks (Event|Throttle) Reasons\//) {
        seen_thr = 1
        split(p, a, "/"); k = a[2]
        if (v ~ /^Active/) {
          if (k == "HW Thermal Slowdown")       { bad_thr++; emit("crit", g, "Hardware thermal slowdown active", "nvidia-smi -q: " p " = " v) }
          else if (k == "HW Slowdown")          { bad_thr++; emit("crit", g, "Hardware slowdown active", "nvidia-smi -q: " p " = " v) }
          else if (k == "HW Power Brake Slowdown") { bad_thr++; emit("warn", g, "Hardware power-brake slowdown active", "nvidia-smi -q: " p " = " v ". Can be triggered by the platform power system.") }
          else if (k == "SW Thermal Slowdown")  { bad_thr++; emit("warn", g, "Software thermal slowdown active", "nvidia-smi -q: " p " = " v) }
        }
      }

      if (p ~ /^PCI\/(GPU Link Info\/)?Link Width\/Max$/)     wmax[g] = lead(v)
      if (p ~ /^PCI\/(GPU Link Info\/)?Link Width\/Current$/) wcur[g] = lead(v)

      if (p ~ /(^|\/)Fabric\/State$/) {
        if (v !~ /^N\/A/) { seen_fab = 1; if (v !~ /^Completed/) { bad_fab++; emit("warn", g, "Fabric state is not Completed", "nvidia-smi -q: " p " = " v ". Possible NVLink/NVSwitch fabric issue.") } }
      }
      if (p ~ /(^|\/)Fabric\/Status$/) {
        if (v !~ /^N\/A/) { seen_fab = 1; if (v !~ /^Success/) { bad_fab++; emit("warn", g, "Fabric status is not Success", "nvidia-smi -q: " p " = " v ". Possible NVLink/NVSwitch fabric issue.") } }
      }
    }
    END {
      if (ngpu == 0) exit
      for (g = 0; g <= maxg; g++) {
        if (cur[g] != "" && isnum(cur[g])) {
          seen_temp = 1
          if (slow[g] != "" && isnum(slow[g])) {
            if (cur[g] + 0 >= slow[g] + 0) { bad_temp++; emit("crit", g, "GPU temperature at or above slowdown threshold", "nvidia-smi -q: current " cur[g] " C, slowdown " slow[g] " C") }
            else if (cur[g] + 0 >= slow[g] - 5) { bad_temp++; emit("warn", g, "GPU temperature within 5 C of slowdown threshold", "nvidia-smi -q: current " cur[g] " C, slowdown " slow[g] " C") }
          }
          if (shut[g] != "" && isnum(shut[g]) && cur[g] + 0 >= shut[g] + 0) { bad_temp++; emit("crit", g, "GPU temperature at or above shutdown threshold", "nvidia-smi -q: current " cur[g] " C, shutdown " shut[g] " C") }
        }
        if (tlim[g] != "" && isnum(tlim[g])) {
          seen_tlim = 1
          if (tlim[g] + 0 <= 0) { bad_tlim++; emit("crit", g, "No thermal margin left (T.Limit)", "nvidia-smi -q: GPU T.Limit Temp = " tlim[g] " C") }
          else if (tlim[g] + 0 < 5) { bad_tlim++; emit("warn", g, "Thermal margin below 5 C (T.Limit)", "nvidia-smi -q: GPU T.Limit Temp = " tlim[g] " C (value at time of capture)") }
        }
        if (wmax[g] != "" && wcur[g] != "" && isnum(wmax[g]) && isnum(wcur[g])) {
          seen_pcie = 1
          if (wcur[g] + 0 < wmax[g] + 0) { bad_pcie++; emit("warn", g, "PCIe link width below maximum", "nvidia-smi -q: current x" wcur[g] ", max x" wmax[g] ". May indicate a seating/riser/cable issue; re-check under load.") }
        }
      }
      if (attached != "" && isnum(attached)) {
        if (attached + 0 != ngpu) printf "crit\tsmi\t-\tGPU count mismatch\tnvidia-smi -q: Attached GPUs = %s but %d GPU section(s) were found.\n", attached, ngpu
        else printf "ok\tsmi\t-\tGPU count consistent\t%d GPU(s) reported; matches Attached GPUs.\n", ngpu
      } else printf "info\tsmi\t-\tGPUs found\t%d GPU section(s) in nvidia-smi -q output.\n", ngpu

      c("Row remapping", seen_rf, bad_rf, "no remapping failure reported")
      c("Row remap pending", seen_rp, bad_rp, "no pending remap")
      c("ECC error counters", seen_ecc, bad_ecc, "no uncorrectable ECC errors")
      c("ECC mode", seen_mode, bad_mode, "ECC enabled")
      c("Retired pages", seen_ret, bad_ret, "no pending page retirement")
      c("GPU reset status", seen_rst, bad_rst, "no reset requested")
      c("GPU temperature", seen_temp, bad_temp, "within slowdown thresholds")
      c("Thermal margin (T.Limit)", seen_tlim, bad_tlim, "margin at least 5 C")
      c("Clock throttling (thermal/HW)", seen_thr, bad_thr, "no thermal/hardware slowdown active")
      c("PCIe link width", seen_pcie, bad_pcie, "current width matches maximum")
      c("Fabric (NVLink/NVSwitch) state", seen_fab, bad_fab, "fabric state Completed/Success")
    }
    function c(name, seen, bad, okmsg) {
      if (!seen) printf "info\tsmi\t-\tNot evaluated: %s\tThe relevant field(s) are not present in this nvidia-smi -q output (older/newer driver, or not applicable to this GPU).\n", name
      else if (bad + 0 == 0) printf "ok\tsmi\t-\t%s\tChecked on %d GPU(s): %s.\n", name, ngpu, okmsg
    }
  ' "$flat" >> "$FINDINGS"

  # nvidia-smi -L cross-check
  if [ -s "$RAW/nvidia-smi-L.txt" ]; then
    local nl ns
    nl="$(grep -c '^GPU [0-9]*:' "$RAW/nvidia-smi-L.txt")"
    ns="$(grep -c "$(printf '\t')_busid" "$flat")"
    if [ "$nl" != "$ns" ]; then
      add_finding warn smi - "nvidia-smi -L and -q disagree on GPU count" "-L lists $nl GPU(s); -q has $ns GPU section(s)."
    fi
  fi
}

# GPU summary table (HTML) from the flattened TSV
smi_summary_html() {
  local flat="$PARSED/smi.tsv"
  [ -s "$flat" ] || return 0
  awk -F'\t' '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    function first(g, key, v) { if (!((g, key) in S) && v != "" && v != "N/A") S[g, key] = v }
    $2 == "_busid" { bus[$1] = $3; if ($1 + 0 > maxg) maxg = $1 + 0; next }
    $1 == "global" { next }
    {
      g = $1; p = $2; v = $3
      if (p == "Product Name") first(g, "name", v)
      if (p == "Serial Number") first(g, "serial", v)
      if (p == "GPU UUID") first(g, "uuid", v)
      if (p == "VBIOS Version") first(g, "vbios", v)
      if (p == "Temperature/GPU Current Temp") first(g, "temp", v)
      if (p == "Temperature/GPU T.Limit Temp") first(g, "tlim", v)
      if (p == "Temperature/Memory Current Temp") first(g, "mtemp", v)
      if (p ~ /Power Draw$/) first(g, "pwr", v)
      if (p ~ /Remapped Rows\/Pending$/) first(g, "rpend", v)
      if (p ~ /Remapped Rows\/Remapping Failure Occurred$/) first(g, "rfail", v)
      if (p ~ /Remapped Rows\/Uncorrectable Error$/) first(g, "runc", v)
      if (p ~ /^ECC Errors\/Volatile\/.*(Uncorrectable|Double Bit)/) { if (v ~ /^[0-9]/) { vunc[g] += v + 0; first(g, "hasvunc", "1") } }
      if (p ~ /^Retired Pages\/Pending Page Blacklist$/) first(g, "retpend", v)
    }
    END {
      print "<table class=\"data\"><thead><tr><th>GPU</th><th>PCI bus id</th><th>Product</th><th>Serial</th><th>VBIOS</th><th>Temp</th><th>T.Limit</th><th>Mem temp</th><th>Power draw</th><th>Remap pending</th><th>Remap failure</th><th>Rows remapped (unc.)</th><th>Volatile unc. ECC</th></tr></thead><tbody>"
      for (g = 0; g <= maxg; g++) {
        printf "<tr><td>%d</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", g, esc(bus[g]), esc(S[g, "name"]), esc(S[g, "serial"]), esc(S[g, "vbios"]), esc(S[g, "temp"]), esc(S[g, "tlim"]), esc(S[g, "mtemp"]), esc(S[g, "pwr"]), esc(S[g, "rpend"]), esc(S[g, "rfail"]), esc(S[g, "runc"]), ((g, "hasvunc") in S ? vunc[g] : "n/a")
      }
      print "</tbody></table>"
    }' "$flat"
}

analyze_dmesg() {
  local f="$RAW/dmesg-T.txt"
  if [ ! -e "$f" ]; then
    add_finding info dmesg - "dmesg -T was not run" "dmesg is not available on this node."
    return
  fi
  if [ ! -s "$f" ]; then
    add_finding crit dmesg - "dmesg -T produced no output" "$(head -n 2 "$RAW/dmesg-T.stderr" 2>/dev/null | tr '\n' ' ') Re-run with sudo if the kernel log is restricted."
    return
  fi
  tr -d '\000-\010\013-\037' < "$f" | awk '
    function trunc(s) { if (length(s) > 240) return substr(s, 1, 237) "..."; return s }
    function addk(key, sev, title, line, ts) {
      if (!(key in cnt)) { nk++; keys[nk] = key; sevk[key] = sev; titk[key] = title; first[key] = ts; sample[key] = trunc(line) }
      cnt[key]++; last[key] = ts
    }
    function xsev(c) {
      if (c == 48 || c == 62 || c == 64 || c == 74 || c == 79 || c == 95 || c == 119 || c == 120) return "crit"
      return "warn"
    }
    function xdesc(c) {
      if (c == 13)  return "graphics engine exception"
      if (c == 31)  return "GPU memory page fault"
      if (c == 43)  return "GPU stopped processing"
      if (c == 45)  return "preemptive cleanup after a previous error"
      if (c == 48)  return "double-bit ECC error"
      if (c == 61)  return "internal microcontroller warning"
      if (c == 62)  return "internal microcontroller halt"
      if (c == 63)  return "ECC page retirement / row remap recorded"
      if (c == 64)  return "ECC page retirement / row remap recording failure"
      if (c == 74)  return "NVLink error"
      if (c == 79)  return "GPU has fallen off the bus"
      if (c == 92)  return "high single-bit ECC error rate"
      if (c == 94)  return "contained ECC error"
      if (c == 95)  return "uncontained ECC error"
      if (c == 119) return "GSP RPC timeout"
      if (c == 120) return "GSP error"
      return "see the NVIDIA Xid catalog for this code"
    }
    {
      nl++; line = $0; ts = ""; body = line
      if (match(line, /^\[[^]]+\]/)) { ts = substr(line, 2, RLENGTH - 2); body = substr(line, RLENGTH + 2) }
      if (nl == 1) t1 = ts
      tl = ts
      low = tolower(body)

      if (match(body, /Xid \(PCI:[^)]*\): *[0-9]+/)) {
        s = substr(body, RSTART, RLENGTH)
        pci = s; sub(/^Xid \(PCI:/, "", pci); sub(/\).*$/, "", pci)
        code = s; sub(/^.*\): */, "", code)
        addk("xid|" code "|" pci, xsev(code + 0), "NVIDIA Xid " code " on PCI " pci " (commonly: " xdesc(code + 0) ")", line, ts)
        next
      }
      if (low ~ /has fallen off the bus/)                         addk("fob", "crit", "GPU reported as fallen off the bus", line, ts)
      if (low ~ /rminitadapter failed/)                           addk("rminit", "crit", "NVIDIA driver failed to initialise a GPU (RmInitAdapter)", line, ts)
      if (low ~ /nvrm:/ && low ~ /(failed|error|timeout)/)        addk("nvrm", "warn", "NVRM error/failed message", line, ts)
      if (low ~ /(nvlink|nvswitch|fabric ?manager)/ && low ~ /(error|fail|timeout|degrad|link down)/) addk("nvl", "warn", "NVLink/NVSwitch/fabric error message", line, ts)
      if (low ~ /(aer:|pcie bus error|pcieport.*error|aer_status)/) addk("aer", "warn", "PCIe error (AER) message", line, ts)
      if (low ~ /(\[hardware error\]|machine check exception|mce: .*(uncorrected|corrected error))/) addk("mce", "crit", "Machine-check / hardware error", line, ts)
      if (low ~ /edac/ && low ~ /(uncorrect| ue )/)        addk("edacue", "crit", "EDAC uncorrectable memory error", line, ts)
      else if (low ~ /edac/ && low ~ /(correct| ce )/)            addk("edacce", "warn", "EDAC correctable memory error", line, ts)
      if (low ~ /(throttl|temperature above threshold|overheat|critical temperature|thermal shutdown)/) addk("therm", "warn", "Thermal/throttling message", line, ts)
      if (low ~ /(soft lockup|hard lockup|rcu.*stall|blocked for more than|kernel bug|call trace:|oops:)/) addk("lockup", "warn", "Kernel lockup/stall/trace message", line, ts)
      if (low ~ /(out of memory|oom-kill)/)                       addk("oom", "warn", "Out-of-memory killer activity", line, ts)
      if (low ~ /(i\/o error|nvme.*(timeout|reset)|blk_update_request|ext4-fs error|xfs.*error)/) addk("io", "warn", "Storage I/O error message", line, ts)
    }
    END {
      for (i = 1; i <= nk; i++) {
        k = keys[i]
        printf "%s\tdmesg\t-\t%s\t%d occurrence(s); first %s; last %s. Sample: %s\n", sevk[k], titk[k], cnt[k], first[k], last[k], sample[k]
      }
      if (nk == 0) printf "ok\tdmesg\t-\tNo known error patterns found\tScanned %d line(s) for Xid, NVLink, PCIe AER, machine-check, EDAC, thermal, lockup, OOM and storage patterns.\n", nl
      printf "info\tdmesg\t-\tKernel log coverage\t%d line(s), from [%s] to [%s]. Events older than the ring buffer are not visible, and -T timestamps can drift after suspend/resume.\n", nl, t1, tl
    }' >> "$FINDINGS"
}

analyze_bugreport() {
  local f="$BUGREPORT_FILE"
  if [ "$SKIP_BUGREPORT" -eq 1 ]; then
    add_finding info bugreport - "nvidia-bug-report.sh was skipped" "Skipped with --skip-bugreport."
    return
  fi
  if ! have nvidia-bug-report.sh; then
    add_finding warn bugreport - "nvidia-bug-report.sh not found" "Not found in PATH. It ships with the NVIDIA driver; support may need to ask for it separately."
    return
  fi
  if [ -z "$f" ] || [ ! -s "$f" ]; then
    case "$BUGREPORT_RC" in
      124) add_finding crit bugreport - "nvidia-bug-report.sh timed out" "No output file after ${BUGREPORT_TIMEOUT}s. Try --bugreport-timeout with a larger value; a hung GPU/driver can also cause this." ;;
      *)   add_finding crit bugreport - "nvidia-bug-report.sh produced no output" "Exit code ${BUGREPORT_RC:-?}. See raw/nvidia-bug-report.stderr in the archive." ;;
    esac
    return
  fi
  local sz; sz="$(wc -c < "$f" | tr -d ' ')"
  case "$f" in
    *.gz)
      if gzip -t "$f" 2>/dev/null; then
        gzip -dc "$f" 2>/dev/null | head -n 400 > "$PARSED/bugreport-head.txt"
        add_finding ok bugreport - "Bug report file is a valid gzip archive" "$(basename "$f"), $sz bytes compressed."
      else
        add_finding crit bugreport - "Bug report file is a truncated or corrupt gzip" "$(basename "$f"), $sz bytes. The run may have been interrupted."
      fi ;;
    *) head -n 400 "$f" > "$PARSED/bugreport-head.txt"
       add_finding ok bugreport - "Bug report file produced" "$(basename "$f"), $sz bytes." ;;
  esac
  [ "${BUGREPORT_RC:-0}" = "0" ] || add_finding warn bugreport - "nvidia-bug-report.sh exited non-zero" "Exit code $BUGREPORT_RC; the file may be incomplete."
}

# Thermal CSV analysis. Columns are located by header name, since the OEM script
# adds columns in front of / after the nvidia-smi query columns.
analyze_thermal() {
  [ -n "$THERMAL_CSV" ] && [ -s "$THERMAL_CSV" ] || {
    if [ "$DO_THERMAL" -eq 1 ] || [ -n "$THERMAL_CSV_IN" ]; then
      add_finding crit thermal - "No thermal CSV available" "The thermal step did not produce a CSV. See the run log and the Run log page."
    fi
    return
  }
  tr -d '\000-\010\013\014\016-\037' < "$THERMAL_CSV" | awk -F',' '
    function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
    function hex(s,  i, c, n, d) {
      s = tolower(trim(s)); sub(/^0x/, "", s); n = 0
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); d = index("0123456789abcdef", c); if (d == 0) return 0; n = n * 16 + (d - 1) }
      return n
    }
    function num(s) { s = trim(s); if (s ~ /^-?[0-9]/) return s + 0; return "" }
    function hasbit(n, b) { return (int(n / b) % 2) == 1 }
    function emit(sev, scope, title, detail) { gsub(/\t/, " ", detail); printf "%s\tthermal\t%s\t%s\t%s\n", sev, scope, title, detail }
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        h = tolower(trim($i))
        if (h ~ /^index$/) ci = i
        else if (h ~ /^temperature\.gpu( |$|\[)/) ct = i
        else if (h ~ /temperature\.memory/) cm = i
        else if (h ~ /tlimit/) cl = i
        else if (h ~ /^power\.draw/) cp = i
        else if (h ~ /^clocks\.current\.sm/) cc = i
        else if (h ~ /(clocks_throttle_reasons|clocks_event_reasons)\.active/) cr = i
        else if (h ~ /^utilization\.gpu/) cu = i
        else if (h ~ /bmc\.inlet\.temp/) cb = i
        else if (h ~ /^timestamp$/) cts = i
      }
      if (!ci || !ct) { bad = 1 }
      next
    }
    bad { next }
    {
      g = trim($ci); rows++
      if (!(g in seen)) { seen[g] = 1; ng++; order[ng] = g; tmin[g] = ""; lmin[g] = "" }
      if (cts && first == "") first = trim($cts)
      if (cts) lastts = trim($cts)
      if (cb && inlet == "") inlet = trim($cb)
      v = num($ct); if (v != "") { if (tmax[g] == "" || v > tmax[g]) tmax[g] = v }
      if (cm) { v = num($cm); if (v != "") { if (mmax[g] == "" || v > mmax[g]) mmax[g] = v } }
      if (cl) { v = num($cl); if (v != "") { if (lmin[g] == "" || v < lmin[g]) lmin[g] = v } }
      if (cp) { v = num($cp); if (v != "") { if (pmax[g] == "" || v > pmax[g]) pmax[g] = v } }
      if (cc) { v = num($cc); if (v != "") { if (cmin[g] == "" || v < cmin[g]) cmin[g] = v; if (cmax[g] == "" || v > cmax[g]) cmax[g] = v } }
      if (cu) { v = num($cu); if (v != "") { if (umax[g] == "" || v > umax[g]) umax[g] = v } }
      if (cr) { m = hex($cr); for (b = 1; b <= 128; b *= 2) { if (hasbit(m, b)) bits[g, b]++ } }
    }
    END {
      if (bad) { emit("warn", "-", "Thermal CSV format not recognised", "Could not find the index / temperature.gpu columns in the header, so no analysis was done. The raw CSV is included below."); exit }
      if (rows == 0) { emit("crit", "-", "Thermal CSV has no data rows", "The file contains a header only."); exit }
      emit("info", "-", "Thermal samples", rows " row(s) across " ng " GPU(s); first " first ", last " lastts "; BMC inlet temp at start: " (inlet == "" ? "n/a" : inlet) ".")
      hottest = -1; coolest = 1000
      for (i = 1; i <= ng; i++) { g = order[i]; if (tmax[g] != "") { if (tmax[g] > hottest) { hottest = tmax[g]; hg = g } if (tmax[g] < coolest) coolest = tmax[g] } }
      thermal_bad = 0
      for (i = 1; i <= ng; i++) {
        g = order[i]; sc = "GPU " g
        if (bits[g, 64]) { thermal_bad++; emit("crit", sc, "HW thermal slowdown observed during the test", bits[g, 64] " sample(s) with the HW thermal slowdown reason set.") }
        if (bits[g, 8])  { thermal_bad++; emit("crit", sc, "HW slowdown observed during the test", bits[g, 8] " sample(s) with the HW slowdown reason set.") }
        if (bits[g, 128]){ thermal_bad++; emit("warn", sc, "HW power brake observed during the test", bits[g, 128] " sample(s) with the HW power-brake reason set.") }
        if (bits[g, 32]) { thermal_bad++; emit("warn", sc, "SW thermal slowdown observed during the test", bits[g, 32] " sample(s) with the SW thermal slowdown reason set.") }
        if (lmin[g] != "") {
          if (lmin[g] <= 0) { thermal_bad++; emit("crit", sc, "Thermal margin reached zero (T.Limit)", "Minimum temperature.gpu.tlimit = " lmin[g] " C.") }
          else if (lmin[g] < 5) { thermal_bad++; emit("warn", sc, "Thermal margin below 5 C (T.Limit)", "Minimum temperature.gpu.tlimit = " lmin[g] " C.") }
        }
        if (tmax[g] != "" && hottest - coolest >= 15 && tmax[g] == hottest) { thermal_bad++; emit("warn", sc, "Runs much hotter than the coolest GPU", "Max " tmax[g] " C vs coolest GPU max " coolest " C (spread " (hottest - coolest) " C). May point to cooling/airflow or thermal-paste differences on this GPU.") }
      }
      anyu = 0; lowu = 0
      for (i = 1; i <= ng; i++) { g = order[i]; if (umax[g] != "") { anyu = 1; if (umax[g] < 50) lowu++ } }
      if (anyu && lowu > 0) emit("warn", "-", "GPU utilization stayed low on " lowu " GPU(s)", "Max utilization.gpu was under 50% on those GPUs, so the test may not have loaded them fully.")
      if (thermal_bad == 0) emit("ok", "-", "No thermal slowdown or margin problems observed", "Checked throttle-reason bits, T.Limit margin and GPU-to-GPU spread over " rows " row(s). Thresholds are simple defaults; the OEM decides pass/fail.")
    }' >> "$FINDINGS"
}

thermal_summary_html() {
  [ -n "$THERMAL_CSV" ] && [ -s "$THERMAL_CSV" ] || return 0
  tr -d '\000-\010\013\014\016-\037' < "$THERMAL_CSV" | awk -F',' '
    function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
    function num(s) { s = trim(s); if (s ~ /^-?[0-9]/) return s + 0; return "" }
    NR == 1 {
      for (i = 1; i <= NF; i++) { h = tolower(trim($i))
        if (h ~ /^index$/) ci = i
        else if (h ~ /^temperature\.gpu( |$|\[)/) ct = i
        else if (h ~ /temperature\.memory/) cm = i
        else if (h ~ /tlimit/) cl = i
        else if (h ~ /^power\.draw/) cp = i
        else if (h ~ /^clocks\.current\.sm/) cc = i
        else if (h ~ /^utilization\.gpu/) cu = i }
      next }
    ci && ct {
      g = trim($ci)
      if (!(g in seen)) { seen[g] = 1; ng++; order[ng] = g }
      v = num($ct); if (v != "" && (tmax[g] == "" || v > tmax[g])) tmax[g] = v
      if (cm) { v = num($cm); if (v != "" && (mmax[g] == "" || v > mmax[g])) mmax[g] = v }
      if (cl) { v = num($cl); if (v != "" && (lmin[g] == "" || v < lmin[g])) lmin[g] = v }
      if (cp) { v = num($cp); if (v != "" && (pmax[g] == "" || v > pmax[g])) pmax[g] = v }
      if (cc) { v = num($cc); if (v != "" && (cmin[g] == "" || v < cmin[g])) cmin[g] = v }
      if (cu) { v = num($cu); if (v != "" && (umax[g] == "" || v > umax[g])) umax[g] = v }
    }
    END {
      if (ng == 0) exit
      print "<table class=\"data\"><thead><tr><th>GPU</th><th>Max temp (C)</th><th>Max mem temp (C)</th><th>Min T.Limit (C)</th><th>Max power (W)</th><th>Min SM clock (MHz)</th><th>Max util (%)</th></tr></thead><tbody>"
      for (i = 1; i <= ng; i++) { g = order[i]
        printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", g, tmax[g], mmax[g], lmin[g], pmax[g], cmin[g], umax[g] }
      print "</tbody></table>"
    }'
}

analyze_system() {
  local failed
  failed="$(awk -F'\t' '$3 == "failed" || $3 == "timeout" { printf "%s (exit %s); ", $1, $4 }' "$MANIFEST")"
  if [ -n "$failed" ]; then
    add_finding warn system - "Some collection steps did not succeed" "$failed See the Run log page."
  fi
  local skipped
  skipped="$(awk -F'\t' '$3 == "skipped" { printf "%s (%s); ", $1, $7 }' "$MANIFEST")"
  [ -z "$skipped" ] || add_finding info system - "Skipped steps" "$skipped"
}

# ------------------------------------------------------------ HTML report ---
html_escape() {
  tr -d '\000-\010\013\014\016-\037' | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}
esc() { printf '%s' "$1" | html_escape; }

# embed_raw TITLE FILE MODE(head|tail)
embed_raw() {
  local title="$1" file="$2" mode="${3:-head}" max size
  max=$((MAX_EMBED_KB * 1024))
  if [ -z "$file" ] || [ ! -s "$file" ]; then
    printf '<details class="raw"><summary>%s <span class="muted">(no output captured)</span></summary></details>\n' "$(esc "$title")"
    return
  fi
  size="$(wc -c < "$file" | tr -d ' ')"
  printf '<details class="raw"><summary>%s <span class="muted">(%s bytes)</span></summary>\n' "$(esc "$title")" "$size"
  if [ "$size" -gt "$max" ]; then
    printf '<p class="note">Showing the %s %s KB of %s bytes. The complete file is in the archive under <code>%s</code>.</p>\n' \
      "$([ "$mode" = tail ] && echo last || echo first)" "$MAX_EMBED_KB" "$size" "$(esc "${file#"$RUN_DIR"/}")"
    printf '<pre>'
    if [ "$mode" = tail ]; then tail -c "$max" "$file" | html_escape; else head -c "$max" "$file" | html_escape; fi
    printf '</pre>\n'
  else
    printf '<pre>'; html_escape < "$file"; printf '</pre>\n'
  fi
  printf '</details>\n'
}

# render_findings PAGE|ALL  SEVERITIES(comma list)
render_findings() {
  awk -F'\t' -v page="$1" -v sevs="$2" '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    function label(s) { return (s == "crit") ? "CRITICAL" : (s == "warn") ? "WARN" : (s == "info") ? "INFO" : "OK" }
    function pname(p) {
      if (p == "smi") return "nvidia-smi -q"; if (p == "dmesg") return "dmesg -T"; if (p == "bugreport") return "Bug report"
      if (p == "thermal") return "Thermal"; if (p == "system") return "System"; return p
    }
    BEGIN { n = split(sevs, sv, ",") }
    { if (page == "ALL" || $2 == page) { rows[NR] = $0; sevof[NR] = $1; total = NR } }
    END {
      printed = 0
      for (s = 1; s <= n; s++) for (r = 1; r <= total; r++) if ((r in rows) && sevof[r] == sv[s]) {
        if (!printed) {
          print "<table class=\"findings\"><thead><tr><th>Severity</th>" (page == "ALL" ? "<th>Page</th>" : "") "<th>Scope</th><th>Finding</th><th>Evidence</th></tr></thead><tbody>"
          printed = 1
        }
        split(rows[r], f, "\t")
        printf "<tr class=\"sev-%s\"><td><span class=\"badge b-%s\">%s</span></td>", f[1], f[1], label(f[1])
        if (page == "ALL") printf "<td><a href=\"#p-%s\">%s</a></td>", f[2], esc(pname(f[2]))
        printf "<td>%s</td><td>%s</td><td class=\"ev\">%s</td></tr>\n", esc(f[3]), esc(f[4]), esc(f[5])
      }
      if (printed) print "</tbody></table>"
      else print "<p class=\"muted\">No findings to show.</p>"
    }' "$FINDINGS"
}

count_sev() { awk -F'\t' -v p="$1" -v s="$2" '($2 == p || p == "ALL") && $1 == s { n++ } END { print n + 0 }' "$FINDINGS"; }

nav_item() { # id label
  local c w
  c="$(count_sev "$1" crit)"; w="$(count_sev "$1" warn)"
  printf '<a href="#p-%s" data-page="%s">%s' "$1" "$1" "$(esc "$2")"
  [ "$c" -gt 0 ] && printf ' <span class="badge b-crit">%s</span>' "$c"
  [ "$w" -gt 0 ] && printf ' <span class="badge b-warn">%s</span>' "$w"
  printf '</a>\n'
}

smi_global() { awk -F'\t' -v k="$1" '$1 == "global" && $2 == k { print $3; exit }' "$PARSED/smi.tsv" 2>/dev/null; }

build_report() {
  local out="$RUN_DIR/report.html"
  local nc nw ni nok
  nc="$(count_sev ALL crit)"; nw="$(count_sev ALL warn)"; ni="$(count_sev ALL info)"; nok="$(count_sev ALL ok)"
  local drv cuda att os_name kern up
  drv="$(smi_global 'Driver Version')"; cuda="$(smi_global 'CUDA Version')"; att="$(smi_global 'Attached GPUs')"
  os_name="$( ( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}" ) )"
  kern="$(uname -r)"; up="$(uptime 2>/dev/null | sed 's/^ *//')"

  {
cat <<'EOF'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Denvr GPU diagnostics report</title>
<style>
:root{--bg:#f6f7f9;--panel:#fff;--text:#1d2530;--muted:#5b6675;--line:#d9dee5;--accent:#1f5fbf;
--crit:#b3261e;--critbg:#fde7e5;--warn:#8a5a00;--warnbg:#fff1d6;--info:#1f5fbf;--infobg:#e4eefc;--ok:#1e6b34;--okbg:#e2f3e6;--code:#f0f2f5}
@media (prefers-color-scheme:dark){:root{--bg:#14171c;--panel:#1c2027;--text:#e6e9ee;--muted:#9aa5b4;--line:#2f3641;--accent:#7fb0ff;
--crit:#ff9a92;--critbg:#3b1d1b;--warn:#f2c46b;--warnbg:#38290d;--info:#8fbaff;--infobg:#1b2a44;--ok:#8fd9a2;--okbg:#17301f;--code:#12151a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
header{padding:14px 20px;border-bottom:1px solid var(--line);background:var(--panel)}
header h1{margin:0;font-size:18px}header .sub{color:var(--muted);font-size:12px}
.layout{display:flex;align-items:flex-start}
nav{position:sticky;top:0;width:240px;flex:0 0 240px;height:100vh;overflow:auto;padding:12px;border-right:1px solid var(--line);background:var(--panel)}
nav a{display:block;padding:8px 10px;margin-bottom:2px;border-radius:6px;color:var(--text);text-decoration:none}
nav a:hover{background:var(--code)}nav a.active{background:var(--infobg);color:var(--info);font-weight:600}
nav .grp{margin:12px 10px 4px;font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}
main{flex:1;min-width:0;padding:20px}
.page{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:18px 20px;margin-bottom:20px}
.page h2{margin:0 0 4px;font-size:18px}.page h3{margin:20px 0 8px;font-size:14px}
.muted{color:var(--muted)}.note{color:var(--muted);font-size:12px;margin:6px 0}
table{border-collapse:collapse;width:100%;margin:8px 0;font-size:13px}
th,td{border:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}
th{background:var(--code);font-weight:600}
table.kv th{width:200px}
td.ev{word-break:break-word;color:var(--muted)}
.badge{display:inline-block;padding:1px 7px;border-radius:10px;font-size:11px;font-weight:700;letter-spacing:.03em}
.b-crit{background:var(--critbg);color:var(--crit);border:1px solid var(--crit)}
.b-warn{background:var(--warnbg);color:var(--warn);border:1px solid var(--warn)}
.b-info{background:var(--infobg);color:var(--info);border:1px solid var(--info)}
.b-ok{background:var(--okbg);color:var(--ok);border:1px solid var(--ok)}
.cards{display:flex;gap:10px;flex-wrap:wrap;margin:10px 0}
.card{flex:1 1 120px;border:1px solid var(--line);border-radius:8px;padding:10px 12px}
.card .n{font-size:26px;font-weight:700}
details.raw{border:1px solid var(--line);border-radius:6px;margin:10px 0}
details.raw>summary{cursor:pointer;padding:8px 10px;font-weight:600;background:var(--code)}
details.raw pre{margin:0;padding:10px;overflow:auto;max-height:560px;font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:var(--code);white-space:pre}
code{background:var(--code);padding:1px 4px;border-radius:3px}
.toolbar{margin:8px 0}.toolbar button{font:inherit;padding:4px 10px;border:1px solid var(--line);background:var(--panel);color:var(--text);border-radius:6px;cursor:pointer}
.js .page{display:none}.js .page.active{display:block}
@media (max-width:760px){.layout{display:block}nav{position:static;width:auto;height:auto;border-right:0;border-bottom:1px solid var(--line)}}
@media print{nav,.toolbar{display:none}.js .page{display:block}.layout{display:block}details.raw pre{max-height:none}}
</style></head><body>
EOF
printf '<header><h1>Denvr GPU diagnostics report</h1><div class="sub">%s &middot; collected %s &middot; denvr-bug-report %s &middot; generated offline</div></header>\n' "$(esc "$HOST")" "$(esc "$RUN_START_HUMAN")" "$VERSION"
echo '<div class="layout"><nav>'
echo '<div class="grp">Summary</div>'
nav_item overview "Overview"
nav_item system "System"
echo '<div class="grp">Collected output</div>'
nav_item smi "nvidia-smi -q"
nav_item dmesg "dmesg -T"
nav_item bugreport "nvidia-bug-report"
if [ "$DO_THERMAL" -eq 1 ] || [ -n "$THERMAL_CSV_IN" ]; then nav_item thermal "Thermal test"; fi
echo '<div class="grp">Run</div>'
nav_item runlog "Run log & files"
echo '</nav><main>'

# ---- Overview
echo '<section class="page" id="p-overview"><h2>Overview</h2>'
echo '<p class="muted">Findings are indicators from simple pattern checks on the collected output. They are not a diagnosis; please confirm against NVIDIA/OEM documentation.</p>'
printf '<div class="cards"><div class="card"><div class="n">%s</div><span class="badge b-crit">CRITICAL</span></div><div class="card"><div class="n">%s</div><span class="badge b-warn">WARN</span></div><div class="card"><div class="n">%s</div><span class="badge b-info">INFO</span></div><div class="card"><div class="n">%s</div><span class="badge b-ok">OK</span></div></div>\n' "$nc" "$nw" "$ni" "$nok"
echo '<h3>Critical and warning findings</h3>'
if [ "$((nc + nw))" -eq 0 ]; then echo '<p>No critical or warning findings were raised by the automated checks.</p>'; else render_findings ALL crit,warn; fi
echo '<h3>Node</h3><table class="kv"><tbody>'
printf '<tr><th>Hostname</th><td>%s</td></tr>\n' "$(esc "$HOST")"
printf '<tr><th>OS / kernel</th><td>%s / %s</td></tr>\n' "$(esc "${os_name:-unknown}")" "$(esc "$kern")"
printf '<tr><th>NVIDIA driver / CUDA</th><td>%s / %s</td></tr>\n' "$(esc "${drv:-n/a}")" "$(esc "${cuda:-n/a}")"
printf '<tr><th>GPUs attached</th><td>%s</td></tr>\n' "$(esc "${att:-n/a}")"
printf '<tr><th>Uptime</th><td>%s</td></tr>\n' "$(esc "${up:-n/a}")"
echo '</tbody></table></section>'

# ---- System
echo '<section class="page" id="p-system"><h2>System</h2>'
render_findings system crit,warn,info,ok
echo '<h3>GPUs (nvidia-smi -L)</h3>'
embed_raw "nvidia-smi -L" "$RAW/nvidia-smi-L.txt" head
echo '<h3>Raw output</h3>'
embed_raw "System information" "$RAW/system.txt" head
echo '</section>'

# ---- nvidia-smi -q
echo '<section class="page" id="p-smi"><h2>nvidia-smi -q</h2>'
echo '<p class="muted">Error counters, row remapping, ECC, temperatures, throttle reasons and link state per GPU.</p>'
echo '<h3>Findings</h3>'
render_findings smi crit,warn,info,ok
echo '<h3>Per-GPU summary</h3>'
smi_summary_html
echo '<h3>Raw output</h3>'
embed_raw "nvidia-smi -q (full output)" "$RAW/nvidia-smi-q.txt" head
echo '</section>'

# ---- dmesg
echo '<section class="page" id="p-dmesg"><h2>dmesg -T</h2>'
echo '<p class="muted">Kernel log scanned for NVIDIA Xid, NVLink/NVSwitch, PCIe AER, machine-check, EDAC, thermal, lockup, OOM and storage messages.</p>'
echo '<h3>Findings</h3>'
render_findings dmesg crit,warn,info,ok
echo '<h3>Raw output</h3>'
embed_raw "dmesg -T (newest part if truncated)" "$RAW/dmesg-T.txt" tail
echo '</section>'

# ---- bug report
echo '<section class="page" id="p-bugreport"><h2>nvidia-bug-report</h2>'
echo '<p class="muted">The full bug report is large and binary-compressed, so it is not embedded. It is included in the archive for NVIDIA/OEM review; only the first lines are previewed here.</p>'
echo '<h3>Findings</h3>'
render_findings bugreport crit,warn,info,ok
echo '<h3>Raw output</h3>'
if [ -n "$BUGREPORT_FILE" ] && [ -s "$BUGREPORT_FILE" ]; then
  printf '<p>File: <code>%s</code></p>\n' "$(esc "${BUGREPORT_FILE#"$RUN_DIR"/}")"
fi
embed_raw "Bug report preview (first 400 lines)" "$PARSED/bugreport-head.txt" head
embed_raw "nvidia-bug-report.sh console output" "$RAW/nvidia-bug-report.stdout" head
echo '</section>'

# ---- thermal
if [ "$DO_THERMAL" -eq 1 ] || [ -n "$THERMAL_CSV_IN" ]; then
  echo '<section class="page" id="p-thermal"><h2>Thermal test</h2>'
  echo '<p class="muted">Summary of the OEM thermal test CSV. Thresholds here are simple defaults; the OEM makes the pass/fail decision.</p>'
  echo '<h3>Findings</h3>'
  render_findings thermal crit,warn,info,ok
  echo '<h3>Per-GPU summary</h3>'
  thermal_summary_html
  echo '<h3>Raw output</h3>'
  embed_raw "Thermal CSV" "$THERMAL_CSV" head
  embed_raw "Thermal script console output" "$RAW/thermal/thermal-run.log" head
  echo '</section>'
fi

# ---- run log
echo '<section class="page" id="p-runlog"><h2>Run log &amp; files</h2>'
echo '<h3>Steps</h3><table class="data"><thead><tr><th>Step</th><th>Command</th><th>Status</th><th>Exit</th><th>Seconds</th><th>Output bytes</th><th>Note</th></tr></thead><tbody>'
awk -F'\t' '
  function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
  { cls = ($3 == "ok") ? "ok" : ($3 == "skipped") ? "info" : "crit"
    printf "<tr><td>%s</td><td><code>%s</code></td><td><span class=\"badge b-%s\">%s</span></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", esc($1), esc($2), cls, toupper($3), esc($4), esc($5), esc($6), esc($7) }' "$MANIFEST"
echo '</tbody></table>'
echo '<h3>Files collected</h3><table class="data"><thead><tr><th>File</th><th>Bytes</th></tr></thead><tbody>'
( cd "$RUN_DIR" && find raw -type f 2>/dev/null | sort | while IFS= read -r p; do
    printf '<tr><td><code>%s</code></td><td>%s</td></tr>\n' "$(esc "$p")" "$(wc -c < "$p" | tr -d ' ')"
  done )
echo '</tbody></table>'
echo '<p class="note">Tip: send the whole .tar.gz to Denvr Support, not just this HTML file; the raw files are needed for deeper analysis.</p>'
echo '</section>'

echo '</main></div>'
cat <<'EOF'
<script>
(function(){
  document.documentElement.className+=' js';
  var pages=[].slice.call(document.querySelectorAll('.page'));
  var links=[].slice.call(document.querySelectorAll('nav a'));
  function show(id){
    var found=false;
    pages.forEach(function(p){var on=(p.id==='p-'+id);p.classList.toggle('active',on);if(on)found=true;});
    if(!found){id='overview';document.getElementById('p-overview').classList.add('active');}
    links.forEach(function(a){a.classList.toggle('active',a.getAttribute('data-page')===id);});
    window.scrollTo(0,0);
  }
  function route(){var h=(location.hash||'').replace(/^#p-/,'');show(h||'overview');}
  window.addEventListener('hashchange',route);route();
  var tools=document.createElement('div');tools.className='toolbar';
  tools.innerHTML='<button id="exp">Expand all raw output</button> <button id="col">Collapse all</button>';
  document.querySelector('main').insertBefore(tools,document.querySelector('main').firstChild);
  document.getElementById('exp').onclick=function(){[].forEach.call(document.querySelectorAll('details.raw'),function(d){d.open=true;});};
  document.getElementById('col').onclick=function(){[].forEach.call(document.querySelectorAll('details.raw'),function(d){d.open=false;});};
})();
</script></body></html>
EOF
  } > "$out"
  log "Report written: $out"
}

# -------------------------------------------------------------------- main ---
if [ "$SKIP_BUGREPORT" -eq 0 ] && [ "$BUGREPORT_TIMEOUT_SET" -eq 0 ]; then
  prompt_timeout_minutes "nvidia-bug-report.sh" "$BUGREPORT_TIMEOUT" BUGREPORT_TIMEOUT "--bugreport-timeout"
fi
if [ "$DO_THERMAL" -eq 1 ] && [ "$THERMAL_TIMEOUT_SET" -eq 0 ]; then
  prompt_timeout_minutes "Thermal test" "$THERMAL_TIMEOUT" THERMAL_TIMEOUT "--thermal-timeout"
fi

collect_system
collect_smi
collect_dmesg
collect_thermal
collect_bugreport   # last: slowest step; everything above is already saved

log "Analysing collected output"
analyze_system
analyze_smi
analyze_dmesg
analyze_bugreport
analyze_thermal

build_report

ARCHIVE=""
if [ "$NO_ARCHIVE" -eq 0 ]; then
  ARCHIVE="$OUT_BASE/$RUN_NAME.tar.gz"
  if tar -czf "$ARCHIVE" -C "$OUT_BASE" "$RUN_NAME" 2>/dev/null; then
    log "Archive written: $ARCHIVE"
  else
    warn "Could not create the archive; send the folder $RUN_DIR instead."
    ARCHIVE=""
  fi
fi

NC="$(count_sev ALL crit)"; NW="$(count_sev ALL warn)"
echo
echo "================ Summary ================"
printf 'Critical: %s   Warnings: %s\n' "$NC" "$NW"
echo "Report:   $RUN_DIR/report.html   (open in a browser)"
[ -n "$ARCHIVE" ] && echo "Archive:  $ARCHIVE"
if [ -n "$ARCHIVE" ] && have sha256sum; then
  echo "SHA-256:  $(sha256sum "$ARCHIVE" | awk '{print $1}')"
fi
echo "Next:     attach the .tar.gz to your Denvr support ticket."
echo "========================================="

exit 0
