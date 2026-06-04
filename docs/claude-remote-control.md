# Claude Code remote-control: install + cleanup runbook

The hosts that drive claude.ai/code's Remote Control dropdown:

| Host                       | OS / runtime | Workdir                            | `--name` / session-name-prefix | Installer |
|----------------------------|--------------|------------------------------------|--------------------------------|-----------|
| kai-server                 | Linux (systemd) | `/home/kai/projects/coilysiren` | `kai-server`                  | [`scripts/claude-remote-control-install.sh`](../scripts/claude-remote-control-install.sh) |
| kai-desktop-tower (WSL)    | Linux (systemd inside WSL2) | `/mnt/x/projects-x/coilysiren` | `kai-desktop-tower-wsl`      | [`scripts/claude-remote-control-install-wsl.sh`](../scripts/claude-remote-control-install-wsl.sh) |
| kai-desktop-tower (native) | Windows (Scheduled Task) | `X:\projects-x\coilysiren`       | `kai-desktop-tower-native`   | [`scripts/claude-remote-control-install-windows.ps1`](../scripts/claude-remote-control-install-windows.ps1) |
| kais-macbook-pro           | macOS (launchd LaunchAgent) | `/Users/kai/projects/coilysiren` | `kais-macbook-pro`          | [`scripts/claude-remote-control-install-macos.sh`](../scripts/claude-remote-control-install-macos.sh) |
| kai-mac-kapwing            | macOS (launchd LaunchAgent) | `/Users/kai/projects`            | `kai-mac-kapwing`           | same installer, env-overridden: `CLAUDE_RC_NAME=kai-mac-kapwing CLAUDE_RC_WORKDIR="$HOME/projects" ./scripts/claude-remote-control-install-macos.sh` |

All hosts pass both `--name` and `--remote-control-session-name-prefix` set to the same value. The dropdown row in claude.ai/code is keyed off the **prefix** (default: `hostname`), not `--name`; `--name` labels the pre-created session inside the daemon. Passing both keeps every surface labelled. Setting the prefix explicitly is what prevents the WSL/Windows-native collision: inside WSL `hostname` returns the Windows host name, so the unscoped default produced two indistinguishable dropdown rows.

Spawn mode: `--spawn same-dir` on all three. The workdir on every host is `projects/coilysiren` (or `projects-x/coilysiren` on the desktop hosts), which is the **parent** of git repos, not a repo. `--spawn worktree` cannot apply there.

## First-time install per host

### kai-server

```bash
cd ~/infrastructure
./scripts/claude-remote-control-install.sh
```

### kai-desktop-tower, WSL side

```bash
# inside the WSL distro, as kai
cd ~/infrastructure   # or wherever this repo is checked out
./scripts/claude-remote-control-install-wsl.sh
```

Prereqs: `claude login` already run once as `kai` inside WSL; `/mnt/x/projects-x/coilysiren` reachable.

First run also drops a `[network] hostname=kai-desktop-tower-wsl` block into `/etc/wsl.conf`. WSL otherwise inherits the Windows host's `COMPUTERNAME` from `gethostname(2)`, which collides with the Windows-native daemon in the dropdown (the bottom-line label is keyed off `gethostname`, not the session-name-prefix). After the installer writes the file, run `wsl --shutdown` once from Windows so `/init` re-reads it on next boot.

### kai-desktop-tower, Windows native

In a non-elevated PowerShell as `firem`:

```powershell
cd X:\projects-x\coilysiren\infrastructure   # or wherever this repo is checked out
.\scripts\claude-remote-control-install-windows.ps1
```

Prereqs: `claude` on PATH (npm-global under `firem`), `claude login` already run once as `firem`, `claude --help` lists a `remote-control` subcommand. The script aborts loudly if any of these fail.

### kais-macbook-pro (macOS)

```bash
cd ~/projects/coilysiren/infrastructure   # or wherever this repo is checked out
./scripts/claude-remote-control-install-macos.sh
```

Prereqs: `claude` on PATH, `claude login` already run once as the user, `claude remote-control --help` lists the subcommand. No sudo - macOS uses a **user LaunchAgent** (`~/Library/LaunchAgents/me.coilysiren.claude-remote-control.plist`), not a root LaunchDaemon, because the daemon needs the user's login keychain, PATH, git/SSH creds, and the workspace under `/Users/kai`. The installer patches `~/.claude.json` (same trust keys as the Linux unit), writes the plist with `claude`'s resolved path plus an explicit PATH for spawned sessions, then `launchctl bootstrap`s it.

