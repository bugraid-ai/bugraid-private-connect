# BugRaid runbook — Reverse PrivateLink consumer setup

This is the internal BugRaid runbook for the consumer side. The customer has already run `templates/customer/reverse-privatelink.yml` and sent us three values. We deploy `templates/bugraid/consumer-endpoint.yml`, accept the connection on the customer's side via shared Slack, wire melt-fetcher.

## Prerequisites

| Item | Where |
|---|---|
| Customer's `ServiceName`, `ServiceRegion`, and tool hostname | Shared Slack / TAM handoff doc |
| BugRaid VPC + private subnets in `ap-southeast-1` | `dev-vpc` or `prod-vpc` |
| Pre-existing security group `bugraid-private-connect-sg` allowing outbound to interface endpoints | Created once via `infra/sg/bugraid-private-connect-sg.yml` |
| Customer-slug already created in dev-api integrations | The integration record where we'll swap the tool URL |

## Step-by-step

### Step 1 — Deploy `consumer-endpoint.yml`

```
aws cloudformation create-stack \
  --stack-name bugraid-pc-<customer>-<tool> \
  --template-body file://templates/bugraid/consumer-endpoint.yml \
  --region ap-southeast-1 \
  --parameters \
    ParameterKey=CustomerSlug,ParameterValue=<customer> \
    ParameterKey=ToolName,ParameterValue=<tool> \
    ParameterKey=ToolHostname,ParameterValue=<original-hostname-from-customer> \
    ParameterKey=ToolPort,ParameterValue=<port> \
    ParameterKey=ServiceName,ParameterValue=<service-name-from-customer> \
    ParameterKey=ServiceRegion,ParameterValue=<region-from-customer> \
    ParameterKey=VpcId,ParameterValue=<bugraid-vpc-id> \
    ParameterKey=SubnetIds,ParameterValue=\"<subnet-a>,<subnet-b>\" \
    ParameterKey=SecurityGroupIds,ParameterValue=<bugraid-private-connect-sg-id>

aws cloudformation wait stack-create-complete \
  --stack-name bugraid-pc-<customer>-<tool> --region ap-southeast-1
```

Stack status will be `CREATE_IN_PROGRESS` for ~1 minute, then the endpoint goes into `pendingAcceptance` and the stack waits.

### Step 2 — Ask the customer to accept the connection

Post in the shared Slack channel:

> Endpoint created on our side, pending your acceptance.
> Endpoint ID: `<EndpointId-output>`
> Please run customer-runbook Step 5 (or accept via console: VPC → Endpoint services → `bugraid-<tool>-endpoint-svc` → Endpoint connections → Accept).

Status moves to `available` within 30 seconds of acceptance. CloudFormation stack reaches `CREATE_COMPLETE`.

### Step 3 — Capture the stack outputs

```
aws cloudformation describe-stacks \
  --stack-name bugraid-pc-<customer>-<tool> \
  --query 'Stacks[0].Outputs' \
  --region ap-southeast-1
```

Key output: `ToolHostnameForMeltFetcher` — the URL to put in the customer's integration record. Should be exactly `https://<original-hostname>:<port>`.

### Step 4 — Update the customer's integration in dev-api

The integration record in MongoDB stores the tool's `api_endpoint` (or `endpoint_url` depending on adapter). Swap the public hostname for the same hostname over the PrivateLink path. From inside BugRaid's VPC the new hostname resolves to the endpoint ENIs; from outside it still resolves to whatever the customer's public DNS says (which is fine — melt-fetcher runs inside the VPC).

Patch flow (use dev-api admin endpoint or talk to BE):

```
PATCH /api/v2/integrations/<integration-id>
{
  "credentials": {
    "endpoint": "https://grafana.weworkindia.internal:3000",
    ...other unchanged fields...
  }
}
```

> **No code change in melt-fetcher.** The adapter just sees a different hostname; everything else (auth, headers, query templates) is unchanged.

### Step 5 — Verify end-to-end

