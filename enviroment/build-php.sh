#!/usr/bin/env bash
set -euo pipefail

: "${PHPENV_ROOT:?PHPENV_ROOT is required}"
: "${PHPENV_VERSION:?PHPENV_VERSION is required}"

printf 'Building PHP %s with the controlled Ubuntu 22.04 toolchain\n' "${PHPENV_VERSION}"
printf 'Architecture: %s\n' "$(uname -m)"
printf 'Compiler: %s\n' "$(cc -dumpfullversion)"
printf 'libxml2: %s\n' "$(pkg-config --modversion libxml-2.0)"
printf 'OpenSSL: %s\n' "$(pkg-config --modversion openssl)"

exec "${PHPENV_ROOT}/bin/phpenv" install "${PHPENV_VERSION}"
