# Rationale

This document records the design decisions that shape `hashicorp-vault-lab`.
For *how to run* the lab, see [`../README.md`](../README.md); for *what it
is made of*, [OVERVIEW.md](OVERVIEW.md). For *how to
inspect* it once running, see [EXPLORING.md](EXPLORING.md). This document
answers *why the lab has the shape it does*.

Each section states the chosen shape and the reason that shape supports the
lab's claim. The claim, restated:

> A working dataplane in which 12 applications use Vault concurrently with
> the patterns a real medium-sized web service organization would use.

Everything below follows from that.

## Read this as one worked answer

[DECIDING.md](DECIDING.md) sets out seven decisions that anyone adopting Vault
has to make for their own environment. This lab is **one answer to them**, not
the answer. Reading this document alongside your own provisional answers is the
point: where they differ, one of you has a reason the other does not.

| Decision | Answered by |
|----------|-------------|
| 1. What goes into Vault | [PKI as two tiers, one consumer](#pki-as-two-tiers-one-consumer), [Database role TTLs as a combination catalog](#database-role-ttls-as-a-combination-catalog) |
| 2. What counts as one subject | [Application shape: one Go binary, twelve configurations](#application-shape-one-go-binary-twelve-configurations) |
| 3. How subjects authenticate | [Bootstrap shape: response wrap with tmpfs](#bootstrap-shape-response-wrap-with-tmpfs) |
| 4. Static or dynamic | [Database role TTLs as a combination catalog](#database-role-ttls-as-a-combination-catalog) |
| 5. TTL | [Database role TTLs as a combination catalog](#database-role-ttls-as-a-combination-catalog) |
| 6. Who can change issuance settings | [Operator workflow: OIDC only, no root fallback](#operator-workflow-oidc-only-no-root-fallback), [Revocation is separated from observation](#revocation-is-separated-from-observation) |
| 7. Where unseal trust lives | Answered by whoever runs the Vault underneath this lab, see [Scope and the two-repo split](#scope-and-the-two-repo-split) |

Decision 7 is answered by the cluster the lab runs on, not by the lab, and it
is the more expensive of the two high-cost ones. Do not read its absence from
this document as "not applicable".

---

## Scope and the two-repo split

`hashicorp-vault-lab` covers application ↔ Vault interaction. Operating the
Vault it runs on is someone else's job: with
[`hashicorp-vault-sandbox`](https://github.com/zinrai/hashicorp-vault-sandbox),
that repository's, whose Workload Vault is one Vault the lab runs on. Two
narrow repositories, paired by the operational division they reflect: the lab
is configured on the Vault by its operators, the way any team's applications
would be.

Real organizations operate these two surfaces with different teams, different
risk tolerances, and different change cadence. The dataplane changes when
applications change; the controlplane changes when Vault is upgraded,
re-sealed, scaled, or restored. Combining both into one lab would force every
reader to absorb both axes before getting useful insight on either. Keeping
the labs narrow lets each one carry a sharper teaching point.

The split runs through the containers too. The lab has its own `compose.yaml`,
a Compose project of its own, and joins the Docker network the Vault nodes are
on (`VAULT_NETWORK`) rather than being defined alongside them. What it takes
from the Vault side is what any application team gets: an address
(`VAULT_ADDR`), a CA to verify it (`VAULT_CACERT`), a network to reach it, and
an operator to configure it. The Vault side knows nothing of the applications,
as with different teams in production: neither has to change when the other
does, and taking the lab down cannot take the Vault with it.

The split also matches how the OSS Vault documentation itself is organized:
Agent / AppRole / database / PKI material is dataplane-shaped; cluster
operation, seal mechanisms, raft membership, and recovery procedures are
controlplane-shaped.

---

## Why the lab runs on a real cluster

The lab has no Vault of its own. It runs on a Vault that someone else operates,
reached over TLS at `VAULT_ADDR`, which keeps its state across restarts, has no
root token in use, and records changes in an audit device the lab did not
enable. A load-bearing question remains: *which simplifications are acceptable
and which are not?*

The criterion this lab applies:

> A simplification is acceptable if applications and operators still see the
> same surface shape as in production. A simplification is unacceptable if a
> reader would internalize the simplified form as the canonical pattern.

Running on a real cluster passes that test for the dataplane without
exceptions on the Vault side:

- Applications connect to Vault over HTTPS and verify a real X.509 chain
  against the Vault's CA. Where Vault is comes from the deployment's
  environment (`VAULT_ADDR`, `VAULT_CACERT`), not from the lab's agent
  configuration, so failover is handled behind that address, not in the
  lab.
- The CA distribution problem (operator needs to obtain the CA to use the
  Vault CLI) is reproduced realistically: `VAULT_CACERT` has to point at the
  Vault's CA, for the operator's CLI and for every agent.
- Configuration survives restarts and failover, and changes to it are made by
  named operators under an audit device the lab did not enable and cannot
  change.

What the cluster does underneath (sealed startup, key custody, storage
initialization, HA membership) is the surface its operators cover, and
`hashicorp-vault-sandbox` exists to cover for its Vault. The lab uses it and
does not re-explain it.

By the same criterion, `sslmode=disable` on app↔Postgres connections is
called out in [OVERVIEW.md](OVERVIEW.md#lab-simplifications) as a known
simplification: Postgres listener TLS is orthogonal to the Vault patterns
being demonstrated.

---

## Bootstrap shape: response wrap with tmpfs

The deployment distributes each agent's `role-id` and a new `secret-id` as
response-wrapped tokens (wrap TTL 10m). `vault-config/configure.sh` creates
the AppRole roles but issues no secret-id: handing them to the agents is the
deployment's job. The agent's entrypoint script
unwraps once at first start, writes the resulting values to a per-container
`tmpfs` at `/vault-creds`, and exec's `vault agent`.

Three properties of this shape are deliberate:

**The delivery channel mirrors a real orchestrator.** Response wrap is the
canonical Vault answer to the AppRole "secret zero" problem. In production,
Ansible (or Nomad, or a Kubernetes controller) holds the wrap token between
issuance and consumption. In this lab, the operator plays that role by
hand: `wrap` in the README writes the wraps to the lab's `bootstrap/<app>/`,
mounted read-only into each agent at `/vault-bootstrap/<app>/`.

**Single-use is preserved.** The wrap is consumed the moment the agent
unwraps it. The wrap token file in the bootstrap directory becomes a dead
artifact. A reader who tries `vault unwrap` on it gets
"wrapping token is not valid or does not exist". This is the truth that
production wrap tokens behave this way, expressed in lab time.

**Container restart fails by design.** `/vault-creds` is a `tmpfs`; restart
clears it and the entrypoint re-tries unwrap, which fails because the wrap
is consumed. Persisting unwrapped credentials in a named volume would make
restart "just work", and would teach readers that secret zero is a
filesystem problem to be solved with persistence, when in fact it is an
orchestrator problem to be solved with re-provisioning: here,
`wrap` and recreating the agent. The failure mode is the
lesson.

---

## Application shape: one Go binary, twelve configurations

The 12 applications share a single binary under `app/`, parameterised by
per-app YAML under `apps/`. Each instance is a real long-running process
holding a real `pgxpool`, real KV state, and (for `admin-panel`) a real
parsed cert.

The driving constraint: a medium-sized web service organization does not
have one real service and eleven shell loops. It has many real services,
each consuming a different combination of Vault features. The lab's claim
about resolution depends on the 12 instances being uniform in their
relationship to the operator (logs, lifecycle, observation surface) while
varying in their Vault footprint.

A single binary serves this:

- Reader-facing complexity is bounded: there is one `main.go` to read, not
  twelve.
- The "combination catalog" property (see below) sits cleanly in the YAML:
  add an app by writing a config file.
- The credential rotation behaviour (pool drain + rebuild on
  `creds_file` change) is implemented once and demonstrated 12 times.

---

## Why all containers run as root

Both the Vault Agent containers and the application containers run as root.
The Vault Agent templates write rendered files with `perms = "0400"`. The
mode is preserved as a documentation of intent, but the owner is root.

The teaching point of the file-rendering pattern is *file-based credential
delivery in place of environment-variable injection*. With env-var
injection, the credential is visible to `ps`, to anyone reading
`/proc/<pid>/environ`, and to children of the process. With file delivery
plus `perms = 0400`, the credential is bound to a single readable identity
and never appears in the process's environment.

That teaching point is preserved even when both containers run as root: the
credential lives in a file, not in `env`, and `0400` advertises the intent.
The separate question of UNIX user isolation between Agent and app is a
distinct axis. Pulling it into this lab would require either build-time
user provisioning in the application image or runtime `chown` gymnastics
on shared volumes; neither contributes to the Vault-shape resolution that is
the lab's actual claim.

[OVERVIEW.md](OVERVIEW.md#lab-simplifications) flags this as a known lab simplification. The production
counterpart (a non-root app user reading the rendered file) is a small
add-on that does not change the Vault-side shape.

---

## Database role TTLs as a combination catalog

The 9 database roles vary along several axes intentionally:

| Axis             | Roles                                                                 |
|------------------|-----------------------------------------------------------------------|
| Read vs write    | `*-readonly` vs `*-readwrite`                                         |
| Postgres backend | `main` (3 roles) / `payment` / `analytics` (3 roles) / `internal`     |
| TTL profile      | short (10m / 15m) / standard (1h) / long (8h)                         |

Two roles (`main-short`, `analytics-long`) have no application consumer.
They are not orphans; they exist to keep the catalog complete along its
axes, and to give operators ready-made roles for ad-hoc credential
issuance during exploration. Trimming them to "only what an app uses"
would distort the picture of what a real Vault deployment's database
role inventory looks like.

The `payment-short` role uses `default_ttl = max_ttl = 10m`. This is the
one role tuned for lab observability rather than production realism: with
`max_ttl > default_ttl`, the Vault Agent would renew the same lease until
the ceiling was hit, and credential re-issuance (the event the lab most
wants to make visible) would only fire near the 1h mark. Tightening
`max_ttl` to match `default_ttl` collapses the renewal loop and forces
re-issuance at the 10m mark. Other roles keep the conventional
"`default_ttl` < `max_ttl`" relationship so a reader can also observe the
renewal-cycle path.

The mount-level ceiling (`database` mount tuned to `max_lease_ttl = 24h`)
exists as a system-wide backstop; it bounds storage growth from
accumulated leases, independent of per-role tuning.

---

## PKI as two tiers, one consumer

`pki/` holds the root CA. `pki_int/` holds the intermediate CA, signed by
`pki/` the first time `configure.sh` runs. The single application that issues end-entity
certificates (`admin-panel`) does so against `pki_int/issue/admin-panel`,
not against `pki/`.

A single-CA PKI would have been simpler to implement and would have worked
for the one consumer. The reason for the two-tier shape is the same as the
reason for the lab's overall framing: showing one consumer the wrong
canonical pattern is worse than showing them the right one. Production
Vault PKI is almost always tiered (root offline or air-gapped, intermediate
online); a lab that demonstrates Vault PKI with a single online CA risks
teaching a pattern that does not survive contact with a production
deployment.

The intermediate sees only one consumer because the lab's overall principle
is the combination catalog: each application exists to demonstrate a
distinct combination of Vault features, and only `admin-panel` is the
"PKI + DB" combination. Adding a second PKI consumer for symmetry would
either duplicate an existing combination or invent one that doesn't add
operational insight.

`admin-panel`'s role uses `ttl = 1h`. Vault Agent re-renders the PKI
template at approximately 50% of cert lifetime, so a reader observes a
rotation event every ~30 minutes of lab uptime.

---

## Operator workflow: OIDC only, no root fallback

Nobody uses a root token with this lab. `configure.sh` runs with the token of
an operator of the Vault who logged in as themselves (with
hashicorp-vault-sandbox, userpass and policy `admin`), so configuring the lab
is a change like any other, by someone, under audit. Everything done *with* the lab goes
through OIDC: the three roles (`sre`, `developer`, `incident`) give three
policy surfaces to compare.

Two consequences of this choice:

- `check-status.sh`, `verify.py` and any direct `vault` CLI use require a
  prior `vault login -method=oidc`. The lab does not provide a way to bypass.
- The browser-callback dependency is real. The browser has to reach
  `local-idp:5556` and the CLI listens on `localhost:8250`, so on a remote
  host both have to be forwarded.

Keeping a root-token shortcut alongside would have removed the friction, at
the cost of giving operators a quiet path that does not match production. In
production, root tokens exist as recovery instruments, generated via key
quorum and revoked once their purpose is served, for what the operators' own
policies cannot do, such as changing an audit device. That belongs to the
Vault underneath, not to the lab.

---

## The shared policy is named after its grant, not its position

The policy every application token carries is called `self-renewal`, not
`base` or `common` or `default-app`.

Vault has no policy inheritance. A token's permissions are the union of its
policies, with `deny` winning. A name like `base` implies a hierarchy the system
does not implement, and someone who reads it as inheritance will assume a more
specific policy can narrow it. Nothing can. Whatever goes in the shared policy
is granted to every holder, permanently, until it is removed there.

That makes the shared policy the single place where a careless addition has
maximum blast radius, and a name meaning "the shared one" removes the friction
that would make someone hesitate. Anything vaguely universal qualifies for
admission, and the file becomes a junk drawer that quietly widens every token.
Vault's own `default` policy is the cautionary example: it has accreted
identity paths, OIDC provider endpoints, control-group status and hashing tools
across releases, and nobody attaching it is choosing those.

Naming it after the grant inverts the pressure. `self-renewal` contains only
paths for keeping your own token and your own leases alive, and a proposal to
add `secret/data/*` to a file with that name is visibly wrong before anyone has
to argue about blast radius.

This is not a HashiCorp-blessed pattern. There is no canonical "base policy"
convention in Vault, only a widespread habit of collecting shared grants
somewhere. The habit is fine. The naming is what decides whether it stays small.

---

## Application tokens carry no implicit policy

The AppRole roles set `token_no_default_policy=true`, so an application token
lists only `self-renewal` and its own policy. Reading
`["api-server" "self-renewal"]` tells you
exactly which two files in `vault-config/policies/` govern that token.

The alternative was the Vault default, where every token silently also carries
the built-in `default` policy. `default` cannot be renamed, so
`["default" "self-renewal" "api-server"]` leaves a reader with one entry they
look up in this repository and no indication of what it grants.

Worse, it hid a redundancy. Every grant in `self-renewal` is also in
`default`, so until this changed the shared policy was adding nothing to any
application token. Turning `default` off makes it load-bearing and makes the
omission visible if it ever stops being sufficient.

Operator tokens still carry `default`. They genuinely use parts of it that no
lab policy declares, `sys/capabilities-self` and `cubbyhole/*` and the
`sys/wrapping/*` family among them, and copying those into three operator
policies would trade one kind of opacity for a worse one. The asymmetry is
deliberate, and it is the reason `vault token lookup` shows
`["default" "sre-admin"]` for a human and `["api-server" "self-renewal"]` for a
machine.

Operator tokens are bounded on the same reasoning. `sre` and `developer` set
`token_ttl=8h`, a working day, and `incident` sets 30m. Without an explicit
`token_ttl` these inherit Vault's 32 day default, and a lab whose applications
hold 20 minute tokens while its operators hold month-long ones teaches the
opposite of its own point.

---

## local-idp is Dex

`local-idp` is [Dex](https://dexidp.io/), configured by
`local-idp/config.yaml`. Its issuer is configurable, `http://local-idp:5556/dex`,
and every endpoint it advertises in its discovery document is under that
issuer.

That matters because the OIDC flow reaches the IdP from two places. The
browser reaches it for the authorize step. Vault reaches it for the
server-side token exchange, and on a cluster that can be any of its nodes.
Both sides have to agree on one name. On `VAULT_NETWORK` the nodes resolve
`local-idp` directly; on the browser's machine, `local-idp` resolves to
`127.0.0.1`, where the Docker host publishes port 5556 (forwarded over SSH on a
remote host). `oidc_discovery_url` in
`configure.sh` and the issuer in Dex's configuration are the same URL, so
every URL in the flow agrees.

Dex keeps its state in memory and holds one client, `vault`, with the CLI
callback only, and two static users. The Vault roles name users by
`user_claim=email`, because Dex's own `sub` is an opaque encoding nobody can
read in an audit trail.

The cost is one more component with its own configuration file, small enough
to read in full. In exchange, local-idp has its own network identity and
survives anything done to the Vault nodes.

---

## Operators can see the shape of KV, not its contents

`sre-admin` grants `secret/metadata/*` and `secret-internal/metadata/*`, and
does not grant `secret/data/*`. An SRE session can list which secrets exist,
when they were written and how many versions they have, and cannot read a
single value.

```sh
vault login -method=oidc role=sre
vault list secret/metadata               # api-server/ auth-service/ payment/ ...
vault kv get secret/api-server/config    # permission denied
```

The broadest routine operator role in the lab is therefore not the one that can
read secrets. `developer-readonly` is, within its narrower path set.

Operating a secrets system and being entitled to its contents are different
jobs. An operator debugging a lease, checking a rotation, or auditing which
applications hold what needs the shape. They do not need the values, and if
they hold them, then compromising the operator session compromises every secret
at once regardless of how carefully the application policies were written.

The cost is that `vault kv get` in a walkthrough needs `role=developer`, which
is easy to trip over. That friction is the point being demonstrated.

---

## Revocation is separated from observation

`sre-admin` is read-only. It can list and read across mounts and it can look up
leases, but it holds no `sys/leases/revoke`, no `sys/leases/revoke-prefix`, and
no `auth/token/revoke-accessor`. Revocation lives in a separate policy,
`incident-response`, reached through a separate OIDC role, `incident`, with a
shorter token TTL.

This shape exists for two reasons.

**A session used for looking should not be able to stop production.** Most
operator time is spent inspecting. Carrying revocation authority through all of
it means a mistyped prefix takes down four applications. Splitting the roles
also makes the audit log distinguish looking from acting, which is the record
you want after an incident.

**Stopping and re-issuing are different powers.** `incident-response` can stop
what is currently running. It cannot write `sys/policies/acl/*` or
`auth/*/role/*`, so it cannot change what gets issued next. A token that can do
the latter can rewrite a role's policies inside its own TTL, and the original
token dying does not stop the rewritten role from issuing new ones. Bounding
damage by time fails at that one point, so the lab keeps that power out of
every session of its three OIDC roles. It belongs to the Vault's operators,
by name: they log in as themselves, `configure.sh` runs with their token, and
the Vault's audit device records who changed what.

The cost is a third login. Re-authenticating in the middle of an incident is
friction, and in a real deployment that friction is the argument for a
break-glass path with detection rather than for merging the policies.

Without this split, nothing in the lab could revoke anything at all, and the
mechanism the lab exists to demonstrate would be unobservable.

---

## Scope boundary

The following are out of scope for this lab. The boundary is stated, not
elaborated; each item belongs to whoever runs the Vault (with the example
Vault, `hashicorp-vault-sandbox`) or to independent operator practice. The lab
runs on the first four but does not explain them.

- **HA topology**: Raft / Consul / Integrated Storage configuration,
  membership operations.
- **Seal / unseal**: manual and auto-unseal, and the custody of the keys
  behind them.
- **Root token recovery**: `vault operator generate-root` driven by key
  quorum.
- **Vault listener TLS**: certificate provisioning for the Vault listener
  itself (the PKI hierarchy in this lab issues application certificates
  only).
- **Vault upgrades and migrations**: version stepping, raft snapshot
  handling, post-upgrade verification.
- **mTLS for Agent ↔ Vault**: AppRole already authenticates the Agent;
  adding mTLS at the transport layer is a defence-in-depth choice whose
  cost/value depends on the surrounding threat model.
- **Kubernetes integration**: this lab is docker-compose-shaped on
  purpose. K8s auth methods, sidecar injectors, and CSI drivers are a
  separate set of patterns.

Items in this list are not "missing features" to be added later. They are
material that lives elsewhere by intent.
