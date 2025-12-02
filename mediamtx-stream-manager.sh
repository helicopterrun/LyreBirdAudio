#!/bin/bash
# mediamtx-stream-manager.sh - 9 streams per device: stereo raw, mono raw, filtered, bird, frigate
# Version: 2.3.0 - Added stereo raw stream and dual Frigate streams (left + right)

set -euo pipefail

readonly VERSION="2.3.0"
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
readonly DEFAULT_CHANNELS="2"
readonly DEFAULT_CODEC="libopus"
readonly DEFAULT_MONO_BITRATE="64k"

# General purpose filtering: optimized for human monitoring
# 2x 600Hz HPF (24dB/oct removes rumble), 2x 9kHz LPF (24dB/oct tames hiss, preserves bird detail)
# Gentle 2:1 compression for even dynamics
# Filter order: HPF → LPF → Compression → Resampling
# Change from v2.0.0: LPF lowered from 12kHz to 9kHz to reduce high-frequency hiss
readonly DEFAULT_FILTERS="highpass=f=600,highpass=f=600,lowpass=f=9000,lowpass=f=9000,acompressor=threshold=-20dB:ratio=2:attack=10:release=100,aresample=async=1:first_pts=0"

# Bird detection optimized: maximum urban noise rejection with reduced hiss
# Quadruple-stacked 4kHz HPF for 48dB/octave slope - urban noise crushed to <1%
# +30dB gain provides strong signal with good headroom
# Early compression at -10dB (6:1 ratio) for dynamic range control
# 2x 11kHz LPF (24dB/oct) removes hiss above useful bird range while preserving harmonics
# -4dB limiter ceiling provides reliable clipping protection (1dB safety margin)
# Compressor: faster attack (3ms) catches transient bird calls, longer release (100ms) prevents pumping
# Change from v2.0.0: Added 2x 11kHz LPF to reduce top-end hiss per spectral analysis
readonly BIRD_FILTERS="highpass=f=4000,highpass=f=4000,highpass=f=4000,highpass=f=4000,volume=30dB,lowpass=f=11000,lowpass=f=11000,acompressor=threshold=-10dB:ratio=6:attack=3:release=100,alimiter=limit=-4dB:attack=1:release=100"

# Frigate/YamNet optimized: 16kHz mono AAC for ML audio detection
# YamNet operates on 16kHz audio with 125-7500 Hz mel spectrogram
# Filter chain designed for robust event detection in urban environment:
# 1. Resample to 16kHz and force mono (YamNet native format)
# 2. 100Hz HPF removes rumble (traffic, HVAC, wind) below event range
# 3. 8kHz LPF removes noise above Nyquist/2 for 16kHz (anti-alias)
# 4. Compand provides multi-band compression:
#    - Brings up quiet distant sounds (-60dB → -50dB)
#    - Compresses mid-range (-40dB → -30dB, -20dB → -15dB)
#    - Soft limiting at top (0dB → -5dB)
#    - Fast attack (5ms) preserves transients, moderate release (100ms) natural
#    - +3dB makeup gain compensates for compression loss
# 5. Loudnorm applies EBU R128 normalization to -16 LUFS (YamNet optimal level)
#    - True peak limited to -2dB prevents inter-sample clipping
#    - LRA 7 allows some dynamics while ensuring consistency
#    - Linear mode preserves transient character for bird calls
# Target: Consistent -16 LUFS with preserved transients and minimal false positives
readonly FRIGATE_FILTERS="aformat=sample_rates=16000:channel_layouts=mono,highpass=f=100:poles=2:width_type=h:width=50,lowpass=f=8000:poles=2:width_type=h:width=1000,compand=attacks=0.005:decays=0.1:soft-knee=6:points=-80/-80|-60/-50|-40/-30|-20/-15|0/-5:gain=3,loudnorm=I=-16:TP=-2:LRA=7:linear=true:print_format=none,aresample=16000"

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
apiAddress: :9997
metrics: yes
metricsAddress: :9998
rtsp: yes
rtspAddress: :8554
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

  log INFO "Starting 9-stream set for: $stream_name (card $card_num)"
  local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
  local log_file="${FFMPEG_PID_DIR}/${stream_name}.log"
  mkdir -p "${FFMPEG_PID_DIR}"

  cat > "$wrapper" << EOF
