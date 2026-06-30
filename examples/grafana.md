# Example — Self-hosted Grafana

Concrete walk-through for a customer onboarding their internal Grafana to BugRaid. Uses `wework` as the customer slug and `weworkindia.internal` as the internal DNS domain — substitute your own.

## Customer's pre-state

- Grafana running on an EC2 instance behind an internal ALB at `grafana.weworkindia.internal:3000`.
- ALB private IP: `10.0.1.42` (look up via `aws ec2 describe-network-interfaces --filters Name=description,Values='*grafana-alb*'`).
- VPC: `vpc-0abc123def456789a`, private subnets `subnet-aaa` (apse2-az1), `subnet-bbb` (apse2-az2).
- Grafana TLS cert: covers `grafana.weworkindia.internal` (and possibly a wildcard `*.weworkindia.internal`).
- Currently reachable only from corporate VPN — no public IP.

## Step 1 — Customer deploys reverse-privatelink stack

```
aws cloudformation create-stack \
  --stack-name bugraid-pl-grafana \
  --template-body file://templates/customer/reverse-privatelink.yml \
  --region ap-south-1 \
  --parameters \
    ParameterKey=ToolName,ParameterValue=grafana \
    ParameterKey=ToolPort,ParameterValue=3000 \
    ParameterKey=TargetType,ParameterValue=ip \
    ParameterKey=TargetValue,ParameterValue=10.0.1.42 \
    ParameterKey=VpcId,ParameterValue=vpc-0abc123def456789a \
    ParameterKey=SubnetIds,ParameterValue=\"subnet-aaa,subnet-bbb\" \
    ParameterKey=BugRaidAccountId,ParameterValue=528104389666 \
    ParameterKey=BugRaidConsumerRegions,ParameterValue=ap-southeast-1 \
    ParameterKey=HealthCheckProtocol,ParameterValue=TCP
```

Wait for `CREATE_COMPLETE`. Get outputs:

```
aws cloudformation describe-stacks --stack-name bugraid-pl-grafana \
  --query 'Stacks[0].Outputs' --region ap-south-1
```

Yields:

| Output | Value (example) |
|---|---|
| ServiceName | `com.amazonaws.vpce.ap-south-1.vpce-svc-0a1b2c3d4e5f6789a` |
| ServiceRegion | `ap-south-1` |
| ServiceId | `vpce-svc-0a1b2c3d4e5f6789a` |

## Step 2 — Customer sends BugRaid three values via Slack

> @bugraid-tam — Grafana stack deployed.
> ServiceName: `com.amazonaws.vpce.ap-south-1.vpce-svc-0a1b2c3d4e5f6789a`
> ServiceRegion: `ap-south-1`
> Tool hostname: `grafana.weworkindia.internal`

## Step 3 — BugRaid deploys consumer-endpoint stack

```
aws cloudformation create-stack \
  --stack-name bugraid-pc-wework-grafana \
  --template-body file://templates/bugraid/consumer-endpoint.yml \
  --region ap-southeast-1 \
  --parameters \
    ParameterKey=CustomerSlug,ParameterValue=wework \
    ParameterKey=ToolName,ParameterValue=grafana \
    ParameterKey=ToolHostname,ParameterValue=grafana.weworkindia.internal \
    ParameterKey=ToolPort,ParameterValue=3000 \
    ParameterKey=ServiceName,ParameterValue=com.amazonaws.vpce.ap-south-1.vpce-svc-0a1b2c3d4e5f6789a \
    ParameterKey=ServiceRegion,ParameterValue=ap-south-1 \
    ParameterKey=VpcId,ParameterValue=vpc-bugraid-dev \
    ParameterKey=SubnetIds,ParameterValue=\"subnet-bugraid-a,subnet-bugraid-b\" \
    ParameterKey=SecurityGroupIds,ParameterValue=sg-bugraid-private-connect
```

