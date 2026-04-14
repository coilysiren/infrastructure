# Security: readonly kubectl wrapper for Claude

Claude Code sessions work against kai-server by ssh-ing in as `kai`. To let Claude inspect the cluster without ever prompting for a sudo password or risking destructive operations, there's a narrow NOPASSWD sudoers entry that only allows one binary: a wrapper script that enforces "readonly verbs, no Secret reads."

## The wrapper: `/usr/local/bin/k3s-readonly-kubectl`

A bash script that parses its arguments (flags, flag values, positional args), identifies the verb and resource type, and refuses anything that isn't strictly readonly:

- **Allowed verbs**: `get`, `describe`, `logs`, `top`, `version`, `explain`, `api-resources`, `api-versions`, `cluster-info`, `events`, plus the specific compound verbs `config view` and `auth can-i`.
- **Refused verbs**: everything else (`apply`, `delete`, `edit`, `patch`, `create`, `replace`, `scale`, `rollout`, `drain`, `cordon`, `exec`, `cp`, etc.).
- **Refused resources**: `Secret` reads, no matter how they're spelled. The wrapper skips over flags and their values when locating the resource argument, so `kubectl -n foo get secret`, `kubectl get -n foo secret`, `kubectl get secret,pod`, `kubectl get secret.v1.`, `kubectl get secret/myname` etc. are all rejected. Non-Secret CRDs whose names contain "secret" (`secretstore`, `clustersecretstore`, `externalsecret`) are NOT rejected.

After all checks pass, the wrapper `exec`s the real `/usr/local/bin/k3s kubectl "$@"`.

## The sudoers entry: `/etc/sudoers.d/kai-k3s-readonly`

```
kai ALL=(root) NOPASSWD: /usr/local/bin/k3s-readonly-kubectl, /usr/local/bin/k3s-readonly-kubectl *
```

That's the entire grant. sudo will only pass calls through if the absolute path matches this wrapper; calls to `/usr/local/bin/k3s kubectl ...` directly still require the password.

## Usage

```bash
# Works, password-less:
sudo k3s-readonly-kubectl get pods -A
sudo k3s-readonly-kubectl describe ingress -n coilysiren-backend
sudo k3s-readonly-kubectl logs -n cert-manager deploy/cert-manager --tail=50
sudo k3s-readonly-kubectl top pods -A

# Refused (wrapper prints reason and exits 1):
sudo k3s-readonly-kubectl get secret -A
sudo k3s-readonly-kubectl -n external-secrets get secret
sudo k3s-readonly-kubectl delete pod foo
sudo k3s-readonly-kubectl apply -f manifest.yml

# Still requires password (not gated by the wrapper):
sudo k3s kubectl apply -f manifest.yml
sudo k3s kubectl delete pod foo
```

## Why not just give Claude `view` RBAC on a service account?

1. We'd still need a kubeconfig-resolution path that didn't require sudo, which means chmodding `/etc/rancher/k3s/k3s.yaml` — more exposure than we want.
2. The `view` ClusterRole permits reading Secrets. Our wrapper doesn't.
3. Any access revocation requires deleting RBAC; with sudoers, it's one `rm /etc/sudoers.d/kai-k3s-readonly`.

## Extending the wrapper

Edit `/usr/local/bin/k3s-readonly-kubectl`. The verb allowlist is at the top (`READONLY_VERBS` array). The Secret check walks positional args and normalizes each (strips API group/version and `/name`), so adding more blocked resources is straightforward: append to the check near the end.

Do not loosen the wrapper without also tightening the sudoers scope — the two are a matched pair.
