#!/bin/sh
# VAULT_ADDR and VAULT_CACERT from the deployment, not from <app>.hcl: where
# Vault is depends on where the lab runs.
#
# Once only, not on every start: a wrap token is single-use, so a restarted
# agent fails until the deployment hands it new ones. Secret zero is the
# orchestrator's to deliver again, not something to persist on disk.

set -eu

APP_NAME=${1:?usage: entrypoint.sh <app>}
: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_CACERT:?VAULT_CACERT is required}"

WRAP_DIR="/vault-bootstrap/${APP_NAME}"
CRED_DIR="/vault-creds"

for f in role-id.wrap secret-id.wrap; do
  if [ ! -f "${WRAP_DIR}/$f" ]; then
    echo "[entrypoint] no ${WRAP_DIR}/$f: the deployment has not handed ${APP_NAME} its wrap tokens" >&2
    exit 1
  fi
done

echo "[entrypoint] unwrapping role-id for ${APP_NAME}"
VAULT_TOKEN=$(cat "${WRAP_DIR}/role-id.wrap") vault unwrap -field=role_id > "${CRED_DIR}/role-id"
echo "[entrypoint] unwrapping secret-id for ${APP_NAME}"
VAULT_TOKEN=$(cat "${WRAP_DIR}/secret-id.wrap") vault unwrap -field=secret_id > "${CRED_DIR}/secret-id"
chmod 0400 "${CRED_DIR}/role-id" "${CRED_DIR}/secret-id"

echo "[entrypoint] starting vault agent for ${APP_NAME}"
exec vault agent -config="$(dirname "$0")/${APP_NAME}.hcl"
