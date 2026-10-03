#!/bin/bash

# ============================================================
# Master Thermal Test Script
# Supports: Hopper (H100 / H200) and Blackwell (B200)
# ============================================================

# ---- Common dependency checks (required by both platforms) ----

# GPU Driver Check
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi not found; NVIDIA driver may not be installed" >&2
  exit 1
fi

# ipmitool dependency check
if ! command -v ipmitool &>/dev/null; then
    echo "ipmitool is not installed on this system! Please install before running the thermal script."
    exit 1
fi

# ---- Prompt customer for platform selection ----
PLATFORM=""
while [[ -z "$PLATFORM" ]]; do
    echo ""
    echo "Select GPU platform to run the thermal test:"
    echo "  1) Hopper (H100 / H200)"
    echo "  2) Blackwell (B200)"
    read -rp "Enter choice [1-2]: " CHOICE

    case "$CHOICE" in
        1|[Hh]opper)
            PLATFORM="Hopper"
            ;;
        2|[Bb]lackwell)
            PLATFORM="Blackwell"
            ;;
        *)
            echo "[ERROR] Invalid selection. Please enter 1 (Hopper) or 2 (Blackwell)." >&2
            ;;
    esac
done

echo "Selected platform: $PLATFORM"

# ============================================================
# Hopper (H100 / H200) branch
# ============================================================
if [[ "$PLATFORM" == "Hopper" ]]; then

    # Hopper GPU Verification
    if nvidia-smi -L 2>/dev/null | grep -Eq "NVIDIA H100|NVIDIA H200"; then
        echo "Detected NVIDIA Hopper GPU(s) (H100/H200)"
    else
        echo "Required GPU (NVIDIA H100/H200) not found" >&2
        exit 1
    fi

    # dcgmproftester dependency check (supports either v12 or v13 binary)
    DCPROF=$(command -v dcgmproftester12 || command -v dcgmproftester13 || echo "")
    if [[ -z "$DCPROF" ]]; then
        echo "[ERROR] dcgmproftester not found in PATH." >&2
        exit 1
    fi
    echo "Using dcgmproftester binary: $DCPROF"

    # set duration in seconds
    DURATION=900
    CURRENT_DATE=$(date +"%Y-%m-%d.%Hh%Mm%Ss")
    LOGDIR=$(pwd)
    echo "Duration: $DURATION"
    echo "Current date: $CURRENT_DATE"
    echo "Log directory: $LOGDIR"
    target=1004

    WORKLOAD_CMD="$DCPROF --no-dcgm-validation --max-processes 0 -t $target -d $DURATION"

    # Create the log file name using the hostname and current date
    LOGFILE="thermal_results.$(hostname).${target}.${DURATION}.${CURRENT_DATE}.csv"
    LOGPATH="${LOGDIR}/${LOGFILE}"

    # Catch inlet temp and save the fix value
    temp_file=$(mktemp) # Create a temporary file
    sudo ipmitool sensor | grep -w 'Inlet Temp' | head -n1 | awk -F "|" '{print $2}' | tr -d ' ' > "$temp_file"
    inlet_temp=$(cat "$temp_file")

    # Runs the stress/diagnostic test on all GPUs (as background process)
    export RUN_INFO="$(hostname),$target,$DURATION"
    echo `date` starting ${RUN_INFO}

    $WORKLOAD_CMD &

    # Capture the process ID (PID) of the last command (workload)
    WORKLOAD_PID=$!
    # Collect data from multiple GPU sensors using the nvidia-smi tool (needed for tlimit) every 1
    #second (--loop=1)
    nvidia-smi --query-gpu=serial,name,timestamp,index,temperature.gpu,temperature.memory,temperature.gpu.tlimit,power.draw,clocks.current.sm,clocks_throttle_reasons.active,utilization.gpu --loop=1 --format=csv --filename=$LOGPATH &
    # Capture the process ID (PID) of the last command (telemetry)
    TELEMETRY_PID=$!

    wait $WORKLOAD_PID
    echo `date` Done workload ${WORKLOAD_PID}
    kill -s INT $TELEMETRY_PID
    # Give time for the telemetry process to exit and write its file
    wait $TELEMETRY_PID
    # Add information about the run to each row in the logfile
    awk '{print ENVIRON["RUN_INFO"]","$0}' $LOGPATH > ${LOGPATH}.tmp
    sed -i -e '/$/s/$/, '$inlet_temp', 100/' ${LOGPATH}.tmp
    # Fix header for the fields just added
    sed -i -e '1s/[^,]*,[0-9]*,[0-9]*,/hostname,dcgm target,duration [s],/' ${LOGPATH}.tmp
    sed -i '1s/'$inlet_temp', 100/bmc.inlet.temp, bmc.fan.pwm/' ${LOGPATH}.tmp

    mv ${LOGPATH}.tmp $LOGPATH

