##Build docker image from the python opentelemetry metrics sample code
git clone https://github.com/Kaivalya1997/sample-app-otelcollector.git
cd sample-app-otelcollector
docker build -t sample-app:latest .
kind create cluster --name cluster1
kubectl cluster-info --context kind-cluster1
kind load docker-image sample-app:latest --name cluster1

##Install prometheus and grafana
kubectl create namespace monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace monitoring

#Portforward so that we can access them from the browser, will run in the background
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring > /dev/null 2>&1 & #promUI will be available at localhost:9090
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring > /dev/null 2>&1 & #grafana will be available at localhost:3000

##We have to update prometheus settings to enable remote-write-receiver
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --set prometheus.prometheusSpec.enableFeatures={remote-write-receiver} --reuse-values  -n monitoring

##Install the openTelemetry operator, cert-manager is a prerequisite
##OpenTelemetry operator will install all the necessary CRDs which are needed to create a collector
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml

sleep 30

kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

sleep 30


##Create a opentelemetry collector, with exporter as prometheusremotewrite and receiver as otlp

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
    exporters:
      prometheusremotewrite:
        endpoint: 'http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write'
        tls:
          insecure: true
    service:
      pipelines:
        metrics:
          receivers: [otlp]
          exporters: [prometheusremotewrite]
EOF


##deploy sample-app in a deployment (also deploys the node-port service to access the app outside)

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: sample-app
  template:
    metadata:
      labels:
        app: sample-app
    spec:
      containers:
      - name: sample-app-cont
        image: sample-app:latest
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
  name: sample-app-nodeport
spec:
  type: NodePort
  selector:
    app: sample-app
  ports:
    - protocol: TCP
      port: 8080
      targetPort: 8080
EOF

#Check the output of this to get the port which the service is running on
kubectl get svc --no-headers | grep 'sample-app-nodeport' | awk '{print $5}'

#check the internal ip of the node to curl the service
kubectl get nodes -o wide

#check if you successfully get the output from the app
curl http://<internal-ip-above>:<service-port-above>

##To test the above code and check if we are successfully getting the metrics in prometheus or not, we need to create a load on the app
ab -n 100 -c 100 http://<internal-ip-above>:<service-port-above>/

##Finally check if you are getting the metrics correctly in the prometheus UI and grafana

