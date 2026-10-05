#!/usr/bin/env python3
#
# Claims, not a snapshot: check-status.sh prints and leaves the reading to
# you, while every check here is a statement in docs/, so a failure means
# either the lab drifted or a document is wrong. A policy that grants too
# little fails silently until someone needs it (docs/DECIDING.md, Principles),
# so the operations a policy exists for are run here, not read from it.
#
# Read-only, not exercising issuance: it issues no credentials and revokes
# nothing, so it can run at any time. Experiments that create or break
# things are in docs/EXPLORING.md.
#
# Python, not shell: these are comparisons and counts over JSON, and the
# Vault API answers in JSON. The standard library only, so that nothing has
# to be installed.

import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

LAB = Path(__file__).resolve().parent
APPS = sorted(p.stem for p in (LAB / "apps").glob("*.yaml"))


# Exit 2, not 1: it could not run, which is not a failed claim.
def cannot_run(why):
    print(why, file=sys.stderr)
    sys.exit(2)


def need(name):
    value = os.environ.get(name)
    if not value:
        cannot_run(f"set {name}, see README.md")
    return value


ADDR = need("VAULT_ADDR").rstrip("/")
TLS = ssl.create_default_context(cafile=need("VAULT_CACERT"))
SRE = need("VAULT_TOKEN_SRE")
DEV = need("VAULT_TOKEN_DEV")
INC = need("VAULT_TOKEN_INC")


