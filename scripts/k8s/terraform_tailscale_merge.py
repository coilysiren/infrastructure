#!/usr/bin/env python3
"""One-shot migration: fold tailscale-policy + tailscale-oidc + tailscale-devices
into a single terraform/tailscale/ stack.

Plan:
  1. terraform init each of the four stacks (3 sources + 1 target).
  2. terraform state pull each source to /tmp/<stack>.tfstate.
  3. terraform state pull target to /tmp/tailscale.tfstate (empty on first run).
  4. terraform state mv each resource from its source-state file into
     /tmp/tailscale.tfstate (local-file mode, source backends untouched
     until the orphan step).
  5. PAUSE: dump every address moved into /tmp/tailscale.tfstate and
     run `terraform state list` for human review.
  6. On --push: terraform state push /tmp/tailscale.tfstate into the
     new backend, then terraform plan against real tailnet state.

The orphan step (terraform state rm from the three sources) and the
old-dir + old-state-key deletions are deliberately a separate run, gated
on the post-push plan diff being empty.

Usage:
  terraform_tailscale_merge.py prepare    # steps 1-5, idempotent
  terraform_tailscale_merge.py push       # step 6, after Kai approves
  terraform_tailscale_merge.py orphan     # final: state rm from sources
"""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run, tailscale_admin_oauth_env  # noqa: E402


SOURCES = {
    "tailscale-policy": [
        "tailscale_acl.policy",
        'tailscale_device_tags.physical["kai-server"]',
        'tailscale_device_tags.physical["kai-desktop-tower"]',
        'tailscale_device_tags.physical["kai-windows-laptop"]',
        'tailscale_device_tags.physical["kais-macbook-pro"]',
    ],
    "tailscale-oidc": [
        # The duplicate tailscale_acl.main is intentionally NOT migrated;
        # tailscale-policy's version is canonical.
        'tailscale_federated_identity.ci["backend"]',
        'tailscale_federated_identity.ci["eco-jobs-tracker"]',
        'tailscale_federated_identity.ci["eco-mcp"]',
        'tailscale_federated_identity.ci["galaxy-gen"]',
        'tailscale_federated_identity.ci["personal-dashboard"]',
        'tailscale_federated_identity.ci["repo-recall"]',
    ],
    "tailscale-devices": [
        f'tailscale_tailnet_key.service["{s}"]'
        for s in [
            "2fauth", "repo-recall", "vmsingle", "eco-mcp", "eco-spec",
            "galaxy-gen", "backend", "backend-db", "forgejo", "signoz", "ntfy",
        ]
    ] + [
        f'aws_ssm_parameter.ts_authkey["{s}"]'
        for s in [
            "2fauth", "repo-recall", "vmsingle", "eco-mcp", "eco-spec",
            "galaxy-gen", "backend", "backend-db", "forgejo", "signoz", "ntfy",
        ]
    ],
}

TARGET = "tailscale"
TARGET_STATE = "/tmp/tailscale-merged.tfstate"


def src_state_path(stack):
    return f"/tmp/{stack}.tfstate"


def prepare(env):
    # Init all four stacks.
    for stack in [*SOURCES, TARGET]:
        run(f"terraform -chdir=terraform/{stack} init", env=env)

    # Drop the source ACL resource from tailscale-oidc state first so we
    # don't migrate the duplicate. State rm from a pulled local file
    # would lose this on push; do it against the live backend now.
    run(
        "terraform -chdir=terraform/tailscale-oidc state rm tailscale_acl.main",
        env=env,
        warn=True,
    )

    # Pull each source to /tmp.
    for stack in SOURCES:
        run(
            f"terraform -chdir=terraform/{stack} state pull > {src_state_path(stack)}",
            env=env,
        )

    # Pull (empty) target state.
    run(
        f"terraform -chdir=terraform/{TARGET} state pull > {TARGET_STATE}",
        env=env,
    )

    # Move every resource from its source-state file into the target file.
    for stack, addrs in SOURCES.items():
        src = src_state_path(stack)
        for addr in addrs:
            run(
                f"terraform -chdir=terraform/{TARGET} state mv "
                f"-state={src} -state-out={TARGET_STATE} {addr!r} {addr!r}",
                env=env,
            )

    print("\n=== Merged state contents ===")
    run(
        f"terraform -chdir=terraform/{TARGET} state list -state={TARGET_STATE}",
        env=env,
    )
    print(
        f"\nPrepared. Merged state at {TARGET_STATE}.\n"
        "Review the addresses above, then run with `push` to land the "
        "merged state in the new backend and print a plan."
    )


def push(env):
    run(
        f"terraform -chdir=terraform/{TARGET} state push {TARGET_STATE}",
        env=env,
    )
    print("\n=== Plan against real tailnet state ===")
    run(f"terraform -chdir=terraform/{TARGET} plan", env=env)


def orphan(env):
    for stack, addrs in SOURCES.items():
        for addr in addrs:
            run(
                f"terraform -chdir=terraform/{stack} state rm {addr!r}",
                env=env,
                warn=True,
            )


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "prepare"
    env = tailscale_admin_oauth_env()
    if action == "prepare":
        prepare(env)
    elif action == "push":
        push(env)
    elif action == "orphan":
        orphan(env)
    else:
        sys.exit(f"unknown action: {action!r}")


if __name__ == "__main__":
    main()
