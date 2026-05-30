# lunch-money deployment

Deploys the [lunch-money-k8s](https://github.com/coilyco-flight-deck/lunch-money-k8s) MCP
server to the kai-server k3s cluster. The chart lives in that repo. This folder
holds the real deployment values and the token wiring.

## Deploy

```
sudo k3s kubectl apply -f deploy/lunch-money/secret.yml
helm install lunch-money <lunch-money-k8s-checkout>/chart \
  -n lunch-money -f deploy/lunch-money/values.yaml
```

`secret.yml` creates the namespace and an ExternalSecret that pulls the API
token from SSM. The Helm release reads that Secret via `lunchMoney.existingSecret`.

Upgrade with `helm upgrade lunch-money ...` using the same values file.

## SSM configs

All Lunch Money config lives in AWS SSM under `/coilysiren/lunchmoney/`. The
parameter names are documented openly here - the values stay in SSM. Read one
with `coily ops aws ssm get-parameter --name <path>`.

- `/coilysiren/lunchmoney/api-token` - SecureString. Lunch Money developer API
  token. Consumed by the ExternalSecret above.
- `/coilysiren/lunchmoney/category-ids` - String. JSON map of category name to
  Lunch Money category id, e.g. `{"Groceries": 2871198, ...}`. The source of
  truth for budgeting integers and the auto-categorization seed.

Budget amounts per category are set through the MCP server's `upsert_budget`
tool against the ids in `category-ids`.
