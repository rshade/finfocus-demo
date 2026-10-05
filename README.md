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

- **`release`** uses the pinned release (`@v2.0.0` and `@v2`). This is what
  users get, and it owns the PR comment
- **`action-main`** uses `rshade/finfocus-action@main` as an early warning for
  unreleased changes. It is allowed to fail without failing the run

### Known Issues in finfocus-action v2.0.0

These show up in the PR #1 comment:

- The budget section is informational. Exceeding the budget does not fail the
  job ([finfocus-action#109](https://github.com/rshade/finfocus-action/issues/109),
  [#110](https://github.com/rshade/finfocus-action/issues/110))
- Sustainability totals are 1000x too high
  ([finfocus-action#111](https://github.com/rshade/finfocus-action/issues/111))
- The what-if estimate prices a standalone `t3.large` with a $0.00 baseline;
  it does not compare against the plan
  ([finfocus-action#112](https://github.com/rshade/finfocus-action/issues/112)).
  The recommendations section shows the real `t2` to `t3` savings

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

## Links

- [finfocus-action](https://github.com/rshade/finfocus-action)
- [finfocus](https://github.com/rshade/finfocus)
- [finfocus-plugin-aws-public](https://github.com/rshade/finfocus-plugin-aws-public)
