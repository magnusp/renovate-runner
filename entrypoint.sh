#!/bin/bash
# Starts a GitHub Actions runner when configured through the environment, otherwise behaves as the plain Renovate image.
#
#   JIT config (no registration step):  ACTIONS_RUNNER_INPUT_JITCONFIG
#   Registration token:                 RUNNER_URL + RUNNER_TOKEN, optional RUNNER_NAME, RUNNER_LABELS,
#                                       RUNNER_GROUP, RUNNER_WORKDIR, RUNNER_EPHEMERAL (default "true")
#
# actions-runner-controller overrides the container command and never reaches this script.
set -euo pipefail

cd /home/runner

if [[ -n "${ACTIONS_RUNNER_INPUT_JITCONFIG:-}" ]]; then
  exec ./run.sh
fi

if [[ -z "${RUNNER_URL:-}" || -z "${RUNNER_TOKEN:-}" ]]; then
  exec /usr/local/sbin/renovate-entrypoint.sh "$@"
fi

# Keep the registration token out of the environment inherited by jobs
token="$RUNNER_TOKEN"
unset RUNNER_TOKEN

ephemeral="${RUNNER_EPHEMERAL:-true}"
args=(--unattended --replace --url "$RUNNER_URL" --token "$token"
  --name "${RUNNER_NAME:-$(hostname)}" --work "${RUNNER_WORKDIR:-_work}")
[[ -n "${RUNNER_LABELS:-}" ]] && args+=(--labels "$RUNNER_LABELS")
[[ -n "${RUNNER_GROUP:-}" ]] && args+=(--runnergroup "$RUNNER_GROUP")
[[ "$ephemeral" == "true" ]] && args+=(--ephemeral)

./config.sh "${args[@]}"

# An ephemeral runner deregisters itself after one job
if [[ "$ephemeral" == "true" ]]; then
  exec ./run.sh
fi

./run.sh &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null || true' TERM INT
status=0
wait "$pid" || status=$?
# A trapped signal interrupts the first wait; collect the runner's real exit status
if kill -0 "$pid" 2>/dev/null; then
  wait "$pid" || status=$?
fi
./config.sh remove --token "$token" || true
exit "$status"
