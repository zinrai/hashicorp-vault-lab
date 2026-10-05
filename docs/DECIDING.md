# Deciding

This document is the reason the lab exists.

[CONCEPTS.md](CONCEPTS.md) explains how Vault works. This document is about
what *you* have to decide for your own environment, which Vault cannot decide
for you and which no amount of Vault knowledge will settle.

Vault's configuration is a mapping of how your organization already decides
who may reach what. In most organizations that decision is implicit. Adopting
Vault is, in practice, the work of writing it down for the first time. The
blocker is usually not missing knowledge but a missing decision, so it cannot
be fixed by reading more documentation.

## How to use this with the lab

**Form a hypothesis on paper before you touch the lab.** The lab answers
questions you bring to it. Touching it without one produces a lot of
interesting output and no conclusion.

For each decision below:

1. Write down a provisional answer for your environment.
2. Run the verification path, where one exists.
3. Change the answer if the observation contradicts it.

Not every decision has a verification path. Some are about your environment
and the lab has nothing to say about them. That is marked per decision rather
than papered over.

## The seven decisions

| # | Decision | What it constrains | Cost to change later | Lab |
|---|----------|--------------------|----------------------|-----|
| 1 | What goes into Vault | Which secrets engines you need | Low. Mounts can be added | No |
| 2 | What counts as one subject | Role count, policy split, revocation unit | **High**. Every application's config and a redeploy | **Yes** |
| 3 | How subjects authenticate | Whether you must distribute a first credential | Medium. Changing method re-provisions every subject | Partial |
| 4 | Static or dynamic | Whether Vault needs an account at the target | Low. Migrate one engine at a time | Yes |
| 5 | TTL | Exposure window, and time you survive a Vault outage | Low. A role update | **Yes** |
| 6 | Who can change issuance settings | Whether every other control holds | Low to change, but time spent loose does not come back | Partial |
| 7 | Where unseal trust lives | Whether you can recover at all | **High**. Rebuild of the whole Vault | No, the Vault underneath |

Spend the time on 2 and 7. Policies can be rewritten later, so do not invest
in writing them finely at the start.

Decision 7 is not covered by this lab but by the Vault it runs on. It is
listed anyway, because skipping it silently is how the most expensive failure
gets built in.

## Principles

Five rules to fall back on when an individual decision is unclear.

### Granularity comes from subjects, not from policy detail

However finely a policy is written, if one credential is shared by three
applications the granularity is not there. Conversely, if the subjects are
separate, a coarse policy still separates blast radius.

The same is true of revocation. **The unit you can stop during an incident is
never finer than the subject split you built in advance.**

### Do not put Vault in the request path

If Vault sits in the verification path, Vault's availability becomes the
ceiling on the availability of everything behind it. Do that on an operations
or incident-response path and the tooling disappears at the moment you need
it.

Put Vault in the *issuance* path only. Issue certificates and tokens ahead of
time and do not call Vault to verify them. A Vault outage then stops renewal,
not service.

### The recovery path must not depend on what it protects

If recovering Vault depends on something Vault protects, the dependency is
circular. It never shows up in normal operation and only appears at the moment
you most need to recover.

Unseal trust, emergency reachability, audit log storage. Choose each by asking
whether it works when the protected thing is broken.

### A policy that grants too little fails only when you need it

A policy carries two obligations. It must not reach further than the job
requires, and it must reach far enough to do the job. **Only the first can be
settled by reading it.**

A policy that reaches too far is wrong continuously. Every request it should
not have allowed is in the audit log, and any review of that log finds it.

A policy that does not reach far enough is wrong only at the moment someone
attempts the operation it was written for. If that operation is routine, the
gap surfaces on the first working day. If it is incident response, nothing
attempts it until an incident, and the gap surfaces while you are trying to
stop a breach.

This lab shipped with four such gaps, all found by running commands rather than
by reading policies:

| Gap | Consequence |
|-----|-------------|
| No policy granted any revocation | Nothing in the lab could stop anything |
| `sys/leases/lookup` without `sudo` | Leases could not be enumerated |
| `sys/audit` without `sudo` | Audit devices could not be listed |
| `pki_int/+` stopping at one segment | PKI roles could not be read |

Twelve applications ran correctly the whole time. Nothing in normal operation
touches any of those paths.

