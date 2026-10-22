#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHPENV_ROOT="${ROOT_DIR}/enviroment/phpenv"
PHP_VERSION="8.3.6"
PHP_INSTALL_DIR="${PHPENV_ROOT}/versions/${PHP_VERSION}"
PHP_BACKUP_DIR=''
PHP_BUILD_JOBS="${PHP_BUILD_JOBS:-2}"
PHPENV_REPOSITORY="https://github.com/phpenv/phpenv.git"
PHP_BUILD_REPOSITORY="https://github.com/php-build/php-build.git"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

restore_previous_php() {
  local status="$?"
  trap - EXIT

  if [ "${status}" -ne 0 ] && { [ -e "${PHP_BACKUP_DIR}/previous" ] || [ -L "${PHP_BACKUP_DIR}/previous" ]; }; then
    if [ -e "${PHP_INSTALL_DIR}" ] || [ -L "${PHP_INSTALL_DIR}" ]; then
      if ! mv -- "${PHP_INSTALL_DIR}" "${PHP_BACKUP_DIR}/failed"; then
        printf 'Error: cannot move the failed PHP installation. The previous installation is preserved at %s\n' "${PHP_BACKUP_DIR}/previous" >&2
        exit "${status}"
      fi
    fi

    if mv -- "${PHP_BACKUP_DIR}/previous" "${PHP_INSTALL_DIR}"; then
      printf 'PHP repair failed; the previous installation was restored to %s\n' "${PHP_INSTALL_DIR}" >&2
    else
      printf 'Error: cannot restore PHP automatically. The previous installation is preserved at %s\n' "${PHP_BACKUP_DIR}/previous" >&2
    fi
  fi

  exit "${status}"
}