def vault(method, path, token=None, body=None):
    """The Vault API itself, not the vault CLI: its JSON, not text meant
    for people, decides each check."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{ADDR}/v1/{path}", data=data, method=method)
    if token:
        req.add_header("X-Vault-Token", token)
    try:
        with urllib.request.urlopen(req, context=TLS) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as e:
        return e.code, {}


def listing(path, token):
    status, body = vault("GET", f"{path}?list=true", token)
    return status, body.get("data", {}).get("keys", [])


def capabilities(token, path):
    _, body = vault("POST", "sys/capabilities-self", token, {"paths": [path]})
    return sorted(body.get("data", {}).get(path, []))


def lookup_self(token):
    _, body = vault("GET", "auth/token/lookup-self", token)
    return body.get("data", {})


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def compose(*args):
    return run("docker", "compose", "-f", str(LAB / "compose.yaml"), "--profile", "apps", *args)


# (passed, what was found), not a bare bool: a failure shows what was found.
# None, not a pass, when a check cannot run here. Plain functions in a
# table, not one block of if and else per claim: what is claimed and how it
# is checked then read side by side.


# A fixed 29, not the count compose.yaml declares: a service missing from it
# must fail the check, not lower the expectation.
def lab_containers_running():
    states = compose("ps", "--format", "{{.State}}").stdout.split()
    return states.count("running") == 29, states.count("running")


# Counted first, not after the other checks: it is the claim the revoke
# experiments in docs/EXPLORING.md change, so their trace shows at the top.
# The message gives their recovery rather than the check being dropped.
def main_readwrite_held_by_four():
    _, keys = listing("sys/leases/lookup/database/creds/main-readwrite", INC)
    if len(keys) == 4:
        return True, 4
    return False, (f"{len(keys)}. After a revoke experiment, recover as docs/EXPLORING.md "
                   "says: wrap (README), then recreate the agents")


def app_token(name):
    return run("docker", "exec", f"app-{name}-agent", "cat", "/tmp/token").stdout.strip()


def app_token_carries_only_repository_policies():
    policies = sorted(lookup_self(app_token("api-server")).get("policies", []))
    return policies == ["api-server", "self-renewal"], policies


# default kept, not left out as on application tokens: people use parts of
# it that no lab policy declares (docs/RATIONALE.md 6).
def operator_token_carries_default():
    policies = sorted(lookup_self(SRE).get("policies", []))
    return policies == ["default", "sre-admin"], policies


# Every role read, not one as a sample: a subject merged by hand in
# docs/EXPLORING.md and not restored must fail here. A fixed 12, not only
# the count of apps/: a missing file must fail too.
def one_approle_role_per_application():
    _, roles = listing("auth/approle/role", SRE)
    if len(APPS) != 12 or sorted(roles) != APPS:
        return False, roles
    wrong = []
    for name in APPS:
        data = vault("GET", f"auth/approle/role/{name}", SRE)[1].get("data", {})
        shape = (sorted(data.get("token_policies", [])), data.get("token_no_default_policy"),
                 data.get("token_ttl"), data.get("token_max_ttl"))
        if shape != (sorted([name, "self-renewal"]), True, 1200, 7200):
            wrong.append(f"{name}: {shape}")
    return not wrong, wrong or len(APPS)


def token_ttl(token, seconds):
    ttl = lookup_self(token).get("creation_ttl")
    return ttl == seconds, ttl


def developer_reads_kv_values():
    _, body = vault("GET", "secret/data/api-server/config", DEV)
    value = body.get("data", {}).get("data", {}).get("max-connections")
    return value == "100", value


def denied(token, method, path):
    status, _ = vault(method, path, token)
    return status == 403, status


def sre_lists_kv_metadata():
    _, keys = listing("secret/metadata", SRE)
    return "api-server/" in keys, keys


def can_revoke(token, want):
    caps = capabilities(token, "sys/leases/revoke")
    return caps == want, caps


def cannot_change_what_gets_issued(token):
    caps = capabilities(token, "sys/policies/acl/api-server")
    return not {"create", "update", "delete"} & set(caps), caps


def sre_lists_audit_devices():
    status, body = vault("GET", "sys/audit", SRE)
    return status == 200 and "file/" in body.get("data", body), status


def sre_reads_a_pki_role():
    status, body = vault("GET", "pki_int/roles/admin-panel", SRE)
    return status == 200 and "allowed_domains" in body.get("data", {}), status


def incident_enumerates_leases():
    status, _ = listing("sys/leases/lookup/database/creds/main-readwrite", INC)
    return status == 200, status


def incident_revokes_by_prefix():
    caps = capabilities(INC, "sys/leases/revoke-prefix/database/creds/x")
    return "sudo" in caps, caps


# The application's own token, not a person's: a mount is the boundary
# between applications (docs/RATIONALE.md 1).
def app_token_cannot_reach_another_mount():
    return denied(app_token("api-server"), "GET", "secret-internal/data/internal-cms/config")


# The ACL, not a read: a read that was allowed would create a PostgreSQL
# user. A denial in the ACL is final, so here capabilities-self is enough.
def cannot_issue_database_credentials(token):
    caps = capabilities(token, "database/creds/main-short")
    return not {"read", "create", "update"} & set(caps), caps


# Seconds, not durations like 1h: the API answers in seconds.
# (database, default_ttl, max_ttl) per role, as docs/ARCHITECTURE.md lists them.
DATABASE_ROLES = {
    "main-readonly": ("postgres-main", 3600, 86400),
    "main-readwrite": ("postgres-main", 3600, 86400),
    "main-short": ("postgres-main", 900, 900),
    "main-long": ("postgres-main", 28800, 86400),
    "payment-short": ("postgres-payment", 600, 600),
    "analytics-readonly": ("postgres-analytics", 3600, 86400),
    "analytics-readwrite": ("postgres-analytics", 3600, 86400),
    "analytics-long": ("postgres-analytics", 28800, 86400),
    "internal-readwrite": ("postgres-internal", 3600, 86400),
}


def database_roles_as_documented():
    _, roles = listing("database/roles", SRE)
    if sorted(roles) != sorted(DATABASE_ROLES):
        return False, roles
    wrong = []
    for role, want in DATABASE_ROLES.items():
        data = vault("GET", f"database/roles/{role}", SRE)[1].get("data", {})
        got = (data.get("db_name"), data.get("default_ttl"), data.get("max_ttl"))
        if got != want:
            wrong.append(f"{role}: {got}")
    return not wrong, wrong or len(roles)


# Without a token, not with one: the CA endpoint answers anyone, while
# capabilities-self reports what the ACL grants, so the two disagree
# (docs/CONCEPTS.md, Reading a path).
def ca_readable_without_a_token():
    status, body = vault("GET", "pki/cert/ca")
    caps = capabilities(DEV, "pki/cert/ca")
    found = "BEGIN CERTIFICATE" in body.get("data", {}).get("certificate", "")
    return status == 200 and found and caps == ["deny"], f"status {status}, developer acl {caps}"


def kv_returns_the_same_value_twice():
    first = vault("GET", "secret/data/api-server/config", DEV)[1].get("data", {}).get("data")
    second = vault("GET", "secret/data/api-server/config", DEV)[1].get("data", {}).get("data")
    return first is not None and first == second, f"{first} / {second}"


# Reading database/creds is deliberately not checked here. Every read creates a
# real Postgres user and a real lease, which makes this script mutate the thing
# it is verifying and makes the lease count above unreliable. The claim that
# each read returns a new user is exercised in docs/EXPLORING.md 4 (Read
# credentials by hand), where creating them is the point.


# openssl, not Python: the standard library cannot verify a chain it is
# handed as files.
def leaf_verifies_through_the_intermediate():
    rendered = run("docker", "exec", "app-admin-panel", "cat", "/secrets/pki.json").stdout
    if not shutil.which("openssl") or not rendered:
        return None
    pki = json.loads(rendered)
    root = vault("GET", "pki/cert/ca")[1].get("data", {}).get("certificate", "")
    with tempfile.TemporaryDirectory() as tmp:
        chain, leaf = Path(tmp, "chain.pem"), Path(tmp, "leaf.pem")
        chain.write_text(pki["issuing_ca"].rstrip() + "\n" + root.rstrip() + "\n")
        leaf.write_text(pki["certificate"].rstrip() + "\n")
        result = run("openssl", "verify", "-CAfile", str(chain), str(leaf))
    return result.returncode == 0, result.stdout.strip() or result.stderr.strip()


# The audit log is on the Vault nodes, which the lab does not run: their
# containers come from VAULT_NODES, every one of them, because whichever
# node was active wrote its own file.
def audit_log_hmacs_tokens(node):
    hmac = '"client_token":"hmac-sha256:'
    return run("docker", "exec", node, "grep", "-q", hmac, "/vault/logs/audit.log").returncode == 0


def tokens_hmaced_in_the_audit_log():
    nodes = os.environ.get("VAULT_NODES", "").split()
    if not nodes:
        return None
    found = [n for n in nodes if audit_log_hmacs_tokens(n)]
    return bool(found), found


CHECKS = [
    ("bootstrap", [
        ("29 lab containers running", lab_containers_running),
        ("main-readwrite is held by four applications", main_readwrite_held_by_four),
    ]),
    ("token shapes", [
        ("app token carries only repository policies", app_token_carries_only_repository_policies),
        ("SRE token ttl 28800s", lambda: token_ttl(SRE, 28800)),
        ("DEV token ttl 28800s", lambda: token_ttl(DEV, 28800)),
        ("INC token ttl 1800s", lambda: token_ttl(INC, 1800)),
        ("operator token carries default", operator_token_carries_default),
    ]),
    ("one subject per application (DECIDING 2)", [
        ("one AppRole role per application, 20m up to 2h", one_approle_role_per_application),
        ("app token cannot reach another mount", app_token_cannot_reach_another_mount),
    ]),
    ("credential TTLs (DECIDING 5)", [
        ("database roles as documented", database_roles_as_documented),
    ]),
    ("three tiers of operator authority (DECIDING 6)", [
        ("developer reads KV values", developer_reads_kv_values),
        ("developer cannot list database roles", lambda: denied(DEV, "GET", "database/roles?list=true")),
        ("sre lists KV metadata", sre_lists_kv_metadata),
        ("sre cannot read KV values", lambda: denied(SRE, "GET", "secret/data/api-server/config")),
        ("developer revoke=deny", lambda: can_revoke(DEV, ["deny"])),
        ("sre revoke=deny", lambda: can_revoke(SRE, ["deny"])),
        ("incident revoke=update", lambda: can_revoke(INC, ["update"])),
        ("developer cannot change what gets issued", lambda: cannot_change_what_gets_issued(DEV)),
        ("sre cannot change what gets issued", lambda: cannot_change_what_gets_issued(SRE)),
        ("incident cannot change what gets issued", lambda: cannot_change_what_gets_issued(INC)),
        ("developer cannot issue database credentials", lambda: cannot_issue_database_credentials(DEV)),
        ("sre cannot issue database credentials", lambda: cannot_issue_database_credentials(SRE)),
        ("incident cannot issue database credentials", lambda: cannot_issue_database_credentials(INC)),
    ]),
    ("policies reach far enough (DECIDING, Principles)", [
        ("sre can list audit devices", sre_lists_audit_devices),
        ("sre can read a pki role", sre_reads_a_pki_role),
        ("incident can enumerate leases", incident_enumerates_leases),
        ("incident can revoke by prefix", incident_revokes_by_prefix),
        ("CA readable without a token, though the ACL denies it", ca_readable_without_a_token),
    ]),
    ("static secrets (DECIDING 4)", [
        ("KV returns the same value twice", kv_returns_the_same_value_twice),
    ]),
    ("pki chain (RATIONALE 1)", [
        ("leaf verifies to the root through the intermediate", leaf_verifies_through_the_intermediate),
    ]),
    ("audit", [
        ("tokens are hmac'd in the audit log", tokens_hmaced_in_the_audit_log),
    ]),
]


def report(description, result):
    if result is None:
        print(f"  skip  {description}")
        return None
    if result[0]:
        print(f"  ok    {description}")
        return True
    print(f"  FAIL  {description}\n        got: {result[1]}")
    return False


def main():
    if compose("ps").returncode != 0:
        cannot_run("set VAULT_ADDR, VAULT_CACERT and VAULT_NETWORK, see README.md")
    outcomes = []
    for section, checks in CHECKS:
        print(f"\n{section}")
        for description, check in checks:
            outcomes.append(report(description, check()))
    passed, failed = outcomes.count(True), outcomes.count(False)
    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
