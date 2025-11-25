#!/bin/bash
# lyrebird-deploy.sh - Deploy latest LyreBirdAudio from GitHub
# Version: 1.0.0

set -euo pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# ========= Configuration =========
readonly GITHUB_REPO="https://github.com/helicopterrun/LyreBirdAudio.git"
readonly INSTALL_DIR="/opt/lyrebird"
readonly STREAM_MANAGER="${INSTALL_DIR}/mediamtx-stream-manager.sh"
readonly BACKUP_DIR="/opt/lyrebird-backups"
readonly LOG_FILE="/var/log/lyrebird-deploy.log"

# ========= Colors =========
if [[ -t 2 ]]; then
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"; BOLD="$(tput bold)"; NC="$(tput sgr0)"
else
  RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" NC=""
fi

# ========= Logging =========
log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
  case "${level}" in
    ERROR) echo -e "${RED}✗${NC} ${msg}" >&2 ;;
    WARN)  echo -e "${YELLOW}⚠${NC} ${msg}" >&2 ;;
    INFO)  echo -e "${GREEN}✓${NC} ${msg}" ;;
    STEP)  echo -e "${CYAN}${BOLD}▶${NC} ${msg}" ;;
  esac
}

error_exit() {
  log ERROR "$1"
  exit "${2:-1}"
}

# ========= Preflight Checks =========
check_root() {
  [[ $EUID -eq 0 ]] || error_exit "Must run as root. Try: sudo $SCRIPT_NAME"
}

check_dependencies() {
  local missing=()
  for cmd in git systemctl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    error_exit "Missing required commands: ${missing[*]}"
  fi
}

# ========= Backup =========
create_backup() {
  if [[ -d "${INSTALL_DIR}" ]]; then
    log STEP "Creating backup of current installation..."
    local backup_name="lyrebird-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${BACKUP_DIR}"
    
    if cp -r "${INSTALL_DIR}" "${BACKUP_DIR}/${backup_name}"; then
      log INFO "Backup created: ${BACKUP_DIR}/${backup_name}"
      
      # Keep only last 5 backups
      cd "${BACKUP_DIR}" || return
      ls -t | tail -n +6 | xargs -r rm -rf
      log INFO "Cleaned old backups (keeping 5 most recent)"
    else
      log WARN "Backup failed, but continuing..."
    fi
  fi
}

# ========= Stream Management =========
stop_streams() {
  log STEP "Stopping audio streams..."
  
  if [[ -f "${STREAM_MANAGER}" ]]; then
    if bash "${STREAM_MANAGER}" stop 2>/dev/null; then
      log INFO "Streams stopped successfully"
    else
      log WARN "Stream stop command failed, forcing cleanup..."
      pkill -9 -f "mediamtx" 2>/dev/null || true
      pkill -9 -f "ffmpeg.*rtsp" 2>/dev/null || true
      sleep 2
      log INFO "Force stopped all processes"
    fi
  else
    log WARN "Stream manager not found at ${STREAM_MANAGER}"
    log INFO "Attempting to stop any running MediaMTX/FFmpeg processes..."
    pkill -9 -f "mediamtx" 2>/dev/null || true
    pkill -9 -f "ffmpeg.*rtsp" 2>/dev/null || true
  fi
  
  # Give processes time to clean up
  sleep 3
}

start_streams() {
  log STEP "Starting audio streams..."
  
  if [[ ! -f "${STREAM_MANAGER}" ]]; then
    error_exit "Stream manager not found at ${STREAM_MANAGER}"
  fi
  
  if bash "${STREAM_MANAGER}" start; then
    log INFO "Streams started successfully"
  else
    error_exit "Failed to start streams"
  fi
}

# ========= Git Operations =========
clone_or_pull() {
  log STEP "Fetching latest code from GitHub..."
  
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    # Existing repo - pull updates
    cd "${INSTALL_DIR}" || error_exit "Cannot access ${INSTALL_DIR}"
    
    # Stash any local changes
    if [[ -n "$(git status --porcelain)" ]]; then
      log WARN "Local changes detected, stashing..."
      git stash save "Auto-stash before deploy $(date +%Y%m%d-%H%M%S)" || true
    fi
    
    # Get current commit for comparison
    local old_commit; old_commit=$(git rev-parse --short HEAD)
    
    # Pull latest
    if git pull origin main; then
      local new_commit; new_commit=$(git rev-parse --short HEAD)
      
      if [[ "$old_commit" == "$new_commit" ]]; then
        log INFO "Already up to date (${new_commit})"
      else
        log INFO "Updated from ${old_commit} to ${new_commit}"
        
        # Show what changed
        echo
        echo -e "${CYAN}Recent changes:${NC}"
        git log --oneline --decorate --graph "${old_commit}..${new_commit}" | head -10
        echo
      fi
    else
      error_exit "Git pull failed"
    fi
    
  else
    # New installation - clone
    log INFO "No existing installation found, cloning repository..."
    mkdir -p "$(dirname "${INSTALL_DIR}")"
    
    if git clone "${GITHUB_REPO}" "${INSTALL_DIR}"; then
      log INFO "Repository cloned successfully"
    else
      error_exit "Git clone failed"
    fi
  fi
}

set_permissions() {
  log STEP "Setting permissions..."
  
  # Make scripts executable
  find "${INSTALL_DIR}" -type f -name "*.sh" -exec chmod +x {} \;
  
  # Set ownership (adjust if needed)
  # chown -R youruser:yourgroup "${INSTALL_DIR}"
  
  log INFO "Permissions updated"
}

