locals {
  dashboard_dir = "${path.module}/dashboards"
}

# Dashboards are authored in YAML for editor-readability. The grafana
# provider wants JSON, so we yamldecode then jsonencode at apply time.
resource "grafana_dashboard" "eco_telemetry" {
  config_json = jsonencode(yamldecode(file("${local.dashboard_dir}/eco-telemetry.yaml")))
  overwrite   = true
}
