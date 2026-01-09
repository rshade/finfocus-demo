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

## Links

- [finfocus-action](https://github.com/rshade/finfocus-action)
- [AWS OIDC for GitHub Actions](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