select_build_image() {
  local host_libc
  local libc_major
  local libc_minor

  [ -r /etc/os-release ] || die "Cannot determine the host distribution."
  . /etc/os-release

  case "${ID:-}" in
    ubuntu|debian) ;;
    *)
      die "Automatic PHP builds support Debian and Ubuntu only."
      ;;
  esac

  host_libc="$(getconf GNU_LIBC_VERSION)" || die "Cannot determine the host glibc version."
  if [[ "${host_libc}" =~ ^glibc\ ([0-9]+)\.([0-9]+) ]]; then
    libc_major="${BASH_REMATCH[1]}"
    libc_minor="${BASH_REMATCH[2]}"
  else
    die "The isolated PHP runtime requires glibc 2.35 or newer; found ${host_libc}."
  fi
  if (( libc_major < 2 || (libc_major == 2 && libc_minor < 35) )); then
    die "The controlled PHP build requires glibc 2.35 or newer (Ubuntu 22.04+ or Debian 12+); found ${host_libc}."
  fi

  case "$(uname -m)" in
    x86_64) BUILD_PLATFORM='linux/amd64' ;;
    aarch64) BUILD_PLATFORM='linux/arm64' ;;
    *) die "The controlled PHP build supports x86_64 and aarch64 only." ;;
  esac

  [[ "${PHP_BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] || die "PHP_BUILD_JOBS must be a positive integer."
  BUILD_IMAGE_TAG="local-phpenv-build:php-${PHP_VERSION}-ubuntu-22.04-${BUILD_PLATFORM##*/}"
}

select_docker_command() {
  if docker info >/dev/null 2>&1; then
    DOCKER_COMMAND=(docker)
  elif [ "${EUID}" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    DOCKER_COMMAND=(sudo docker)
  else
    die "Docker Engine is required to build isolated PHP 8.3.6."
  fi
}

ensure_build_image() {
  if [ "${BUILD_IMAGE_READY:-0}" -eq 1 ]; then
    return
  fi

  "${DOCKER_COMMAND[@]}" build \
    --platform "${BUILD_PLATFORM}" \
    -t "${BUILD_IMAGE_TAG}" \
    -f "${ROOT_DIR}/enviroment/php-build.Dockerfile" \
    "${ROOT_DIR}/enviroment"
  BUILD_IMAGE_READY=1
}

build_php_runtime() {
  local log_dir
  local log_file
  local status=0

  mkdir -p "${PHPENV_ROOT}/logs"
  log_dir="$(mktemp -d "${PHPENV_ROOT}/logs/php-${PHP_VERSION}.XXXXXX")"
  printf 'Building PHP %s with %s parallel job(s)\n' "${PHP_VERSION}" "${PHP_BUILD_JOBS}"
  printf 'Persistent build logs: %s\n' "${log_dir}"

  "${DOCKER_COMMAND[@]}" run --rm \
    --platform "${BUILD_PLATFORM}" \
    --user "$(id -u):$(id -g)" \
    --env "HOME=/tmp" \
    --env "TMPDIR=/build-logs" \
    --env "PHP_BUILD_TMPDIR=/tmp" \
    --env "PHP_BUILD_EXTRA_MAKE_ARGUMENTS=-j${PHP_BUILD_JOBS}" \
    --env "PHPENV_ROOT=${PHPENV_ROOT}" \
    --env "PHPENV_VERSION=${PHP_VERSION}" \
    --volume "${ROOT_DIR}:${ROOT_DIR}" \
    --volume "${log_dir}:/build-logs" \
    --workdir "${ROOT_DIR}" \
    "${BUILD_IMAGE_TAG}" \
    bash "${ROOT_DIR}/enviroment/build-php.sh" 2>&1 | tee "${log_dir}/build.log" || status=$?

  if [ "${status}" -ne 0 ]; then
    printf 'PHP compilation failed. Full logs were preserved at %s\n' "${log_dir}" >&2
    for log_file in "${log_dir}"/php-build.*.log; do
      [ -f "${log_file}" ] || continue
      grep -n -m 3 -B 3 -A 5 -E '(^|[[:space:]])(fatal )?error:|Killed signal|out of memory' "${log_file}" >&2 || true
    done
    return "${status}"
  fi
}

install_missing_runtime_libraries() {
  local missing_libraries
  local previous_missing=''
  local attempt

  mkdir -p "${PHPENV_ROOT}/lib"
  for attempt in 1 2 3; do
    missing_libraries="$(LD_LIBRARY_PATH="${PHPENV_ROOT}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
      ldd "${PHPENV_ROOT}/versions/${PHP_VERSION}/bin/php" |
      awk '$2 == "=>" && $3 == "not" && $4 == "found" {print $1}')"
    [ -n "${missing_libraries}" ] || return 0
    [ "${missing_libraries}" != "${previous_missing}" ] || die "Unable to provide required PHP libraries: ${missing_libraries}"
    previous_missing="${missing_libraries}"

    printf 'Copying missing PHP runtime libraries into %s\n' "${PHPENV_ROOT}/lib"
    ensure_build_image
    "${DOCKER_COMMAND[@]}" run --rm \
      --platform "${BUILD_PLATFORM}" \
      --user "$(id -u):$(id -g)" \
      --env "PHPENV_ROOT=${PHPENV_ROOT}" \
      --env "MISSING_LIBRARIES=${missing_libraries}" \
      --volume "${ROOT_DIR}:${ROOT_DIR}" \
      "${BUILD_IMAGE_TAG}" \
      bash "${ROOT_DIR}/enviroment/copy-runtime-libraries.sh"
  done

  die "Unable to resolve all PHP runtime libraries."
}

command -v git >/dev/null 2>&1 || die "Git is required to install phpenv."
select_build_image
select_docker_command

if [ ! -d "${PHPENV_ROOT}" ]; then
  printf 'Installing phpenv in %s\n' "${PHPENV_ROOT}"
  git clone --depth 1 "${PHPENV_REPOSITORY}" "${PHPENV_ROOT}"
fi
[ -x "${PHPENV_ROOT}/bin/phpenv" ] || die "${PHPENV_ROOT} exists but is not a valid phpenv installation."

mkdir -p "${PHPENV_ROOT}/plugins"
if [ ! -d "${PHPENV_ROOT}/plugins/php-build" ]; then
  git clone --depth 1 "${PHP_BUILD_REPOSITORY}" "${PHPENV_ROOT}/plugins/php-build"
fi
[ -x "${PHPENV_ROOT}/plugins/php-build/bin/php-build" ] || die "The php-build plugin is incomplete."

export PHPENV_ROOT PHPENV_VERSION="${PHP_VERSION}"
export PATH="${PHPENV_ROOT}/shims:${PHPENV_ROOT}/bin:${PATH}"

if ! bash "${ROOT_DIR}/enviroment/check-phpenv.sh" >/dev/null 2>&1; then
  ensure_build_image

  if [ -e "${PHP_INSTALL_DIR}" ] || [ -L "${PHP_INSTALL_DIR}" ]; then
    PHP_BACKUP_DIR="$(mktemp -d "${PHPENV_ROOT}/.php-${PHP_VERSION}-backup.XXXXXX")"
    trap restore_previous_php EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mv -- "${PHP_INSTALL_DIR}" "${PHP_BACKUP_DIR}/previous"
    printf 'Previous PHP installation backed up to %s\n' "${PHP_BACKUP_DIR}/previous"
  fi

  build_php_runtime
fi

install_missing_runtime_libraries
phpenv rehash
bash "${ROOT_DIR}/enviroment/check-phpenv.sh"
printf 'PHP %s is ready in %s\n' "${PHP_VERSION}" "${PHPENV_ROOT}"
if [ -n "${PHP_BACKUP_DIR}" ]; then
  printf 'Previous PHP installation preserved at %s\n' "${PHP_BACKUP_DIR}/previous"
fi
