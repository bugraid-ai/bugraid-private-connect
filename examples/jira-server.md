# Example — Jira Server (Atlassian Data Center)

Reverse PrivateLink for a self-hosted Jira Server or Data Center instance running inside the customer's VPC. Useful when BugRaid's RCA needs to fetch tickets, comments, or status updates as evidence.

## Differences from the Grafana example

| Field | Grafana | Jira Server |
|---|---|---|
| ToolName | `grafana` | `jira` |
| ToolPort | `3000` | `443` (Jira default HTTPS) |
| HealthCheckProtocol | `TCP` | `HTTPS` (Jira `/status` works) |
| HealthCheckPath | `/` | `/status` |
| TargetType | `ip` (typically behind ALB) | `ip` (typically behind ALB) |
| Internal hostname | `grafana.weworkindia.internal` | `jira.weworkindia.internal` |

## Customer deploy

```
aws cloudformation create-stack \
  --stack-name bugraid-pl-jira \
  --template-body file://templates/customer/reverse-privatelink.yml \
  --region <customer-region> \
  --parameters \
    ParameterKey=ToolName,ParameterValue=jira \
    ParameterKey=ToolPort,ParameterValue=443 \
    ParameterKey=TargetType,ParameterValue=ip \
    ParameterKey=TargetValue,ParameterValue=<jira-internal-ip> \
    ParameterKey=VpcId,ParameterValue=<vpc-id> \
    ParameterKey=SubnetIds,ParameterValue=\"<subnet-a>,<subnet-b>\" \
    ParameterKey=HealthCheckProtocol,ParameterValue=HTTPS \
    ParameterKey=HealthCheckPath,ParameterValue=/status
```

## BugRaid deploy

Same `consumer-endpoint.yml` template; substitute `jira` for `grafana` and port `443`.

## Auth notes

Jira Server uses HTTP Basic auth or Personal Access Tokens (PAT). BugRaid's Jira adapter stores the token in the integration record. Token is unchanged by PrivateLink — it's an app-layer concern.

## Verify

```
./scripts/verify-private-path.sh jira.weworkindia.internal 443 /status
```

Expected: HTTP 200 returning Jira's JSON status. With auth headers, the adapter can then fetch issues via `/rest/api/2/search`.
