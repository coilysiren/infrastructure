# Certificates (cert-manager, Let's Encrypt, Route 53)

## Current flow: DNS-01 via Route 53

cert-manager proves domain ownership to Let's Encrypt by writing a TXT record into Route 53. Let's Encrypt reads the record from public DNS. **No HTTP self-check**, no need for the cluster to reach itself over its own public URL, no hairpin NAT dependency.

### Pieces

1. **Route 53 hosted zone** for `coilysiren.me` at zone id `Z06714552N3MO04UBWF33`.
2. **IAM group `route53-coilysiren-me`** with an inline least-privilege policy scoped to that zone. IAM user `kai-server-k3s` is a member.
3. **`route53-credentials` Secret** in the `cert-manager` namespace with a single key `secret-access-key`. Currently hand-placed; mirrors the secret access key from `external-secrets/aws-credentials`.
4. **ClusterIssuers** `letsencrypt-production` and `letsencrypt-staging` in `deploy/cert_manager.yml`. Both use the same `dns01.route53` solver pointing at the zone ID above.
5. **Ingress annotation** `cert-manager.io/cluster-issuer: letsencrypt-production` — the cert-manager ingress shim auto-creates a `Certificate` resource from each annotated Ingress + TLS section.

### Applying changes

```bash
cd ~/projects/infrastructure
inv k8s.cert-manager        # applies upstream cert-manager + our deploy/cert_manager.yml
```

Or just the issuers:

```bash
sudo k3s kubectl apply -f deploy/cert_manager.yml
```

### Rotating the AWS secret access key

When you rotate `kai-server-k3s`'s access key, you must update **two** places:

1. The bootstrap secret used by external-secrets:
   ```bash
   sudo k3s kubectl -n external-secrets create secret generic aws-credentials \
     --from-literal=aws_access_key_id='AKIA_NEW' \
     --from-literal=aws_secret_access_key='NEW_SECRET' \
     --dry-run=client -o yaml | sudo k3s kubectl apply -f -
   sudo k3s kubectl -n external-secrets rollout restart deploy/external-secrets
   ```
2. The `cert-manager/route53-credentials` secret:
   ```bash
   SECRET_KEY=$(sudo k3s kubectl -n external-secrets get secret aws-credentials -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)
   sudo k3s kubectl -n cert-manager create secret generic route53-credentials \
     --from-literal=secret-access-key="$SECRET_KEY" \
     --dry-run=client -o yaml | sudo k3s kubectl apply -f -
   unset SECRET_KEY
   ```

The ClusterIssuer spec has the access key ID in plaintext — update `deploy/cert_manager.yml` too if the access key ID changes.

### Troubleshooting

```bash
# Status of a specific cert
sudo k3s kubectl describe certificate coilysiren-backend-tls -n coilysiren-backend

# Any stuck ACME orders / challenges cluster-wide
sudo k3s kubectl get certificate,certificaterequest,order,challenge -A

# cert-manager controller logs
sudo k3s kubectl logs -n cert-manager deploy/cert-manager --tail=100

# Is the TXT record live on public DNS?
dig +short TXT _acme-challenge.api.coilysiren.me @8.8.8.8

# External HTTPS sanity check
echo | openssl s_client -servername api.coilysiren.me -connect api.coilysiren.me:443 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

To force re-issuance of a stuck cert: delete the Certificate + its Order + CertificateRequest + Challenge in that namespace, and cert-manager will recreate everything from the Ingress annotation.

## Previous (retired) flow: HTTP-01 with hairpin-NAT workaround

Before April 2026, cert-manager used HTTP-01 via traefik. That worked until the home router stopped hairpinning NAT traffic: cert-manager's in-cluster "self check" of the public URL would time out, because packets sent from inside the cluster to the public IP would leave the WAN interface and die.

The original workaround, implemented as `cert_manager_loopback_fix` in `src/k8s.py` (removed April 2026):

1. Scrape all Ingress resources, collect hostname → private-LB-IP mappings
2. Render a CoreDNS ConfigMap from a jinja template with `hosts {}` entries aliasing each public hostname to the internal LB IP
3. Apply the ConfigMap, roll CoreDNS
4. Patch the cert-manager Deployment to remove its default `hostAliases` (which otherwise took precedence over our CoreDNS override)

It worked, then silently stopped working when k3s's addon reconciler overwrote the CoreDNS ConfigMap on a restart. By the time anyone noticed, the production cert had been expired for months.

DNS-01 via Route 53 has no such failure mode. Do not resurrect the HTTP-01 path.
