#!/bin/bash
# mediamtx-stream-manager.sh - 6 streams per device: raw, filtered, bird-optimized
# Version: 1.8.2 - Cascaded filters for steep slopes, fixed limiter

set -euo pipefail

readonly VERSION="1.8.2"
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

# General purpose filtering: gentle processing for normal listening
# Simple cascaded filters for maximum compatibility
readonly DEFAULT_FILTERS="volume=-3dB,highpass=f=800,highpass=f=800,lowpass=f=10000,lowpass=f=10000,aresample=async=1:first_pts=0"

# Bird detection optimized: 24dB/octave 3kHz HPF + 38dB gain + compression + limiting
# Double-stacked 3kHz HPF for 24dB/octave slope (2x12dB/octave)
# Limiter at -2dB to prevent clipping
readonly BIRD_FILTERS="highpass=f=3000,highpass=f=3000,volume=38dB,acompressor=threshold=-8dB:ratio=4:attack=5:release=50,alimiter=limit=-2dB:attack=2:release=50"

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
  # 1. Raw L/R - unprocessed mono channels
  # 2. Filtered L/R - general purpose (-3dB, 800Hz HPF, 10kHz LPF)
  # 3. Bird L/R - filtered + additional 3kHz HPF + 40dB gain
  cat > "$wrapper" << EOF
#!/bin/bash
while true; do
  ffmpeg -hide_banner -loglevel warning \
    -thread_queue_size 512 \
    -f alsa -ar ${DEFAULT_SAMPLE_RATE} -ac ${DEFAULT_CHANNELS} -i plughw:${card_num},0 \
    -filter_complex "\
[0:a]asplit=2[aL][aR]; \
[aL]pan=mono|c0=FL[Lu]; \
[aR]pan=mono|c0=FR[Ru]; \
[Lu]asplit=2[Lu_raw][Lu_f]; \
[Ru]asplit=2[Ru_raw][Ru_f]; \
[Lu_f]${DEFAULT_FILTERS}[Lu_filt_out]; \
[Ru_f]${DEFAULT_FILTERS}[Ru_filt_out]; \
[Lu_filt_out]asplit=2[Lu_filt][Lu_bird_pre]; \
[Ru_filt_out]asplit=2[Ru_filt][Ru_bird_pre]; \
[Lu_bird_pre]${BIRD_FILTERS}[Lu_bird]; \
[Ru_bird_pre]${BIRD_FILTERS}[Ru_bird]" \
    -map "[Lu_raw]" -ac 1 -c:a ${DEFAULT_CODEC} -b:a ${DEFAULT_MONO_BITRATE} -application audio -vbr on \
      -f rtsp -rtsp_transport tcp rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left_raw \
    -map "[Ru_raw]" -ac 1 -c:a ${DEFAULT_CODEC} -b:a ${DEFAULT_MONO_BITRATE} -application audio -vbr on \
      -f rtsp -rtsp_transport tcp rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right_raw \
    -map "[Lu_filt]" -ac 1 -c:a ${DEFAULT_CODEC} -b:a ${DEFAULT_MONO_BITRATE} -application audio -vbr on \
      -f rtsp -rtsp_transport tcp rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left_filt \
    -map "[Ru_filt]" -ac 1 -c:a ${DEFAULT_CODEC} -b:a ${DEFAULT_MONO_BITRATE} -application audio -vbr on \
      -f rtsp -rtsp_transport tcp rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right_filt \
    -map "[Lu_bird]" -ac 1 -c:a ${DEFAULT_CODEC} -b:a ${DEFAULT_MONO_BITRATE} -application audio -vbr on \
      -f rtsp -rtsp_transport tcp rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left_bird \
    -map "[Ru_bird]" -ac 1 -c:a ${DEFAULT_CODEC} -b:a ${DEFAULT_MONO_BITRATE} -application audio -vbr on \
      -f rtsp -rtsp_transport tcp rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right_bird \
    >> ${log_file} 2>&1

  echo "[\$(date)] FFmpeg exited, restarting in 5s" >> ${log_file}
  sleep 5
done
EOF

  chmod +x "$wrapper"
  nohup bash "$wrapper" >/dev/null 2>&1 &
  echo $! > "${FFMPEG_PID_DIR}/${stream_name}.pid"
  log INFO "Stream started: $stream_name (PID: $!)"
}

