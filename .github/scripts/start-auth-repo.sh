#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Start the authenticating repository in the background and wait until
# it listens.
#
# Usage: start-auth-repo.sh <server-root> <port-file> <request-log>
#
# AUTH_USER and AUTH_PASSWORD name the credentials the server demands.
# Prints the server's base URL. The port file appears only once the
# socket is listening, so waiting for it (rather than sleeping a fixed
# time) is what keeps this reliable on a slow or busy runner.

set -euo pipefail

root="${1:?server root required}"
port_file="${2:?port file required}"
request_log="${3:?request log required}"
: "${AUTH_USER:?AUTH_USER required}" "${AUTH_PASSWORD:?AUTH_PASSWORD required}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rm -f "${port_file}"
nohup python3 "${here}/auth_repo.py" "${root}" "${port_file}" \
  "${request_log}" > "${port_file}.log" 2>&1 &

for _ in $(seq 1 100); do
  if [ -s "${port_file}" ]; then
    printf 'http://127.0.0.1:%s\n' "$(tr -d '[:space:]' < "${port_file}")"
    exit 0
  fi
  sleep 0.1
done
echo "authenticating repository did not start within 10 seconds:" >&2
cat "${port_file}.log" >&2
exit 1
