#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORIES_DIR="${ROOT_DIR}/repositorios"
ENV_FILE="${ROOT_DIR}/.env"
FORCE_UPDATE=0
SKIP_SERVICES=0
START_MYSQL=0
START_POSTGRES=0
START_REDIS=0

declare -a DOCKER_COMMAND=(docker)
declare -a COMPOSE_FILES=(-f docker-compose.yml)

declare -a UPDATED_REPOSITORIES=()
declare -a CURRENT_REPOSITORIES=()
declare -a SKIPPED_REPOSITORIES=()
declare -a FAILED_REPOSITORIES=()

if [ -t 1 ]; then
  BOLD=$'\033[1m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'
  RED=$'\033[0;31m'
  RESET=$'\033[0m'
else
  BOLD=''
  GREEN=''
  YELLOW=''
  BLUE=''
  RED=''
  RESET=''
fi

log_step() {
  printf '\n%b\n' "${BOLD}${BLUE}==> $*${RESET}"
}

log_info() {
  printf '%b\n' "${BLUE}$*${RESET}"
}

log_success() {
  printf '%b\n' "${GREEN}$*${RESET}"
}

log_warn() {
  printf '%b\n' "${YELLOW}$*${RESET}"
}

log_error() {
  printf '%b\n' "${RED}$*${RESET}" >&2
}

usage() {
  cat <<'EOF'
Usage:
  bash ./update-local.sh [--force] [--with-mysql] [--with-postgres] [--with-redis] [--skip-services]

Options:
  -f, --force  Reset dirty, divergent, or locally-ahead repositories to their
               configured upstream branch. This discards tracked and untracked changes.
  --with-mysql     Include the optional shared MySQL service.
  --with-postgres  Include the optional shared PostgreSQL service.
  --with-redis     Include the optional shared Redis service.
  --skip-services  Update repositories without starting shared services.
  -h, --help   Show this help message.
EOF
}

print_list() {
  local title="$1"
  shift

  [ "$#" -gt 0 ] || return 0

  printf '%b\n' "${BOLD}${title}:${RESET}"
  printf ' - %s\n' "$@"
}

ensure_php_runtime() {
  log_step "Checking isolated PHP runtime"
  if bash "${ROOT_DIR}/enviroment/check-phpenv.sh"; then
    log_success "The required PHP runtime is ready."
    return 0
  fi

  log_warn "PHP is missing, unusable, or has the wrong version. Attempting automatic repair."
  if ! bash "${ROOT_DIR}/enviroment/setup-phpenv.sh"; then
    log_error "PHP repair failed. Application repositories and shared services were not updated."
    return 1
  fi

  if ! bash "${ROOT_DIR}/enviroment/check-phpenv.sh"; then
    log_error "PHP verification failed after repair. Application repositories and shared services were not updated."
    return 1
  fi

  log_success "The required PHP runtime was repaired and verified."
}

select_docker_command() {
  if docker info >/dev/null 2>&1; then
    DOCKER_COMMAND=(docker)
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER_COMMAND=(sudo docker)
  else
    log_error "Docker Engine is not accessible. Run setup-local.sh or start Docker in this Linux distribution."
    return 1
  fi
}

run_docker() {
  "${DOCKER_COMMAND[@]}" "$@"
}