From a Fargate task in the melt-fetcher service (use ECS Exec):

```
aws ecs execute-command \
  --cluster bugraid-dev-ai-ml \
  --task <task-id> \
  --container melt-fetcher \
  --interactive --command "/bin/sh"

# Inside the task:
nslookup grafana.weworkindia.internal
# Should return private IPs from BugRaid's VPC CIDR (10.20.x.x)

curl -v https://grafana.weworkindia.internal:3000/api/health
# Should return Grafana's health JSON over TLS
```

If both succeed, trigger a real chaos-console incident on the customer's service. melt-fetcher CloudWatch should show:
- `grafana_fetcher_initialized: ... endpoint=https://grafana.weworkindia.internal:3000`
- `grafana_logs_fetched: ... rows>0` (or whatever data path is exercised)
- No `connection refused` / `DNS resolution failed` errors

### Step 6 — Update tracking

- File a row in the BugRaid customer-onboarding tracker: customer × tool × endpoint-id × deployed-at.
- Add the stack to the `bugraid-private-connect` Terraform-imported list (we'll move CFN stacks into Terraform once we have ≥5).
- Update `docs/feature-flags.md` in the relevant melt-fetcher branch if the adapter has a "use private endpoint" toggle.

## Best practices

1. **Stack naming**: `bugraid-pc-<customer-slug>-<tool>`. Predictable, greppable, deletable.
2. **One Interface Endpoint per tool per customer.** Don't share endpoints across customers — keeps blast-radius and IAM scoping clean.
3. **Same region as melt-fetcher**: BugRaid runs in `ap-southeast-1`; deploy the endpoint stack there. Cross-region PrivateLink is supported (customer in `ap-south-1`/Mumbai is common) but the endpoint itself must be in BugRaid's region.
4. **PrivateDnsEnabled stays `false`**: that flag is only meaningful for AWS-managed services (S3, EC2). For PrivateLink-as-a-service we use our own Private Hosted Zone.
5. **Don't reuse the same Private Hosted Zone across customers.** Each customer's hosted zone is keyed to their own tool hostname. If two customers happen to use the same hostname (very unlikely), separate Route 53 zones in separate stacks keep them isolated.
6. **Acceptance Required stays on the customer side.** We do NOT auto-accept — the customer's manual review is part of their trust gate.

## Rollback

```
aws cloudformation delete-stack \
  --stack-name bugraid-pc-<customer>-<tool> --region ap-southeast-1
```

Cleanly removes the endpoint, Private Hosted Zone, and A-record. melt-fetcher will start failing the next time it tries to resolve the hostname (because the Private Hosted Zone is gone). Revert the integration record in dev-api to whatever public hostname (or stale credentials) the customer was using before.

## Troubleshooting

See `docs/troubleshooting.md` for the full table. Quick reference:

- **`pendingAcceptance` doesn't move**: customer hasn't accepted. Ping them.
- **`nslookup` from Fargate returns NXDOMAIN**: Private Hosted Zone wasn't attached to the right VPC, or the VPC has `enableDnsHostnames=false`. Check `aws route53 list-hosted-zones-by-vpc --vpc-id <bugraid-vpc>`.
- **`curl` returns TLS cert error**: customer's tool cert doesn't cover the hostname we used. Either (a) ask customer for the actual hostname their cert covers and re-deploy with that, or (b) ask customer to add a SAN to their cert.
- **`curl` resolves to a private IP but connects-refused**: customer hasn't accepted yet, or NLB target health-check is failing on the customer side. Ask them to check `aws elbv2 describe-target-health`.

## What this does NOT cover

- SaaS tools (Datadog, New Relic, github.com, atlassian.net) — those need our NAT EIP added to the SaaS network allowlist, not PrivateLink.
- Self-hosted tools outside customer's AWS account (their on-prem DC or another cloud) — needs Site-to-Site VPN or Direct Connect Partner; talk to platform.
- Customer-initiated push (OTel Collector → BugRaid ingest) — separate pattern, see `bugraid-edal-live`.
