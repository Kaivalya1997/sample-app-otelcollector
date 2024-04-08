#!/bin/bash

# We need the app-name, dockerfile dir and the kind cluster's name as arguments
# Initialize these variables
APP_NAME=""
DOCKERFILE_DIR=""
CLUSTER_NAME=""


# Define a function to print usage
usage() {
    echo "Usage: $0 --app-name <app-name> --docker-dir <dockerfile-directory-path> --cluster-name <cluster-name>"
    exit 1
}

# Use getopt to parse long options
TEMP=$(getopt -o a:d:c: --long app-name:,docker-dir:,cluster-name: -- "$@")
if [ $? != 0 ]; then echo "Terminating..." >&2; exit 1; fi

eval set -- "$TEMP"

# Extract options and their arguments into variables
while true; do
    case "$1" in
        -a | --app-name)
            APP_NAME="$2"; shift 2;;
        -d | --docker-dir)
            DOCKERFILE_DIR="$2"; shift 2;;
        -c | --cluster-name)
            CLUSTER_NAME="$2"; shift 2;;
        --)
            shift; break;;
        *)
            usage;;
    esac
done

# Check for required arguments
if [ -z "${APP_NAME}" ] || [ -z "${DOCKERFILE_DIR}" ] || [ -z "${CLUSTER_NAME}" ]; then
    usage
fi

echo "##################################################"
echo "This setup assumes you have a kind cluster with name "${CLUSTER_NAME}" already created. If not, create it first..."
echo "##################################################"
echo ""

# Assuming kind is already installed, and a cluster is ready
# If you need to create a kind cluster, uncomment the following line and specify the cluster name
# kind create cluster --name cluster1
echo "##################################################"
echo "Setting kubectl context to kind-${CLUSTER_NAME}..."
echo "##################################################"
echo ""

# Set the context to point the cluster
kubectl cluster-info --context kind-${CLUSTER_NAME}

echo "##################################################"
echo "Building Docker image ${APP_NAME}:latest..."
echo "##################################################"
echo ""

# Navigate to the Dockerfile directory and build the docker image
cd $DOCKERFILE_DIR || exit
docker build -t $APP_NAME:latest .

echo "##################################################"
echo "Loading the Docker image into the kind cluster..."
echo "##################################################"
echo ""

# Load the docker image into the kind cluster
kind load docker-image $APP_NAME:latest --name ${CLUSTER_NAME}

echo "##################################################"
echo "Installing Prometheus and Grafana..."
echo "##################################################"
echo ""

# Install prometheus and grafana
kubectl create namespace monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace monitoring


echo "##################################################"
echo "Enabling remote-write-receiver feature for Prometheus..."
echo "##################################################"
echo ""

# Enable remote-write-receiver feature for Prometheus
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --set prometheus.prometheusSpec.enableFeatures={remote-write-receiver} --reuse-values -n monitoring

echo "##################################################"
echo "Installing cert-manager..."
echo "##################################################"
echo ""

# Install the openTelemetry operator, cert-manager is a prerequisite
# OpenTelemetry operator will install all the necessary CRDs which are needed to create a collector
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
sleep 60

echo "##################################################"
echo "Installing the openTelemetry operator..."
echo "##################################################"
echo ""

kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
sleep 30

echo "##################################################"
echo "Disabling default scraping of kube-state-metrics, kubelet, cadvisor, and node_exporter metrics..."
echo "##################################################"
echo ""

# Disable the default scraping of kube-state-metrics, kubelet, cadvisor and node_exporter metrics from prometheus backend
# by updating the helm config for prometheus
# We will be pulling the above mterics from the otel collector and then pushing it to prometheus backend later

helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --reuse-values  --namespace monitoring \
  --set kubelet.enabled=false \
  --set nodeExporter.enabled=false \
  --set kubeStateMetrics.enabled=false

echo "##################################################"
echo "Creating an OpenTelemetry collector with name otel-collector-1..."
echo "##################################################"
echo ""

# Create a opentelemetry collector, with exporter as prometheusremotewrite and receiver as otlp and prometheus
# We will also be pulling the kube-state-metrics, kubelet, cadvisor and node_exporter metrics from the collector, so we need a prometheus receiver as well

