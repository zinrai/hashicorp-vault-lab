# Deciding

The seven decisions that adopting Vault forces on you, and how to test your
answers in this lab. Each decision links to its test in
[EXPLORING](EXPLORING.md) and to this lab's answer in
[RATIONALE](RATIONALE.md). For unfamiliar words, see [CONCEPTS](CONCEPTS.md).

## How to use this page

Nothing in normal operation tells you whether these decisions are right. A bad
subject split produces no error. Every application keeps working, and the
mistake shows only when something leaks. The lab is a place to find it first.

So form your answer before you touch the lab. For each decision:

1. Write down a provisional answer for your environment.
2. Run the test, where the lab has one.
3. Change the answer if what you see contradicts it.
4. Compare with this lab's answer. It is one worked answer, not the answer.

Record your answers with their reasons. Test again when the design changes: a
split that is right for four applications may be wrong for forty.

## The seven decisions

| # | Decision | Cost to change later | Lab can test |
|---|----------|----------------------|--------------|
| 1 | [What goes into Vault](#1-what-goes-into-vault) | Low: add mounts | No |
| 2 | [What counts as one subject](#2-what-counts-as-one-subject) | **High**: every application's config and a redeploy | **Yes** |
| 3 | [How subjects authenticate](#3-how-subjects-authenticate) | Medium: re-provision every subject | Partly |
| 4 | [Static or dynamic](#4-static-or-dynamic) | Low: one engine at a time | Yes |
| 5 | [TTL](#5-ttl) | Low: a role update | Yes |
| 6 | [Who can change issuance settings](#6-who-can-change-issuance-settings) | Low, but time spent loose does not come back | Partly |
| 7 | [Where unseal trust lives](#7-where-unseal-trust-lives) | **High**: rebuild the whole Vault | No |

Spend your time on 2 and 7. Policies can be rewritten later, so do not invest
in writing them finely at the start.

## Principles

Four rules to fall back on when a decision is unclear.

**Granularity comes from subjects, not from policy detail.** If three
applications share one credential, no policy can tell them apart. If the
subjects are separate, even a coarse policy separates them. The unit you can
stop during an incident is never finer than the subject split you built in
advance.

**Keep Vault out of the request path.** Issue credentials and certificates
ahead of time, and do not call Vault to check each request. A Vault outage
then stops renewal, not service.

**The recovery path must not depend on what it protects.** If recovering Vault
needs something Vault protects, the dependency is circular, and it shows only
when you need to recover. Ask this of unseal trust, of emergency access, and of
where the audit log is stored.

**A policy that grants too little fails only when you need it.** A policy that
reaches too far is visible by reading it. A policy that falls short is wrong
only when someone tries the operation it exists for, and if that is incident
response, you find out during an incident. So give every policy one named
operation, and run it. `sys/capabilities-self` is no substitute: it reports
what the ACL grants, not what the request does (see
[CONCEPTS](CONCEPTS.md#reading-a-path)). `verify.py` runs these operations for
this lab's policies, under "policies reach far enough".

## 1. What goes into Vault

**Question.** Which secrets are worth moving first?

**How to answer.** Name them: "the production database's app user", "the
payment provider's API key", "the internal CA's private key". If you can only
answer with categories, you do not yet know your inventory. Then write down
what you do today when one of them leaks, step by step. The steps that are not
automated, or depend on someone remembering, are what Vault replaces. The
mounts you need follow from this list.

**Test it.** The lab has nothing to say about your inventory.

**This lab's answer.** [RATIONALE 1](RATIONALE.md#1-what-goes-into-vault).

## 2. What counts as one subject

**Question.** What is one identity to Vault: an application, an application in
one environment, a team, or a process?

**Options.**

| Split | You can stop | Cost |
|-------|--------------|------|
| One subject per application | one application | one credential to distribute per application |
| Per environment and application | one application in one environment | multiplied by the number of environments |
| Per team | everything the team runs | small, but an incident stops the whole team |
| Per process instance | one process | grows with instances, needs an orchestrator |

**Test it.**

- What splitting buys: revoke one application's lease and only its PostgreSQL
  user is dropped. [Revoke one lease](EXPLORING.md#revoke-one-lease).
- What a shared template costs: four applications with separate subjects share
  `main-readwrite`, and one command stops all four.
  [Revoke by prefix](EXPLORING.md#revoke-by-prefix).
- What merging costs: make two applications one subject, and their tokens
  cannot be told apart. [Merge two subjects](EXPLORING.md#5-merge-two-subjects).
- What each subject costs to run: one more wrap pair to deliver, again after
  every agent restart. [Restart an agent](EXPLORING.md#restart-an-agent).

**What would change your answer.** If you cannot name two applications where
"stop A, keep B running" is a real requirement, your split is finer than you
need. If two applications share a credential template, splitting their
subjects bought less than it seems.

**This lab's answer.** [RATIONALE 2](RATIONALE.md#2-what-counts-as-one-subject).

## 3. How subjects authenticate

**Question.** How does each subject prove who it is, and who delivers its
first credential?

**Options.** If the platform already vouches for identity, nothing has to be
delivered.

| Method | Identity comes from | Delivery |
|--------|---------------------|----------|
| Kubernetes | ServiceAccount token | Kubernetes puts it in the pod |
| AWS, GCP, Azure | instance identity | the provider vouches |
| cert | client certificate | depends on a PKI |
| AppRole | RoleID and SecretID | **you deliver it** |

On premises or on plain VMs, the answer is usually AppRole, and delivery is
your problem. Only AppRole runs here. The others are described in
[Vault's auth methods](https://developer.hashicorp.com/vault/docs/auth).

**Test it.** The running cost of AppRole: a wrap token works once, an agent
restart spends it, and the only recovery is a new delivery.
[Reuse a wrap token](EXPLORING.md#reuse-a-wrap-token) and
[Restart an agent](EXPLORING.md#restart-an-agent).

**This lab's answer.**
[RATIONALE 3](RATIONALE.md#3-how-subjects-authenticate).

## 4. Static or dynamic

**Question.** For each credential, does Vault store it (static) or create it
on demand (dynamic)?

**How to answer.** If a person sees the value today, dynamic is worth it,
because then no person ever sees one. If no person touches it, static changes
little. Dynamic has a cost at the target: Vault needs an account there that can
create users (for PostgreSQL, one with `CREATE ROLE`). Weigh it per
credential.

**Test it.** KV returns the same value however often you read it. `verify.py`
checks this. `database/creds/` returns a new PostgreSQL user on every read.
[Read credentials by hand](EXPLORING.md#read-credentials-by-hand).

**This lab's answer.** [RATIONALE 4](RATIONALE.md#4-static-or-dynamic).

## 5. TTL

**Question.** How long does each credential live?

**How to answer.** A ceiling and two floors set it.

- **Ceiling: the exposure window.** The longest a stolen credential stays
  usable. Revocation does not close a session already open, so the TTL bounds
  new access, not access in flight.
- **Floor 1: how long you must survive a Vault outage.** While Vault is down
  nothing renews, and each credential dies when its TTL runs out.
- **Floor 2: whether the application survives a new credential.** An
  application that cannot rebuild its connections cannot run a short TTL. If
  it reads credentials only at startup, its floor is its restart interval.

**Test it.**

- Floor 2: replace an application's credential and see whether it carries on
  without a restart.
  [Replace a credential](EXPLORING.md#replace-a-credential).
- Floor 1: stop the Vault and the applications keep serving.
  [Stop the Vault](EXPLORING.md#8-stop-the-vault).
- Ceiling: revoke a lease and the application keeps serving on its open
  connection. [Revoke one lease](EXPLORING.md#revoke-one-lease).

How often Vault Agent renews or replaces a credential is Agent's own timing,
described in its
[template documentation](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/template).

**This lab's answer.** [RATIONALE 5](RATIONALE.md#5-ttl).

## 6. Who can change issuance settings

**Question.** Who may write `sys/policies/acl/*` and `auth/*/role/*`?

**Why it matters.** A token with that power can, inside its own short TTL,
change which policies a role hands out. The token dies and the changed role
keeps issuing. Bounding damage by time fails at this one point, however
tightly every other subject is scoped. Vault Community has no permission
boundary to limit it, so the answer is organizational.

**How to answer.** With a person's name, not a team's. At small scale, one or
two people. Then decide which auth method gives them that power, at what TTL,
and where its use is audited.

**Test it.** One version runs here: three roles for people that can look, read
values, or stop things, and none can change what gets issued. `verify.py`
checks each of these.
[People and their roles](EXPLORING.md#2-people-and-their-roles) and
[Who did what](EXPLORING.md#who-did-what).

**This lab's answer.**
[RATIONALE 6](RATIONALE.md#6-who-can-change-issuance-settings).

## 7. Where unseal trust lives

**Question.** What does Vault trust to unseal itself at every start?

**Why it matters.** Automatic unsealing needs another root of trust, often a
cloud KMS. If that KMS depends on what Vault protects, the dependency is
circular: the protected system fails, the KMS stops answering, Vault cannot
unseal. It never shows in a drill.

**Options.** A separate Vault for Transit auto-unseal, an HSM, or manual
Shamir unsealing; see
[Seal/Unseal](https://developer.hashicorp.com/vault/docs/concepts/seal).
Choose by whether
[the recovery path depends on what it protects](#principles), not by which is
fastest. The same applies to emergency access.

**Test it.** Not in this lab. It belongs to the Vault the lab runs on.

**This lab's answer.** [RATIONALE 7](RATIONALE.md#7-where-unseal-trust-lives).
