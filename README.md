# hashicorp-vault-lab

Adopting HashiCorp Vault forces decisions that nothing in normal operation
grades: what counts as one subject, how long a credential lives, who may
change what gets issued. A wrong answer keeps working until something leaks.
This lab lets you test your answers first. Twelve applications use a real
Vault the way a medium-sized web service organization would. You can stop
one of them, revoke what it holds, and see within seconds what falls with it.

Along the way you get a working example of AppRole with response wrapping,
Vault Agent, dynamic PostgreSQL credentials, a two-tier PKI, KV, OIDC login
for people, policies and audit logging, and a script that checks what the
documents claim about it.

The lab has no Vault of its own. It runs against a Vault that runs elsewhere.
The Workload Vault of
[hashicorp-vault-sandbox](https://github.com/zinrai/hashicorp-vault-sandbox)
is one such Vault.

## How to use it

1. If Vault's vocabulary is new to you, read
   [docs/CONCEPTS.md](docs/CONCEPTS.md) first.
2. Read [docs/DECIDING.md](docs/DECIDING.md) and write down a provisional
   answer to each of its seven decisions for your own organization.
3. Bring the lab up (below) and test each answer. Where the lab can test a
   decision, it links to the experiment in
   [docs/EXPLORING.md](docs/EXPLORING.md).
4. Compare your answers with this lab's in
   [docs/RATIONALE.md](docs/RATIONALE.md). Where they differ, one of you has a
   reason the other does not.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) lists which application uses
what.

## Requirements

- Docker with Compose, the `vault` CLI, and a browser for OIDC login.
- A Vault reachable at `VAULT_ADDR`, with its CA certificate in the file
  `VAULT_CACERT` on the Docker host, set as for the vault CLI. The agents get
  both from the same variables.
- A token of an operator who can configure that Vault, from `vault login`.
- `VAULT_NETWORK`, the Docker network the Vault nodes are on. The lab joins it,
  so the nodes reach the databases and `local-idp` by name.
- For `verify.py`: Python 3 and, for the certificate chain check, OpenSSL.

## Bring the lab up

Run everything in this directory. Always pass `-f compose.yaml`: a
`COMPOSE_FILE` in your shell may name another project's file.

Start the databases and `local-idp`, then configure Vault. `configure.sh` runs
with the operator's own token and is safe to run again:

```sh
docker compose -f compose.yaml up -d                # databases and local-idp
vault-config/configure.sh
```

Hand each agent its wrap tokens, as an orchestrator would: a wrapped role-id
and a wrapped new secret-id, in `bootstrap/<app>/`, which is mounted into the
agent. They are valid for 10 minutes, so start the agents within that:

```sh
wrap() {
  mkdir -p -m 0700 "bootstrap/$1"
  vault read -field=wrapping_token -wrap-ttl=10m "auth/approle/role/$1/role-id" > "bootstrap/$1/role-id.wrap"
  vault write -f -field=wrapping_token -wrap-ttl=10m "auth/approle/role/$1/secret-id" > "bootstrap/$1/secret-id.wrap"
}
for f in apps/*.yaml; do wrap "$(basename "$f" .yaml)"; done

docker compose -f compose.yaml --profile apps up -d --build  # 12 agent and app pairs
```

A wrap token works once, so a restarted agent fails. This is on purpose (see
[RATIONALE](docs/RATIONALE.md#3-how-subjects-authenticate)). Hand it new
wraps and recreate it:

```sh
wrap <name>
docker compose -f compose.yaml --profile apps up -d --force-recreate app-<name>-agent
```

## Log in as a person

People log in to the lab's Vault configuration with OIDC, through `local-idp`.
The Vault's operators keep their own logins.

```sh
vault login -method=oidc role=sre        # sre@example.local / srepass
```

The roles are `sre`, `developer` and `incident`. The second user is
`developer@example.local` / `devpass`, and either user may select any role.
What each role may do is in
[ARCHITECTURE](docs/ARCHITECTURE.md#people-and-their-roles).

The browser has to reach `local-idp:5556`, and the CLI listens for the
callback on `localhost:8250`. `local-idp` is published on `127.0.0.1:5556` of
the Docker host, so make `local-idp` resolve to `127.0.0.1` on the browser's
machine. On a remote host, also forward both ports:

```sh
ssh -L 8250:localhost:8250 -L 5556:localhost:5556 <host>
```

## Check the lab

Run both in this directory, with `VAULT_ADDR`, `VAULT_CACERT` and
`VAULT_NETWORK` set.

`check-status.sh` prints a snapshot and leaves the reading to you. It uses your
current token, so it shows what your role may see:

```sh
./check-status.sh
```

`verify.py` checks the claims the documents make, and exits non-zero when one
is false. It needs a token for each role:

```sh
vault login -method=oidc role=sre       && export VAULT_TOKEN_SRE=$(vault print token)
vault login -method=oidc role=developer && export VAULT_TOKEN_DEV=$(vault print token)
vault login -method=oidc role=incident  && export VAULT_TOKEN_INC=$(vault print token)
./verify.py
```

Its audit check reads the audit log on the Vault nodes, which the lab does not
run. It is skipped unless `VAULT_NODES` lists those nodes' containers.

## Stop the lab

```sh
docker compose -f compose.yaml --profile apps down -v
```

This removes only the lab: its containers, its databases and the 12
`<app>-rendered` volumes. What `configure.sh` wrote to Vault stays, and so
does the Vault itself.

To start again, first remove the database connections, as an operator of the
Vault. Vault rotated a password the new databases never had:

```sh
vault lease revoke -force -prefix database/creds/
for db in main payment analytics internal; do
  vault delete database/config/postgres-$db
done
```

Then bring the lab up as above.

## License

This project is licensed under the [MIT License](./LICENSE).
