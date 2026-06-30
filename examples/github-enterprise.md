# Example — GitHub Enterprise Server (self-hosted)

For customers running **GHE Server** (the self-hosted variant) inside their VPC. NOT applicable to GitHub Enterprise Cloud (github.com SaaS) — for that, use BugRaid's NAT EIP allowlist.

## Differences from the Grafana example

| Field | Grafana | GHE Server |
|---|---|---|
| ToolName | `grafana` | `ghe` |
| ToolPort | `3000` | `443` (or `8443` if you've remapped) |
| HealthCheckProtocol | `TCP` | `HTTPS` |
| HealthCheckPath | `/` | `/_ping` (GHE management API) |
| TargetType | `ip` | `instance` if running on a single primary EC2 |
| Internal hostname | `grafana.weworkindia.internal` | `github.weworkindia.internal` |

## Customer deploy

```
aws cloudformation create-stack \
  --stack-name bugraid-pl-ghe \
  --template-body file://templates/customer/reverse-privatelink.yml \
  --region <customer-region> \
  --parameters \
    ParameterKey=ToolName,ParameterValue=ghe \
    ParameterKey=ToolPort,ParameterValue=443 \
    ParameterKey=TargetType,ParameterValue=instance \
    ParameterKey=TargetValue,ParameterValue=i-0ghe... \
    ParameterKey=VpcId,ParameterValue=<vpc-id> \
    ParameterKey=SubnetIds,ParameterValue=\"<subnet-a>,<subnet-b>\" \
    ParameterKey=HealthCheckProtocol,ParameterValue=HTTPS \
    ParameterKey=HealthCheckPath,ParameterValue=/_ping
```

## Auth notes

GHE uses Personal Access Tokens (classic or fine-grained) or GitHub App installation tokens. BugRaid prefers fine-grained PATs scoped to the specific orgs/repos we read from. Token rotation is handled by the customer; PrivateLink doesn't change rotation cadence.

## Webhooks (if needed)

If wework also wants to push webhook events from GHE to BugRaid, the direction reverses: GHE inside the customer's VPC needs to reach BugRaid's ingest endpoint. That's a separate pattern documented in the `bugraid-edal-live` repo (BugRaid-as-provider for OTel push). PrivateLink supports both directions but each is its own stack.

## Verify

```
./scripts/verify-private-path.sh github.weworkindia.internal 443 /_ping
```

Expected: HTTP 200 with body `pong`. After token is configured, the adapter fetches commit/PR data via `/api/v3/repos/<org>/<repo>/...`.