kubectl apply -f - <<EOF
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector-1
spec:
  config: |
    receivers:
      otlp:
        protocols:
          http:
            endpoint: 0.0.0.0:4318
          grpc:
            endpoint: 0.0.0.0:4317  
      prometheus:
        config:
          scrape_configs:
            - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
              job_name: integrations/kubernetes/cadvisor
              kubernetes_sd_configs:
                - role: node
              relabel_configs:
                - replacement: kubernetes.default.svc.cluster.local:443
                  target_label: __address__
                - regex: (.+)
                  replacement: /api/v1/nodes/$${1}/proxy/metrics/cadvisor
                  source_labels:
                    - __meta_kubernetes_node_name
                  target_label: __metrics_path__
              scheme: https
              tls_config:
                ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
                insecure_skip_verify: false
                server_name: kubernetes
            - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
              job_name: integrations/kubernetes/kubelet
              kubernetes_sd_configs:
                - role: node
              relabel_configs:
                - replacement: kubernetes.default.svc.cluster.local:443
                  target_label: __address__
                - regex: (.+)
                  replacement: /api/v1/nodes/$${1}/proxy/metrics
                  source_labels:
                    - __meta_kubernetes_node_name
                  target_label: __metrics_path__
              scheme: https
              tls_config:
                ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
                insecure_skip_verify: false
                server_name: kubernetes
            - job_name: integrations/kubernetes/kube-state-metrics
              kubernetes_sd_configs:
                - role: pod
              relabel_configs:
                - action: keep
                  regex: kube-state-metrics
                  source_labels:
                    - __meta_kubernetes_pod_label_app_kubernetes_io_name
            - job_name: integrations/node_exporter
              kubernetes_sd_configs:
                - role: pod
              relabel_configs:
                - action: keep
                  regex: prometheus-node-exporter.*
                  source_labels:
                    - __meta_kubernetes_pod_label_app_kubernetes_io_name
                - action: replace
                  source_labels:
                    - __meta_kubernetes_pod_node_name
                  target_label: instance
                - action: replace
                  source_labels:
                    - __meta_kubernetes_namespace
                  target_label: namespace 
    exporters:
      prometheusremotewrite:
        endpoint: 'http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write'
        tls:
          insecure: true
    service:
      pipelines:
        metrics:
          receivers: [otlp, prometheus]
          exporters: [prometheusremotewrite]

EOF

# We need to create a clusterrole and clusterrolebinding to give adequate permissions to the service account of the otel collector
# A service account will already be deployed by the otel operator in the collector pod's namespace with typically the same name as the 
# the above deployment + suffix "-collector" (eg. otel-collector-1-collector for the above deployment)

kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector
rules:
  - apiGroups:
      - ''
    resources:
      - nodes
      - nodes/proxy
      - services
      - endpoints
      - pods
      - events
    verbs:
      - get
      - list
      - watch
  - nonResourceURLs:
      - /metrics
    verbs:
      - get

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector
subjects:
  - kind: ServiceAccount
    name: otel-collector-1-collector # replace with your service account name for the otel-collector deployed by the operator
    namespace: default # replace with your namespace
roleRef:
  kind: ClusterRole
  name: otel-collector
  apiGroup: rbac.authorization.k8s.io

EOF


# Deploy the application in a deployment (also deploys the node-port service to access the app outside)

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
      - name: ${APP_NAME}-cont
        image: ${APP_NAME}:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 8080
        env:
        - name: OTEL_COLLECTOR_ENDPOINT
          value: "otel-collector-1-collector:4317" #Make sure to pass the endpoint of the grpc or http otel collector
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-nodeport
spec:
  type: NodePort
  selector:
    app: ${APP_NAME}
  ports:
    - protocol: TCP
      port: 8080
      targetPort: 8080
EOF

echo "##################################################"

echo "Setup otel collector successfully."
echo ""

echo "##################################################"
echo "Setting up port forwarding for Prometheus and Grafana..."
echo "##################################################"
echo ""

# Portforward so that we can access them from the browser, will run in the background
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring > /dev/null 2>&1 &
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring > /dev/null 2>&1 &
echo "Prometheus UI is now accessible on http://localhost:9090 and grafana on http:/localhost:3000"

echo ""
# Instructions for load testing and verifying metrics
echo "To test whether the app is accessible, follow these instructions:"
echo ""

# Additional commands to get service port, node IP, and test the app
echo "Use the following command to get the port which the service is running on:"
echo "kubectl get svc --no-headers | grep '<app-name>-nodeport' | awk '{print \$5}'"

echo ""
echo "Use the following command to get the internal IP of the node:"
echo "kubectl get nodes -o wide"

echo ""
echo "Replace <internal-ip> and <service-port> in the following command to test if the app is accessible:"
echo "curl http://<internal-ip>:<service-port>"

# Finally check if you are getting the metrics correctly in the prometheus UI and grafana
# We should get metrics exposed by the app and also the kubernetes metrics (exposed by kube-state-metrics, kubelet, cadvisor and node_exporter metrics)


