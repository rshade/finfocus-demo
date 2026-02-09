# FinFocus Demo - Agent Guidelines

## Purpose

This repository demonstrates the `finfocus-action` GitHub Action for Pulumi cost estimation. It serves as both a demo and a testing ground for the action.

## Related Repositories

- **finfocus-action**: `../finfocus-action` - The GitHub Action itself
- **pulumicost-core**: `../pulumicost-core` - The CLI tool that performs cost analysis  
- **pulumicost-plugin-aws-public**: `../pulumicost-plugin-aws-public` - AWS pricing plugin

## Workflow Overview

The cost estimation workflow (`cost-estimate.yml`) does the following:

1. Checkout code
2. Configure AWS credentials via OIDC
3. Install Pulumi CLI
4. Run `pulumi preview --json` to generate plan
5. Run `finfocus-action` which:
   - Downloads and installs `pulumicost` CLI
   - Installs plugins (e.g., `aws-public`)
   - Runs cost analysis on the plan JSON
   - Posts a comment to the PR

## Troubleshooting CI Failures

### Key Principle: Never Suppress Errors

**NEVER use `|| true` to suppress errors in workflows.** This repository exists to test the finfocus-action, so we need to see actual errors. If a step fails, let it fail visibly.

### Common Failure Points

1. **Pulumi Preview Fails**
   - Check AWS OIDC credentials are configured
   - Verify `Pulumi.yaml` is valid
   - Check that required Pulumi plugins are available

2. **pulumicost Installation Fails**
   - Check GitHub API rate limits
   - Verify the release assets exist at `rshade/pulumicost-core/releases`
   - Expected asset format: `pulumicost-core-v{version}-{platform}-{arch}.tar.gz`

3. **Plugin Installation Fails**
   - Check plugin exists in pulumicost-core's registry.json
   - Verify plugin releases exist at the plugin's repo
   - For `aws-public`, assets include region suffix: `pulumicost-plugin-aws-public_{version}_Linux_x86_64_us-east-1.tar.gz`

4. **Cost Analysis Fails**
   - Ensure `plan.json` contains valid JSON (not error messages)
   - Check that the plan file is not empty
   - Verify the plugin was installed successfully

### Debugging Tips

1. The finfocus-action now includes extensive logging. Look for:
   - `=== Environment Diagnostics ===` - Shows runtime environment
   - `=== Action Inputs (raw) ===` - Shows what inputs were received
   - `=== Installer: ===` - Shows download/install progress
   - `=== PluginManager: ===` - Shows plugin installation
   - `=== Analyzer: ===` - Shows cost analysis execution

2. To get more details, enable GitHub Actions debug logging:
   - Set repository secret `ACTIONS_STEP_DEBUG` to `true`

3. Check the plan.json content in logs - it should start with `{` and be valid JSON

### Updating the finfocus-action

After making changes to `finfocus-action`:

1. Rebuild the dist: `cd ../finfocus-action && npm run build`
2. The v1 branch must have the `dist/` folder (main branch does not)
3. Push changes to the v1 branch for workflows to pick them up

### Testing Locally

You can manually test pulumicost:

```bash
# Install pulumicost
curl -sL https://github.com/rshade/pulumicost-core/releases/latest/download/pulumicost-core-v{version}-linux-amd64.tar.gz | tar xz

# Install plugin
./pulumicost plugin install aws-public

# Generate Pulumi plan
pulumi preview --json > plan.json

# Run cost analysis
./pulumicost cost projected --pulumi-json plan.json --output json
```

## Files

- `Pulumi.yaml` - Pulumi program defining AWS infrastructure
- `Pulumi.dev.yaml` - Stack configuration for dev environment
- `.github/workflows/cost-estimate.yml` - CI workflow for cost estimation
- `.github/workflows/analyzer-mode.yml` - CI workflow for analyzer mode testing
