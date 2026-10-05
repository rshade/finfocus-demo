# FinFocus Demo - Agent Guidelines

## Purpose

This repository demonstrates the `finfocus-action` GitHub Action for Pulumi cost estimation. It serves as both a demo and a testing ground for the action.

## Related Repositories

- **finfocus-action**: `../finfocus-action` - The GitHub Action itself
- **finfocus**: `../finfocus` - The CLI tool that performs cost analysis
- **finfocus-plugin-aws-public**: `../finfocus-plugin-aws-public` - AWS pricing plugin

## Workflow Overview

The cost estimation workflow (`cost-estimate.yml`) does the following:

1. Checkout code
2. Configure AWS credentials via OIDC
3. Install Pulumi CLI
4. Run `pulumi preview --json` to generate plan
5. Run `finfocus-action` which:
   - Downloads and installs `finfocus` CLI
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

2. **finfocus Installation Fails**
   - Check GitHub API rate limits
   - Verify the release assets exist at `rshade/finfocus/releases`
   - Expected asset format: `finfocus-v{version}-{platform}-{arch}.tar.gz`
   - `finfocus-version: latest` resolves to the newest stable `v*` CLI release

3. **Plugin Installation Fails**
   - Check the plugin is listed by `finfocus plugin list --available`
   - Verify plugin releases exist at the plugin's repo
   - For `aws-public`, assets include region suffix: `finfocus-plugin-aws-public_{version}_Linux_x86_64_us-east-1.tar.gz`

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
2. `dist/` is committed on `main`; release-please cuts releases and moves the
   `v2` / `v2.x` / `v2.x.y` tags
3. `cost-estimate.yml` pins an exact release (`@v2.0.0`); `analyzer-mode.yml`
   tracks the major tag (`@v2`). Bump the pin after a new release

### v2 Breaking Changes

v2.0.0 removed the budget health and scoped-budget inputs
(`budget-alert-threshold`, `fail-on-budget-health`, `show-budget-forecast`,
`budget-scopes`, `fail-on-budget-scope-breach`) and their outputs. Use
`budget-amount` / `budget-currency` / `budget-period` / `budget-alerts` instead.
Budget breach enforcement (`--exit-on-threshold`, exit code 10) only runs when
`fail-on-cost-increase` is set, and as of v2.0.0 it never fires: the action
writes the budget to `~/.finfocus/config.yaml`, but finfocus v0.4.x reads
`config.hujson` (finfocus-action#109, #110). The budget shown in the PR comment
is calculated by the action itself, not by finfocus.

### Known v2.0.0 Issues Visible in the Demo

- Carbon totals are 1000x too high: gCO2e summed as kg (finfocus-action#111)
- What-if section shows a $0.00 baseline in single-resource mode
  (finfocus-action#112)

### Testing Locally

You can manually test finfocus:

```bash
# Install finfocus
curl -sL https://github.com/rshade/finfocus/releases/download/v{version}/finfocus-v{version}-linux-amd64.tar.gz | tar xz

# Install plugin
./finfocus plugin install aws-public

# Generate Pulumi plan
pulumi preview --json > plan.json

# Run cost analysis
./finfocus cost projected --pulumi-json plan.json --output json
```

## Files

- `Pulumi.yaml` - Pulumi program defining AWS infrastructure
- `Pulumi.dev.yaml` - Stack configuration for dev environment
- `.github/workflows/cost-estimate.yml` - CI workflow for cost estimation
- `.github/workflows/analyzer-mode.yml` - CI workflow for analyzer mode testing
