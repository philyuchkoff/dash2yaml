# dashtoyaml

Bash script to convert Grafana JSON dashboards to YAML format for [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack).

## Features

- Convert Grafana JSON dashboards to YAML format
- Fix template variables from `[[var]]` to `$var` format
- Fix datasource references
- Add custom prefix/suffix to dashboard UID
- Specify folder for dashboards (added as comment)
- Custom datasource naming
- Force specific UID
- Optional YAML formatting via `yq`

## Requirements

- `jq` - JSON processor
- `python3` - for template variable fixes
- `yq` (optional) - for YAML formatting

### Installing Dependencies

```bash
# Ubuntu/Debian
sudo apt-get install jq python3

# macOS
brew install jq python3 yq

# CentOS/RHEL
sudo yum install jq python3
```

## Usage

### Basic

```bash
./dashtoyaml.sh dashboard.json dashboards/dashboard.yaml
```

### With prefix and suffix

```bash
./dashtoyaml.sh dashboard.json dashboards/dashboard.yaml \
  --prefix prod_ \
  --suffix _v1
```

### With folder specification

```bash
./dashtoyaml.sh dashboard.json dashboards/dashboard.yaml \
  --folder "Production Dashboards"
```

### With custom datasource

```bash
./dashtoyaml.sh dashboard.json dashboards/dashboard.yaml \
  --datasource "MyPrometheus"
```

### Full options

```bash
./dashtoyaml.sh dashboard.json dashboards/my.yaml \
  --prefix stage_ \
  --suffix _2024 \
  --folder "Stage Dashboards" \
  --datasource "Prometheus"
```

### Force specific UID

```bash
./dashtoyaml.sh dashboard.json dashboards/my.yaml \
  --uid custom-uid
```

## Options

| Option | Description |
|--------|-------------|
| `--prefix TEXT` | Add prefix to dashboard UID |
| `--suffix TEXT` | Add suffix to dashboard UID |
| `--folder NAME` | Specify folder name (added as comment) |
| `--datasource NAME` | Datasource name (default: `Prometheus`) |
| `--uid NAME` | Force specific UID |
| `--help` | Show help message |

## Integration with kube-prometheus-stack

After conversion, deploy dashboards via ConfigMap:

```bash
kubectl create configmap grafana-dashboards \
  --from-file=dashboards/ \
  --dry-run=client \
  -o yaml | kubectl apply -f -
```

Or use Helm values:

```yaml
grafana:
  dashboards:
    dashboard-provider:
      folders:
        - name: Production
          path: /tmp/dashboards/production
        - name: Stage
          path: /tmp/dashboards/stage
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: 'default'
          orgId: 1
          folder: ''
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards/default
```

## Example

Input JSON (`dashboard.json`):

```
{
  "title": "Kubernetes Cluster Monitoring",
  "uid": "cluster-monitoring",
  "panels": [...],
  "templating": {
    "list": [...]
  }
}
```

Output YAML (`dashboards/cluster.yaml`):

```
# cluster.yaml
# Automated generated from dashboard.json
# 2026-05-25 10:30:00
# Directory: Production Dashboards
# Datasource: Prometheus

title: Kubernetes Cluster Monitoring
uid: prod_cluster-monitoring_v1
version: 1
tags:
  - kubernetes
  - monitoring
panels:
  - ...
templating:
  list:
    - ...
```

## License

MIT
