# Rationale

This lab's answers to the seven decisions in [DECIDING](DECIDING.md), with
the reasons for each. Look up a decision here after you have written and
tested your own answer. Where they differ, one of you has a reason the other
does not. The end of this page states what the lab leaves out and where it
simplifies.

The aim behind every answer: twelve applications use Vault at once, with the
patterns a medium-sized web service organization would use.

## 1. What goes into Vault

Database credentials, one application certificate, and the static secrets
that remain: third-party API keys, a JWT signing key, and configuration. All
values are dummies.

**Two KV mounts.** `secret/` holds what most applications read.
`secret-internal/` is a separate mount that only `internal-cms` may read. A
mount is the simplest boundary between tenants. `verify.py` checks that
another application's token cannot reach it.

**PKI in two tiers, with one consumer.** `pki/` holds the root CA and signs
only the intermediate in `pki_int/`. `admin-panel` gets its certificates from
`pki_int/`. One online CA would have worked, but production PKI is almost
always tiered, with the root kept offline, and a lab should not teach the
pattern that does not survive production. `verify.py` checks the chain. There
is only one consumer on purpose: a second would make the intermediate a shared
template, the trap `main-readwrite` already shows.

**A catalog of database roles.** Nine roles vary by read or write, database,
and TTL. Two, `main-short` and `analytics-long`, have no consumer. They give
operators ready-made roles for issuing credentials by hand, as a real
inventory would. `verify.py` checks every role's database and TTLs.

## 2. What counts as one subject

One subject per application: twelve applications, twelve AppRole roles, each
with `token_policies="self-renewal,<app>"`. `verify.py` checks all twelve.

**Templates shared on purpose.** Subjects are separate, but templates are not
always. `main-readonly` is shared by `web-frontend`, `admin-panel` and
`search`, because there is no case where stopping `search` should leave the
other two running. `main-readwrite` is shared by four applications to make the
cost visible: one revoke stops all four.

## 3. How subjects authenticate

AppRole, with the role-id and a new secret-id delivered as response-wrapped
tokens with a 10 minute wrap TTL. `configure.sh` creates the roles but issues
no secret-id: delivery is the deployment's job. The agent's entrypoint unwraps
once at first start, writes the values to a tmpfs at `/vault-creds`, and starts
`vault agent`.

**The delivery mirrors an orchestrator.** In production, Ansible, Nomad or a
Kubernetes controller holds the wrap token between issue and use. Here `wrap`
in the README plays that part.

**A restarted agent fails, on purpose.** The tmpfs is cleared on restart, and
the spent wrap cannot be unwrapped again. Keeping the unwrapped values in a
volume would make restarts "just work", and would teach that secret zero is a
storage problem. It is a delivery problem, solved by delivering again.

## 4. Static or dynamic

Dynamic for every database, static (KV) for everything else. Vault has an
engine that can create PostgreSQL users. The lab has none for the third-party
services behind the KV values, so those stay static.

## 5. TTL

**Application tokens:** 20 minutes, renewable up to 2 hours.

**Database credentials:** 1 hour, renewable up to 24 hours, as the standard.
Two applications differ, and the reasons are also in their policy files:

- `payment` uses `payment-short`, 10 minutes with `max_ttl` equal to
  `default_ttl`, so each credential is replaced rather than renewed. Payment
  data is the one thing here worth a 10 minute exposure window, and `payment`
  rebuilds its pool without a restart. Both must hold before a short TTL is
  worth it.
- `etl` uses `main-long`, 8 hours. A batch run can outlive a 1 hour lease, and
  a credential that expires mid-run fails the job. Its `analytics-readwrite`
  stays at 1 hour, because those writes are incremental and can restart.

**Certificates:** 1 hour, within the role's 24 hour maximum.

**People:** `sre` and `developer` tokens live 8 hours, a working day.
`incident` lives 30 minutes. Without an explicit TTL they would get Vault's
32 day default, and people holding month-long tokens next to 20 minute
application tokens would teach the opposite of the point.

`verify.py` checks each of these except the certificate, whose expiry
[EXPLORING](EXPLORING.md#6-pki) shows.

## 6. Who can change issuance settings

The Vault's operators, by name. They log in as themselves, run
`vault-config/configure.sh` with their own token, and the Vault's audit device
records each change. Nobody uses a root token. None of the lab's three OIDC
roles can change what gets issued, which `verify.py` checks.

This has a cost: `check-status.sh`, `verify.py` and any direct `vault` use
need an OIDC login first. A root-token shortcut would remove the friction and
give a quiet path that does not match production.

**Revocation is separate from observation.** `sre-admin` reads broadly and can
list leases, but cannot revoke. Revocation is in `incident-response`, reached
through a separate role, `incident`, with a shorter TTL. A session used for
looking should not be able to stop production, and the split lets the audit
log tell looking from acting. `incident-response` can stop what runs now, but
cannot change what gets issued next. The cost is a second login during an
incident.

**Operators see the shape of KV, not its contents.** `sre-admin` grants KV
metadata, not values. An SRE can see which secrets exist and how many
versions they have, but cannot read a value; `developer-readonly` can. If the
operator held the values, one compromised operator session would expose every
secret.

**Application tokens carry no implicit policy.** The AppRole roles set
`token_no_default_policy=true`, so an application token lists only
`api-server` and `self-renewal`, both files in `vault-config/policies/`. The
shared one is named after what it grants, so anything added to it that is not
about renewing your own credentials looks wrong at once. Operator tokens still
carry `default`, because they use parts of it, such as
`sys/capabilities-self`, that no lab policy declares.

## 7. Where unseal trust lives

Not answered by the lab. It belongs to whoever runs the Vault underneath; see
[Seal/Unseal](https://developer.hashicorp.com/vault/docs/concepts/seal). Do not
read its absence here as "not applicable": it is the more expensive of the two
high-cost decisions.

## Scope

The lab covers how applications and people use Vault. Operating the Vault
itself is somebody else's job, as in most organizations. The lab takes from
the Vault side what any application team gets: an address (`VAULT_ADDR`), a
CA (`VAULT_CACERT`), a network, and an operator to configure it. Taking the
lab down cannot take the Vault with it.

Out of scope, by intent:

- HA topology, storage, upgrades.
- Sealing, unsealing, root token generation and rekeying.
- TLS for Vault's own listener. The lab's PKI issues application certificates
  only.
- mTLS between Agent and Vault.
- Kubernetes auth, sidecar injectors and CSI drivers. The lab is
  Compose-shaped on purpose.

## Lab simplifications

A simplification is acceptable if applications and people still see the same
surface as in production. It is not if a reader would learn the simplified
form as the right pattern.

- **All lab containers run as root.** The agent still writes rendered files
  with mode `0400`. The point taught is files instead of environment
  variables: an environment variable is visible to child processes and
  `/proc/<pid>/environ`, and a file is not. Separate users for agent and
  application would not change anything on the Vault side.
- **Applications connect to PostgreSQL with `sslmode=disable`.** Production
  would use TLS there too. It does not change the Vault patterns.
- **`local-idp` is a small Dex with two static users** and one client, `vault`,
  with only the CLI callback, so there is no UI login. Group claims are not
  used. Vault and the browser must reach it by one name,
  `http://local-idp:5556/dex`, which is why the README asks the browser's
  machine to resolve `local-idp`. Vault names users by email, so the audit
  log shows a name a person can read.
- **The OIDC roles are not bound to people.** Either user may select any of
  the three. In production the role a person may take is bound to their
  identity, and `incident` would be a break-glass path with detection.
