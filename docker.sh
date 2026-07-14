#!/usr/bin/env bash
set -euo pipefail

DOCKER_USER=""
DOCKER_HOME=""
export DEBIAN_FRONTEND=noninteractive

apt_update_once() {
  if [[ -z "${APT_UPDATED:-}" ]]; then
    log "Refreshing apt package index"
    apt-get update
    APT_UPDATED=1
  fi
}

configure_docker_service() {
  log "Enabling and starting Docker"
  systemctl enable --now docker
}

configure_docker_user_shell() {
  local profile="${DOCKER_HOME}/.profile"
  local bashrc="${DOCKER_HOME}/.bashrc"
  local marker="# bootstrap-shell-config"

  ensure_file "$profile"
  ensure_file "$bashrc"

  ensure_line '[[ -f ~/.bashrc ]] && source ~/.bashrc' "$profile"
  ensure_line '[[ -f /etc/bash_completion ]] && . /etc/bash_completion' "$bashrc"
  ensure_line 'export EDITOR=nano' "$bashrc"
  ensure_line 'export VISUAL=nano' "$bashrc"

  if ! grep -Fqx "$marker" "$bashrc"; then
    cat >> "$bashrc" <<'EOF'

# bootstrap-shell-config
alias dir='ls -aFhl --color'
alias edit="/bin/nano -w"
export EDITOR="/bin/nano"
PS1="\[\033[1;32m\][\$(date '+%Y-%m-%d_%H:%M:%S')]\[\033[1;35m\][\u@\h:\w]\$\[\033[0m\] "
fingerprintssh() { ssh-keygen -lf "$1" -E sha256; }
fingerprintssl() { openssl pkey -pubin -in "$1" -outform DER | openssl dgst -sha256 -c; }
EOF
  fi

  chown "${DOCKER_USER}:${DOCKER_USER}" "$profile" "$bashrc"
}

configure_docker_user_ssh() {
  local ssh_dir="${DOCKER_HOME}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"
  local pubkey

  install -d -m 700 -o "${DOCKER_USER}" -g "${DOCKER_USER}" "${ssh_dir}"

  if [[ ! -f "${auth_keys}" ]]; then
    install -m 600 -o "${DOCKER_USER}" -g "${DOCKER_USER}" /dev/null "${auth_keys}"
  else
    chmod 600 "${auth_keys}"
    chown "${DOCKER_USER}:${DOCKER_USER}" "${auth_keys}"
  fi

  printf '\nPaste the SSH public key for %s, then press Enter:\n' "${DOCKER_USER}"
  read -r pubkey

  [[ -n "${pubkey}" ]] || die "No SSH public key was provided."

  grep -Fqx "${pubkey}" "${auth_keys}" || echo "${pubkey}" >> "${auth_keys}"

  chown "${DOCKER_USER}:${DOCKER_USER}" "${auth_keys}"
  chmod 600 "${auth_keys}"
}

create_docker_user() {
  if id -u "${DOCKER_USER}" >/dev/null 2>&1; then
    log "User ${DOCKER_USER} already exists"
  else
    log "Creating user ${DOCKER_USER}"
    useradd -m -s /bin/bash "${DOCKER_USER}"
  fi

  [[ -d "${DOCKER_HOME}" ]] || die "Home directory not found for ${DOCKER_USER}"
}

create_script_dirs() {
  ensure_dir "${DOCKER_HOME}/bin"
  ensure_dir "${DOCKER_HOME}/scripts"
  chown -R "${DOCKER_USER}:${DOCKER_USER}" "${DOCKER_HOME}/bin" "${DOCKER_HOME}/scripts"
}

die() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

ensure_dir() {
  local dir="$1"
  mkdir -p "$dir"
}

ensure_file() {
  local file="$1"
  touch "$file"
}

ensure_line() {
  local line="$1"
  local file="$2"
  ensure_file "$file"
  grep -Fqx "$line" "$file" || echo "$line" >> "$file"
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker is already installed"
    return 0
  fi

  apt_update_once
  log "Installing Docker"
  apt-get install -y docker.io
}

install_packages() {
  local pkgs=()
  for pkg in bash-completion ca-certificates curl git nano; do
    dpkg -s "$pkg" >/dev/null 2>&1 || pkgs+=("$pkg")
  done

  if (( ${#pkgs[@]} > 0 )); then
    apt_update_once
    log "Installing packages: ${pkgs[*]}"
    apt-get install -y "${pkgs[@]}"
  else
    log "Required base packages already installed."
  fi
}

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

main() {
  require_root
  require_ubuntu
  prompt_for_username
  install_packages
  install_docker
  configure_docker_service
  create_docker_user
  create_script_dirs
  configure_docker_user_shell
  configure_docker_user_ssh
  setup_docker_group
  show_summary
}

prompt_for_username() {
  local input
  local default_user="dr"

  while true; do
    read -r -p "Enter the new Docker username [${default_user}]: " input
    input="${input:-$default_user}"

    if [[ "$input" =~ ^[a-z][-a-z0-9_]*$ ]]; then
      DOCKER_USER="$input"
      DOCKER_HOME="/home/${DOCKER_USER}"
      log "Using Docker user: ${DOCKER_USER}"
      return 0
    fi

    warn "Invalid username. Use lowercase letters, digits, hyphens, or underscores, starting with a letter."
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root."
  fi
}

require_ubuntu() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This script supports Ubuntu only."
}

setup_docker_group() {
  if ! getent group docker >/dev/null 2>&1; then
    log "Creating docker group"
    groupadd docker
  fi

  log "Adding ${DOCKER_USER} to docker group"
  usermod -aG docker "${DOCKER_USER}"
}

show_summary() {
  log "Docker setup complete"
  printf '%s\n' \
    "Docker user: ${DOCKER_USER}" \
    "Home: ${DOCKER_HOME}" \
    "Docker service: enabled" \
    "SSH key: added to ${DOCKER_HOME}/.ssh/authorized_keys" \
    "Docker access: granted via docker group" \
    "Next step: log in as ${DOCKER_USER} again so docker group membership applies"
}

warn() {
  printf '\n[WARN] %s\n' "$*" >&2
}

main "$@"
