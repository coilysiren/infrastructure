# ansible

First-class Ansible for the coilysiren fleet. Today it converges macOS
workstation Homebrew state; the layout is built to grow into Linux hosts and
kai-server roles.

## Layout

```
ansible/
├── ansible.cfg                     # repo-local config (inventory, roles, yaml output)
├── inventory/hosts.yml             # `mac` group -> localhost over a local connection
├── inventory/group_vars/mac.yml    # declared taps / formulae / casks (seeded from live)
├── playbooks/mac.yml               # converge a Mac
└── roles/homebrew/                 # taps + formulae + casks via community.general
```

## Usage

```bash
coily ansible-mac-seed              # capture this Mac's brew state into group_vars/mac.yml
coily ansible-mac                   # dry run (--check --diff), mutates nothing
coily ansible-mac action=apply      # converge for real
```

Ansible ships as the `ansible` dependency in the repo's `pyproject.toml`
(uv-managed, version-locked in `uv.lock`); `community.general` Homebrew
modules come bundled. The playbook is **additive** - it ensures declared
packages are present and never uninstalls. Seeding makes a first apply on the
seeded machine a near no-op; curate `group_vars/mac.yml` by hand afterward to
set the fleet baseline.

## Adding a Mac

Add the host under the `mac` group in `inventory/hosts.yml`. Remote Macs need
`ansible_host` + SSH reachability (tailnet); the local control host uses
`ansible_connection: local`.
