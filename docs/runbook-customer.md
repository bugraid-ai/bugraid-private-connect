# Customer runbook — Reverse PrivateLink to BugRaid

This runbook is what you (the customer) follow to expose one internal tool to BugRaid AI over AWS PrivateLink. Walking through this end-to-end takes about 20 minutes.

> **Read first**: [architecture.md](architecture.md) — explains what's being built and why. Skim [security-faq.md](security-faq.md) if you have a security review board to satisfy.

## Prerequisites

| Item | How to confirm |
|---|---|
| AWS account access with permission to create NLB, VPC Endpoint Service, target group | IAM role has `ec2:*`, `elasticloadbalancing:*` on the relevant VPC |
| Internal tool is reachable from inside your VPC | `curl -kv https://<tool-ip>:<port>` from any EC2 instance in the VPC returns the tool |
| Two private subnets in different AZs in the same VPC as the tool | `aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id>` shows ≥2 subnets in distinct `AvailabilityZone`s |
| BugRaid TAM has confirmed BugRaid's AWS account ID | Default `528104389666`. Confirm before running. |
| Tool's current internal hostname is known | e.g. `grafana.weworkindia.internal`. Send to BugRaid in step 4. |

## Worksheet — fill in before you start

| Parameter | Your value |
|---|---|
| `ToolName` (one of: `grafana`, `jira`, `prometheus`, `ghe`, …) | |
| `ToolPort` (TCP port, e.g. `3000` for Grafana, `443` for GHE, `9090` for Prometheus) | |
| `TargetType` (`ip` or `instance`) | |
| `TargetValue` (private IP or instance-id) | |
| `VpcId` (`vpc-…`) | |
| `SubnetIds` (≥2, in different AZs) | |
| `BugRaidAccountId` (default `528104389666` — confirm with TAM) | |
| `BugRaidConsumerRegions` (default `ap-southeast-1`) | |
| Tool's internal hostname (sent to BugRaid at the end) | |

## Step-by-step

### Step 1 — Download the template

```
curl -O https://raw.githubusercontent.com/bugraid-ai/bugraid-private-connect/main/templates/customer/reverse-privatelink.yml
```

Or clone the repo and use `templates/customer/reverse-privatelink.yml` directly.

### Step 2 — Validate it locally (optional but recommended)

```
aws cloudformation validate-template \
  --template-body file://reverse-privatelink.yml \
  --region <your-region>
```

Should print the parameter list with no error.

### Step 3 — Deploy the stack

Console path (easier for first-timers):

