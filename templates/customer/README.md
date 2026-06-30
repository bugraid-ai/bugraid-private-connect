# Customer-side CloudFormation templates

Deploy these from the customer's AWS account. They expose one internal tool to BugRaid via PrivateLink. Read [`docs/runbook-customer.md`](../../docs/runbook-customer.md) before deploying.

## `reverse-privatelink.yml`

One template, parameterised for any HTTP/TCP tool. Deploys:

- Internal Network Load Balancer (multi-AZ, TCP passthrough — no cert needed)
- Target Group registered with the customer's tool (IP or instance target)
- TCP Listener at the tool's port
- VPC Endpoint Service in front of the NLB
- Principal allowlist with BugRaid's AWS account

**Run one stack per tool** — name them `bugraid-pl-grafana`, `bugraid-pl-jira`, etc. Independent rollback per tool matters.

## Required parameters

See the `ParameterGroups` block in the template, or use the CloudFormation console form — every field has inline description text.

## Outputs to send to BugRaid

After `CREATE_COMPLETE`, send these three values to your BugRaid TAM:

1. `ServiceName` — full `com.amazonaws.vpce.<region>.vpce-svc-…` string
2. `ServiceRegion` — the region you deployed in
3. The internal hostname your team uses to reach this tool (e.g. `grafana.your-company.internal`)

BugRaid uses these three values to create their Interface Endpoint and Private Hosted Zone.

## What this does NOT create

- IAM roles / users for BugRaid (none needed — PrivateLink uses AWS principal trust)
- DNS changes in your account (BugRaid creates a Private Hosted Zone scoped to *their* VPC only)
- Security group changes to your tool (BugRaid never touches your tool's SG)
- Changes to your tool's TLS cert or auth (TCP passthrough preserves them)
