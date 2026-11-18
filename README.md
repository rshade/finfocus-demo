# FinFocus Demo

[![Cost Estimate](https://github.com/rshade/finfocus-demo/actions/workflows/cost-estimate.yml/badge.svg?event=schedule)](https://github.com/rshade/finfocus-demo/actions/workflows/cost-estimate.yml)
[![Analyzer Mode Demo](https://github.com/rshade/finfocus-demo/actions/workflows/analyzer-mode.yml/badge.svg?event=schedule)](https://github.com/rshade/finfocus-demo/actions/workflows/analyzer-mode.yml)

Live demo of [finfocus-action](https://github.com/rshade/finfocus-action), a
GitHub Action that estimates cloud costs for Pulumi changes and posts them on
the pull request. It runs [finfocus](https://github.com/rshade/finfocus) with
public AWS pricing, so it needs no billing access.

## See It in Action

**[Pull request #1](https://github.com/rshade/finfocus-demo/pull/1)** is the
demo. It stays open on purpose and will never merge: every push to it runs
both workflows against real AWS APIs, so it doubles as the end-to-end test for
finfocus-action.

On that PR you will find:

- A **Cloud Cost Estimate** comment from finfocus-action: monthly cost, budget
  status, top resources, optimization recommendations (for example `t2` to
  `t3` and Graviton migrations), a what-if estimate, and sustainability
  metrics
- A **Pulumi preview** comment from analyzer mode, with cost diagnostics
  inline next to each resource
- The workflow logs under **Checks**

## How the Demo Is Set Up

`main` holds a small baseline Pulumi YAML program in `us-east-1`:

- VPC, subnet and security group
- 20 GB gp3 EBS volume
- `t3.micro` EC2 instance

PR #1 changes it the way a real infrastructure PR would. It adds a legacy
`t2.large` instance and a `t3.large` instance, which give finfocus something
to price and something to recommend. Only `pulumi preview` runs; nothing is
ever deployed.

## Workflows

- **[`cost-estimate.yml`](.github/workflows/cost-estimate.yml)** (standard
  mode) runs `pulumi preview --json` and hands the plan to finfocus-action,
  which posts the cost comment
- **[`analyzer-mode.yml`](.github/workflows/analyzer-mode.yml)** (analyzer
  mode) installs finfocus as a Pulumi policy pack, so costs appear in the
  `pulumi preview` output

Each workflow runs:

- **On pull requests** to `main`, which is how PR #1 gets its comments
- **Weekly on a schedule** (Mondays 13:00 UTC) as a health check. The badges
  above show the result. A red badge means the demo itself is broken: an
  expired AWS role, a deleted secret, or a bad action release
- **On demand** from the Actions tab (`workflow_dispatch`)

Each run has two jobs:

- **`release`** uses the pinned release (`@v2.1.0`). This is what
  users get, and it owns the PR comment
- **`action-main`** uses `rshade/finfocus-action@main` as an early warning for
  unreleased changes. It is allowed to fail without failing the run

## Run It in Your Own Repository

The workflows need an AWS role they can assume through GitHub OIDC. The role
only needs read access, because `pulumi preview` looks up an AMI but creates
nothing.

### Step 1: Create the AWS OIDC Identity Provider

1. Go to **IAM Console → Identity providers → Add provider**
2. Select **OpenID Connect**
3. Provider URL: `https://token.actions.githubusercontent.com`
4. Audience: `sts.amazonaws.com`
5. Click **Add provider**

### Step 2: Create the IAM Role

Create an IAM role with this trust policy (replace the account ID and repo):

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
          "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/YOUR_REPO:*"
        }
      }
    }
  ]
}
```

Attach a read-only EC2 policy such as `AmazonEC2ReadOnlyAccess`.

### Step 3: Add the GitHub Secret

Add this secret under **Settings → Secrets and variables → Actions**:

| Secret | Value |
| :--- | :--- |
| `AWS_ROLE_ARN` | `arn:aws:iam::YOUR_ACCOUNT_ID:role/YOUR_ROLE_NAME` |

### Step 4: Open a Pull Request

1. Push this repository's contents to `main` of your repository
2. On a branch, change something in `Pulumi.yaml`, for example
   `instanceType: t3.micro` to `instanceType: t3.large`
3. Open a pull request to `main` and wait for the cost comment

## Debugging

Both workflows already set `debug: "true"` on the action. For runner-level
logs as well, set the `ACTIONS_STEP_DEBUG` secret to `true`.

## Notes

- Uses the local Pulumi file backend, so no Pulumi Cloud account is needed
- AWS OIDC provides short-lived credentials, so no static keys are stored
- The `aws-public` plugin uses public AWS list prices
- Local helper scripts for finfocus development (`run-analyzer-preview.sh`,
  `verify-tag-enrichment.sh`) live on the
  [PR #1 branch](https://github.com/rshade/finfocus-demo/tree/test-cost-chang/scripts)

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
- [finfocus](https://github.com/rshade/finfocus)
- [finfocus-plugin-aws-public](https://github.com/rshade/finfocus-plugin-aws-public)
