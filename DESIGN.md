# Design

This document records the design decisions that shape `hashicorp-vault-lab`.
For *how to run* the lab, see `README.md`. For *how to inspect* it once
running, see `EXPLORING.md`. This document answers *why the lab has the shape
it does*.

Each section states the chosen shape and the reason that shape supports the
lab's claim. The claim, restated:

> A working dataplane in which 12 applications use Vault concurrently with
> the patterns a real medium-sized web service organization would use.

Everything below follows from that.

---

## Scope and the two-repo split

`hashicorp-vault-lab` covers application ↔ Vault interaction.
[`hashicorp-vault-sandbox`](https://github.com/zinrai/hashicorp-vault-sandbox)
covers Vault cluster operation. Two narrow repositories, paired by the
operational division they reflect.

Real organizations operate these two surfaces with different teams, different
risk tolerances, and different change cadence. The dataplane changes when
applications change; the controlplane changes when Vault is upgraded,
re-sealed, scaled, or restored. Combining both into one lab would force every
reader to absorb both axes before getting useful insight on either. Keeping
the labs narrow lets each one carry a sharper teaching point.

The split also matches how the OSS Vault documentation itself is organized:
Agent / AppRole / database / PKI material is dataplane-shaped; cluster
operation, seal mechanisms, raft membership, and recovery procedures are
controlplane-shaped.

---

## Why `-dev-tls` is sufficient

The lab runs Vault in dev mode with the `-dev-tls` flag. This is a
simplification, but a load-bearing question is: *which simplifications are
acceptable and which are not?*

The criterion this lab applies:

> A simplification is acceptable if applications and operators still see the
> same surface shape as in production. A simplification is unacceptable if a
> reader would internalize the simplified form as the canonical pattern.

`-dev-tls` passes that test for the dataplane:

- Applications connect to Vault over HTTPS with hostname verification and CA
  trust against a real X.509 chain. The Vault Agent's `tls_server_name`
  parameter is exercised in earnest.
- The CA distribution problem (operator needs to obtain the CA to use the
  Vault CLI) is reproduced realistically.

What `-dev-tls` does *not* reproduce (sealed startup, unseal-key custody,
storage initialization, HA membership) is exactly the surface that
`hashicorp-vault-sandbox` exists to cover. Adopting a non-dev Vault in this
lab would either duplicate that material or teach a shallow version of it.

By the same criterion, `sslmode=disable` on app↔Postgres connections is
called out in `README.md` as a known simplification: Postgres listener TLS is
orthogonal to the Vault patterns being demonstrated.

---

## Bootstrap shape: response wrap with tmpfs

`vault-init` distributes each agent's `role-id` and `secret-id` as
response-wrapped tokens (`wrap_ttl=600s`). The agent's entrypoint script
unwraps once at first start, writes the resulting values to a per-container
`tmpfs` at `/vault-creds`, and exec's `vault agent`.

Three properties of this shape are deliberate:

**The delivery channel mirrors a real orchestrator.** Response wrap is the
canonical Vault answer to the AppRole "secret zero" problem. In production,
Ansible (or Nomad, or a Kubernetes controller) holds the wrap token between
issuance and consumption. In this lab, the `vault-bootstrap` named volume
plays that role.

**Single-use is preserved.** The wrap is consumed the moment the agent
unwraps it. The wrap token file on the bootstrap volume becomes a dead
artifact. A reader who tries `vault unwrap` on it gets
"wrapping token is not valid or does not exist". This is the truth that
production wrap tokens behave this way, expressed in lab time.

**Container restart fails by design.** `/vault-creds` is a `tmpfs`; restart
clears it and the entrypoint re-tries unwrap, which fails because the wrap
is consumed. Persisting unwrapped credentials in a named volume would make
restart "just work", and would teach readers that secret zero is a
filesystem problem to be solved with persistence, when in fact it is an
orchestrator problem to be solved with re-provisioning. The failure mode is
the lesson.

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

`README.md` flags this as a known lab simplification. The production
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
`pki/` at lab init time. The single application that issues end-entity
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

`vault-init` revokes the dev mode root token before exiting. From that
point forward, every operator command requires an OIDC-issued token. The
two OIDC roles (`sre`, `developer`) give two policy surfaces to compare.

Two consequences of this choice:

- `check-status.sh` and any direct `vault` CLI use require a prior
  `vault login -method=oidc`. The lab does not provide a way to bypass.
- The browser-callback dependency is real. On a remote lab host, port
  forwarding is required.

Keeping a root-token shortcut alongside OIDC would have removed the
friction, at the cost of giving operators a quiet path that does not match
production. In production, root tokens exist as recovery instruments,
generated via unseal-key quorum and revoked once their purpose is served.
The lab cannot reproduce the quorum part (no seal mechanism), but it can
reproduce the lifecycle: root used at bootstrap, revoked after,
operators on OIDC thereafter.

---

## Scope boundary

The following are out of scope for this lab. The boundary is stated, not
elaborated; each item is the subject matter of `hashicorp-vault-sandbox` or
of independent operator practice.

- **HA topology**: Raft / Consul / Integrated Storage configuration,
  membership operations.
- **Seal / unseal**: Shamir share generation, cloud KMS auto-unseal,
  unseal-key custody.
- **Root token recovery**: `vault operator generate-root` driven by
  unseal-key quorum.
- **Production Vault listener TLS**: certificate provisioning for the
  Vault listener itself (the lab uses `-dev-tls` self-signed; PKI hierarchy
  in this lab issues application certificates only).
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
