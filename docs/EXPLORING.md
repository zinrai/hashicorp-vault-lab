# Exploring hashicorp-vault-lab

This document is the companion to [`../README.md`](../README.md) and
[OVERVIEW.md](OVERVIEW.md). They describe *how* to bring the lab up and *what*
it is. This document describes
*how to poke at it after it is running*: which Vault feature is exercised by
which application, which command shows which aspect of its state, and what to
break to see how the system behaves.

It is organized by Vault feature, which makes it an index of means rather than
a route. If you are here to settle a design question for your own environment,
enter through [DECIDING.md](DECIDING.md) instead. It names what to decide and
points back here for the observations that inform each decision.

The 8 sections below are self-contained. Each section follows the same shape:

1. **Where**: which applications exercise this feature.
2. **Static inspection**: read the configuration written by
   `vault-config/configure.sh`.
3. **Dynamic inspection**: observe live state (leases, tokens, rendered
   files, container logs).
4. **Audit log view**: what entries this feature produces.
5. **Experiments**: what to change or break to see how the lab reacts.

---

## Prerequisites: open an operator session

Nobody uses a root token with this lab. Every command below requires a valid
OIDC token. Open a session once per shell, in the lab's directory, with
`VAULT_ADDR`, `VAULT_CACERT` and `VAULT_NETWORK` set as in the
[README](../README.md#quick-start):

```sh
vault login -method=oidc role=sre   # browser opens, sre@example.local / srepass
vault token lookup                   # confirm: policies=[default sre-admin]
```

Every `vault` command below runs on the host, against `VAULT_ADDR`. The
containers have fixed names, so `docker logs`, `docker exec` and `docker
restart` work from any directory; `docker compose -f compose.yaml` commands
run in the lab's directory.

The audit log is not in the lab. It is a file on each Vault node, written by
the active node. `ACTIVE` is the container of the Vault node that is active;
your Vault's tooling tells you which (with
[hashicorp-vault-sandbox](https://github.com/zinrai/hashicorp-vault-sandbox):
`vault-ceremony status` in its workload directory):

```sh
ACTIVE=<container of the active Vault node>
```

Look it up again after a failover.

`sre-admin` gives broad read/list across mounts. Use `role=developer` for the
narrower `developer-readonly` policy. This is useful when you want to verify
that a given path *isn't* visible to a non-admin operator.

**`sre-admin` cannot revoke anything.** It is read-only by design. Any
experiment below that stops a token or a lease needs a third role:

```sh
vault login -method=oidc role=incident
vault token lookup                   # confirm: policies=[default incident-response]
```

The separation is deliberate: routine inspection should not be able to stop
production by accident, and the audit log then distinguishes looking from
acting. `incident-response` can stop what is running but cannot change what
gets issued next, which is a different power again. See
[DECIDING 6](DECIDING.md#6-who-can-change-issuance-settings).

> OIDC needs a browser callback. The browser has to reach `local-idp:5556`
> and the CLI listens on `localhost:8250`. If you are running the lab on a
> remote host, forward both; `local-idp` is published on `127.0.0.1:5556` of
> the Docker host. Make `local-idp` resolve to `127.0.0.1` on the browser's
> machine:
> `ssh -L 8250:localhost:8250 -L 5556:localhost:5556 <host>`.

---

## 1. AppRole + response wrap (machine authentication)

### Where

All 12 applications. The agent sidecar (`app-<name>-agent`) authenticates to
Vault via AppRole. The `role-id` and `secret-id` arrive at the agent as
single-use wrap tokens. The deployment, played by `wrap` in the
[README](../README.md#quick-start), writes them to
the lab's `bootstrap/<app>/`, mounted read-only into the agent at
`/vault-bootstrap/<app>/`.

### Static inspection

```sh
vault list auth/approle/role
vault read auth/approle/role/api-server
# Expected: token_policies=[self-renewal api-server], token_ttl=20m,
# token_max_ttl=2h, secret_id_ttl=720h, secret_id_num_uses=0
```

Inspect what's mounted on each agent container:

```sh
docker exec app-api-server-agent ls -la /vault-bootstrap/api-server/
# role-id.wrap and secret-id.wrap: wrap tokens (already consumed at startup)

docker exec app-api-server-agent ls -la /vault-creds/
# role-id and secret-id: the unwrapped values, in tmpfs (lost on restart)
```

### Dynamic inspection

The agent renews its own Vault token every ~14m (2/3 of token_ttl=20m). At
token_max_ttl=2h it re-authenticates with the same secret-id:

```sh
docker logs app-api-server-agent | grep -E "renew|authentic"
# agent.auth.handler: renewed auth token
# agent.auth.handler: authentication successful
```

Attempt to re-use a wrap token (it was consumed during the agent's
entrypoint, so this must fail):

```sh
WRAP=$(docker exec app-api-server-agent cat /vault-bootstrap/api-server/role-id.wrap)
VAULT_TOKEN=$WRAP vault unwrap
# Error: wrapping token is not valid or does not exist
```

### Audit log view

```sh
docker exec $ACTIVE grep '"path":"auth/approle/login"' /vault/logs/audit.log | head -3
docker exec $ACTIVE grep '"path":"sys/wrapping/unwrap"' /vault/logs/audit.log | head -3
```

The `unwrap` entries are emitted at agent startup; `login` entries continue
every 2h (token_max_ttl).

### Experiments

**Verify single-use wrap by restarting an agent container:**

```sh
docker restart app-api-server-agent
docker logs --tail=20 app-api-server-agent
# [entrypoint] unwrapping role-id for api-server
# Error unwrapping: wrapping token is not valid or does not exist
# Container exits.
```

This is the intended real-env behaviour: re-provisioning requires the
deployment to hand the agent new wraps (the orchestrator's job in production,
[`wrap`](../README.md#quick-start) here), and the agent to be recreated:

```sh
wrap api-server
docker compose -f compose.yaml --profile apps up -d --force-recreate app-api-server-agent
```

---

## 2. OIDC operator login (human authentication)

### Where

Three roles are defined: `sre` (broad observability), `developer` (KV reads
only), and `incident` (revocation). They are backed by `local-idp` (Dex),
which has two preconfigured users:

| user                      | password | OIDC roles available     |
|---------------------------|----------|--------------------------|
| `sre@example.local`       | srepass  | sre, developer, incident |
| `developer@example.local` | devpass  | sre, developer, incident |

The roles are not bound to a particular subject, so either user may select any
role. Binding a role to an identity is out of scope here, and is noted as a lab
simplification in [OVERVIEW.md](OVERVIEW.md#lab-simplifications).

### Static inspection

```sh
vault read auth/oidc/role/sre
vault read auth/oidc/role/developer
vault read auth/oidc/role/incident
vault read auth/oidc/config

vault policy read sre-admin           # broad read/list, no write, no revoke
vault policy read developer-readonly
vault policy read incident-response   # revocation, no issuance changes
```

Three tiers of operator authority are visible here, and the split between them
is the shape of [DECIDING 6](DECIDING.md#6-who-can-change-issuance-settings):

| Policy | Can look | Can stop | Can change what gets issued |
|--------|----------|----------|-----------------------------|
| `developer-readonly` | KV only | no | no |
| `sre-admin` | broadly | no | no |
| `incident-response` | enough to pick a target | yes | no |
| The Vault's operators (with hashicorp-vault-sandbox, `admin`, userpass) | broadly | yes | yes |

### Dynamic inspection

Token comparison:

```sh
vault login -method=oidc role=sre
vault token lookup -format=json | jq '{policies, ttl, display_name}'

vault login -method=oidc role=developer
vault token lookup -format=json | jq '{policies, ttl, display_name}'
```

Policy enforcement comparison:

```sh
# As developer (KV reads only):
vault kv get secret/api-server/config   # OK
vault list database/roles               # 403
vault list auth/approle/role            # 403

# As sre:
vault list database/roles               # OK
vault list auth/approle/role            # OK
```

### Audit log view

```sh
docker exec $ACTIVE grep '"path":"auth/oidc/oidc/callback"' /vault/logs/audit.log | grep '"type":"response"' | tail -1
```

A login is two requests: `auth/oidc/oidc/auth_url`, which sends the browser
to local-idp, and `auth/oidc/oidc/callback`, which returns the token. The
path does not name the role. The callback's response does, in clear:
`auth.metadata.role` is the role (`sre`), and `auth.display_name` is the
user's email with the mount's prefix (`oidc-sre@example.local`). Who logged
in, and as what, can be read straight from the audit log.

### Experiments

**Confirm `bound_audiences` enforcement:**

`auth/oidc/role/sre` is bound to `audience=vault`. local-idp issues tokens
with `aud=vault` for the `vault` client. Changing the client ID in
`vault-config/configure.sh` (and `local-idp/config.yaml`) to something else
and re-running it as an operator would make the login fail at the audience
check.

**Confirm there is no root token to fall back on:**

There is nothing to try. `configure.sh` runs with an operator's own token, and
none of the lab's roles is a root token. Whether a root token can be generated,
and by whom, belongs to the Vault underneath, not to the lab.

---

## 3. KV v2 (static secrets)

### Where

7 applications consume KV v2 paths:

| KV path                                 | mount            | consumed by         |
|-----------------------------------------|------------------|---------------------|
| `secret/config`                         | secret           | web-frontend        |
| `secret/api-server/config`              | secret           | api-server          |
| `secret/auth-service/jwt-key`           | secret           | auth-service        |
| `secret/payment/stripe`                 | secret           | payment             |
| `secret/notification/sendgrid`          | secret           | notification        |
| `secret/notification/webhook`           | secret           | notification        |
| `secret/webhook-receiver/secret`        | secret           | webhook-receiver    |
| `secret-internal/internal-cms/config`   | secret-internal  | internal-cms        |

Two separate KV v2 mounts (`secret/` and `secret-internal/`) demonstrate
tenancy by mount-level path prefix; only `internal-cms` has a policy that
grants read on `secret-internal/data/*`.

### Static inspection

```sh
vault kv list secret/
vault kv list secret-internal/
vault kv get secret/api-server/config
vault kv metadata get secret/api-server/config
```

### Dynamic inspection

```sh
docker exec app-api-server cat /secrets/kv-config.json
# {"max-connections":"100"}

docker logs app-api-server | grep "kv state"
# {"msg":"kv state","kv":"config","values":{"max-connections":"100"}}
```

### Audit log view

```sh
docker exec $ACTIVE grep '"path":"secret/data/' /vault/logs/audit.log | wc -l
# Number of KV reads since startup (agents read once per template render)
```

### Experiments

**Modify a KV value and watch the app pick it up:**

```sh
vault kv put secret/api-server/config max-connections=200
# Within 1s, the agent re-renders the template:
docker logs --since 10s app-api-server
# {"msg":"kv reloaded","kv":"config","keys":["max-connections"]}
# {"msg":"kv state","kv":"config","values":{"max-connections":"200"}}
```

**Verify mount isolation:**

```sh
# api-server policy grants secret/data/api-server/*, nothing on secret-internal/
docker exec app-api-server-agent sh -c \
  'VAULT_TOKEN=$(cat /tmp/token) vault kv get secret-internal/internal-cms/config'
# 403: even though the agent has a valid Vault token, its policy denies
```

---

## 4. Dynamic database credentials (the headline feature)

### Where

11 applications (everyone except `notification`). Vault issues per-lease
PostgreSQL roles via the `database` engine.

| Database role         | Postgres backend     | default_ttl | max_ttl | consumed by               |
|-----------------------|----------------------|-------------|---------|---------------------------|
| `main-readonly`       | postgres-main        | 1h          | 24h     | web-frontend, admin-panel, search |
| `main-readwrite`      | postgres-main        | 1h          | 24h     | api-server, auth-service, batch-runner, webhook-receiver |
| `main-short`          | postgres-main        | 15m         | 15m     | (no consumer; reserved for short-window demos) |
| `main-long`           | postgres-main        | 8h          | 24h     | etl                       |
| `payment-short`       | postgres-payment     | 10m         | 10m     | payment                   |
| `analytics-readonly`  | postgres-analytics   | 1h          | 24h     | analytics                 |
| `analytics-readwrite` | postgres-analytics   | 1h          | 24h     | batch-runner, etl         |
| `analytics-long`      | postgres-analytics   | 8h          | 24h     | (no consumer)             |
| `internal-readwrite`  | postgres-internal    | 1h          | 24h     | internal-cms              |

`payment-short` is intentionally tightest (max_ttl == default_ttl) to make
credential re-issuance observable within ~10 minutes of lab time.

### Static inspection

```sh
vault list database/config
vault read database/config/postgres-main
# Reveals plugin, connection_url template, allowed_roles. The Vault-side
# password is not shown (rotate-root has invalidated the seed adminpass).

vault list database/roles
vault read database/roles/payment-short
# default_ttl=10m, max_ttl=10m, creation_statements=...
```

### Dynamic inspection

Count active leases per role:

```sh
for r in main-readonly main-readwrite main-short main-long payment-short \
         analytics-readonly analytics-readwrite analytics-long internal-readwrite; do
  printf "%-25s " "$r"
  vault list -format=json sys/leases/lookup/database/creds/$r 2>/dev/null \
    | jq 'length // 0'
done
```

Look up a specific lease:

```sh
LEASE=$(vault list -format=json sys/leases/lookup/database/creds/payment-short | jq -r '.[0]')
vault lease lookup database/creds/payment-short/$LEASE
# Shows issue_time, expire_time, last_renewal, renewable, ttl
```

See the dynamic Postgres role from the Postgres side. The `vault-admin`
password was rotated when `configure.sh` wrote the connection, but `pg_hba.conf` allows trust for
local connections, so `\du` is still reachable:

```sh
docker exec postgres-main psql -h localhost -U vault-admin -d postgres \
  -c "\du" | grep "v-approle-"
# v-approle-payment--EMav32DhRvLzcv4ESdR5-1781010719 | (db role)
# v-approle-main-rea-SmWlNlig1VcfpiHJNonG-1781009670 | ...
```

Confirm the app actually uses the credential:

```sh
docker logs --tail=4 app-payment | grep "db check ok"
# {"msg":"db check ok","db":"payment",
#  "username":"v-approle-payment--EMav32DhRvLzcv4ESdR5-1781010719",
#  "lease_id":"database/creds/payment-short/HJwMdZzWFHeDp0gQHveQ8y0z",
#  "lease_duration_s":600}
```

### Audit log view

```sh
docker exec $ACTIVE grep '"path":"database/creds/payment-short"' /vault/logs/audit.log \
  | wc -l
# Each credential issuance is one request + one response = 2 lines.
```

### Experiments

**Watch a rotation cycle (allow ~8 minutes):**

```sh
docker logs -f app-payment | grep "rotated"
# T+0:     db pool rotated lease_id=A lease_duration_s=600
# T+~7m:   db pool rotated lease_id=B lease_duration_s=600
```

The `lease_id` changing is the rotation. A measured run:

```
03:34:17  app    db pool rotated  lease_id=...EiART9  lease_duration_s=600
03:41:22  agent  vault.read(database/creds/payment-short): renewer done
                 (maybe the lease expired)
03:41:22  agent  rendered "(dynamic)" => "/vault/file/db-payment.json"
03:41:22  app    db pool rotated  lease_id=...DzXlMM  lease_duration_s=600
```

**Rotation happens at roughly two thirds of `max_ttl`, not at `max_ttl`.**
The agent sleeps until about 2/3 of the lease duration before attempting a
renewal. With `max_ttl == default_ttl` the renewal cannot extend anything, the
renewer reports itself done, and the template re-renders straight away. So a
10m role turns over about every 7m.

There is no intermediate log line for a successful renewal. A renewal that
keeps the same lease does not change the rendered file, so the application
never sees a change and never reports a rotation. Only re-issuance is visible
from the application side.

When sizing a TTL, the number that matters to the application is this ~2/3
interval, because that is how often it has to survive rebuilding its
connections. Material for [DECIDING 5](DECIDING.md#5-ttl).

**Manually revoke a lease and see what revocation does not do** (needs
`role=incident`):

```sh
vault login -method=oidc role=incident
vault lease revoke database/creds/main-readwrite/<id>
```

Vault drops the role in Postgres immediately:

```sh
docker exec postgres-main psql -U vault-admin -d postgres \
  -tAc "select count(*) from pg_roles where rolname like 'v-%'"
# the count falls
```

The credential is genuinely dead for anything opening a new connection:

```sh
# username and password the app is still holding
docker exec app-api-server-agent cat /vault/file/db-main.json

docker exec -e PGPASSWORD=<password> postgres-main \
  psql -h 127.0.0.1 -U <username> -d postgres -tAc 'select 1'
# FATAL:  role "v-approle-main-rea-..." does not exist
```

**And the application keeps working anyway:**

```sh
docker logs --tail=4 app-api-server
# {"msg":"db check ok","username":"v-approle-main-rea-...", ...}
```

Revocation removes the role in Postgres but does not terminate sessions already
established with it. The application's `pgxpool` holds open connections and
those keep serving. The Vault Agent is not told either: it learns the lease is
gone only when it next tries to renew, which for a `default_ttl=1h` role is
around forty minutes away.

This is the single most important thing to take away from the lab, because it
qualifies the whole revocation story. Stopping a lease stops the credential
from being *used again*. It does not evict whoever is already connected. If the
threat is an attacker holding an open session, revocation is not sufficient and
the connection has to be killed at the target. Material for
[DECIDING 5](DECIDING.md#5-ttl).

To see the recovery path instead, wait for a natural expiry rather than
revoking. `payment` uses `payment-short` with `max_ttl=10m`, so it re-issues on
its own inside ten minutes.

**Inspect the per-lease Postgres role lifecycle:**

```sh
docker exec postgres-main psql -h localhost -U vault-admin -d postgres \
  -c "SELECT rolname, rolvaliduntil FROM pg_roles WHERE rolname LIKE 'v-approle-%';"
```

`rolvaliduntil` is set to the lease expiry. Vault drops the role when the
lease is revoked (or expires).

---

## 5. PKI two-tier (dynamic certificates)

### Where

Only `admin-panel`. `pki/` holds the root CA; `pki_int/` holds the
intermediate, signed by the root. `admin-panel` issues end-entity certs via
the `pki_int/issue/admin-panel` role, with `ttl=1h`.

### Static inspection

```sh
vault read pki/cert/ca | openssl x509 -text -noout | head -10
# CN=lab.example.local Root CA, valid 10 years

vault read pki_int/cert/ca | openssl x509 -text -noout | head -10
# CN=lab.example.local Intermediate CA, signed by Root, valid 5 years

vault read pki_int/roles/admin-panel
# allowed_domains=lab.example.local, allow_subdomains=true, max_ttl=24h
```

### Dynamic inspection

Inspect the cert the agent rendered:

```sh
docker exec app-admin-panel cat /secrets/pki.json \
  | jq -r '.certificate' | openssl x509 -text -noout \
  | grep -E "Subject:|Not After|DNS:"
```

App-side observation log:

```sh
docker logs --tail=4 app-admin-panel | grep "pki state"
# {"msg":"pki state","cn":"admin.lab.example.local",
#  "sans":["admin.lab.example.local"],
#  "not_after":"2026-06-09T13:54:31Z","remaining_s":3566}
```

### Audit log view

```sh
docker exec $ACTIVE grep '"path":"pki_int/issue/admin-panel"' /vault/logs/audit.log \
  | wc -l
# One pair (request + response) per cert issuance; the agent re-issues every ~30m.
```

### Experiments

**Watch a cert rotation:**

Wait ~30 minutes after lab startup. The agent re-renders the PKI template at
50% of cert lifetime (1h ttl → re-issue at 30m):

```sh
docker logs app-admin-panel | grep "pki cert rotated"
# {"msg":"pki cert rotated","cn":"admin.lab.example.local",
#  "sans":["admin.lab.example.local"],"not_after":"2026-06-09T14:54:31Z"}
```

**Verify cert chain validates against the lab root CA:**

```sh
docker exec app-admin-panel cat /secrets/pki.json | jq -r '.certificate' > /tmp/leaf.pem
docker exec app-admin-panel cat /secrets/pki.json | jq -r '.issuing_ca' > /tmp/intermediate.pem
vault read -field=certificate pki/cert/ca > /tmp/root.pem

cat /tmp/intermediate.pem /tmp/root.pem > /tmp/chain.pem
openssl verify -CAfile /tmp/chain.pem /tmp/leaf.pem
# /tmp/leaf.pem: OK
```

---

## 6. Audit log

### Where

An audit device enabled by the Vault's operators before the lab existed, so
the audit log captures all of `configure.sh`'s activity and the operator who
ran it. The lab does not enable it and does not run the nodes it is on. The
commands below assume a `file` device at `/vault/logs/audit.log` on each node.

Each node has its own file and the active node writes it, so after a failover
the history is split across nodes. Commands below use `$ACTIVE` from the
[prerequisites](#prerequisites-open-an-operator-session).

### Static inspection

```sh
vault audit list
# Path     Type    Description
# file/    file    n/a

docker exec $ACTIVE stat /vault/logs/audit.log
docker exec $ACTIVE wc -l /vault/logs/audit.log
```

### Dynamic inspection

Live tail:

```sh
docker exec $ACTIVE tail -f /vault/logs/audit.log
```

Each operation produces two entries: `"type":"request"` and `"type":"response"`.
Sensitive fields are HMAC'd; the path and operation are cleartext.

Useful filters:

```sh
# All paths touched in the last 10 minutes:
docker exec $ACTIVE tail -n 1000 /vault/logs/audit.log \
  | jq -r 'select(.type=="request") | .request.path' | sort -u

# Lease issuance history (dynamic creds + cert + wrap):
docker exec $ACTIVE grep -E '"path":"(database/creds|pki_int/issue|sys/wrapping/wrap)' \
  /vault/logs/audit.log | wc -l

# Errors only:
docker exec $ACTIVE grep '"error":' /vault/logs/audit.log
```

### Audit log view

(This section is about audit log itself; meta-recursion not interesting.)

### Experiments

**Verify audit fail-closed behaviour:**

This acts on the Vault nodes, not on the lab, and stops the whole Vault for
everyone on it for as long as it lasts. The commands assume the nodes are
containers you can `docker exec` into, as with hashicorp-vault-sandbox.

```sh
docker exec $ACTIVE chmod 000 /vault/logs/audit.log
vault kv get secret/api-server/config
# OK: Vault still holds the file open, and the mode is checked only on open.

docker kill -s HUP $ACTIVE        # reopens the audit file
vault kv get secret/api-server/config
# Code: 500. Errors: * internal error
docker logs --since 30s $ACTIVE | grep 'failed to audit'
# open /vault/logs/audit.log: permission denied

docker exec $ACTIVE chmod 600 /vault/logs/audit.log
docker kill -s HUP $ACTIVE
vault kv get secret/api-server/config
# OK
```

The file is opened once, not for every write, so a broken file shows only
when Vault next opens it: on a SIGHUP, which is also how a rotated log is
picked up.

This demonstrates the production-critical "fail-closed" property: if audit
cannot be written, Vault refuses to operate. Real deployments mitigate this
by configuring multiple audit devices (file + syslog, for example).

---

## 7. `check-status.sh` as cross-feature summary

`check-status.sh` produces a one-shot snapshot of the lab. Run it as
`./check-status.sh` in the lab's directory, with `VAULT_ADDR`,
`VAULT_CACERT` and `VAULT_NETWORK` set. It runs against your operator session (the OIDC token in your shell), so the output reflects
the policies you have.

Section-to-feature mapping:

| Section in script        | Feature                              |
|--------------------------|--------------------------------------|
| Container status         | The lab's Compose project            |
| Vault status             | Seal and HA state, via `VAULT_ADDR`  |
| Auth methods             | AppRole + OIDC                       |
| Secrets engines          | KV / KV-internal / database / PKI    |
| Policies                 | Per-app + sre-admin + developer      |
| OIDC roles               | sre / developer / incident           |
| AppRole roles            | 12 per-app machine roles             |
| Database connections     | 4 Postgres backends                  |
| Database roles           | 9 dynamic role definitions           |
| PKI mounts               | Root and intermediate CA certs       |
| Database roles holding leases | Which roles have live credentials |
| Application logs         | Per-app observation log              |

Run it twice (initially and after 30m of uptime) to see rotation events
appear in the app log section. The lease count per role is the loop in
[section 4](#4-dynamic-database-credentials-the-headline-feature).

---

## 8. Disruption experiments

These break the lab in small, recoverable ways to make the failure mode of
each feature observable.

### 8.1 Stop Vault

This acts on the Vault nodes, not on the lab, and stops the whole Vault for
everyone on it. Stop every node, by whatever means your Vault is run; with
hashicorp-vault-sandbox, `docker compose stop` for the Workload Vault's nodes,
in its workload directory. Then:

```sh
docker logs --since 30s app-api-server
# {"msg":"db check ok", ...}  every application keeps serving
docker logs --since 30s app-api-server-agent
# often nothing: the agent notices only when it next renews, minutes away
```

Applications carry on for as long as their already-issued credentials last.
That interval is the answer to
[DECIDING 5](DECIDING.md#5-ttl), floor 1: it is the time you survive without
Vault.

Bring the Vault back and wait until every node is unsealed (with the sandbox,
`docker compose start` for the same nodes, then the same status command as in
the [prerequisites](#prerequisites-open-an-operator-session)).

Mounts, policies, roles and secrets are in the Vault's storage, and
`local-idp` and the databases are the lab's own containers, so nothing the lab
depends on was lost. Nothing has to be re-provisioned: the agents' tokens are
in the Vault's storage too and stay valid, and an agent whose token has
expired logs in again with the role-id and secret-id it still holds in
`/vault-creds`.

Stopping only the active node is a different measurement. Another node becomes
active, and `VAULT_ADDR` reaches it once whatever is behind that address
notices (about 15 seconds with the sandbox's load balancer); that is the outage
the lab sees. Find the active node again afterwards for the audit log.

### 8.2 Restart an agent container (response-wrap exhaustion)

```sh
docker restart app-payment-agent
docker logs --tail=10 app-payment-agent
# [entrypoint] unwrapping role-id for payment
# Error unwrapping: wrapping token is not valid or does not exist
# Container exits.
```

The only recovery path is for the deployment to issue fresh wrap tokens and
recreate the agent. Here `wrap` plays the deployment:

```sh
wrap payment
docker compose -f compose.yaml --profile apps up -d --force-recreate app-payment-agent
```

`wrap` is defined in the [README](../README.md#quick-start). In a production K8s/Nomad/Ansible setup, the
orchestrator would re-wrap and redeploy.

### 8.3 Revoke a dynamic DB lease

Single lease: see section 4 experiments.

By prefix, which is the shape incident response actually takes. This also shows
that **subjects and credential templates are two different granularity axes**.
`main-readwrite` is shared by four applications with four separate AppRole
subjects:

```sh
vault login -method=oidc role=incident

vault list sys/leases/lookup/database/creds/main-readwrite
# four leases, one per application

vault lease revoke -prefix database/creds/main-readwrite

docker exec postgres-main psql -U vault-admin -d postgres \
  -tAc "select count(*) from pg_roles where rolname like 'v-%'"
# four roles gone in one command
```

Compare with a template used by exactly one application:

```sh
vault list sys/leases/lookup/database/creds/payment-short
# one lease
```

Separate subjects did not separate blast radius here, because the credential
template was shared. One prefix revoke reached four applications that have four
different AppRole identities. Material for
[DECIDING 2](DECIDING.md#2-what-counts-as-one-subject).

Note that the four applications keep serving on their open connections. See the
section 4 experiment above for why, and do not read continued `db check ok` as
the revoke having failed.

### 8.4 Rotate a KV value

See section 3 experiments.

### 8.5 Block audit log writes

See section 6 experiments.

### 8.6 Stop a Postgres backend

```sh
docker stop postgres-payment
docker logs --since 30s app-payment
# {"msg":"db check failed","db":"payment","err":"...connection refused..."}

docker start postgres-payment
# When the next lease renewal happens (or the connection is retried), the
# pool recovers.
```

### 8.7 Tear down completely

```sh
docker compose -f compose.yaml --profile apps down -v
```

The lab is its own Compose project, so this removes only the lab. Its
containers, its databases and the per-app rendered volumes are erased. What
`configure.sh` wrote to Vault stays: mounts, policies, roles, KV secrets and
the PKI roots. So does the audit log, which belongs to the Vault.

To start again, remove the database connections first, as an operator of the
Vault. Vault rotated the `vault-admin` password, and the new databases
never had it:

```sh
vault lease revoke -force -prefix database/creds/
for db in main payment analytics internal; do
  vault delete database/config/postgres-$db
done
```

Then bring the lab up as in [`../README.md`](../README.md#quick-start). The
next run gets fresh AppRole secret-ids and fresh dynamic database users, and
keeps the PKI roots, because `configure.sh` generates them only once.

### 8.8 Merge two subjects (granularity comparison)

Every application in the lab is its own subject, so the coarse case has to be
constructed. This is the one experiment that needs an operator of the Vault
rather than one of the lab's OIDC roles, because changing what a role hands
out is an issuance change and none of those three roles holds that power
([DECIDING 6](DECIDING.md#6-who-can-change-issuance-settings)).

```sh
vault login ...      # as an operator; with the sandbox, -method=userpass username=alice
```

**Step 1.** Give `api-server` the union of both applications' policies:

```sh
vault write auth/approle/role/api-server \
  token_policies="self-renewal,api-server,payment" \
  token_no_default_policy=true \
  token_ttl="20m" \
  token_max_ttl="2h" \
  secret_id_ttl="720h" \
  secret_id_num_uses=0
```

**Step 2.** Hand `payment`'s agent a credential belonging to `api-server`'s
role. Hand `api-server` new wraps as usual, and `payment` wraps from the
`api-server` role:

```sh
wrap api-server
vault read -field=wrapping_token -wrap-ttl=10m \
  auth/approle/role/api-server/role-id > bootstrap/payment/role-id.wrap
vault write -f -field=wrapping_token -wrap-ttl=10m \
  auth/approle/role/api-server/secret-id > bootstrap/payment/secret-id.wrap
```

Wrap tokens are single-use, so both agents have to be recreated to pick these
up:

```sh
docker compose -f compose.yaml --profile apps up -d --force-recreate \
  app-api-server-agent app-payment-agent
```

### What you get

Both agents now authenticate as `api-server`, and the two tokens are
indistinguishable:

```sh
docker exec app-payment-agent sh -c \
  'VAULT_TOKEN=$(cat /tmp/token) vault token lookup -format=json'
docker exec app-api-server-agent sh -c \
  'VAULT_TOKEN=$(cat /tmp/token) vault token lookup -format=json'
```

```
payment:     policies ['api-server','payment','self-renewal']  meta {'role_name':'api-server'}  display_name approle
api-server:  policies ['api-server','payment','self-renewal']  meta {'role_name':'api-server'}  display_name approle
```

Enumerate every machine token and the problem is plain:

```sh
vault login -method=oidc role=incident
vault list auth/token/accessors
# then for each: vault write auth/token/lookup-accessor accessor=<a>
```

```
  role_name=api-server     policies=['api-server','payment','self-renewal']
  role_name=api-server     policies=['api-server','payment','self-renewal']
  role_name=admin-panel    policies=['admin-panel','self-renewal']
  ...
```

Two identical `api-server` rows, and **no `payment` anywhere**. To stop payment
you must pick its token out of those two, and nothing in Vault tells you which
one it is. You revoke both or neither.

The audit log has the same hole. Count activity by role:

```sh
docker exec $ACTIVE sh -c \
  "grep -o '\"role_name\":\"[a-z-]*\"' /vault/logs/audit.log | sort | uniq -c"
```

Merged, `api-server` carries roughly double the entries of its neighbours and
`payment` does not appear at all. **Merging subjects does not merely coarsen
the revocation unit. It deletes the workload from the audit record.**

### What separating costs

Going back means one more wrap token pair under `bootstrap/<app>/`, one
more distribution, and one more thing to re-provision when an agent restarts.
That is the whole price of the finer revocation unit and of being able to name
the workload afterwards. Material for
[DECIDING 2](DECIDING.md#2-what-counts-as-one-subject).

Restore by running `vault-config/configure.sh` again
as an operator, which writes the `api-server` role back with its own policies,
then `wrap` for both and recreating the two agents as above.