So every policy needs **one named operation it exists to make possible**, and
that operation has to be run. Write the operation down beside the policy.
`sre-admin` exists to inspect, so run the inspection. `incident-response`
exists to stop things, so revoke something. A policy nobody has exercised is a
policy nobody has verified, however carefully it was minimized.

`sys/capabilities-self` does not substitute for running it. It answers a
question about the ACL, not about the request, and in this lab it is wrong in
both directions:

```sh
vault login -method=oidc role=developer
vault write -f sys/capabilities-self paths=pki/cert/ca   # deny
vault read -field=certificate pki/cert/ca                # -----BEGIN CERTIFICATE-----

vault login -method=oidc role=sre
vault write -f sys/capabilities-self paths=sys/auth      # [list read]
vault list sys/auth                                      # permission denied
```

The first succeeds despite `deny` because PKI CA endpoints are unauthenticated.
The second fails despite `list` because `sys/auth` is root-protected and the
token carries no `sudo`. Neither condition is part of the ACL, so neither is
visible to the thing that reports on the ACL.

### Daily operation does not grade this design

A bad label design makes queries slow. A bad subject split produces nothing at
all. Everything keeps working. It surfaces only on a leak, which is rare.

Unless you deliberately create a place that grades the design, it stays
unverified. That is what this lab is for.

## 1. What goes into Vault

**Lab: no verification path.** This is about your environment.

Not everything needs to go in. Identify what is worth moving first.

Answer with concrete names. "The production DB's app user", "the payment
SaaS API key", "the internal CA private key". If the answer can be given as an
abstract category, the actual inventory is not yet known.

Then write out what you do *today* when one of them leaks. Change the
password, find every reference, edit the configs, redeploy in order, confirm
nothing was missed. Add up the time per step.

Mark the steps that are **not automated** and the steps that **depend on
someone remembering**. Those are the steps Vault replaces. The rest survive
adoption unchanged.

The count of mounts you need falls out of this. You do not have to touch every
secrets engine on day one.

## 2. What counts as one subject

**Lab: verification path below.** This is the expensive one.

### The option space

| Split | Revocation unit | Cost |
|-------|-----------------|------|
| One subject per application | One application | One credential distribution per application |
| Per environment x application | One application in one environment | Multiplied by the environment count |
| Per team | Everything that team runs | Small, but incidents stop the whole team |
| Per process instance | One process | Distribution scales with instance count, needs an orchestrator |

The lab uses one subject per application: twelve applications, twelve AppRole
roles, each with `token_policies="self-renewal,<app>"`.

### Verification path

**Observe what splitting buys.** Stop one application's credentials and watch a
neighbour keep running. `api-server` and `payment` are separate subjects.

**Observe what sharing costs.** The lab already shares at a second level:
`main-readwrite` is used by `api-server`, `auth-service`, `batch-runner`, and
`webhook-receiver`. One prefix revoke reaches all four, even though their
subjects are separate.

```sh
vault login -method=oidc role=incident
vault list sys/leases/lookup/database/creds/main-readwrite   # four leases
vault lease revoke -prefix database/creds/main-readwrite

docker exec postgres-main psql -U vault-admin -d postgres \
  -tAc "select count(*) from pg_roles where rolname like 'v-%'"
# four roles dropped by one command
```

Compare with a role used by one application:

```sh
vault list sys/leases/lookup/database/creds/payment-short    # one lease
```

**This is the point most easily missed.** Subjects and credential templates are
two different granularity axes. Splitting subjects does not split blast radius
if they share a credential template.

