from flask import Flask
import time
from opentelemetry import metrics
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource 
import os

app = Flask(__name__)

# Configure the OTel collector endpoint
collector_endpoint = os.getenv("OTEL_COLLECTOR_ENDPOINT", "otel-collector-1-collector:4317")

resource = Resource(attributes={
    "service.name": "test-hello-world-service"
})

# Configure OpenTelemetry metrics
metrics.set_meter_provider(
    MeterProvider(
        resource=resource,
        metric_readers=[
            PeriodicExportingMetricReader(
                OTLPMetricExporter(endpoint=collector_endpoint, insecure=True),
                export_interval_millis=1000
            )
        ]
    )
)

meter = metrics.get_meter_provider().get_meter(
    "sample-app", "0.1.2"
)

request_counter = meter.create_counter(
    "http_requests_total",
    description="Total number of HTTP requests",
)
request_duration = meter.create_histogram(
    "http_request_duration_milliseconds", 
    description="Duration of HTTP requests in milliseconds",
    unit="ms",
)

@app.route("/")
def hello():
    start_time = time.time()
    response = "Hello, World!"
    duration = (time.time() - start_time) * 1000
    
    request_counter.add(1)
    request_duration.record(duration)
    
    return response

if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=8080)