#!/bin/bash
while true; do
  ffmpeg -hide_banner -loglevel warning \
    -thread_queue_size 512 \
    -f alsa -ar ${DEFAULT_SAMPLE_RATE} -ac ${DEFAULT_CHANNELS} -i plughw:${card_num},0 \
    -filter_complex "\
[0:a]asplit=2[stereo_raw][split_lr]; \
[split_lr]asplit=2[aL][aR]; \
[aL]pan=mono|c0=FL[Lu]; \
[aR]pan=mono|c0=FR[Ru]; \
[Lu]asplit=2[Lu_raw][Lu_f]; \
[Ru]asplit=2[Ru_raw][Ru_f]; \
[Lu_f]${DEFAULT_FILTERS}[Lu_filt_out]; \
[Ru_f]${DEFAULT_FILTERS}[Ru_filt_out]; \
[Lu_filt_out]asplit=2[Lu_filt][Lu_bird_pre]; \
[Ru_filt_out]asplit=2[Ru_filt][Ru_bird_pre]; \
[Lu_bird_pre]${BIRD_FILTERS}[Lu_bird]; \
[Ru_bird_pre]${BIRD_FILTERS}[Ru_bird]; \
[Lu_filt_out]${FRIGATE_FILTERS}[Lu_frigate]; \
[Ru_filt_out]${FRIGATE_FILTERS}[Ru_frigate]" \
    -map "[stereo_raw]" -ac 2 -c:a ${DEFAULT_CODEC} -b:a 128k -application audio -vbr on \
      -f rtsp -rtsp_transport tcp rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_raw_stereo \
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
    -map "[Lu_frigate]" -ac 1 -c:a aac -b:a 64k -ar 16000 \
      -f rtsp -rtsp_transport tcp rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left_frigate \
    -map "[Ru_frigate]" -ac 1 -c:a aac -b:a 64k -ar 16000 \
      -f rtsp -rtsp_transport tcp rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right_frigate \
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

  echo; echo -e "${GREEN}=== Available RTSP Streams (9 per device) ===${NC}"
  for dev in "${devices[@]}"; do
    IFS=':' read -r device_name card_num <<< "$dev"
    local stream_name; stream_name="$(generate_stream_name "$device_name")"
    echo -e "${GREEN}✔${NC} ${stream_name}:"
    echo "   ${CYAN}Raw (unprocessed):${NC}"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_raw_stereo    [STEREO - archival]"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left_raw      [MONO L]"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right_raw     [MONO R]"
    echo "   ${CYAN}Filtered (general monitoring):${NC}"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left_filt"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right_filt"
    echo "   ${CYAN}Bird (detection optimized):${NC}"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left_bird"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right_bird"
    echo "   ${CYAN}Frigate (YamNet ML detection):${NC}"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left_frigate  [16kHz AAC]"
    echo "     rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right_frigate [16kHz AAC]"
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
      echo "    Stream set: ${stream_name} (9 streams total)"
      echo "      Raw:      _raw_stereo (48kHz stereo archival)"
      echo "                _left_raw, _right_raw (48kHz mono)"
      echo "      Filtered: _left_filt, _right_filt (2x 600Hz HPF, 2x 9kHz LPF, 2:1 comp)"
      echo "      Bird:     _left_bird, _right_bird (4x 4kHz HPF + 30dB + 2x 11kHz LPF + 6:1 comp + limiter)"
      echo "      Frigate:  _left_frigate, _right_frigate (16kHz AAC, 100Hz HPF + 8kHz LPF + compand + loudnorm -16 LUFS)"
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
  echo "Filter Pipeline Details (v2.3.0 - Stereo Raw + Dual Frigate):"
  echo "  Monitoring: 2x 600Hz HPF (24dB/oct) → 2x 9kHz LPF (24dB/oct) → 2:1 compression"
  echo "  Bird:       4x 4000Hz HPF (48dB/oct) → +30dB gain → 2x 11kHz LPF (24dB/oct) → 6:1 compression → -4dB limiter"
  echo "              (Compressor: -10dB threshold, 3ms attack, 100ms release)"
  echo "              (Limiter: -4dB ceiling, 1dB safety margin for clipping protection)"
  echo "  Frigate:    16kHz resample → 100Hz HPF → 8kHz LPF → compand (multi-band) → loudnorm -16 LUFS → AAC 64kbps"
  echo "              (Optimized for YamNet: preserves transients, consistent levels, minimal false positives)"
  echo
  echo "Stream Architecture (9 per device):"
  echo "  • 1x Stereo raw:     Full spatial information for archival/analysis"
  echo "  • 2x Mono raw:       Individual channel archival"
  echo "  • 2x Filtered:       Human monitoring (left/right)"
  echo "  • 2x Bird-optimized: BirdNET detection (left/right)"
  echo "  • 2x Frigate:        YamNet ML detection (left/right)"
  echo
  echo "Expected Performance by Stream:"
  echo "  Bird:       Peak -4dB to -6dB, RMS -22dB to -26dB, Energy 75-85% in 3-8kHz, 0% clipping"
  echo "  Frigate:    Integrated -16 LUFS, True Peak -2dB, LRA 7, optimized for ML event detection"
  echo
  echo "Changes from v2.2.0:"
  echo "  • Added stereo raw stream for archival with spatial information intact"
  echo "  • Added left_frigate stream (in addition to right_frigate)"
  echo "  • Now supports future dual-mic configurations for beamforming/comparison"
  echo "  • Total: 9 streams per device (up from 7)"
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
