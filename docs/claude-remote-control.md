# Claude Code remote-control: install + cleanup runbook

The three hosts that drive claude.ai/code's Remote Control dropdown:

| Host                       | OS / runtime | Workdir                            | `--name`                    | Installer |
|----------------------------|--------------|------------------------------------|-----------------------------|-----------|
| kai-server                 | Linux (systemd) | `/home/kai`                     | `kai-server`                | [`scripts/claude-remote-control-install.sh`](../scripts/claude-remote-control-install.sh) |
| kai-desktop-tower (WSL)    | Linux (systemd inside WSL2) | `/mnt/x/projects-x/coilysiren` | `kai-desktop-tower-wsl`    | [`scripts/claude-remote-control-install-wsl.sh`](../scripts/claude-remote-control-install-wsl.sh) |
| kai-desktop-tower (native) | Windows (Scheduled Task) | `X:\projects-x\coilysiren`       | `kai-desktop-tower-native` | [`scripts/claude-remote-control-install-windows.ps1`](../scripts/claude-remote-control-install-windows.ps1) |

All three pass `--name` explicitly. None derive it from `hostname` — inside WSL `hostname` returns the Windows host name, which is what produced the duplicate-entry bug in the dropdown.

Spawn mode:

- kai-server: `--spawn worktree` (current; workdir is `/home/kai`).
- WSL / Windows-native: `--spawn same-dir`. The workdir on both desktop hosts is `projects-x/coilysiren`, which is the **parent** of git repos, not a repo. `--spawn worktree` cannot apply there.

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

### kai-desktop-tower, Windows native

In a non-elevated PowerShell as `firem`:

```powershell
cd X:\projects-x\coilysiren\infrastructure   # or wherever this repo is checked out
.\scripts\claude-remote-control-install-windows.ps1
```

Prereqs: `claude` on PATH (npm-global under `firem`), `claude login` already run once as `firem`, `claude --help` lists a `remote-control` subcommand. The script aborts loudly if any of these fail.

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

5. **Confirm exactly one `claude remote-control` per host.** Check each host as in step 2 (this time expecting exactly one match on Linux, one process on Windows). In the claude.ai/code dropdown you should now see exactly three live entries: `kai-server`, `kai-desktop-tower-wsl`, `kai-desktop-tower-native`.

## Disabling legacy `claude.service` user units

Older docs in sibling repos shipped a user-scoped `claude.service` (`systemctl --user`). It is superseded by the system-scoped `claude-remote-control.service` installed here. To retire it:

```bash
systemctl --user stop claude.service 2>/dev/null || true
systemctl --user disable claude.service 2>/dev/null || true
rm -f ~/.config/systemd/user/claude.service
systemctl --user daemon-reload
```

## Where the canonical names live

Hard-coded, no env-var fallback to `hostname`:

- `systemd/claude-remote-control.service` -> `--name kai-server`
- `systemd/claude-remote-control-wsl.service` -> `--name kai-desktop-tower-wsl`
- `scripts/claude-remote-control-install-windows.ps1` -> default `-Name kai-desktop-tower-native`

If you ever add a fourth host, give it a distinct `--name` and add a row to the table above before shipping the installer.
