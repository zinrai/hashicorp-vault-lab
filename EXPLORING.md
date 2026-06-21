# Exploring hashicorp-vault-lab

This document is the companion to `README.md`. README describes *what* the lab
is and *how* to bring it up. This document describes *how to poke at it
after it is running*: which Vault feature is exercised by which application,
which command shows which aspect of its state, and what to break to see how
the system behaves.

The 8 sections below are self-contained. Each section follows the same shape:

1. **Where**: which applications exercise this feature.
2. **Static inspection**: read the configuration written by `vault-init`.
3. **Dynamic inspection**: observe live state (leases, tokens, rendered
   files, container logs).
4. **Audit log view**: what entries this feature produces.
5. **Experiments**: what to change or break to see how the lab reacts.

---

## Prerequisites: open an operator session

The root token is revoked at the end of `vault-init`. Every command below
requires a valid OIDC token. Open a session once per shell:

```sh
docker compose cp vault:/vault/tls/vault-ca.pem ./ca.pem
export VAULT_ADDR=https://localhost:8200
export VAULT_CACERT=$PWD/ca.pem
export VAULT_TLS_SERVER_NAME=localhost

vault login -method=oidc role=sre   # browser opens, user 'sre' / 'srepass'
vault token lookup                   # confirm: policies=[default sre-admin]
```

`sre-admin` gives broad read/list across mounts. Use `role=developer` for the
narrower `developer-readonly` policy. This is useful when you want to verify
that a given path *isn't* visible to a non-admin operator.

> OIDC needs a browser callback. If you are running the lab on a remote
> host, SSH-forward 8200 and 8080 so the callback URLs resolve locally:
> `ssh -L 8200:localhost:8200 -L 8080:localhost:8080 <host>`.

---

## 1. AppRole + response wrap (machine authentication)

### Where

All 12 applications. The agent sidecar (`app-<name>-agent`) authenticates to
Vault via AppRole. The `role-id` and `secret-id` arrive at the agent as
single-use wrap tokens written by `vault-init` to `/vault-bootstrap/<app>/`.

### Static inspection

```sh
vault list auth/approle/role
vault read auth/approle/role/api-server
# Expected: token_policies=[base api-server], token_ttl=20m,
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
docker compose logs app-api-server-agent | grep -E "renew|authentic"
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
docker compose exec vault grep '"path":"auth/approle/login"' /vault/logs/audit.log | head -3
docker compose exec vault grep '"path":"sys/wrapping/unwrap"' /vault/logs/audit.log | head -3
```

The `unwrap` entries are emitted at agent startup; `login` entries continue
every 2h (token_max_ttl).

### Experiments

**Verify single-use wrap by restarting an agent container:**

```sh
docker compose restart app-api-server-agent
docker compose logs --tail=20 app-api-server-agent
# [entrypoint] unwrapping role-id for api-server
# Error unwrapping: wrapping token is not valid or does not exist
# Container exits.
```

