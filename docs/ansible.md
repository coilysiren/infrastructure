# Ansible

Fleet host-level configuration management. The tree lives at `ansible/` at the repo root.

## Constraints

Two non-standard rules baked in (see [agentic-os-kai#598](https://forgejo.coilysiren.me/coilyco-bridge/agentic-os-kai/issues/598) for the why):

1. **Local-only execution.** Every play runs with `connection: local`. There is no central control node. Each host owns its own checkout of `coilysiren/infrastructure` and runs `ansible-playbook` against itself.
2. **Channel-dispatched orchestration.** Fleet-wide application happens via o2r Agent Channels, not SSH fanout. An on-host worker (separate, [otel-a2a-relay#55](https://forgejo.coilysiren.me/coilyco-flight-deck/otel-a2a-relay/issues/55)) subscribes to a channel for `ansible.task` comms events and runs the local playbook.

The bootstrap of a brand-new host is the one exception - a one-shot scp-then-ssh path until the host owns its own checkout. After bootstrap, the host runs Ansible on itself.

## Layout

```
ansible/
├── ansible.cfg              # local-only defaults, no SSH config
├── inventory/
│   └── local.yml            # single-host inventory: localhost, connection=local
├── playbooks/
│   └── ser8-bootstrap.yml   # first-time bring-up for ser8
├── roles/
│   └── authorized-keys/     # add GitHub-published SSH keys to a local account
└── files/
    └── sudoers-coilysiren-fleet   # canonical sudoers fragment Ansible deploys
```

## Running

On the target host, after the bootstrap one-shot:

```sh
cd /opt/infrastructure   # or wherever the checkout lives
ansible-playbook -i ansible/inventory/local.yml ansible/playbooks/ser8-bootstrap.yml
```

Before the bootstrap, the one-shot path is documented in the channel R9GH state - scp the `ansible/` tree to `/tmp/ansible` on the target, `apt install -y ansible`, run with `--connection=local`.

## authorized-keys role

`roles/authorized-keys` authorizes the SSH public keys that a GitHub user
publishes at `https://github.com/<user>.keys`. The `ansible.posix.authorized_key`
module fetches the URL at converge time, so rotating a key on GitHub propagates
on the next run. Defaults (`roles/authorized-keys/defaults/main.yml`):
`authorized_keys_github_users` (default `[coilysiren]`), `authorized_keys_user`
(default the connecting account), and `authorized_keys_exclusive` (default
`false`, so existing keys are kept). Wired into `ser8-bootstrap.yml`, gated
behind the ser8 host assert in `pre_tasks`.

## Sudoers

The temporary `/etc/sudoers.d/coilysiren-nopasswd` line operators paste at the console during first-time bring-up is **removed** by `ser8-bootstrap.yml` and replaced by the Ansible-managed `/etc/sudoers.d/coilysiren-fleet` shipped from `files/sudoers-coilysiren-fleet`. Same effective permission, but the lineage is Ansible-owned.

## See also

- [agentic-os-kai#598](https://forgejo.coilysiren.me/coilyco-bridge/agentic-os-kai/issues/598) - architecture decision.
- [otel-a2a-relay#55](https://forgejo.coilysiren.me/coilyco-flight-deck/otel-a2a-relay/issues/55) - the o2r Ansible connection plugin follow-up.
- [infrastructure#99](https://forgejo.coilysiren.me/coilyco-flight-deck/infrastructure/issues/99) - cross-site warm standby decision; the ser8 bring-up implements its prerequisites.
