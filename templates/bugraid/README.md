# BugRaid-side CloudFormation templates

Deploy these from BugRaid's AWS account (`528104389666`) in `ap-southeast-1`. Read [`docs/runbook-bugraid.md`](../../docs/runbook-bugraid.md) before deploying.

## `consumer-endpoint.yml`

One template per customer per tool. Deploys:

- Interface VPC Endpoint targeting the customer's `ServiceName`
- Private Hosted Zone for the tool's hostname, scoped to BugRaid's VPC only
- A-record alias from the hostname to the endpoint ENIs

After deploy, melt-fetcher inside BugRaid's VPC can resolve `https://<tool-hostname>:<port>` and reach the customer's tool over the AWS backbone, with the tool's existing TLS cert validated correctly.

## Stack naming

Use `bugraid-pc-<customer-slug>-<tool>`:

- `bugraid-pc-wework-grafana`
- `bugraid-pc-qubehealth-prometheus`
- `bugraid-pc-taxbuddy-jira`

Predictable, greppable, deletable.

## Required inputs (from customer)

The customer's `reverse-privatelink.yml` stack outputs three values they hand off:

1. `ServiceName` → goes into the `ServiceName` parameter here
2. `ServiceRegion` → goes into the `ServiceRegion` parameter here
3. Tool internal hostname → goes into the `ToolHostname` parameter here

BugRaid-internal values:

- `VpcId`, `SubnetIds`: from `infra/vpc-bugraid-dev` or `infra/vpc-bugraid-prod`
- `SecurityGroupIds`: use the pre-existing `bugraid-private-connect-sg`

## After deploy

Update the customer's integration record in dev-api to use the new `ToolHostnameForMeltFetcher` output URL. Then verify via `scripts/verify-private-path.sh` from a melt-fetcher Fargate task.
