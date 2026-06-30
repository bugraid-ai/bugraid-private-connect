# Example — Prometheus / Mimir / Thanos

For customers running self-hosted Prometheus (or one of the long-term-storage forks: Cortex, Mimir, Thanos, VictoriaMetrics) inside their VPC.

## Differences from the Grafana example

| Field | Grafana | Prometheus |
|---|---|---|
| ToolName | `grafana` | `prometheus` |
| ToolPort | `3000` | `9090` (default), `8080` (Mimir), `10901` (Thanos query) |
| HealthCheckProtocol | `TCP` | `HTTP` or `HTTPS` |
| HealthCheckPath | `/` | `/-/healthy` (Prometheus), `/ready` (Mimir) |
| TargetType | `ip` | `ip` (usually behind ALB or EKS service) |
| Internal hostname | `grafana.weworkindia.internal` | `prometheus.weworkindia.internal` |

## Multi-tenant Prometheus (Mimir / Cortex)

For Mimir or Cortex with the `X-Scope-OrgID` header for multi-tenancy:

- The PrivateLink layer doesn't change anything. melt-fetcher's Prometheus adapter already sends `X-Scope-OrgID` from the integration's credentials. Just point at the new hostname.
- See `melt-fetcher/src/adapters/prometheus/` — the multi-tenant header is read from `credentials.tenant_id`.

## Customer deploy

```
aws cloudformation create-stack \
  --stack-name bugraid-pl-prometheus \
  --template-body file://templates/customer/reverse-privatelink.yml \
  --region <customer-region> \
  --parameters \
    ParameterKey=ToolName,ParameterValue=prometheus \
    ParameterKey=ToolPort,ParameterValue=9090 \
    ParameterKey=TargetType,ParameterValue=ip \
    ParameterKey=TargetValue,ParameterValue=<prom-internal-ip> \
    ParameterKey=VpcId,ParameterValue=<vpc-id> \
    ParameterKey=SubnetIds,ParameterValue=\"<subnet-a>,<subnet-b>\" \
    ParameterKey=HealthCheckProtocol,ParameterValue=HTTP \
    ParameterKey=HealthCheckPath,ParameterValue=/-/healthy
```

## TLS

If the customer's Prometheus uses HTTP (not HTTPS), set `HealthCheckProtocol=HTTP` and accept that the connection inside their VPC is plaintext. PrivateLink itself runs over the AWS backbone which AWS encrypts at L1, so even plaintext-at-the-app-layer is acceptable here for many customers. For HIPAA/PCI environments, ensure Prometheus is fronted by TLS (reverse-proxy or sidecar).

## Verify

```
./scripts/verify-private-path.sh prometheus.weworkindia.internal 9090 /-/healthy
```

Expected: HTTP 200 body `Prometheus is Healthy.`. Then a real query:

```
curl -s "https://prometheus.weworkindia.internal:9090/api/v1/query?query=up" | jq '.data.result | length'
```

Should return the number of `up` series, confirming end-to-end data flow.
