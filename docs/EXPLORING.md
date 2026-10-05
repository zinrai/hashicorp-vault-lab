# Exploring

Experiments for the running lab, grouped by Vault feature. Look things up
here; do not read it through. Each decision in [DECIDING](DECIDING.md) links
to the experiment that tests it. Which application uses what is in
[ARCHITECTURE](ARCHITECTURE.md).

Every experiment here shows its result within seconds. The ones that change
the lab say how to put it back, after which `verify.py` passes again.

## Before you start

The lab must be up, as in the [README](../README.md#bring-the-lab-up). Run
`vault` commands on the host, with `VAULT_ADDR` and `VAULT_CACERT` set, and
`docker compose -f compose.yaml` commands in the lab's directory. Some
commands use `jq` on the host.

Pick the session the command needs:

```sh
vault login -method=oidc role=sre        # look
vault login -method=oidc role=developer  # read KV values
vault login -method=oidc role=incident   # stop tokens and leases
```

A few commands change roles or issue credentials by hand. They need an
operator of the Vault, who logs in their own way, and each says so.

Watch an application and its agent:

```sh
docker logs -f app-api-server         # JSON: db check, kv state
docker logs -f app-api-server-agent   # agent login, template renders
```

The audit log is a file on the Vault nodes, not in the lab. Set `ACTIVE` to
the container of the active node, as your Vault's tooling reports it:

```sh
ACTIVE=<container of the active Vault node>
```

## 1. AppRole and response wrapping

Every agent logs in with AppRole. Its role-id and secret-id arrive as
single-use wrap tokens in `bootstrap/<app>/`, mounted at
`/vault-bootstrap/<app>/`.

**Inspect** (as `sre`):

```sh
vault list auth/approle/role             # one role per application
vault read auth/approle/role/api-server
# token_policies [api-server self-renewal], token_no_default_policy true,
# token_ttl 20m, token_max_ttl 2h

docker exec app-api-server-agent ls -la /vault-creds/
# role-id and secret-id: the unwrapped values, in a tmpfs
docker exec app-api-server-agent sh -c 'VAULT_TOKEN=$(cat /tmp/token) vault token lookup'
# policies [api-server self-renewal]
```

### Reuse a wrap token

The agent spent it at startup, so this fails:

```sh
WRAP=$(docker exec app-api-server-agent cat /vault-bootstrap/api-server/role-id.wrap)
VAULT_TOKEN=$WRAP vault unwrap
# Error: wrapping token is not valid or does not exist
```

Anyone who unwrapped it in transit would have caused the same error for the
agent, so a stolen wrap is noticed.

### Restart an agent

```sh
docker restart app-payment-agent
docker logs --tail=5 app-payment-agent
# [entrypoint] unwrapping role-id for payment
# ... wrapping token is not valid or does not exist
```

The container exits. The tmpfs is empty after a restart and the wrap token is
spent. The only recovery is a new delivery, which is the orchestrator's job in
production and `wrap` from the README here. Recover as in
[Replace a credential](#replace-a-credential). Every subject you add is one
more of these to deliver.

## 2. People and their roles

People log in through `local-idp` with one of three roles. What each may do is
in [ARCHITECTURE](ARCHITECTURE.md#people-and-their-roles), and `verify.py`
checks it.

```sh
vault token lookup -format=json | jq -c '.data | {policies, creation_ttl}'
# sre: ["default","sre-admin"], 28800. developer: 28800. incident: 1800.
```

As `developer`:

```sh
vault kv get secret/api-server/config   # works: max-connections=100
vault list database/roles               # permission denied
```

As `sre`:

```sh
vault list database/roles               # works
vault list secret/metadata              # api-server/ auth-service/ payment/ ...
vault kv get secret/api-server/config   # permission denied: shape, not contents
vault audit list                        # works
```

Who may revoke, and who may change what gets issued:

```sh
vault write -f sys/capabilities-self paths=sys/leases/revoke
# developer and sre: [deny]. incident: [update].
vault write -f sys/capabilities-self paths=sys/policies/acl/api-server
# none of the three holds create, update or delete
```

## 3. KV v2

Seven applications read KV. `secret/` and `secret-internal/` are two mounts,
and only `internal-cms` may read `secret-internal/`.

As `developer`:

```sh
vault kv get -field=max-connections secret/api-server/config   # 100
vault kv get -field=max-connections secret/api-server/config   # 100 again
docker exec app-api-server cat /secrets/kv-config.json
# {"max-connections":"100"}
```

The same value on every read: that is what static means.

### Mount isolation

```sh
docker exec app-api-server-agent sh -c \
  'VAULT_TOKEN=$(cat /tmp/token) vault kv get secret-internal/internal-cms/config'
# permission denied: a valid token, but its policy does not reach this mount
```

## 4. Dynamic database credentials

Eleven applications, all but `notification`, get PostgreSQL credentials from
`database/`. Roles, TTLs and consumers are in
[ARCHITECTURE](ARCHITECTURE.md#database-roles).

**Inspect** (as `sre`):

```sh
vault read database/config/postgres-main
# connection_url, allowed_roles. No password: Vault rotated it.
vault read database/roles/payment-short
# default_ttl 10m, max_ttl 10m, creation_statements CREATE ROLE ...
```

Count the leases per role:

```sh
for r in main-readonly main-readwrite main-long payment-short \
         analytics-readonly analytics-readwrite internal-readwrite; do
  printf "%-22s " "$r"
  vault list -format=json sys/leases/lookup/database/creds/$r 2>/dev/null | jq 'length'
done
```

`main-readwrite` holds four leases, one per application that uses it.

Look up one lease:

```sh
LEASE=$(vault list -format=json sys/leases/lookup/database/creds/payment-short | jq -r '.[0]')
vault lease lookup database/creds/payment-short/$LEASE
# issue_time, expire_time, renewable, ttl
```

See the users from the PostgreSQL side. `rolvaliduntil` is the lease's expiry:

```sh
docker exec postgres-main psql -h localhost -U vault-admin -d postgres \
  -c "SELECT rolname, rolvaliduntil FROM pg_roles WHERE rolname LIKE 'v-%'"
```

### Read credentials by hand

As an operator of the Vault, because none of the three roles may read
`database/creds/`:

```sh
vault read database/creds/main-short   # twice: two lease_ids, two usernames
```

Each read created a PostgreSQL user; run the `pg_roles` query above to see
them. `main-short` has no consumer, so the applications' leases are untouched.

### Replace a credential

Give `payment` a new credential, as a new delivery does, and see whether it
carries on without a restart:

```sh
wrap payment
docker compose -f compose.yaml --profile apps up -d --force-recreate app-payment-agent
docker logs --since 1m app-payment | grep -E 'app starting|db pool rotated'
# {"msg":"db pool rotated","db":"payment","username":"v-approle-...", ...}
```

`db pool rotated` and no `app starting`: the application rebuilt its pool with
the new credential. An application that cannot do this cannot run a short
TTL.

### Revoke one lease

Take `api-server`'s lease. The rendered file holds its username, password and
lease_id:

```sh
docker exec app-api-server-agent cat /vault/file/db-main.json
```

Revoke it, as `incident`, and count the users in PostgreSQL:

```sh
vault lease revoke <lease_id>
docker exec postgres-main psql -U vault-admin -d postgres \
  -tAc "select count(*) from pg_roles where rolname like 'v-%'"
# one fewer
```

New logins with it fail:

```sh
docker exec -e PGPASSWORD=<password> postgres-main \
  psql -h 127.0.0.1 -U <username> -d postgres -tAc 'select 1'
# FATAL:  role "v-approle-..." does not exist
```

And the application keeps working on the connection it already holds:

```sh
docker logs --since 1m app-api-server | grep "db check"
# {"msg":"db check ok", ...}
```

Revocation stops new access, not access in flight. To stop an open
connection, end the session in PostgreSQL as well.

Recover now, so `verify.py`'s lease count is right again:

```sh
wrap api-server
docker compose -f compose.yaml --profile apps up -d --force-recreate app-api-server-agent
```

### Revoke by prefix

The shape incident response takes. As `incident`:

```sh
vault list sys/leases/lookup/database/creds/main-readwrite   # four leases
vault lease revoke -prefix database/creds/main-readwrite
docker exec postgres-main psql -U vault-admin -d postgres \
  -tAc "select count(*) from pg_roles where rolname like 'v-%'"
# four fewer
```

Four applications with four AppRole subjects fell to one command, because they
share a template. They keep serving on open connections, as above. Recover
all four:

```sh
for a in api-server auth-service batch-runner webhook-receiver; do wrap "$a"; done
docker compose -f compose.yaml --profile apps up -d --force-recreate \
  app-api-server-agent app-auth-service-agent app-batch-runner-agent app-webhook-receiver-agent
```

## 5. Merge two subjects

Every application is its own subject, so the coarse case has to be built. This
needs an operator of the Vault, because it changes what a role hands out.

Give the `search` role `payment`'s policy too, and hand `payment` wraps from
the `search` role:

```sh
vault write auth/approle/role/search \
  token_policies="self-renewal,search,payment" \
  token_no_default_policy=true token_ttl="20m" token_max_ttl="2h" \
  secret_id_ttl="720h" secret_id_num_uses=0
wrap search
vault read -field=wrapping_token -wrap-ttl=10m \
  auth/approle/role/search/role-id > bootstrap/payment/role-id.wrap
vault write -f -field=wrapping_token -wrap-ttl=10m \
  auth/approle/role/search/secret-id > bootstrap/payment/secret-id.wrap
docker compose -f compose.yaml --profile apps up -d --force-recreate \
  app-search-agent app-payment-agent
```

Compare the two tokens:

```sh
for a in search payment; do
  docker exec app-$a-agent sh -c 'VAULT_TOKEN=$(cat /tmp/token) vault token lookup -format=json' \
    | jq -c '.data | {policies, meta}'
done
# {"policies":["payment","search","self-renewal"],"meta":{"role_name":"search"}}
# {"policies":["payment","search","self-renewal"],"meta":{"role_name":"search"}}
```

Nothing tells the two apart. To stop `payment` you must revoke `search` too,
and the audit log names both as `search`. The subject split is also the unit
of attribution. `verify.py` now fails "one AppRole role per application".

Restore: run `vault-config/configure.sh` as an operator, then:

```sh
wrap search
wrap payment
docker compose -f compose.yaml --profile apps up -d --force-recreate \
  app-search-agent app-payment-agent
```

## 6. PKI

Only `admin-panel` uses PKI. `pki/` holds the root CA, and `pki_int/` the
intermediate it signed. The agent asks `pki_int/issue/admin-panel` for a 1h
certificate for `admin.lab.example.local`.

As `sre`:

```sh
vault read -field=certificate pki/cert/ca | openssl x509 -noout -subject
# lab.example.local Root CA
vault read -field=certificate pki_int/cert/ca | openssl x509 -noout -subject
# lab.example.local Intermediate CA
docker exec app-admin-panel cat /secrets/pki.json \
  | jq -r '.certificate' | openssl x509 -noout -subject -issuer -startdate -enddate
# subject admin.lab.example.local, issuer the intermediate, one hour apart
```

`verify.py` checks that the certificate verifies to the root through the
intermediate.

## 7. Audit log

The Vault's operators enabled the audit device before the lab existed. The
commands assume a `file` device at `/vault/logs/audit.log`. Tokens are HMAC'd
in it (`"client_token":"hmac-sha256:..."`), which `verify.py` checks when
`VAULT_NODES` is set; paths and operations are in clear text.

If Vault cannot write to any audit device, it refuses requests; see
[Audit devices](https://developer.hashicorp.com/vault/docs/audit). That makes
where the log is stored part of the recovery path.

### Who did what

After an OIDC login, the response names the user and the role:

```sh
docker exec $ACTIVE grep '"path":"auth/oidc/oidc/callback"' /vault/logs/audit.log \
  | grep '"type":"response"' | tail -1 | jq -c '{user: .auth.display_name, role: .auth.metadata.role}'
# {"user":"oidc-sre@example.local","role":"sre"}
```

An application's login names its AppRole role, which is all the log knows
about which application it was:

```sh
docker exec $ACTIVE grep '"path":"auth/approle/login"' /vault/logs/audit.log \
  | grep '"type":"response"' | tail -1 | jq -c '.auth.metadata'
# {"role_name":"..."}
```

## 8. Stop the Vault

This acts on the Vault, not on the lab, and stops it for everyone on it. Stop
every node, by whatever means your Vault is run. Then:

```sh
docker logs --since 1m app-api-server | grep "db check"
# {"msg":"db check ok", ...}: the applications keep serving
```

Nothing in a request calls Vault. Start the nodes again by your Vault's own
procedure.