refresh_services() {
  if [ "${SKIP_SERVICES}" -eq 1 ]; then
    log_info "Shared service startup was skipped."
    return 0
  fi

  if [ ! -f "${ENV_FILE}" ]; then
    log_error "Infrastructure .env is missing. Run bash ./setup-local.sh first."
    return 1
  fi

  select_docker_command || return 1

  if [ "${START_MYSQL}" -eq 1 ]; then
    COMPOSE_FILES+=(-f docker-compose.mysql.yml)
  fi
  if [ "${START_POSTGRES}" -eq 1 ]; then
    COMPOSE_FILES+=(-f docker-compose.postgres.yml)
  fi
  if [ "${START_REDIS}" -eq 1 ]; then
    COMPOSE_FILES+=(-f docker-compose.redis.yml)
  fi

  log_step "Validating shared service configuration"
  if ! (cd "${ROOT_DIR}" && run_docker compose --env-file "${ENV_FILE}" "${COMPOSE_FILES[@]}" config --quiet); then
    log_error "Shared service configuration is invalid. No service changes were made."
    return 1
  fi

  log_step "Starting shared services and waiting for service health"
  if ! (cd "${ROOT_DIR}" && run_docker compose --env-file "${ENV_FILE}" "${COMPOSE_FILES[@]}" up -d --wait --wait-timeout 180); then
    log_error "One or more shared services did not become ready. Current status:"
    (cd "${ROOT_DIR}" && run_docker compose --env-file "${ENV_FILE}" "${COMPOSE_FILES[@]}" ps) || true
    log_error "Check '${DOCKER_COMMAND[*]} compose ${COMPOSE_FILES[*]} logs <service>' and rerun the update after fixing the cause. Data volumes were preserved."
    return 1
  fi

  log_success "Shared services are running."
  (cd "${ROOT_DIR}" && run_docker compose --env-file "${ENV_FILE}" "${COMPOSE_FILES[@]}" ps)
}

force_sync_repository() {
  local repository_path="$1"
  local upstream_ref="$2"

  git -C "${repository_path}" reset --hard "${upstream_ref}" &&
    git -C "${repository_path}" clean -fd
}

update_repository() {
  local repository_path="$1"
  local repository_name="${repository_path##*/}"
  local upstream_ref
  local before_ref
  local after_ref
  local status

  log_step "Updating ${repository_name}"

  if ! git -C "${repository_path}" symbolic-ref --quiet HEAD >/dev/null; then
    log_warn "Skipping ${repository_name}; it is in a detached HEAD state."
    SKIPPED_REPOSITORIES+=("${repository_name} (detached HEAD)")
    return
  fi

  if ! upstream_ref="$(git -C "${repository_path}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    log_warn "Skipping ${repository_name}; the current branch has no upstream."
    SKIPPED_REPOSITORIES+=("${repository_name} (no upstream)")
    return
  fi

  if ! git -C "${repository_path}" fetch --all --prune; then
    log_error "Failed to fetch ${repository_name}."
    FAILED_REPOSITORIES+=("${repository_name} (fetch failed)")
    return
  fi

  if ! before_ref="$(git -C "${repository_path}" rev-parse HEAD)"; then
    log_error "Failed to determine the current commit for ${repository_name}."
    FAILED_REPOSITORIES+=("${repository_name} (missing HEAD)")
    return
  fi

  status="$(git -C "${repository_path}" status --porcelain)"
  if [ -n "${status}" ]; then
    if [ "${FORCE_UPDATE}" -eq 0 ]; then
      log_warn "Skipping ${repository_name}; local changes were detected."
      SKIPPED_REPOSITORIES+=("${repository_name} (local changes)")
      return
    fi

    log_warn "Forcing ${repository_name} to match ${upstream_ref}."
    if ! force_sync_repository "${repository_path}" "${upstream_ref}"; then
      log_error "Failed to force-update ${repository_name}."
      FAILED_REPOSITORIES+=("${repository_name} (force update failed)")
      return
    fi
  elif git -C "${repository_path}" merge-base --is-ancestor HEAD "${upstream_ref}"; then
    if [ "${before_ref}" = "$(git -C "${repository_path}" rev-parse "${upstream_ref}")" ]; then
      log_info "${repository_name} is already up to date."
      CURRENT_REPOSITORIES+=("${repository_name}")
      return
    fi

    if ! git -C "${repository_path}" merge --ff-only "${upstream_ref}"; then
      log_error "Failed to fast-forward ${repository_name}."
      FAILED_REPOSITORIES+=("${repository_name} (fast-forward failed)")
      return
    fi
  elif git -C "${repository_path}" merge-base --is-ancestor "${upstream_ref}" HEAD; then
    if [ "${FORCE_UPDATE}" -eq 0 ]; then
      log_warn "Skipping ${repository_name}; local commits are ahead of ${upstream_ref}."
      SKIPPED_REPOSITORIES+=("${repository_name} (local commits ahead)")
      return
    fi

    log_warn "Forcing ${repository_name} to match ${upstream_ref}."
    if ! force_sync_repository "${repository_path}" "${upstream_ref}"; then
      log_error "Failed to force-update ${repository_name}."
      FAILED_REPOSITORIES+=("${repository_name} (force update failed)")
      return
    fi
  elif [ "${FORCE_UPDATE}" -eq 1 ]; then
    log_warn "Forcing ${repository_name} to match ${upstream_ref}."
    if ! force_sync_repository "${repository_path}" "${upstream_ref}"; then
      log_error "Failed to force-update ${repository_name}."
      FAILED_REPOSITORIES+=("${repository_name} (force update failed)")
      return
    fi
  else
    log_warn "Skipping ${repository_name}; local and upstream history diverged."
    SKIPPED_REPOSITORIES+=("${repository_name} (diverged history)")
    return
  fi

  after_ref="$(git -C "${repository_path}" rev-parse HEAD)"
  if [ "${before_ref}" = "${after_ref}" ]; then
    CURRENT_REPOSITORIES+=("${repository_name}")
    log_info "${repository_name} is already up to date."
    return
  fi

  UPDATED_REPOSITORIES+=("${repository_name}")
  log_success "Updated ${repository_name}."
}