Stack creates the Interface VPC Endpoint (state `pendingAcceptance`), the Private Hosted Zone `grafana.weworkindia.internal.`, and the apex A-record alias.

## Step 4 — Customer accepts the connection

```
aws ec2 accept-vpc-endpoint-connections \
  --service-id vpce-svc-0a1b2c3d4e5f6789a \
  --vpc-endpoint-ids vpce-bugraidside-xyz \
  --region ap-south-1
```

BugRaid's stack moves from `CREATE_IN_PROGRESS` to `CREATE_COMPLETE` within 30s.

## Step 5 — BugRaid updates the integration record

The Grafana integration record in `dev-api` MongoDB currently has:

```json
{
  "credentials": {
    "endpoint": "http://13.229.145.69:3000",
    "bearer_token": "glsa_eyJ...redacted..."
  }
}
```

Update to:

```json
{
  "credentials": {
    "endpoint": "https://grafana.weworkindia.internal:3000",
    "bearer_token": "glsa_eyJ...redacted..."
  }
}
```

`https` because TLS now works (cert matches the hostname). The bearer token is unchanged.

## Step 6 — Verify from melt-fetcher

```
aws ecs execute-command \
  --cluster bugraid-dev-ai-ml \
  --task <task-id> \
  --container melt-fetcher \
  --interactive --command "/bin/sh"
```

From inside the task:

```sh
# 1. DNS resolves privately
$ nslookup grafana.weworkindia.internal
Address: 10.20.5.13     <- endpoint ENI in BugRaid's VPC
Address: 10.20.5.27     <- endpoint ENI in BugRaid's VPC

# 2. TLS handshake succeeds, cert validates
$ curl -v https://grafana.weworkindia.internal:3000/api/health
* Server certificate: CN=grafana.weworkindia.internal     <- cert matches
{"commit":"abc123","database":"ok","version":"10.x.x"}

# 3. With bearer token, an authenticated query works
$ curl -H "Authorization: Bearer ${TOKEN}" \
       https://grafana.weworkindia.internal:3000/api/datasources
[{"id":1,"name":"Prometheus",...}]
```

## Step 7 — Trigger an incident and watch melt-fetcher logs

Use the chaos-console to trigger an incident on a wework service that has Grafana data. CloudWatch group `/ecs/bugraid-dev-ai-ml/melt-fetcher`:

```
grafana_fetcher_initialized: incident_id=bugraid-INC-NNNN, grafana_endpoint=https://grafana.weworkindia.internal:3000
grafana_datasources_discovered: discovered={'prometheus': '...', 'loki': '...'}
grafana_logs_fetched: incident_id=bugraid-INC-NNNN, rows=147
```

Compare against the previous (pre-PrivateLink) run where the same logs would have come from the public IP `13.229.145.69`. Same data, different network path.

## Cost for this example

| | Customer (ap-south-1) | BugRaid (ap-southeast-1) |
|---|---|---|
| NLB | $19/mo | — |
| NLB LCU | $6/mo | — |
| Endpoint Service | $0 | — |
| Interface Endpoint | — | $19/mo (2 AZs) |
| Cross-region data transfer | — | ~$5/mo at typical telemetry volume |
| Private Hosted Zone | — | $0.50/mo |
| **Subtotal** | **$25/mo** | **$24.50/mo** |

Total: ~$50/mo for this single Grafana integration. Compare to deploying a Site-to-Site VPN ($72/mo + complexity) or VPC peering (free but full-VPC trust).

## What did NOT change for the customer

- Grafana's cert — unchanged.
- Grafana's auth — unchanged (still bearer token).
- Grafana's IP, port, internal DNS — unchanged.
- Their VPC route tables, security groups on Grafana itself — unchanged.
- Their corporate VPN — unchanged (employees still reach Grafana exactly as before; we added a parallel private path for BugRaid).

The only new resources in the customer's account are the NLB, target group, listener, endpoint service, and the principal allowlist — all in one CloudFormation stack, all reversible by `delete-stack`.