start_mediamtx() {
  acquire_lock || error_exit "Failed to acquire lock"
  cleanup_stale_processes

  log INFO "Starting MediaMTX..."
  local -a devices; mapfile -t devices < <(detect_audio_devices)
  [[ ${#devices[@]} -gt 0 ]] || error_exit "No USB audio devices found"
  log INFO "Found ${#devices[@]} USB audio device(s)"

  generate_mediamtx_config
  nohup "${MEDIAMTX_BIN}" "${CONFIG_FILE}" >> "${MEDIAMTX_LOG_FILE}" 2>&1 &
  local pid=$!; echo "$pid" > "${PID_FILE}"
  sleep 1
  kill -0 "$pid" 2>/dev/null || error_exit "MediaMTX failed to start"
  wait_for_mediamtx_ready "$pid" || error_exit "MediaMTX not ready"
  log INFO "MediaMTX started (PID: $pid)"

  for dev in "${devices[@]}"; do
    IFS=':' read -r device_name card_num <<< "$dev"
    local stream_name; stream_name="$(generate_stream_name "$device_name")"
    start_ffmpeg_stream "$device_name" "$card_num" "$stream_name"
  done

  echo; echo -e "${GREEN}=== Available RTSP Streams (6 per device) ===${NC}"
  for dev in "${devices[@]}"; do
    IFS=':' read -r device_name card_num <<< "$dev"
    local stream_name; stream_name="$(generate_stream_name "$device_name")"
    echo -e "${GREEN}✔${NC} ${stream_name}:"
    echo "   ${CYAN}Raw (unprocessed):${NC}"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left_raw"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right_raw"
    echo "   ${CYAN}Filtered (general purpose):${NC}"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left_filt"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right_filt"
    echo "   ${CYAN}Bird (optimized + compressed):${NC}"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left_bird"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right_bird"
    echo
  done
  release_lock
}

stop_mediamtx() {
  STOPPING_SERVICE=true
  log INFO "Stopping MediaMTX..."
  cleanup_stale_processes
  log INFO "MediaMTX stopped"
  STOPPING_SERVICE=false
  release_lock
}

show_status() {
  echo -e "${CYAN}=== MediaMTX Audio Stream Status ===${NC}"
  echo
  if [[ -f "${PID_FILE}" ]]; then
    local pid; pid=$(cat "${PID_FILE}")
    if kill -0 "$pid" 2>/dev/null; then
      echo -e "MediaMTX: ${GREEN}Running${NC} (PID: $pid)"
    else
      echo -e "MediaMTX: ${RED}Not running${NC}"
    fi
  else
    echo -e "MediaMTX: ${RED}Not running${NC}"
  fi
  echo
  echo "USB Audio Devices:"
  local -a devices; mapfile -t devices < <(detect_audio_devices 2>/dev/null || true)
  if [[ ${#devices[@]} -eq 0 ]]; then
    echo "  No devices found"
  else
    for dev in "${devices[@]}"; do
      IFS=':' read -r device_name card_num <<< "$dev"
      local stream_name; stream_name="$(generate_stream_name "$device_name")"
      echo "  - $device_name (card $card_num)"
      echo "    Stream set: ${stream_name}"
      echo "      Raw:      _left_raw, _right_raw (unprocessed)"
      echo "      Filtered: _left_filt, _right_filt (-3dB, 800Hz HPF, 10kHz LPF)"
      echo "      Bird:     _left_bird, _right_bird (filtered + 3kHz HPF + 38dB + compression)"
      if [[ -f "${FFMPEG_PID_DIR}/${stream_name}.pid" ]]; then
        local fpid; fpid=$(cat "${FFMPEG_PID_DIR}/${stream_name}.pid")
        if kill -0 "$fpid" 2>/dev/null; then
          echo -e "    Status: ${GREEN}Running${NC} (PID: $fpid)"
        else
          echo -e "    Status: ${RED}Not running${NC}"
        fi
      else
        echo -e "    Status: ${RED}Not running${NC}"
      fi
      echo
    done
  fi
  echo "Filter Pipeline:"
  echo "  General: -3dB → 2x 800Hz HPF (24dB/oct) → 2x 10kHz LPF (24dB/oct)"
  echo "  Bird:    General → 2x 3000Hz HPF (24dB/oct) → +38dB → Compressor → Limiter"
  echo "           (Compressor: -8dB threshold, 4:1 ratio)"
  echo "           (Limiter: -2dB hard ceiling, prevents clipping)"
}

main() {
  case "${1:-help}" in
    start)
      [[ $EUID -eq 0 ]] || error_exit "Must run as root"
      mkdir -p "$(dirname "${LOG_FILE}")"
      start_mediamtx
      ;;
    stop)
      [[ $EUID -eq 0 ]] || error_exit "Must run as root"
      stop_mediamtx
      ;;
    restart)
      [[ $EUID -eq 0 ]] || error_exit "Must run as root"
      stop_mediamtx
      sleep 2
      start_mediamtx
      ;;
    status)
      show_status
      ;;
    *)
      echo "Usage: $SCRIPT_NAME {start|stop|restart|status}"
      exit 1
      ;;
  esac
}

main "$@"
