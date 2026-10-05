#!/usr/bin/env bash
# run-analyzer-preview.sh — Run pulumi preview with the finfocus analyzer policy pack.
#
# This script sets up the correct environment for running the finfocus analyzer
# locally. The analyzer integrates as a Pulumi policy pack and produces cost
# diagnostics inline with pulumi preview output.
#
# The script isolates the demo to use only the aws-public pricing plugin by
# setting FINFOCUS_HOME to a demo-specific directory (~/.finfocus/demo) that
# symlinks only aws-public. This avoids recorder plugin noise in demo output.
#
# Prerequisites:
#   - finfocus binary built (make build in finfocus repo)
#   - aws-public plugin installed (finfocus plugin install aws-public)
#   - pulumi CLI on PATH
#   - AWS credentials configured
#
# Usage:
#   cd finfocus-demo
#   ./scripts/run-analyzer-preview.sh
#
# Environment variables:
#   FINFOCUS_BIN              Path to finfocus binary (default: auto-detect from PATH)
#   PULUMI_CONFIG_PASSPHRASE  Pulumi stack passphrase (default: empty string)
#   FINFOCUS_LOG_LEVEL        Log verbosity: debug, info, warn, error (default: warn)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

POLICY_PACK_DIR="${HOME}/.finfocus/analyzer"
POLICY_PACK_BINARY="${POLICY_PACK_DIR}/pulumi-analyzer-policy-finfocus"
POLICY_YAML="${POLICY_PACK_DIR}/PulumiPolicy.yaml"

# Demo-specific FINFOCUS_HOME — contains only the aws-public plugin (no recorder).
# This keeps demo output clean by preventing the recorder plugin from loading.
DEMO_HOME="${HOME}/.finfocus/demo"
GLOBAL_PLUGINS_DIR="${HOME}/.finfocus/plugins"

PULUMI_CONFIG_PASSPHRASE="${PULUMI_CONFIG_PASSPHRASE:-}"
FINFOCUS_LOG_LEVEL="${FINFOCUS_LOG_LEVEL:-warn}"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

# ---------------------------------------------------------------------------
# Locate finfocus binary
# ---------------------------------------------------------------------------

if [[ -n "${FINFOCUS_BIN:-}" ]]; then
  FINFOCUS="${FINFOCUS_BIN}"
elif command -v finfocus &>/dev/null; then
  FINFOCUS="$(command -v finfocus)"
else
  die "finfocus binary not found. Set FINFOCUS_BIN or add finfocus to PATH."
fi

info "Using finfocus: ${FINFOCUS}"

# ---------------------------------------------------------------------------
# Set up policy pack directory
# ---------------------------------------------------------------------------

if [[ ! -d "${POLICY_PACK_DIR}" ]]; then
  info "Creating policy pack directory: ${POLICY_PACK_DIR}"
  mkdir -p "${POLICY_PACK_DIR}"
fi

if [[ ! -f "${POLICY_YAML}" ]]; then
  info "Writing PulumiPolicy.yaml"
  cat > "${POLICY_YAML}" <<'EOF'
runtime: finfocus
name: finfocus
version: 0.3.0
EOF
fi

# Always sync the binary to ensure we're using the current build
info "Syncing policy pack binary from: ${FINFOCUS}"
cp "${FINFOCUS}" "${POLICY_PACK_BINARY}"
chmod +x "${POLICY_PACK_BINARY}"

# ---------------------------------------------------------------------------
# Set up demo-specific FINFOCUS_HOME (aws-public only, no recorder)
#
# finfocus loads every plugin found in $FINFOCUS_HOME/plugins/. The recorder
# plugin matches all providers ("*") and injects noise into demo output.
# By pointing FINFOCUS_HOME at a directory that symlinks only aws-public,
# we get clean cost-only output.
# ---------------------------------------------------------------------------

if [[ ! -d "${DEMO_HOME}/plugins" ]]; then
  info "Creating demo FINFOCUS_HOME: ${DEMO_HOME}"
  mkdir -p "${DEMO_HOME}/plugins"
fi

# Write a config.yaml that lists only the aws-public plugin
if [[ ! -f "${DEMO_HOME}/config.yaml" ]]; then
  info "Writing demo config.yaml"
  cat > "${DEMO_HOME}/config.yaml" <<'EOF'
installed_plugins:
    - name: aws-public
      url: github.com/rshade/finfocus-plugin-aws-public
      version: v0.1.5
EOF
fi

# Populate the demo plugins dir with real directories + per-file symlinks.
#
# NOTE: The finfocus registry uses os.ReadDir + DirEntry.IsDir() to discover
# plugins. In Go, DirEntry.IsDir() returns false for directory-level symlinks
# (it reads the symlink type, not the target). Creating a top-level symlink
# from aws-public → ~/.finfocus/plugins/aws-public would cause the registry
# to skip it. Instead, we create real directories and symlink only the files
# inside so the directory walk works correctly.
if [[ -d "${GLOBAL_PLUGINS_DIR}/aws-public" ]]; then
  # Find the versioned subdirectory (e.g. v0.1.5)
  for version_dir in "${GLOBAL_PLUGINS_DIR}/aws-public"/*/; do
    version="$(basename "${version_dir}")"
    dest_dir="${DEMO_HOME}/plugins/aws-public/${version}"
    if [[ ! -d "${dest_dir}" ]]; then
      info "Setting up aws-public plugin (${version}) in demo home"
      mkdir -p "${dest_dir}"
    fi
    # Symlink binary and metadata; skip docs (README, LICENSE, CHANGELOG)
    for src_file in "${version_dir}"finfocus-plugin-* "${version_dir}"plugin.metadata.json; do
      [[ -f "${src_file}" ]] || continue
      dest_file="${dest_dir}/$(basename "${src_file}")"
      if [[ ! -L "${dest_file}" ]]; then
        ln -sf "${src_file}" "${dest_file}"
      fi
    done
  done
else
  die "aws-public plugin not found at ${GLOBAL_PLUGINS_DIR}/aws-public. Run: finfocus plugin install aws-public"
fi

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if ! command -v pulumi &>/dev/null; then
  die "pulumi CLI not found on PATH."
fi

if [[ ! -f "${PROJECT_DIR}/Pulumi.yaml" ]]; then
  die "No Pulumi.yaml found in ${PROJECT_DIR}. Run from within the finfocus-demo project."
fi

# ---------------------------------------------------------------------------
# Run pulumi preview with the finfocus analyzer
#
# Key requirements:
#   1. --policy-pack points to the directory containing PulumiPolicy.yaml
#   2. The policy pack directory must be in PATH so Pulumi can find
#      'pulumi-analyzer-policy-finfocus' by name (Pulumi looks up the
#      binary by runtime name, not just directory contents).
# ---------------------------------------------------------------------------

info "Running pulumi preview with finfocus analyzer..."
info "Policy pack: ${POLICY_PACK_DIR}"
info "Log level:   ${FINFOCUS_LOG_LEVEL}"
info "FINFOCUS_HOME: ${DEMO_HOME} (aws-public only)"
echo ""

export FINFOCUS_LOG_LEVEL
export PULUMI_CONFIG_PASSPHRASE
export FINFOCUS_HOME="${DEMO_HOME}"

# PATH must include the policy pack dir so Pulumi can find pulumi-analyzer-policy-finfocus
exec env PATH="${POLICY_PACK_DIR}:${PATH}" \
  pulumi preview \
    --policy-pack "${POLICY_PACK_DIR}" \
    --cwd "${PROJECT_DIR}" \
    "$@"