**Laptop caveat:** a LaunchAgent only runs while logged in and the Mac is awake. Closed lid -> the dropdown entry goes offline. Unlike always-on kai-server, this host is best-effort - fine for interactive remote control, not for unattended scheduled routines (those should target kai-server).

### kai-mac-kapwing (macOS, Kapwing work mac)

Same installer, two env overrides - a distinct `--name` (or it collides with `kais-macbook-pro` in the dropdown) and a `~/projects` workdir (this host has no `~/projects/coilysiren`; the workspace root is the parent-of-repos `~/projects`, matching the `--spawn same-dir` pattern):

```bash
cd ~/projects/coilyco-flight-deck/infrastructure   # or wherever this repo is checked out
CLAUDE_RC_NAME=kai-mac-kapwing CLAUDE_RC_WORKDIR="$HOME/projects" ./scripts/claude-remote-control-install-macos.sh
```

Same prereqs and laptop caveat as kais-macbook-pro. Because the workdir is `~/projects` (all repos, including Kapwing work), remote sessions spawned here can reach the full workspace - intended, but worth knowing on a work machine.

## Cleanup: removing stale duplicate entries from the dropdown

Background: claude.ai/code's Remote Control dropdown keys on the `--name` the daemon was started with. Old entries linger until you point each side at a unique name and tear down the duplicates.

1. **Stop every running daemon on each host** before changing names. Pick the matching block:

   Linux (kai-server or WSL):
   ```bash
   sudo systemctl stop claude-remote-control.service
   # legacy user unit, if it ever existed
   systemctl --user stop claude.service 2>/dev/null || true
   systemctl --user disable claude.service 2>/dev/null || true
   ```

   Windows-native:
   ```powershell
   Stop-ScheduledTask -TaskName ClaudeRemoteControl -ErrorAction SilentlyContinue
   Get-Process -Name claude -ErrorAction SilentlyContinue | Stop-Process -Force
   ```

2. **Confirm no `claude remote-control` process is left.**

   Linux: `pgrep -af 'claude remote-control'` should print nothing.
   Windows: `Get-Process -Name claude -ErrorAction SilentlyContinue` should return empty.

3. **Refresh the dropdown** in claude.ai/code (full page reload). Stale entries fall off once the daemon backing them stays absent for a few minutes; if one sticks, click into it and let the UI mark it offline.

4. **Re-install** with the new installer for that host (see above). Each installer registers exactly one `--name`.

5. **Confirm exactly one `claude remote-control` per host.** Check each host as in step 2 (this time expecting exactly one match on Linux, one process on Windows). In the claude.ai/code dropdown you should now see up to four live entries: `kai-server`, `kai-desktop-tower-wsl`, `kai-desktop-tower-native`, and `kais-macbook-pro` (the Mac is best-effort, so it shows only while logged in and awake).

## Disabling legacy `claude.service` user units

Older docs in sibling repos shipped a user-scoped `claude.service` (`systemctl --user`). It is superseded by the system-scoped `claude-remote-control.service` installed here. To retire it:

```bash
systemctl --user stop claude.service 2>/dev/null || true
systemctl --user disable claude.service 2>/dev/null || true
rm -f ~/.config/systemd/user/claude.service
systemctl --user daemon-reload
```

## Where the canonical names live

Hard-coded, no env-var fallback to `hostname`. Each installer passes both `--name` and `--remote-control-session-name-prefix` set to the same value:

- `systemd/claude-remote-control.service` -> `kai-server`
- `systemd/claude-remote-control-wsl.service` -> `kai-desktop-tower-wsl`
- `scripts/claude-remote-control-install-windows.ps1` -> default `-Name kai-desktop-tower-native`
- `scripts/claude-remote-control-install-macos.sh` -> default `kais-macbook-pro`; `kai-mac-kapwing` via `CLAUDE_RC_NAME` / `CLAUDE_RC_WORKDIR` env overrides

If you ever add a fourth host, give it a distinct `--name` and add a row to the table above before shipping the installer.