1. Open **CloudFormation → Create stack → With new resources (standard)** in the region where your tool lives.
2. Upload `reverse-privatelink.yml`.
3. Stack name: `bugraid-pl-<tool>` (e.g. `bugraid-pl-grafana`).
4. Fill the parameters from your worksheet. The form has inline descriptions.
5. Acknowledge the IAM capabilities checkbox (the template doesn't create IAM but CloudFormation always asks).
6. **Create stack**. Wait ~3 minutes for `CREATE_COMPLETE`.

CLI path:

```
aws cloudformation create-stack \
  --stack-name bugraid-pl-grafana \
  --template-body file://reverse-privatelink.yml \
  --region <your-region> \
  --parameters \
    ParameterKey=ToolName,ParameterValue=grafana \
    ParameterKey=ToolPort,ParameterValue=3000 \
    ParameterKey=TargetType,ParameterValue=ip \
    ParameterKey=TargetValue,ParameterValue=10.0.1.42 \
    ParameterKey=VpcId,ParameterValue=vpc-0123456789abcdef0 \
    ParameterKey=SubnetIds,ParameterValue=\"subnet-aaa,subnet-bbb\" \
    ParameterKey=BugRaidAccountId,ParameterValue=528104389666 \
    ParameterKey=BugRaidConsumerRegions,ParameterValue=ap-southeast-1

aws cloudformation wait stack-create-complete \
  --stack-name bugraid-pl-grafana --region <your-region>
```

### Step 4 — Send three values to BugRaid

After the stack reaches `CREATE_COMPLETE`, get the outputs:

```
aws cloudformation describe-stacks \
  --stack-name bugraid-pl-grafana \
  --query 'Stacks[0].Outputs' \
  --region <your-region>
```

Send your BugRaid TAM exactly these three values (via your shared Slack channel or email):

| Field | Where to find it |
|---|---|
| **Service Name** | `ServiceName` output (looks like `com.amazonaws.vpce.<region>.vpce-svc-XXXXXXX`) |
| **Service Region** | `ServiceRegion` output |
| **Tool internal hostname** | The hostname your team uses today to reach this tool internally, e.g. `grafana.weworkindia.internal`. We need the exact string — capitalisation, subdomains, all of it. |

> Why hostname? BugRaid creates a Private Hosted Zone in their VPC that resolves this hostname to the endpoint. Your tool's existing TLS cert (which covers this hostname) keeps working. Zero cert changes for you.

### Step 5 — Accept BugRaid's endpoint connection

After BugRaid runs their stack on their side, your VPC console will show a pending connection. You accept it once.

Console path:

1. **VPC → Endpoint services → bugraid-`<tool>`-endpoint-svc** (the one you just created).
2. **Endpoint connections** tab.
3. Select the pending connection from account `528104389666`.
4. **Actions → Accept endpoint connection**.

CLI path:

```
# Get the endpoint-id BugRaid gives you (their stack output), then:
aws ec2 accept-vpc-endpoint-connections \
  --service-id <ServiceId-from-your-stack-output> \
  --vpc-endpoint-ids <vpce-id-from-bugraid> \
  --region <your-region>
```

Status changes from `pendingAcceptance` to `available` in ~30 seconds.

### Step 6 — Verify

From an EC2 instance inside your VPC:

```
# 1. Confirm your tool is still reachable directly (this should not have changed):
curl -kv https://<tool-ip>:<port>/

# 2. Confirm the NLB also reaches the tool:
nslookup bugraid-<tool>-nlb-<random>.elb.<region>.amazonaws.com
curl -kv https://<nlb-dns-from-console>:<port>/
```

If both return the tool's response, the customer side is correctly wired up. BugRaid will run their own verification from their side and confirm in your shared Slack channel.

## Best practices

1. **One stack per tool, not per tenant.** Each tool gets its own `bugraid-pl-<tool>` stack. Don't put Grafana and Jira in one stack — independent rollback matters.
2. **Use the `instance` target type only when the tool runs directly on EC2.** For tools behind ALBs/ECS Services, use `ip` and point at the ALB's private IPs (look up via `aws ec2 describe-network-interfaces`).
3. **Health check protocol.** Default `TCP` is safest. Switch to `HTTPS` only if your tool has an unauthenticated `/health` endpoint — otherwise the NLB will mark targets unhealthy. (Most tools require auth even on `/`.)
4. **Don't change the `Acceptance Required` setting to false.** It's a deliberate gate. Every new BugRaid endpoint connection should be manually reviewed once.
5. **Tag the stack with your normal cost-allocation tags.** Add them via `--tags Key=...,Value=...` on `create-stack`. The NLB inherits them.
6. **Rolling out to more tools?** Run the template again with different parameters. Each tool = its own stack. The pattern composes.
7. **Updating the target IP?** If the tool's underlying IP changes (e.g. you replaced the EC2), update the `TargetValue` parameter and re-deploy the stack. CloudFormation handles the target-group registration swap.

## Rollback

If anything goes wrong or you want to revoke access:

```
# Customer side — delete the whole stack:
aws cloudformation delete-stack --stack-name bugraid-pl-grafana --region <your-region>
```

This destroys the NLB, target group, endpoint service, and principal allowlist in that order. BugRaid's interface endpoint becomes `rejected` and traffic stops immediately. No coordination required.

To keep the infrastructure but temporarily block BugRaid, remove the principal allowlist instead:

```
aws ec2 modify-vpc-endpoint-service-permissions \
  --service-id <ServiceId-from-your-stack-output> \
  --remove-allowed-principals arn:aws:iam::528104389666:root \
  --region <your-region>
```

Re-add the same principal ARN to restore access.

## What to send if something is wrong

If verification fails, send your BugRaid TAM:

1. The full stack output (`describe-stacks --query 'Stacks[0].Outputs'`).
2. The endpoint service status (`describe-vpc-endpoint-service-configurations --service-ids <id>`).
3. The connection list (`describe-vpc-endpoint-connections --filters Name=service-id,Values=<id>`).
4. Output of the two `curl` commands from Step 6.

That's enough for BugRaid to diagnose the mismatch.