# ========= Status Display =========
show_deployment_status() {
  echo
  echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}${BOLD}  LyreBird Deployment Complete${NC}"
  echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════${NC}"
  echo
  
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    cd "${INSTALL_DIR}" || return
    echo -e "${CYAN}Current Version:${NC}"
    echo "  Branch: $(git branch --show-current)"
    echo "  Commit: $(git rev-parse --short HEAD) - $(git log -1 --pretty=%B | head -1)"
    echo "  Date:   $(git log -1 --pretty=%cd --date=relative)"
    echo
  fi
  
  echo -e "${CYAN}Installation Directory:${NC} ${INSTALL_DIR}"
  echo -e "${CYAN}Stream Manager:${NC} ${STREAM_MANAGER}"
  echo
  
  # Show stream status
  if [[ -f "${STREAM_MANAGER}" ]]; then
    echo -e "${CYAN}Stream Status:${NC}"
    bash "${STREAM_MANAGER}" status 2>/dev/null | grep -E "(MediaMTX:|Status:|Stream set:)" || true
  fi
  
  echo
  echo -e "${YELLOW}Useful Commands:${NC}"
  echo "  Check status:    sudo ${STREAM_MANAGER} status"
  echo "  Restart streams: sudo ${STREAM_MANAGER} restart"
  echo "  Stop streams:    sudo ${STREAM_MANAGER} stop"
  echo "  View logs:       tail -f /var/log/mediamtx-stream-manager.log"
  echo "  Deploy again:    sudo $SCRIPT_NAME"
  echo
}

# ========= Rollback =========
rollback() {
  log STEP "Rolling back to previous version..."
  
  local latest_backup
  latest_backup=$(ls -t "${BACKUP_DIR}" 2>/dev/null | head -1)
  
  if [[ -z "$latest_backup" ]]; then
    error_exit "No backups found in ${BACKUP_DIR}"
  fi
  
  log INFO "Found backup: ${latest_backup}"
  
  # Stop streams
  stop_streams
  
  # Remove current installation
  rm -rf "${INSTALL_DIR}"
  
  # Restore backup
  if cp -r "${BACKUP_DIR}/${latest_backup}" "${INSTALL_DIR}"; then
    log INFO "Restored from backup: ${latest_backup}"
    set_permissions
    start_streams
    log INFO "Rollback complete"
  else
    error_exit "Failed to restore backup"
  fi
}

# ========= Main Deployment Flow =========
deploy() {
  echo
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  LyreBird Audio Deployment Script v${VERSION}${NC}"
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
  echo
  
  check_root
  check_dependencies
  
  # Create log directory
  mkdir -p "$(dirname "${LOG_FILE}")"
  
  log INFO "Starting deployment from ${GITHUB_REPO}"
  echo
  
  # Deployment steps
  create_backup
  stop_streams
  clone_or_pull
  set_permissions
  start_streams
  
  echo
  show_deployment_status
}

# ========= CLI =========
show_help() {
  cat << EOF
${BOLD}LyreBird Audio Deployment Script v${VERSION}${NC}

${BOLD}USAGE:${NC}
  sudo $SCRIPT_NAME [COMMAND]

${BOLD}COMMANDS:${NC}
  deploy      Deploy latest code from GitHub (default)
  rollback    Rollback to previous backup
  status      Show current installation status
  help        Show this help message

${BOLD}EXAMPLES:${NC}
  sudo $SCRIPT_NAME              # Deploy latest version
  sudo $SCRIPT_NAME deploy       # Same as above
  sudo $SCRIPT_NAME rollback     # Restore previous version
  sudo $SCRIPT_NAME status       # Check installation

${BOLD}NOTES:${NC}
  - Automatically stops streams before updating
  - Creates backup before each deployment
  - Keeps last 5 backups in ${BACKUP_DIR}
  - Logs to ${LOG_FILE}

${BOLD}REPOSITORY:${NC}
  ${GITHUB_REPO}
EOF
}

show_status_only() {
  echo -e "${CYAN}${BOLD}LyreBird Installation Status${NC}"
  echo
  
  if [[ -d "${INSTALL_DIR}" ]]; then
    echo -e "${GREEN}✓${NC} Installation found: ${INSTALL_DIR}"
    
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
      cd "${INSTALL_DIR}" || exit 1
      echo "  Branch: $(git branch --show-current)"
      echo "  Commit: $(git rev-parse --short HEAD)"
      echo "  Last updated: $(git log -1 --pretty=%cd --date=relative)"
    fi
  else
    echo -e "${RED}✗${NC} Not installed at ${INSTALL_DIR}"
    echo "  Run: sudo $SCRIPT_NAME deploy"
  fi
  
  echo
  
  if [[ -f "${STREAM_MANAGER}" ]]; then
    echo -e "${GREEN}✓${NC} Stream manager: ${STREAM_MANAGER}"
  else
    echo -e "${RED}✗${NC} Stream manager not found"
  fi
  
  echo
  
  # Show backups
  if [[ -d "${BACKUP_DIR}" ]]; then
    local backup_count
    backup_count=$(ls -1 "${BACKUP_DIR}" 2>/dev/null | wc -l)
    echo -e "${CYAN}Backups:${NC} ${backup_count} found in ${BACKUP_DIR}"
    
    if [[ $backup_count -gt 0 ]]; then
      echo "  Latest: $(ls -t "${BACKUP_DIR}" | head -1)"
    fi
  else
    echo -e "${CYAN}Backups:${NC} None"
  fi
}

main() {
  case "${1:-deploy}" in
    deploy)
      deploy
      ;;
    rollback)
      check_root
      rollback
      ;;
    status)
      show_status_only
      ;;
    help|--help|-h)
      show_help
      ;;
    *)
      echo -e "${RED}Unknown command: $1${NC}"
      echo "Run '$SCRIPT_NAME help' for usage information"
      exit 1
      ;;
  esac
}

main "$@"