# ============================================================
# Blackwell (B200) branch
# ============================================================
elif [[ "$PLATFORM" == "Blackwell" ]]; then

    # Blackwell GPU Verification
    if nvidia-smi -L 2>/dev/null | grep -q "NVIDIA B200"; then
        echo "Detected NVIDIA B200 GPU(s)"
    else
        echo "Required GPU (NVIDIA B200) not found" >&2
        exit 1
    fi

    # set duration in seconds
    DURATION=1800
    CURRENT_DATE=$(date +"%Y-%m-%d.%Hh%Mm%Ss")
    LOGDIR=$(pwd)

    echo "Duration: $DURATION"
    echo "Current date: $CURRENT_DATE"
    echo "Log directory: $LOGDIR"

    profile="targeted_power"
    target="targeted_power.test_duration_${DURATION}"

    # Create the log file name using the hostname and current date
    LOGFILE="thermal_results.$(hostname).${profile}.${DURATION}.${CURRENT_DATE}.csv"
    LOGPATH="${LOGDIR}/${LOGFILE}"

    echo ${LOGFILE}

    # Catch inlet temp and save the fix value
    temp_file=$(mktemp) # Create a temporary file
    sudo ipmitool sensor | grep -w 'Inlet Temp' | head -n1 | awk -F "|" '{print $2}' | tr -d ' ' > "$temp_file"
    inlet_temp=$(cat "$temp_file")

    # Run the stress / diagnostic test on all GPUs (as background process)
    export RUN_INFO="$(hostname),$profile,$DURATION"
    echo `date` starting ${RUN_INFO}
    dcgmi diag -r ${profile} -p ${target} -i 0,1,2,3,4,5,6,7 &

    # Capture the process ID (PID) of the last command (workload)
    WORKLOAD_PID=$!

    # Collect data from multiple GPU sensors using the nvidia-smi tool (needed for tlimit) every 1 second (--loop=1)
    nvidia-smi --query-gpu=serial,name,timestamp,index,temperature.gpu,temperature.memory,temperature.gpu.tlimit,power.draw,clocks.current.sm,clocks_throttle_reasons.active,utilization.gpu --loop=1 --format=csv --filename=$LOGPATH &

    # Capture the process ID (PID) of the last command (telemetry)
    TELEMETRY_PID=$!

    wait $WORKLOAD_PID
    echo `date` Done workload ${WORKLOAD_PID}
    kill -s INT $TELEMETRY_PID

    # Give time for the telemetry process to exit and write its file
    wait $TELEMETRY_PID

    # Add information about the run to each row in the logfile
    awk '{print ENVIRON["RUN_INFO"]","$0}' $LOGPATH > ${LOGPATH}.tmp
    sed -i -e '/$/s/$/, '$inlet_temp', 100/' ${LOGPATH}.tmp

    # Fix header for the fields just added
    sed -i -e '1s/[^,]*,[0-9]*,[0-9]*,/hostname,dcgm target,duration [s],/' ${LOGPATH}.tmp
    sed -i '1s/'$inlet_temp', 100/bmc.inlet.temp, bmc.fan.pwm/' ${LOGPATH}.tmp

    mv ${LOGPATH}.tmp $LOGPATH

fi