parse_arguments() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f|--force)
        FORCE_UPDATE=1
        shift
        ;;
      --with-mysql)
        START_MYSQL=1
        shift
        ;;
      --with-postgres)
        START_POSTGRES=1
        shift
        ;;
      --with-redis)
        START_REDIS=1
        shift
        ;;
      --skip-services)
        SKIP_SERVICES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1. Run with --help for usage."
        exit 1
        ;;
    esac
  done
}

parse_arguments "$@"

ensure_php_runtime

command -v git >/dev/null 2>&1 || {
  log_error "git is required but was not found."
  exit 1
}

if [ ! -d "${REPOSITORIES_DIR}" ]; then
  log_warn "No repositories directory exists at repositorios/."
else
  shopt -s nullglob
  repository_paths=("${REPOSITORIES_DIR}"/*)
  shopt -u nullglob

  for repository_path in "${repository_paths[@]}"; do
    [ -d "${repository_path}" ] || continue

    if ! git -C "${repository_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      log_warn "Skipping ${repository_path##*/}; it is not a Git repository."
      SKIPPED_REPOSITORIES+=("${repository_path##*/} (not a Git repository)")
      continue
    fi

    update_repository "${repository_path}"
  done
fi

SERVICES_FAILED=0
refresh_services || SERVICES_FAILED=1

if [ "${#UPDATED_REPOSITORIES[@]}" -eq 0 ] && [ "${#CURRENT_REPOSITORIES[@]}" -eq 0 ] && [ "${#SKIPPED_REPOSITORIES[@]}" -eq 0 ] && [ "${#FAILED_REPOSITORIES[@]}" -eq 0 ]; then
  log_warn "No Git repositories were found in repositorios/."
fi

printf '\n%b\n' "${BOLD}Summary:${RESET}"
print_list "Updated repositories" "${UPDATED_REPOSITORIES[@]}"
print_list "Already current" "${CURRENT_REPOSITORIES[@]}"
print_list "Skipped repositories" "${SKIPPED_REPOSITORIES[@]}"
print_list "Repositories with errors" "${FAILED_REPOSITORIES[@]}"

if [ "${#FAILED_REPOSITORIES[@]}" -gt 0 ] || [ "${SERVICES_FAILED}" -eq 1 ]; then
  exit 1
fi