**Observe the subject axis itself.** The lab ships with every subject separate,
so the coarse case has to be constructed. See
[EXPLORING 8.8](EXPLORING.md#88-merge-two-subjects-granularity-comparison).

Merging `payment` onto `api-server` produces two tokens that are identical in
every field Vault exposes: same policies, same `meta.role_name`, same
`display_name`. Enumerating accessors shows two `api-server` rows and no
`payment` row. **To stop payment you must pick its token out of the two, and
nothing tells you which one it is.**

The audit log is affected the same way. Merged, `payment` stops appearing
entirely and its activity is filed under `api-server`.

So the subject split is not only the revocation unit. **It is also the unit of
attribution.** A coarse split costs you the ability to say afterwards which
workload did what, which is usually discovered during the incident that needs
it.

**Measure the cost of splitting.** Each subject needs its own wrap token pair,
handed over by the deployment (`wrap` in the [README](../README.md#quick-start) here), and each is
single-use. Restarting an agent
container is enough to exhaust it
([EXPLORING 8.2](EXPLORING.md#82-restart-an-agent-container-response-wrap-exhaustion)).
Every subject you add adds one of these to distribute and re-provision.

### What would change your answer

If you cannot name a pair of applications where "stop A, keep B running" is
actually required, the split is finer than the requirement and you are paying
distribution cost for nothing.

If two applications share a credential template, splitting their subjects
bought less than it looks like. Either split the template too or stop
pretending they are independent.

## 3. How subjects authenticate

**Lab: partial.** The option space is a paper decision. The operational cost of
the option the lab chose is observable.

If the platform already vouches for the identity, no first credential has to be
distributed.

| Method | Basis of identity | Distribution |
|--------|-------------------|--------------|
| Kubernetes | ServiceAccount token | Placed in the pod by K8s. Vault verifies against the K8s API. Invalid once the pod is gone |
| AWS / GCP / Azure | Instance identity | Vouched for by the provider. Nothing to distribute |
| cert | Client certificate | Depends on a PKI |
| AppRole | RoleID + SecretID | **You distribute it** |

Where no such platform exists, on-premises or on IaaS VMs, the answer is
AppRole and the distribution problem is yours.

RoleID can sit in a config file. It cannot log in by itself. SecretID is the
part that matters, and response wrapping makes interception detectable: the
recipient's unwrap fails if someone consumed it first. **The act of
distributing it does not go away.** This is a part Vault does not solve, and it
stays in the design.

The lab does exactly this, so the running cost is visible. Wrap tokens are
single-use, an agent restart burns one, and the only recovery is the deployment
handing the agent new ones (`wrap` in the [README](../README.md#quick-start)) and
recreating it. In production that is the orchestrator's job, and it is work
you are taking on.

## 4. Static or dynamic

**Lab: observable.**

Decided by where the credential is today and who can read it.

If a human currently sees the value, dynamic is worth it: the point is that no
human ever sees one. If no human touches it and it is only injected at deploy
time, static changes nothing about granularity.

Dynamic costs something at the target. Vault needs an account there that can
create users. For Postgres that is an account with `CREATE ROLE`, and managing
that account becomes new work. Weigh it per credential, not once globally.

The two shapes are side by side in the lab. KV returns the same value however
many times you read it, and reading it needs `role=developer` because
`sre-admin` deliberately cannot see KV values. `database/creds/*` returns a
different user each time, and the users appear in `pg_roles`. See
[EXPLORING 3](EXPLORING.md#3-kv-v2-static-secrets) and
[EXPLORING 4](EXPLORING.md#4-dynamic-database-credentials-the-headline-feature).

## 5. TTL

**Lab: verification path below.**

The ceiling and the floor are set by different things, and there are **two**
independent floors.

**Ceiling: the exposure window.** The longest a stolen credential remains
usable, *if nothing else intervenes*. Read the next paragraph before treating
revocation as the thing that intervenes.

**Revocation does not evict an open session.** Verified in this lab: revoking a
database lease drops the role in Postgres, new connections with it fail
immediately, and the application keeps serving on its existing pool. Nothing
tells the pool to reconnect, and the Vault Agent only learns the lease is gone
at its next renewal attempt.

So the credential's TTL is the bound on *drawing new access*, not on access
already in flight. If the threat model includes an attacker with an established
connection, the TTL does not bound the damage and the connection has to be
killed at the target. See
[EXPLORING 4](EXPLORING.md#4-dynamic-database-credentials-the-headline-feature).

**Floor 1: how long you want to survive a Vault outage.** When Vault is down
nothing renews, and everything dies as its TTL runs out. Shorter is not better.
The TTL has to exceed your expected recovery time.

**Floor 2: whether the application tolerates rotation.** At `max_ttl` the
credential is replaced outright. An application that cannot rebuild its
connection pool on that event cannot run a short TTL, whatever Vault can do.

Floor 2 is the one that gets missed on paper and is obvious in the lab.

### Verification path

**Watch a rotation.** `payment` uses `payment-short`, `default_ttl=10m` and
`max_ttl=10m`.

```sh
docker logs -f app-payment | grep rotated
```

Measured in this lab, the credential turns over about every **7 minutes**, not
every 10. The agent attempts renewal at roughly 2/3 of the lease, cannot extend
past `max_ttl`, and re-renders immediately.

**So the interval the application must survive is about 2/3 of `max_ttl`.**
Size the TTL against that number, not against `max_ttl` itself.

Ask whether your own applications could absorb it. The lab's application
rebuilds its `pgxpool` on file change. If yours reads credentials once at
startup, floor 2 is your restart interval, and a short TTL is not available to
you until that changes.

**Compare against the long end.** `etl` uses `main-long`, `default_ttl=8h`.

**Measure floor 1.** Stop Vault, every one of its nodes, and watch how long
applications keep working.

```sh
docker logs -f app-api-server
# {"msg":"db check ok", ...} keeps appearing
```

Already-issued credentials stay valid and every application keeps serving.
**The TTL is literally the time you survive without Vault.**

This stops the whole Vault, not only the lab. Stopping only the active node
measures something else, a failover. How to stop and restart the nodes depends
on how your Vault is run; see [EXPLORING 8.1](EXPLORING.md#81-stop-vault).

## 6. Who can change issuance settings

**Lab: partial.**

This means write access to `sys/policies/acl/*` and `auth/*/role/*`. A token
holding it can, inside its own short TTL, rewrite which policies a role hands
out. The original token dies and the rewritten role keeps issuing new ones.
**The whole idea of bounding damage by time collapses at this one point.**

Answer with a person's name, not a team. At small scale it should be one or two
people. If it is not, the split is too coarse.

What this settles: which auth method issues that permission, at what TTL, and
where its use is audited.

This one does not decompose into per-subject minimums. Every other decision
here can be settled by asking what a given subject needs. This one is a
property of the whole system: it does not matter how tightly every other
subject is scoped if one subject can rewrite their roles. Vault Community has
no permission boundary and no equivalent of an SCP, so there is no technical
control that bounds it. The answer is organizational, which is why the question
is who rather than what.

In the lab, the answer is the Vault's operators, by name. They log in as
themselves, run `vault-config/configure.sh` with their own token, and the
Vault's audit device records each change. No root token is involved. None of
the lab's three OIDC roles holds the meta permission at all. Revocation is
also split away from observation: `sre-admin` can read but not stop anything, and
`incident-response` can stop things but cannot change what will be issued
next. See [EXPLORING 2](EXPLORING.md#2-oidc-operator-login-human-authentication).

Whether that separation is right for you is your decision. The lab exists to
let you see one version of it running.

## 7. Where unseal trust lives

**Out of scope for this lab, answered by the Vault it runs on.** For one
worked answer, read
[hashicorp-vault-sandbox](https://github.com/zinrai/hashicorp-vault-sandbox).

It is listed because it is one of the two expensive decisions and skipping it
silently is how the worst failure gets built in.

Vault needs unsealing at every start. Automating that requires another root of
trust, usually a cloud KMS. **If that KMS is part of what Vault protects, the
dependency is circular.**

> The protected system fails, the KMS stops answering, Vault cannot unseal,
> the operational credentials are unreachable, the failure cannot be fixed.

It never appears in a drill. It appears once, at the worst moment.

The alternatives are a separate Vault for Transit auto-unseal, an HSM, or
accepting manual Shamir unsealing. Choose by whether
[the recovery path depends on what it protects](#the-recovery-path-must-not-depend-on-what-it-protects),
not by which is fastest or most automated.

The same applies to emergency reachability. The path used to repair Vault while
Vault is down cannot be protected by Vault, so it cannot use short-lived
certificates or tokens. A static credential is acceptable there. Isolate it
physically and make sure its use is always noticed. A static credential whose
use is detected is manageable.

## After deciding

**Record the answers as ADRs.** They are decisions with context and
consequences, not facts. In six months you will need to know why two
applications were made one subject.

**Compare with this lab's answers.** [RATIONALE.md](RATIONALE.md) records what
this lab decided and why, decision by decision. It is one worked answer, not
the answer.

**Re-verify when the design changes.** A subject split that was right for four
applications may not be right for forty. Nothing in daily operation will tell
you when it stopped being right.
