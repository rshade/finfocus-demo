# FinFocus Demo

Demo repository showcasing the [finfocus-action](https://github.com/rshade/finfocus-action) GitHub Action for cloud cost estimation with Pulumi infrastructure.

## What This Demo Does

This repository contains a sample Pulumi YAML program that provisions AWS EC2 infrastructure:
- VPC with DNS hostname support
- Subnet in us-east-1a
- Security Group with HTTP ingress
- 20GB gp3 EBS Volume
- t3.micro EC2 Instance

Two GitHub Actions workflows demonstrate different modes of the finfocus-action for estimating cloud costs.

## Workflow Modes

### Standard Mode (`cost-estimate.yml`)

Generates a Pulumi preview JSON file and posts a formatted cost summary as a PR comment.

### Analyzer Mode (`analyzer-mode.yml`)

Integrates cost estimation directly into the Pulumi preview output as policy diagnostics.

Both workflows use finfocus-action **v2**. The standard workflow tracks spend
against a $105/month budget with `budget-alerts` at 80% (actual) and 100%
(forecasted). v2 removed the budget health inputs (`budget-alert-threshold`,
`fail-on-budget-health`, `show-budget-forecast`); see the
[v2.0.0 release notes](https://github.com/rshade/finfocus-action/releases/tag/v2.0.0).

The standard workflow also sets `estimate-spec` to run a single-resource
what-if (`finfocus cost estimate`) that prices a standalone `t3.large` EC2
instance. Single-resource mode does not compare against the plan, so the
"What-If Cost Estimate" section shows a $0.00 baseline
([finfocus-action#112](https://github.com/rshade/finfocus-action/issues/112)).
For the `t2.large` to `t3.large` savings on `legacy-instance`, see the
recommendations section of the same comment.

The budget section is informational: the job does not fail when the budget is
exceeded
([finfocus-action#109](https://github.com/rshade/finfocus-action/issues/109),
[#110](https://github.com/rshade/finfocus-action/issues/110)). The
sustainability totals are currently 1000x too high
([finfocus-action#111](https://github.com/rshade/finfocus-action/issues/111)).

## Setup

### Step 1: Create AWS OIDC Identity Provider

1. Go to **IAM Console → Identity providers → Add provider**
2. Select **OpenID Connect**
3. Provider URL: `https://token.actions.githubusercontent.com`
4. Audience: `sts.amazonaws.com`
5. Click **Add provider**

### Step 2: Create IAM Role

Create an IAM role with this trust policy (replace values):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:rshade/finfocus-demo:*"
        }
      }
    }
  ]
}
```

Attach a policy with EC2/VPC read permissions (e.g., `AmazonEC2ReadOnlyAccess`).

### Step 3: Add GitHub Secret

Add this secret to your repository (**Settings → Secrets and variables → Actions**):

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | `arn:aws:iam::YOUR_ACCOUNT_ID:role/YOUR_ROLE_NAME` |

### Step 4: Test It

1. Commit and push to `main`
2. Create a branch, make a small change (e.g., edit instance type in `Pulumi.yaml`)
3. Open a PR to `main`
4. Watch the workflows run and see cost estimates in PR comments!

## Example Change to Test

Edit `Pulumi.yaml` and change the instance type:

```yaml
# Change this:
instanceType: t3.micro

# To this:
instanceType: t3.large
```

This will show the cost difference in the PR comment.

## Debugging

Set `ACTIONS_STEP_DEBUG` secret to `true` for verbose logging.

## Notes

- Uses local Pulumi file backend (no Pulumi Cloud account needed)
- AWS OIDC provides temporary credentials (no static keys)
- Only runs `pulumi preview` — no resources are created
- `aws-public` plugin uses public AWS pricing data

## Testing Tag Enrichment

The `scripts/verify-tag-enrichment.sh` script runs a comprehensive E2E
verification that finfocus correctly enriches actual cost requests with
`provider`, `resource_type`, `sku`, and `region` metadata.

### Prerequisites

- **finfocus binary** built (`make build` in the finfocus repo)
- **aws-public plugin** installed (`finfocus plugin install aws-public`)
- **recorder plugin** installed (`make install-recorder` in the finfocus repo)
- **AWS credentials** configured (for `pulumi stack export`)
- **pulumi CLI** on PATH
- **jq** installed

### Running

```bash
cd finfocus-demo
./scripts/verify-tag-enrichment.sh
```

Override the finfocus binary path if needed:

```bash
FINFOCUS_BIN=/path/to/finfocus ./scripts/verify-tag-enrichment.sh
```

If the stack uses an encrypted config passphrase:

```bash
export PULUMI_CONFIG_PASSPHRASE="your-passphrase"
./scripts/verify-tag-enrichment.sh
```

### What It Tests (110 assertions)

The script runs 11 test sections organized into four parts:

**Part A -- Output-level verification via aws-public (real pricing):**

| Test | What it checks |
|------|----------------|
| 1 | `resourceType` populated for every resource in JSON output |
| 2 | `adapter` field identifies pricing source (aws-public vs estimate) |
| 3 | `resourceType` values use Pulumi type token format |
| 4 | EC2/EBS resources return non-zero costs from real pricing |
| 5 | Consistency: all aws: prefix, USD currency, valid date ranges |

**Part B -- Proto-level verification via recorder (request inspection):**

| Test | What it checks |
|------|----------------|
| 6 | Enriched tags in gRPC request: provider, resource_type, sku, region |
| 7 | User-defined tags (e.g. Name) preserved alongside enriched tags |
| 8 | SKU values match expected instance types from Pulumi.yaml |

**Part C -- Data quality checks on aws-public output:**

| Test | What it checks |
|------|----------------|
| 9 | Breakdown field contains pricing details for priced resources |
| 10 | Cost period sanity: dailyCosts length, date ordering, costPeriod |

**Part D -- Projected cost (informational):**

| Test | What it checks |
|------|----------------|
| 11 | Projected cost output (expected empty when no pending changes) |

### Expected Output

```text
ALL TESTS PASSED: 110/110
```

The script exits 0 on success, non-zero with the failure count on failure.
Test 11 (projected cost) is informational -- it reports INFO rather than
FAIL when the stack has no pending changes.

### Implementation Details

- The script clears `~/.finfocus/cache/cache.db` before the recorder pass
  to ensure fresh plugin calls
- Temporary output is written to `test_output/` and cleaned up on exit
- The recorder pass uses `--adapter recorder` with mock responses enabled

## Links

- [finfocus-action](https://github.com/rshade/finfocus-action)
- [AWS OIDC for GitHub Actions](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