This is the intended real-env behaviour: re-provisioning requires re-running
`vault-init` (the orchestrator's job in production).

---

## 2. OIDC operator login (human authentication)

### Where

Two roles are defined: `sre` (broad observability) and `developer` (KV reads
only). Both are backed by `local-idp` (siocode/local-idp), which has two
preconfigured users:

| user      | password | OIDC role to use   |
|-----------|----------|--------------------|
| sre       | srepass  | sre                |
| developer | devpass  | developer          |

### Static inspection

```sh
vault read auth/oidc/role/sre
vault read auth/oidc/role/developer
vault read auth/oidc/config

vault policy read sre-admin       # broad read/list across mounts
vault policy read developer-readonly
```

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
docker compose exec vault grep '"path":"auth/oidc/login/' /vault/logs/audit.log | head -3
```

The path embeds the role name (e.g. `auth/oidc/login/sre`). The user's
subject claim is HMAC-hashed; you can correlate same-user logins by matching
the hash but cannot recover the cleartext username from the audit log.

### Experiments

**Confirm `bound_audiences` enforcement:**

`auth/oidc/role/sre` is bound to `audience=vault`. local-idp issues tokens
with `aud=vault` for the `vault` client. Changing the client_id in
`vault-init/init.sh` to something else and re-running would make the login
fail at the audience check.

**Confirm root token is revoked:**

```sh
VAULT_TOKEN=root vault token lookup
# Error: 403 (token has been revoked)
```

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

docker compose logs app-api-server | grep "kv state"
# {"msg":"kv state","kv":"config","values":{"max-connections":"100"}}
```

### Audit log view

```sh
docker compose exec vault grep '"path":"secret/data/' /vault/logs/audit.log | wc -l
# Number of KV reads since startup (agents read once per template render)
```

### Experiments

**Modify a KV value and watch the app pick it up:**

```sh
vault kv put secret/api-server/config max-connections=200
# Within 1s, the agent re-renders the template:
docker compose logs --since 10s app-api-server
# {"msg":"kv reloaded","kv":"config","keys":["max-connections"]}
# {"msg":"kv state","kv":"config","values":{"max-connections":"200"}}
```

**Verify mount isolation:**

```sh
# api-server policy grants secret/data/api-server/*, nothing on secret-internal/
docker exec app-api-server-agent vault kv get -address=https://vault:8200 \
  -ca-cert=/vault-tls/vault-ca.pem -tls-server-name=localhost \
  secret-internal/internal-cms/config
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
password was rotated by `vault-init`, but `pg_hba.conf` allows trust for
local connections, so `\du` is still reachable:

```sh
docker exec postgres-main psql -h localhost -U vault-admin -d postgres \
  -c "\du" | grep "v-approle-"
# v-approle-payment--EMav32DhRvLzcv4ESdR5-1781010719 | (db role)
# v-approle-main-rea-SmWlNlig1VcfpiHJNonG-1781009670 | ...
```

Confirm the app actually uses the credential:

```sh
docker compose logs --tail=4 app-payment | grep "db check ok"
# {"msg":"db check ok","db":"payment",
#  "username":"v-approle-payment--EMav32DhRvLzcv4ESdR5-1781010719",
#  "lease_id":"database/creds/payment-short/HJwMdZzWFHeDp0gQHveQ8y0z",
#  "lease_duration_s":600}
```

### Audit log view

```sh
docker compose exec vault grep '"path":"database/creds/payment-short"' /vault/logs/audit.log \
  | wc -l
# Each credential issuance is one request + one response = 2 lines.
```

### Experiments

**Watch a renewal cycle (within ~5 minutes):**

```sh
docker compose logs -f app-payment | grep "rotated"
# T+0:    db pool rotated lease_id=A lease_duration_s=600  (initial)
# T+~5m:  db pool rotated lease_id=A lease_duration_s=599  (renewal: same lease)
# T+~7m:  db pool rotated lease_id=B lease_duration_s=600  (re-issuance: new lease)
```

The transition from "same lease_id" to "different lease_id" is the actual
credential rotation. With `max_ttl=10m`, Vault refuses further renewal once
the lease has lived 10 minutes from issue, and the agent re-renders the
template, which results in a brand-new dynamic Postgres role.

**Manually revoke a lease and watch the app recover:**

```sh
vault lease revoke database/creds/payment-short/<id>
docker compose logs -f app-payment
# {"msg":"db check failed","db":"payment","err":"password authentication failed"}
# (Agent detects expired lease, re-renders, app rebuilds pool)
# {"msg":"db pool rotated",...new lease_id...}
# {"msg":"db check ok",...}
```

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
docker compose logs --tail=4 app-admin-panel | grep "pki state"
# {"msg":"pki state","cn":"admin.lab.example.local",
#  "sans":["admin.lab.example.local"],
#  "not_after":"2026-06-09T13:54:31Z","remaining_s":3566}
```

### Audit log view

```sh
docker compose exec vault grep '"path":"pki_int/issue/admin-panel"' /vault/logs/audit.log \
  | wc -l
# One pair (request + response) per cert issuance; the agent re-issues every ~30m.
```

### Experiments

**Watch a cert rotation:**

Wait ~30 minutes after lab startup. The agent re-renders the PKI template at
50% of cert lifetime (1h ttl → re-issue at 30m):

```sh
docker compose logs app-admin-panel | grep "pki cert rotated"
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

A `file` device is enabled at `/vault/logs/audit.log` on Vault startup
(by `vault-init`, before any other configuration step, so the audit log
captures all of `vault-init`'s own activity).

### Static inspection

```sh
vault audit list
# Path     Type    Description
# file/    file    n/a

docker compose exec vault stat /vault/logs/audit.log
docker compose exec vault wc -l /vault/logs/audit.log
```

### Dynamic inspection

Live tail:

```sh
docker compose exec vault tail -f /vault/logs/audit.log
```

Each operation produces two entries: `"type":"request"` and `"type":"response"`.
Sensitive fields are HMAC'd; the path and operation are cleartext.

Useful filters:

```sh
# All paths touched in the last 10 minutes:
docker compose exec vault tail -n 1000 /vault/logs/audit.log \
  | jq -r 'select(.type=="request") | .request.path' | sort -u

# Lease issuance history (dynamic creds + cert + wrap):
docker compose exec vault grep -E '"path":"(database/creds|pki_int/issue|sys/wrapping/wrap)' \
  /vault/logs/audit.log | wc -l

# Errors only:
docker compose exec vault grep '"error":' /vault/logs/audit.log
```

### Audit log view

(This section is about audit log itself; meta-recursion not interesting.)

### Experiments

**Verify audit fail-closed behaviour:**

```sh
docker compose exec vault chmod 000 /vault/logs/audit.log
vault kv get secret/api-server/config
# Error: 500 (audit device blocked the write)
# (Vault refuses to serve any request that cannot be audited.)

docker compose exec vault chmod 644 /vault/logs/audit.log
vault kv get secret/api-server/config
# OK
```

This demonstrates the production-critical "fail-closed" property: if audit
cannot be written, Vault refuses to operate. Real deployments mitigate this
by configuring multiple audit devices (file + syslog, for example).

---

## 7. `check-status.sh` as cross-feature summary

`check-status.sh` produces a one-shot snapshot of the lab. It runs against
your operator session (the OIDC token in your shell), so the output reflects
the policies you have.

Section-to-feature mapping:

| Section in script        | Feature                              |
|--------------------------|--------------------------------------|
| Container status         | Compose / runtime                    |
| Vault status             | Listener / seal state                |
| Auth methods             | AppRole + OIDC                       |
| Secrets engines          | KV / KV-internal / database / PKI    |
| Policies                 | Per-app + sre-admin + developer      |
| OIDC roles               | sre / developer                      |
| AppRole roles            | 12 per-app machine roles             |
| Database connections     | 4 Postgres backends                  |
| Database roles           | 9 dynamic role definitions           |
| PKI mounts               | Root and intermediate CA certs       |
| Active database leases   | Lease count per role                 |
| Last 5 audit log lines   | Audit device sample                  |
| Application logs         | Per-app observation log              |

Run it twice (initially and after 30m of uptime) to see lease counts grow
and rotation events appear in the app log section.

---

## 8. Disruption experiments

These break the lab in small, recoverable ways to make the failure mode of
each feature observable.

### 8.1 Stop Vault

```sh
docker compose stop vault
docker compose logs --since 30s app-api-server
# Agent token renewal fails; app continues with cached creds until lease
# expires.
docker compose logs --since 30s app-api-server-agent
# agent.auth.handler: error renewing token: Put "https://vault:8200/v1/auth/token/renew-self": dial tcp: connection refused

docker compose start vault
# Agents recover automatically.
```

### 8.2 Restart an agent container (response-wrap exhaustion)

```sh
docker compose restart app-payment-agent
docker compose logs --tail=10 app-payment-agent
# [entrypoint] unwrapping role-id for payment
# Error unwrapping: wrapping token is not valid or does not exist
# Container exits.
```

The only recovery path is to re-run `vault-init` (which would issue fresh
wrap tokens). In a production K8s/Nomad/Ansible setup, the orchestrator
would re-wrap and redeploy.

### 8.3 Revoke a dynamic DB lease

See section 4 experiments.

### 8.4 Rotate a KV value

See section 3 experiments.

### 8.5 Block audit log writes

See section 6 experiments.

### 8.6 Stop a Postgres backend

```sh
docker compose stop postgres-payment
docker compose logs --since 30s app-payment
# {"msg":"db check failed","db":"payment","err":"...connection refused..."}

docker compose start postgres-payment
# When the next lease renewal happens (or the connection is retried), the
# pool recovers.
```

### 8.7 Tear down completely

```sh
docker compose down -v
```

All state (Vault dev-mode storage, audit log, wrap tokens, per-app rendered
volumes) is erased. The next `docker compose up -d` starts fresh: fresh
dev root token (immediately revoked again by `vault-init`), fresh PKI roots,
fresh AppRole secret-ids, fresh dynamic database users.
