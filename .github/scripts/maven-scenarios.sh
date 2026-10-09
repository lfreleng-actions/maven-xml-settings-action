#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Run real Maven against settings.xml documents this action generated,
# and check in the authenticating repository's request log that every
# request carried the credentials those settings supply.
#
# Usage: maven-scenarios.sh <server-root> <server-url> <request-log> \
#          <settings> <wrong-settings>
#
# <server-root>, <server-url> and <request-log> belong to a server that
# start-auth-repo.sh started. <settings> must hold credentials the
# server accepts for xml-settings-snapshots, xml-settings-mirror and
# xml-settings-profile, a mirror xml-settings-mirror of
# xml-settings-upstream at <server-url>/mirror and an active profile
# xml-settings-profile at <server-url>/profile. <wrong-settings> must
# hold a password the server refuses for xml-settings-snapshots.
#
# MVN names the Maven to run (default: mvn); MAVEN_REPO_LOCAL names the
# local repository (default: ${RUNNER_TEMP}/m2). Plugins resolve from
# Maven Central; only the test coordinates reach the local server.

set -euo pipefail

root="${1:?server root required}"
url="${2:?server URL required}"
log="${3:?request log required}"
settings="${4:?settings.xml required}"
wrong_settings="${5:?wrong-password settings.xml required}"
mvn="${MVN:-mvn}"
repo_local="${MAVEN_REPO_LOCAL:-${RUNNER_TEMP:?set RUNNER_TEMP or MAVEN_REPO_LOCAL}/m2}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="${here}/../../tests/fixtures/maven"
group="org/lfreleng/xmlsettings"
dependency="${group}/dependency/1.0/dependency-1.0.pom"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
failures=0

# Each scenario resolves its test coordinates afresh: a copy left in
# the local repository by an earlier scenario would be served from
# there, and the request this scenario must show would never be made.
# Maven runs on a copy of the fixture, so its output (and Maven 4's
# warning about a missing .mvn root marker) stays out of the checkout.
run_maven() {
  local fixture="$1" settings_file="$2"
  shift 2
  rm -rf "${work:?}/${fixture}" "${repo_local:?}/${group}"
  cp -R "${fixtures}/${fixture}" "${work}/${fixture}"
  mkdir -p "${work}/${fixture}/.mvn"
  "${mvn}" -B --no-transfer-progress -s "${settings_file}" \
    "-Dmaven.repo.local=${repo_local}" "-Drepo.url=${url}" \
    -f "${work}/${fixture}/pom.xml" "$@" > "${work}/${fixture}.log" 2>&1
}

# Request log lines written after line $1.
requests_since() {
  tail -n "+$(($1 + 1))" "${log}"
}

# Checks the requests after line $1: one must match $2, and none may
# match $3. Prints the reason and returns non-zero on a failure.
check_requests() {
  local seen
  seen="$(requests_since "$1")"
  if ! grep -qE -- "$2" <<< "${seen}"; then
    echo "no request matched: $2"
    return 1
  fi
  if grep -qE -- "$3" <<< "${seen}"; then
    echo "a request matched: $3"
    return 1
  fi
}

# Records a scenario's outcome. A failure shows Maven's output beside
# the requests the server saw, which together tell a settings problem
# from a server one.
report() {
  local name="$1" fixture="$2" start="$3" reason="$4"
  if [ -z "${reason}" ]; then
    echo "PASS: ${name}"
    return 0
  fi
  failures=$((failures + 1))
  echo "::error::FAIL: ${name}: ${reason}"
  echo "--- Maven output (last 40 lines)"
  tail -n 40 "${work}/${fixture}.log"
  echo "--- requests the server saw"
  requests_since "${start}"
}

# scenario <name> <fixture> <want> <refuse> <maven arguments...>
# Maven must succeed with the generated settings, and the server must
# have seen a request matching <want> and none with wrong credentials
# or matching <refuse>, when that is not empty.
scenario() {
  local name="$1" fixture="$2" want="$3" refuse=" auth=bad " start
  local reason=""
  if [ -n "$4" ]; then
    refuse+="|$4"
  fi
  shift 4
  start="$(wc -l < "${log}")"
  if ! run_maven "${fixture}" "${settings}" "$@"; then
    reason="Maven failed"
  else
    reason="$(check_requests "${start}" "${want}" "${refuse}")" || true
  fi
  report "${name}" "${fixture}" "${start}" "${reason}"
}

seed() {
  mkdir -p "$(dirname "${root}/$1/${dependency}")"
  cp "${fixtures}/dependency-1.0.pom" "${root}/$1/${dependency}"
}

# Left over from an earlier run against the same server, a seed would
# let a resolve scenario pass through the wrong repository.
rm -rf "${root:?}/mirror" "${root:?}/profile" "${root:?}/upstream"

scenario "deploy through distributionManagement" distribution-management \
  "^PUT /snapshots/${group}/distribution-management/[^ ]+\.pom auth=ok status=201$" \
  "" \
  deploy

scenario "deploy through altDeploymentRepository" alt-deployment \
  "^PUT /snapshots/${group}/alt-deployment/[^ ]+\.pom auth=ok status=201$" \
  "" \
  deploy "-DaltDeploymentRepository=xml-settings-snapshots::${url}/snapshots"

# The profile repository is not seeded yet, so the dependency can come
# from the mirror alone. The POM's own URL must never be contacted.
seed mirror
scenario "resolve through the mirror" resolve-mirror \
  "^GET /mirror/${dependency} auth=ok status=200$" \
  "^[A-Z]+ /upstream/" \
  org.apache.maven.plugins:maven-dependency-plugin:3.8.1:resolve

# resolve-profile declares no repository the mirror covers, so the
# profile repository is the only one that can serve the dependency.
seed profile
scenario "resolve through the active profile" resolve-profile \
  "^GET /profile/${dependency} auth=ok status=200$" \
  "^[A-Z]+ /mirror/" \
  org.apache.maven.plugins:maven-dependency-plugin:3.8.1:resolve

# Negative control: a server that accepted any credentials would pass
# every scenario above. With a wrong password the deploy must fail,
# the server must have refused the password Maven sent, and nothing
# may have been stored.
name="deploy with a wrong password fails"
start="$(wc -l < "${log}")"
if run_maven distribution-management "${wrong_settings}" deploy; then
  reason="Maven succeeded"
else
  reason="$(check_requests "${start}" \
    "^[A-Z]+ /snapshots/[^ ]+ auth=bad status=401$" \
    " auth=ok | status=201$")" || true
fi
report "${name}" distribution-management "${start}" "${reason}"

if [ "${failures}" -ne 0 ]; then
  echo "${failures} Maven scenario(s) failed"
  exit 1
fi
echo "All Maven scenarios passed"
