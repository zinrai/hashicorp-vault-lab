#!/bin/sh
# Per-agent entrypoint: unwrap the response-wrapped role-id and secret-id
# that vault-init wrote, then exec vault agent.
#
# Real-env analog: an orchestrator (Ansible/Nomad/K8s) hands a single-use
# wrap token to the workload at deploy time; the workload unwraps once.
# After the wrap_ttl expires (or after first use), restart of this container
# requires re-running vault-init to issue a new wrap.

set -eu

: "${APP_NAME:?APP_NAME is required}"
: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_CACERT:?VAULT_CACERT is required}"

WRAP_DIR="/vault-bootstrap/${APP_NAME}"
CRED_DIR="/vault-creds"
ROLE_WRAP="${WRAP_DIR}/role-id.wrap"
SECRET_WRAP="${WRAP_DIR}/secret-id.wrap"

if [ ! -f "${ROLE_WRAP}" ] || [ ! -f "${SECRET_WRAP}" ]; then
  echo "[entrypoint] missing wrap tokens for ${APP_NAME} under ${WRAP_DIR}" >&2
  exit 1
fi

mkdir -p "${CRED_DIR}"

ROLE_TOKEN=$(cat "${ROLE_WRAP}")
SECRET_TOKEN=$(cat "${SECRET_WRAP}")

echo "[entrypoint] unwrapping role-id for ${APP_NAME}"
VAULT_TOKEN="${ROLE_TOKEN}" vault unwrap -field=role_id > "${CRED_DIR}/role-id"

echo "[entrypoint] unwrapping secret-id for ${APP_NAME}"
VAULT_TOKEN="${SECRET_TOKEN}" vault unwrap -field=secret_id > "${CRED_DIR}/secret-id"

chmod 0400 "${CRED_DIR}/role-id" "${CRED_DIR}/secret-id"

echo "[entrypoint] starting vault agent for ${APP_NAME}"
unset VAULT_TOKEN
exec vault agent -config=/etc/vault-agent/config.hcl
