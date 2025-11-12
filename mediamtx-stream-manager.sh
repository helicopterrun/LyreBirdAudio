#!/bin/bash
# mediamtx-stream-manager.sh - 6 streams per device: raw, filtered, bird-optimized
# Version: 1.9.0 - Optimized bird detection filters with improved gain staging

set -euo pipefail

readonly VERSION="1.9.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# ========= Paths =========
readonly CONFIG_DIR="/etc/mediamtx"
readonly CONFIG_FILE="${CONFIG_DIR}/mediamtx.yml"
readonly PID_FILE="/var/run/mediamtx-audio.pid"
readonly FFMPEG_PID_DIR="/var/lib/mediamtx-ffmpeg"
readonly LOCK_FILE="/var/run/mediamtx-audio.lock"
readonly LOG_FILE="/var/log/mediamtx-stream-manager.log"
readonly MEDIAMTX_LOG_FILE="/var/log/mediamtx.out"
readonly MEDIAMTX_BIN="/usr/local/bin/mediamtx"
readonly MEDIAMTX_HOST="localhost"

# ========= Settings =========
readonly DEFAULT_SAMPLE_RATE="48000"
readonly DEFAULT_CHANNELS="2"            # capture stereo → split to mono
readonly DEFAULT_CODEC="libopus"         # use libopus (stable), not native 'opus'
readonly DEFAULT_MONO_BITRATE="64k"

# General purpose filtering: optimized for human monitoring
# Natural frequency response with moderate noise reduction
# 0dB volume (no reduction needed), 2x 600Hz HPF (24dB/oct removes rumble)
# 2x 12kHz LPF (24dB/oct preserves natural highs), gentle 2:1 compression
readonly DEFAULT_FILTERS="volume=0dB,highpass=f=600,highpass=f=600,lowpass=f=12000,lowpass=f=12000,acompressor=threshold=-20dB:ratio=2:attack=10:release=100,aresample=async=1:first_pts=0"

# Bird detection optimized: aggressive urban noise rejection with safe gain staging
# Quadruple-stacked 4kHz HPF for 48dB/octave slope - maximum low-freq rejection
# Optimized +30dB gain for strong signal with headroom
# Early compression at -10dB threshold (6:1 ratio) for dynamic range control
# Strict -4dB limiter ceiling to guarantee zero clipping
readonly BIRD_FILTERS="highpass=f=4000,highpass=f=4000,highpass=f=4000,highpass=f=4000,volume=30dB,acompressor=threshold=-10dB:ratio=6:attack=3:release=100,alimiter=limit=-4dB:attack=1:release=100"

# ========= Globals =========
declare -gi MAIN_LOCK_FD=-1
declare -g STOPPING_SERVICE=false

# ========= Colors =========
if [[ -t 2 ]]; then
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"; NC="$(tput sgr0)"
else
  RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC=""
fi

command_exists() { command -v "$1" &>/dev/null; }

log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
  case "${level}" in
    ERROR) echo -e "${RED}[ERROR]${NC} ${msg}" >&2 ;;
    WARN)  echo -e "${YELLOW}[WARN]${NC} ${msg}" >&2 ;;
    INFO)  echo -e "${GREEN}[INFO]${NC} ${msg}" ;;
    DEBUG) [[ "${DEBUG:-}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${msg}" >&2 ;;
  esac
}

error_exit() { log ERROR "$1"; exit "${2:-1}"; }

acquire_lock() {
  local lock_dir; lock_dir="$(dirname "${LOCK_FILE}")"
  [[ -d "$lock_dir" ]] || mkdir -p "$lock_dir"
  exec {MAIN_LOCK_FD}>"${LOCK_FILE}" 2>/dev/null || return 1
  flock -w 30 "${MAIN_LOCK_FD}" || return 1
  echo "$$" >&"${MAIN_LOCK_FD}"
  log DEBUG "Lock acquired"
  return 0
}

release_lock() {
  [[ ${MAIN_LOCK_FD} -gt 2 ]] && exec {MAIN_LOCK_FD}>&- 2>/dev/null
  MAIN_LOCK_FD=-1
}

cleanup_stale_processes() {
  log INFO "Cleaning up stale processes"
  pkill -9 -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true
  pkill -9 -f "${FFMPEG_PID_DIR}/.*\.sh" 2>/dev/null || true
  pkill -9 -f "^${MEDIAMTX_BIN}" 2>/dev/null || true
  rm -f "${PID_FILE}" "${FFMPEG_PID_DIR}"/*.pid "${FFMPEG_PID_DIR}"/*.sh "${FFMPEG_PID_DIR}"/*.log
  log INFO "Cleanup completed"
}

detect_audio_devices() {
  local output; output=$(arecord -l 2>/dev/null) || return 1
  local -a devices
  while IFS= read -r line; do
    if [[ "$line" =~ card\ ([0-9]+):\ ([^,]+) ]]; then
      local card_num="${BASH_REMATCH[1]}"; local card_name="${BASH_REMATCH[2]}"
      [[ -f "/proc/asound/card${card_num}/usbid" ]] && devices+=("${card_name}:${card_num}")
    fi
  done <<< "$output"
  [[ ${#devices[@]} -gt 0 ]] || return 1
  printf '%s\n' "${devices[@]}"
}

generate_stream_name() {
  local name="$1"
  if [[ "$name" =~ AI.*Micro|AI-Micro ]]; then
    echo "rode_ai_micro"
  elif [[ "$name" =~ [Bb]lue.*[Yy]eti ]]; then
    echo "blue_yeti"
  else
    echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//' | cut -c1-32
  fi
}

wait_for_mediamtx_ready() {
  local pid="$1"
  log INFO "Waiting for MediaMTX API..."
  for _ in {1..30}; do
    kill -0 "$pid" 2>/dev/null || { log ERROR "MediaMTX died"; return 1; }
    if command_exists curl && curl -s --max-time 2 "http://${MEDIAMTX_HOST}:9997/v3/paths/list" >/dev/null 2>&1; then
      log INFO "MediaMTX API ready"; return 0
    fi
    sleep 1
  done
  log ERROR "MediaMTX API timeout"; return 1
}

generate_mediamtx_config() {
  mkdir -p "${CONFIG_DIR}"
  cat > "${CONFIG_FILE}" << 'EOF'
logLevel: info
api: yes
apiAddress: :9997            # bind all interfaces
metrics: yes
metricsAddress: :9998
rtsp: yes
rtspAddress: :8554           # bind all interfaces
rtspTransports: [tcp, udp]
paths:
  '~^[a-zA-Z0-9_-]+$':
    source: publisher
    sourceOnDemand: no
EOF
  chmod 644 "${CONFIG_FILE}"
}

start_ffmpeg_stream() {
  local device_name="$1"; local card_num="$2"; local stream_name="$3"

  log INFO "Starting 6-stream set for: $stream_name (card $card_num)"
  local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
  local log_file="${FFMPEG_PID_DIR}/${stream_name}.log"
  mkdir -p "${FFMPEG_PID_DIR}"

  # Filter graph creates 6 outputs per device:
  # 1. Raw L/R - unprocessed mono channels (archival/troubleshooting)
  # 2. Filtered
