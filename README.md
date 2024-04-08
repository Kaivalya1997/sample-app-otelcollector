# sample-app-otelcollector

This script automates the setup for monitoring Kubernetes applications with an OpenTelemetry collector using Prometheus and Grafana for a sample application. It prepares a kind cluster, deploys Prometheus and Grafana, and configures an OpenTelemetry collector for advanced monitoring capabilities.

## Prerequisites

- Docker installed and running
- `kubectl` installed and configured
- `helm` installed
- `kind` installed
- Access to a Kubernetes cluster (created with kind)

## Usage

The script accepts arguments through flags for flexibility:

```sh
./setup-monitoring.sh --app-name <app-name> --docker-dir <dockerfile-directory-path> --cluster-name <cluster-name>
