# hashicorp-vault-lab

A lab environment that reproduces a medium-sized web service organization
where multiple applications interact with HashiCorp Vault. Twelve applications
run on a Vault that runs elsewhere, and you stop one and watch what falls with
it. The Workload Vault of
[hashicorp-vault-sandbox](https://github.com/zinrai/hashicorp-vault-sandbox)
is one such Vault.

## Contents

| Path | What it is |
|------|------------|
| `app/` | The Go application, built by `compose.yaml` into the image `vault-lab-app` |
| `apps/<name>.yaml` | Per-application configuration for `vault-lab-app` |
| `vault-agent-configs/` | Per-application Vault Agent configuration, and `entrypoint.sh`, which unwraps the agent's wrap tokens |
| `compose.yaml` | The lab's containers: four Postgres databases, `local-idp`, and under profile `apps` the 12 agent and application pairs |
| `vault-config/configure.sh` | Configures the lab in Vault, run by an operator of that Vault |
| `vault-config/policies/` | The policies `configure.sh` writes |
| `local-idp/config.yaml` | Dex configuration for the OIDC login |
| `check-status.sh` | Prints a snapshot of the lab |
| `verify.py` | Asserts that the lab matches what the documents claim |
| `docs/` | The documents listed under [Where to start](#where-to-start) |

## Where to start

| Read | When | Document |
|------|------|----------|
| 0 | You want to know what the lab is made of and why | [docs/OVERVIEW.md](docs/OVERVIEW.md) |
| 1 | You want to know how Vault works at all | [docs/CONCEPTS.md](docs/CONCEPTS.md) |
| 2 | You are ready to decide things for your environment | [docs/DECIDING.md](docs/DECIDING.md) |
| 3 | You need the command that shows a particular piece of state | [docs/EXPLORING.md](docs/EXPLORING.md) |
| 4 | You want to compare your answers against this lab's | [docs/RATIONALE.md](docs/RATIONALE.md) |

The intended route is CONCEPTS to understand the vocabulary, DECIDING to write
provisional answers, then the lab to test them, pulling commands from EXPLORING
as needed, and finally RATIONALE to compare.

## Quick start

The lab needs:

- A Vault reachable at `VAULT_ADDR`, with its CA certificate in the file
  `VAULT_CACERT` on the Docker host, set as for the vault CLI. The agents get
  both from the same variables.
- A token of an operator who can configure that Vault, from `vault login`.
- `VAULT_NETWORK`, the Docker network the Vault nodes are on. The lab joins it,
  so the nodes reach the databases and `local-idp` by name.

For example, with hashicorp-vault-sandbox's Workload Vault and this
repository cloned into the sandbox's directory, in the sandbox's shell after
starting the Workload Vault as its README describes:

```sh
cd workload && . ./env                         # VAULT_ADDR, VAULT_CACERT
vault login -method=userpass username=alice    # an operator of that Vault
cd ../hashicorp-vault-lab
export VAULT_NETWORK=hashicorp-vault-sandbox_workload
```

Then, in this directory:

```sh
docker compose -f compose.yaml up -d                # databases and local-idp
vault-config/configure.sh
```

`-f compose.yaml` is not optional when your shell sets `COMPOSE_FILE` to
another project's file, as hashicorp-vault-sandbox's shell does.
`configure.sh` runs with the operator's own token and is safe to run again.

Then hand each agent its wrap tokens, as an orchestrator would: a wrapped
role-id and a wrapped new secret-id, in `bootstrap/<app>/`, which is mounted
into the agent. They are valid for 10 minutes; start the agents within that:

```sh
wrap() {
  mkdir -p -m 0700 "bootstrap/$1"
  vault read -field=wrapping_token -wrap-ttl=10m "auth/approle/role/$1/role-id" > "bootstrap/$1/role-id.wrap"
  vault write -f -field=wrapping_token -wrap-ttl=10m "auth/approle/role/$1/secret-id" > "bootstrap/$1/secret-id.wrap"
}
for f in apps/*.yaml; do wrap "$(basename "$f" .yaml)"; done

docker compose -f compose.yaml --profile apps up -d --build  # 12 agent and app pairs
```

A wrap is single-use, so a restarted agent fails. Hand it new wraps and
recreate it:

```sh
wrap <name>
docker compose -f compose.yaml --profile apps up -d --force-recreate app-<name>-agent
```

## Operator login

The lab's people log in with OIDC; the Vault's operators, who configure it,
keep their own logins:

```sh
vault login -method=oidc role=sre        # sre@example.local / srepass
```

Three operator roles exist, and they are deliberately not the same:

| Role | Policy | Can look | Can stop | Can change what gets issued |
|------|--------|----------|----------|-----------------------------|
| `developer` | `developer-readonly` | KV only | no | no |
| `sre` | `sre-admin` | broadly | no | no |
| `incident` | `incident-response` | enough to pick a target | yes | no |

Operator tokens live 8h (`incident` 30m). Application tokens live 20m. The
second user is `developer@example.local` / `devpass`; either user may select
any role.

Any experiment that stops a token or a lease needs
`vault login -method=oidc role=incident`.

The browser has to reach `local-idp:5556`, and the CLI listens for the
callback on `localhost:8250`. `local-idp` is published on `127.0.0.1:5556` of
the Docker host, so make `local-idp` resolve to `127.0.0.1` on the browser's
machine. On a remote host, also forward both ports:

```sh
ssh -L 8250:localhost:8250 -L 5556:localhost:5556 <host>
```

## Checking the lab

Run both in this directory, with `VAULT_ADDR`, `VAULT_CACERT` and
`VAULT_NETWORK` set as in [Quick start](#quick-start).

Snapshot the lab:

```sh
./check-status.sh
```

Assert that it matches what the documents claim:

```sh
vault login -method=oidc role=sre       && export VAULT_TOKEN_SRE=$(vault print token)
vault login -method=oidc role=developer && export VAULT_TOKEN_DEV=$(vault print token)
vault login -method=oidc role=incident  && export VAULT_TOKEN_INC=$(vault print token)
./verify.py
```

`check-status.sh` prints and leaves the reading to you. `verify.py` makes
claims and exits non-zero when they are false; it needs only Python 3 and,
for the certificate chain, OpenSSL. Its audit check reads the
audit log on the Vault nodes, which the lab does not run, and is skipped
unless `VAULT_NODES` lists those nodes' containers.

Watch an application. The containers have fixed names, so this works from
any directory:

```sh
docker logs -f app-api-server         # JSON: db check, kv state
docker logs -f app-api-server-agent   # Agent auth, template renders
```

The audit log is on the Vault nodes, not in the lab; see
[EXPLORING 6](docs/EXPLORING.md#6-audit-log).

## Stopping the lab

```sh
docker compose -f compose.yaml --profile apps down -v
```

The lab is its own Compose project, so this removes only the lab: its
containers, its databases and the 12 `<app>-rendered` volumes. What
`configure.sh` wrote to Vault stays, and so does the Vault itself.

To start again, remove the database connections first, as an operator of the
Vault. Vault rotated a password the new databases never had:

```sh
vault lease revoke -force -prefix database/creds/
for db in main payment analytics internal; do
  vault delete database/config/postgres-$db
done
```

Then bring the lab up as in [Quick start](#quick-start).

## License

This project is licensed under the [MIT License](./LICENSE).
