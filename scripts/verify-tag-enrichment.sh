#!/usr/bin/env bash
# verify-tag-enrichment.sh — Comprehensive E2E verification of finfocus
# tag enrichment using both aws-public (real pricing) and recorder
# (proto-level request inspection).
#
# Prerequisites:
#   - finfocus binary built (make build in finfocus repo)
#   - aws-public plugin installed
#   - recorder plugin installed (make install-recorder in finfocus repo)
#   - AWS credentials configured (for pulumi state access)
#   - pulumi CLI on PATH
#   - jq installed
#
# Usage:
#   cd finfocus-demo
#   ./scripts/verify-tag-enrichment.sh
#
# What it does:
#   Tests 1-5:  Output-level verification via aws-public (real pricing)
#     1. resourceType populated for every resource in JSON output
#     2. adapter field identifies pricing source (aws-public vs estimate)
#     3. resourceType values use Pulumi type token format
#     4. EC2/EBS resources return non-zero costs from real pricing
#     5. Cross-check consistency (provider prefix, currency, dates)
#   Tests 6-8:  Proto-level verification via recorder (request inspection)
#     6. Enriched tags (provider, resource_type, sku, region) in request
#     7. User-defined tags (e.g. Name) preserved alongside enriched tags
#     8. SKU values match expected instance types from Pulumi state
#   Tests 9-10: Data quality checks on aws-public output
#     9. Breakdown field contains pricing details for priced resources
#    10. Cost period sanity (dailyCosts length, date ordering)
#   Test 11:    Projected cost (informational, requires pending changes)

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────
FINFOCUS_BIN="${FINFOCUS_BIN:-$(dirname "$0")/../../finfocus/bin/finfocus}"
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="${DEMO_DIR}/test_output"
RECORD_DIR="${TMP_DIR}/recorded_requests"
STACK="dev"
PASS=0
FAIL=0
TOTAL=0

# Pulumi needs this to decrypt stack config
export PULUMI_CONFIG_PASSPHRASE="${PULUMI_CONFIG_PASSPHRASE:-}"

# ── Helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
}

section() {
    echo ""
    echo -e "${YELLOW}── $1 ──${NC}"
}

short_id() {
    local res_id="$1"
    local short="${res_id##*::}"
    if [[ "$short" == "$res_id" ]]; then
        short="${res_id:0:20}..."
    fi
    echo "$short"
}

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

# ── Pre-flight checks ─────────────────────────────────────────────────
section "Pre-flight checks"

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not installed"
    exit 1
fi
pass "jq is installed"

if ! command -v pulumi &>/dev/null; then
    echo "ERROR: pulumi CLI is required but not installed"
    exit 1
fi
pass "pulumi CLI is installed"

FINFOCUS_BIN="$(realpath "$FINFOCUS_BIN" 2>/dev/null || echo "$FINFOCUS_BIN")"
if [[ ! -x "$FINFOCUS_BIN" ]]; then
    echo "ERROR: finfocus binary not found at $FINFOCUS_BIN"
    echo "  Run 'make build' in the finfocus repo, or set FINFOCUS_BIN"
    exit 1
fi
pass "finfocus binary found: $FINFOCUS_BIN"

if ! "$FINFOCUS_BIN" plugin list --output json 2>/dev/null \
    | jq -e '.[] | select(.name == "aws-public")' \
    &>/dev/null; then
    echo "ERROR: aws-public plugin not installed"
    echo "  Install with: finfocus plugin install aws-public"
    exit 1
fi
pass "aws-public plugin installed"

if ! "$FINFOCUS_BIN" plugin list --output json 2>/dev/null \
    | jq -e '.[] | select(.name == "recorder")' \
    &>/dev/null; then
    echo "ERROR: recorder plugin not installed"
    echo "  Run 'make install-recorder' in the finfocus repo"
    exit 1
fi
pass "recorder plugin installed"

# ── Setup ──────────────────────────────────────────────────────────────
section "Setup"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR" "$RECORD_DIR"
echo "  Output dir: $TMP_DIR"
echo "  Recorder dir: $RECORD_DIR"

cd "$DEMO_DIR"

# ══════════════════════════════════════════════════════════════════════
# PART A: Output-Level Verification via aws-public (Tests 1-5)
# ══════════════════════════════════════════════════════════════════════

# ── Test 1: Actual Cost — resourceType Enrichment ─────────────────────
section "Test 1: Actual cost resourceType enrichment"

ACTUAL_OUTPUT="$TMP_DIR/actual_cost.json"
echo "  Running: finfocus cost actual --stack $STACK --output json ..."
"$FINFOCUS_BIN" cost actual --stack "$STACK" --output json \
    > "$ACTUAL_OUTPUT" 2>/dev/null || true

ACTUAL_COUNT=$(jq 'length' "$ACTUAL_OUTPUT" 2>/dev/null || echo "0")
if [[ "$ACTUAL_COUNT" -eq 0 ]]; then
    fail "No actual cost results in JSON output"
else
    pass "Actual cost results found ($ACTUAL_COUNT resources)"

    for i in $(seq 0 $((ACTUAL_COUNT - 1))); do
        RES_TYPE=$(jq -r ".[$i].resourceType // empty" "$ACTUAL_OUTPUT")
        RES_ID=$(jq -r ".[$i].resourceId // empty" "$ACTUAL_OUTPUT")
        SHORT_ID=$(short_id "$RES_ID")

        if [[ -n "$RES_TYPE" ]]; then
            pass "$SHORT_ID: resourceType = $RES_TYPE"
        else
            fail "$SHORT_ID: resourceType is MISSING"
        fi
    done
fi

# ── Test 2: Actual Cost — Adapter Field Populated ─────────────────────
section "Test 2: Actual cost adapter field"

if [[ "$ACTUAL_COUNT" -gt 0 ]]; then
    for i in $(seq 0 $((ACTUAL_COUNT - 1))); do
        ADAPTER=$(jq -r ".[$i].adapter // empty" "$ACTUAL_OUTPUT")
        RES_ID=$(jq -r ".[$i].resourceId // empty" "$ACTUAL_OUTPUT")
        SHORT_ID=$(short_id "$RES_ID")

        if [[ -n "$ADAPTER" ]]; then
            pass "$SHORT_ID: adapter = $ADAPTER"
        else
            fail "$SHORT_ID: adapter is MISSING"
        fi
    done

    AWS_PUBLIC_COUNT=$(jq \
        '[.[] | select(.adapter | test("aws-public"))] | length' \
        "$ACTUAL_OUTPUT")
    if [[ "$AWS_PUBLIC_COUNT" -gt 0 ]]; then
        pass "aws-public handled $AWS_PUBLIC_COUNT resources"
    else
        fail "No resources handled by aws-public"
    fi
else
    echo "  (Skipped — no actual cost results)"
fi

# ── Test 3: Pulumi Type Token Format ─────────────────────────────────
section "Test 3: resourceType uses Pulumi type token format"

if [[ "$ACTUAL_COUNT" -gt 0 ]]; then
    TYPE_FORMAT_OK=true
    ALL_TYPES=$(jq -r '.[].resourceType // empty' "$ACTUAL_OUTPUT" | sort -u)

    while IFS= read -r t; do
        if [[ -n "$t" && "$t" != *":"* ]]; then
            TYPE_FORMAT_OK=false
            fail "resourceType '$t' not in Pulumi type token format"
        fi
    done <<< "$ALL_TYPES"

    if [[ "$TYPE_FORMAT_OK" == "true" ]]; then
        pass "All resourceType values are Pulumi type tokens"
    fi

    EXPECTED_TYPES=("aws:ec2/instance:Instance" "aws:ebs/volume:Volume")
    for expected in "${EXPECTED_TYPES[@]}"; do
        if echo "$ALL_TYPES" | grep -q "$expected"; then
            pass "Expected type found: $expected"
        else
            fail "Expected type missing: $expected"
        fi
    done
else
    echo "  (Skipped — no actual cost results)"
fi

# ── Test 4: EC2/EBS Resources Have Non-Zero Costs ─────────────────────
section "Test 4: aws-public returns real pricing"

if [[ "$ACTUAL_COUNT" -gt 0 ]]; then
    EC2_COSTS=$(jq -r \
        '[.[] | select(.resourceType == "aws:ec2/instance:Instance")
               | .monthly] | map(select(. > 0)) | length' \
        "$ACTUAL_OUTPUT")
    EC2_TOTAL=$(jq -r \
        '[.[] | select(.resourceType == "aws:ec2/instance:Instance")]
         | length' \
        "$ACTUAL_OUTPUT")

    if [[ "$EC2_TOTAL" -gt 0 ]]; then
        if [[ "$EC2_COSTS" -eq "$EC2_TOTAL" ]]; then
            pass "All $EC2_TOTAL EC2 instances have non-zero costs"
        else
            fail "Only $EC2_COSTS/$EC2_TOTAL EC2 instances have costs"
        fi
    fi

    EBS_COSTS=$(jq -r \
        '[.[] | select(.resourceType == "aws:ebs/volume:Volume")
               | .monthly] | map(select(. > 0)) | length' \
        "$ACTUAL_OUTPUT")
    EBS_TOTAL=$(jq -r \
        '[.[] | select(.resourceType == "aws:ebs/volume:Volume")]
         | length' \
        "$ACTUAL_OUTPUT")

    if [[ "$EBS_TOTAL" -gt 0 ]]; then
        if [[ "$EBS_COSTS" -eq "$EBS_TOTAL" ]]; then
            pass "All $EBS_TOTAL EBS volumes have non-zero costs"
        else
            fail "Only $EBS_COSTS/$EBS_TOTAL EBS volumes have costs"
        fi
    fi
else
    echo "  (Skipped — no actual cost results)"
fi

# ── Test 5: Cross-Check Consistency ───────────────────────────────────
section "Test 5: Cross-check consistency"

if [[ "$ACTUAL_COUNT" -gt 0 ]]; then
    NON_AWS=$(jq -r \
        '[.[] | .resourceType // "" | select(startswith("aws:") | not)]
         | length' \
        "$ACTUAL_OUTPUT")

    if [[ "$NON_AWS" -eq 0 ]]; then
        pass "All resources have aws: provider prefix in resourceType"
    else
        fail "$NON_AWS resources have non-aws resourceType"
    fi

    CURRENCIES=$(jq -r '[.[].currency] | unique | .[]' "$ACTUAL_OUTPUT")
    if [[ "$CURRENCIES" == "USD" ]]; then
        pass "All resources use USD currency"
    else
        fail "Mixed currencies detected: $CURRENCIES"
    fi

    MISSING_DATES=$(jq -r \
        '[.[] | select(.startDate == null or .endDate == null)]
         | length' \
        "$ACTUAL_OUTPUT")
    if [[ "$MISSING_DATES" -eq 0 ]]; then
        pass "All resources have start/end dates"
    else
        fail "$MISSING_DATES resources missing date range"
    fi
fi

# ══════════════════════════════════════════════════════════════════════
# PART B: Proto-Level Verification via Recorder (Tests 6-8)
# ══════════════════════════════════════════════════════════════════════

# ── Run recorder pass ────────────────────────────────────────────────
section "Recorder pass: capturing proto-level requests"

echo "  Running: finfocus cost actual --stack $STACK --adapter recorder ..."
# Clear cache to force fresh plugin calls (ensures recorder receives requests)
CACHE_DB="${HOME}/.finfocus/cache/cache.db"
if [[ -f "$CACHE_DB" ]]; then
    rm -f "$CACHE_DB"
    echo "  Cleared cache to ensure fresh recorder calls"
fi

FINFOCUS_RECORDER_OUTPUT_DIR="$RECORD_DIR" \
FINFOCUS_RECORDER_MOCK_RESPONSE="true" \
    "$FINFOCUS_BIN" cost actual --stack "$STACK" --output json \
    --adapter recorder \
    > /dev/null 2>&1 || true

RECORDER_FILES=("$RECORD_DIR"/*_GetActualCost_*.json)
if [[ ${#RECORDER_FILES[@]} -eq 0 || ! -f "${RECORDER_FILES[0]}" ]]; then
    fail "No GetActualCost recordings found"
    RECORDER_OK=false
else
    pass "GetActualCost recordings found (${#RECORDER_FILES[@]} files)"
    RECORDER_OK=true
fi

# ── Test 6: Proto-Level Enriched Tags ─────────────────────────────────
section "Test 6: Proto-level enriched tags (provider, resource_type, sku, region)"

if [[ "$RECORDER_OK" == "true" ]]; then
    for f in "${RECORDER_FILES[@]}"; do
        RES_ID=$(jq -r '.request.resourceId // "unknown"' "$f")
        SHORT_ID=$(short_id "$RES_ID")

        # Check provider tag
        PROVIDER=$(jq -r '.request.tags.provider // empty' "$f")
        if [[ -n "$PROVIDER" ]]; then
            pass "$SHORT_ID: tags.provider = $PROVIDER"
        else
            fail "$SHORT_ID: tags.provider is MISSING"
        fi

        # Check resource_type tag
        RTYPE=$(jq -r '.request.tags.resource_type // empty' "$f")
        if [[ -n "$RTYPE" ]]; then
            pass "$SHORT_ID: tags.resource_type = $RTYPE"
        else
            fail "$SHORT_ID: tags.resource_type is MISSING"
        fi

        # Check region tag
        REGION=$(jq -r '.request.tags.region // empty' "$f")
        if [[ -n "$REGION" ]]; then
            pass "$SHORT_ID: tags.region = $REGION"
        else
            fail "$SHORT_ID: tags.region is MISSING"
        fi

        # Check sku tag (may be absent for non-compute resources)
        SKU=$(jq -r '.request.tags.sku // empty' "$f")
        if [[ -n "$SKU" ]]; then
            pass "$SHORT_ID: tags.sku = $SKU"
        else
            RTYPE_VAL=$(jq -r '.request.tags.resource_type // ""' "$f")
            case "$RTYPE_VAL" in
                *Instance*|*Volume*|*Cluster*)
                    fail "$SHORT_ID: tags.sku MISSING (expected for $RTYPE_VAL)"
                    ;;
                *)
                    pass "$SHORT_ID: tags.sku absent (OK for $RTYPE_VAL)"
                    ;;
            esac
        fi
    done
else
    echo "  (Skipped — no recorder data)"
fi

# ── Test 7: User Tag Preservation ─────────────────────────────────────
section "Test 7: User-defined tags preserved alongside enriched tags"

if [[ "$RECORDER_OK" == "true" ]]; then
    FOUND_NAME_TAG=false
    for f in "${RECORDER_FILES[@]}"; do
        RES_ID=$(jq -r '.request.resourceId // "unknown"' "$f")
        SHORT_ID=$(short_id "$RES_ID")

        NAME_TAG=$(jq -r '.request.tags.Name // empty' "$f")
        if [[ -n "$NAME_TAG" ]]; then
            pass "$SHORT_ID: user tag Name = $NAME_TAG (preserved)"
            FOUND_NAME_TAG=true

            # Verify enriched tags also present on this same resource
            HAS_PROVIDER=$(jq -r '.request.tags.provider // empty' "$f")
            if [[ -n "$HAS_PROVIDER" ]]; then
                pass "$SHORT_ID: enriched + user tags coexist"
            else
                fail "$SHORT_ID: user tag present but enriched tags missing"
            fi
        fi
    done

    if [[ "$FOUND_NAME_TAG" == "false" ]]; then
        fail "No user-defined Name tags found in any recording"
    fi
else
    echo "  (Skipped — no recorder data)"
fi

# ── Test 8: SKU Correctness ───────────────────────────────────────────
section "Test 8: SKU values match expected instance types"

if [[ "$RECORDER_OK" == "true" ]]; then
    # Expected SKUs from Pulumi.yaml: t3.micro, t2.medium, t3.large, gp3
    EXPECTED_SKUS=("t3.micro" "t2.medium" "t3.large" "gp3")
    FOUND_SKUS=$(for f in "${RECORDER_FILES[@]}"; do
        jq -r '.request.tags.sku // empty' "$f"
    done | sort -u | grep -v '^$' || true)

    for expected_sku in "${EXPECTED_SKUS[@]}"; do
        if echo "$FOUND_SKUS" | grep -q "$expected_sku"; then
            pass "Expected SKU found: $expected_sku"
        else
            fail "Expected SKU missing: $expected_sku"
        fi
    done

    # Verify no unexpected/garbage SKU values
    UNEXPECTED=false
    while IFS= read -r sku; do
        if [[ -z "$sku" ]]; then
            continue
        fi
        MATCHED=false
        for expected_sku in "${EXPECTED_SKUS[@]}"; do
            if [[ "$sku" == "$expected_sku" ]]; then
                MATCHED=true
                break
            fi
        done
        if [[ "$MATCHED" == "false" ]]; then
            UNEXPECTED=true
            fail "Unexpected SKU value: $sku"
        fi
    done <<< "$FOUND_SKUS"

    if [[ "$UNEXPECTED" == "false" ]]; then
        pass "No unexpected SKU values"
    fi

    # Cross-check: EC2 Instance resources should have instance type SKUs
    for f in "${RECORDER_FILES[@]}"; do
        RTYPE=$(jq -r '.request.tags.resource_type // ""' "$f")
        SKU=$(jq -r '.request.tags.sku // empty' "$f")
        RES_ID=$(jq -r '.request.resourceId // "unknown"' "$f")
        SHORT_ID=$(short_id "$RES_ID")

        if [[ "$RTYPE" == *"Instance"* && -n "$SKU" ]]; then
            if [[ "$SKU" == t[23].* || "$SKU" == m[0-9].* ]]; then
                pass "$SHORT_ID: Instance SKU $SKU is valid EC2 type"
            else
                fail "$SHORT_ID: Instance SKU $SKU doesn't look like EC2 type"
            fi
        fi

        if [[ "$RTYPE" == *"Volume"* && -n "$SKU" ]]; then
            if [[ "$SKU" == gp[23] || "$SKU" == io[12] || "$SKU" == st1 \
                || "$SKU" == sc1 || "$SKU" == standard ]]; then
                pass "$SHORT_ID: Volume SKU $SKU is valid EBS type"
            else
                fail "$SHORT_ID: Volume SKU $SKU doesn't look like EBS type"
            fi
        fi
    done
else
    echo "  (Skipped — no recorder data)"
fi

# ══════════════════════════════════════════════════════════════════════
# PART C: Data Quality Checks (Tests 9-10)
# ══════════════════════════════════════════════════════════════════════

# ── Test 9: Breakdown Field Validation ────────────────────────────────
section "Test 9: Breakdown field contains pricing details"

if [[ "$ACTUAL_COUNT" -gt 0 ]]; then
    for i in $(seq 0 $((ACTUAL_COUNT - 1))); do
        ADAPTER=$(jq -r ".[$i].adapter // empty" "$ACTUAL_OUTPUT")
        RES_ID=$(jq -r ".[$i].resourceId // empty" "$ACTUAL_OUTPUT")
        SHORT_ID=$(short_id "$RES_ID")

        # Only aws-public resources should have breakdown details
        if [[ "$ADAPTER" == *"aws-public"* ]]; then
            BREAKDOWN_KEYS=$(jq -r \
                ".[$i].breakdown | length" "$ACTUAL_OUTPUT")
            if [[ "$BREAKDOWN_KEYS" -gt 0 ]]; then
                pass "$SHORT_ID: breakdown has $BREAKDOWN_KEYS entries"
            else
                fail "$SHORT_ID: breakdown is empty for aws-public resource"
            fi

            # Breakdown values should be positive numbers
            NEG_BREAKDOWN=$(jq -r \
                "[.[$i].breakdown | to_entries[].value
                  | select(. < 0)] | length" \
                "$ACTUAL_OUTPUT")
            if [[ "$NEG_BREAKDOWN" -eq 0 ]]; then
                pass "$SHORT_ID: all breakdown values are non-negative"
            else
                fail "$SHORT_ID: $NEG_BREAKDOWN negative breakdown values"
            fi
        fi
    done
else
    echo "  (Skipped — no actual cost results)"
fi

# ── Test 10: Cost Period Sanity ───────────────────────────────────────
section "Test 10: Cost period sanity checks"

if [[ "$ACTUAL_COUNT" -gt 0 ]]; then
    for i in $(seq 0 $((ACTUAL_COUNT - 1))); do
        RES_ID=$(jq -r ".[$i].resourceId // empty" "$ACTUAL_OUTPUT")
        SHORT_ID=$(short_id "$RES_ID")

        # dailyCosts array should be non-empty for priced resources
        DAILY_LEN=$(jq -r ".[$i].dailyCosts | length" "$ACTUAL_OUTPUT")
        MONTHLY=$(jq -r ".[$i].monthly // 0" "$ACTUAL_OUTPUT")
        if [[ "$DAILY_LEN" -gt 0 ]]; then
            pass "$SHORT_ID: dailyCosts has $DAILY_LEN entries"
        elif [[ "$MONTHLY" == "0" ]]; then
            pass "$SHORT_ID: dailyCosts empty (OK for \$0 resource)"
        else
            fail "$SHORT_ID: dailyCosts is empty but monthly=$MONTHLY"
        fi

        # startDate should be before endDate (lexicographic compare works
        # for ISO 8601 dates)
        START=$(jq -r ".[$i].startDate // empty" "$ACTUAL_OUTPUT")
        END=$(jq -r ".[$i].endDate // empty" "$ACTUAL_OUTPUT")
        if [[ -n "$START" && -n "$END" ]]; then
            # Extract date portion for comparison
            START_DATE="${START:0:10}"
            END_DATE="${END:0:10}"
            if [[ "$START_DATE" < "$END_DATE" \
                || "$START_DATE" == "$END_DATE" ]]; then
                pass "$SHORT_ID: date range valid ($START_DATE to $END_DATE)"
            else
                fail "$SHORT_ID: startDate ($START_DATE) > endDate ($END_DATE)"
            fi
        fi

        # costPeriod should be a non-empty string
        COST_PERIOD=$(jq -r ".[$i].costPeriod // empty" "$ACTUAL_OUTPUT")
        if [[ -n "$COST_PERIOD" ]]; then
            pass "$SHORT_ID: costPeriod = $COST_PERIOD"
        else
            fail "$SHORT_ID: costPeriod is MISSING"
        fi
    done
else
    echo "  (Skipped — no actual cost results)"
fi

# ══════════════════════════════════════════════════════════════════════
# PART D: Projected Cost (Test 11)
# ══════════════════════════════════════════════════════════════════════

# ── Test 11: Projected Cost (Informational) ───────────────────────────
section "Test 11: Projected cost (informational)"

PROJ_OUTPUT="$TMP_DIR/projected_cost.json"
echo "  Running: finfocus cost projected --stack $STACK --output json ..."
"$FINFOCUS_BIN" cost projected --stack "$STACK" --output json \
    > "$PROJ_OUTPUT" 2>/dev/null || true

PROJ_COUNT=$(jq '.finfocus.resources | length' "$PROJ_OUTPUT" 2>/dev/null \
    || echo "0")
if [[ "$PROJ_COUNT" -eq 0 ]]; then
    echo -e "  ${YELLOW}INFO${NC}: No projected cost resources"
    echo "  (This is expected when the stack has no pending changes)"
    echo "  To test projected cost, make a change in Pulumi.yaml first"
else
    pass "Projected cost results found ($PROJ_COUNT resources)"

    for i in $(seq 0 $((PROJ_COUNT - 1))); do
        RES_TYPE=$(jq -r \
            ".finfocus.resources[$i].resourceType // empty" "$PROJ_OUTPUT")
        RES_ID=$(jq -r \
            ".finfocus.resources[$i].resourceId // empty" "$PROJ_OUTPUT")
        SHORT_ID=$(short_id "$RES_ID")

        if [[ -n "$RES_TYPE" ]]; then
            pass "$SHORT_ID: resourceType = $RES_TYPE"
        else
            fail "$SHORT_ID: resourceType is MISSING"
        fi

        ADAPTER=$(jq -r \
            ".finfocus.resources[$i].adapter // empty" "$PROJ_OUTPUT")
        if [[ -n "$ADAPTER" ]]; then
            pass "$SHORT_ID: adapter = $ADAPTER"
        else
            fail "$SHORT_ID: adapter is MISSING"
        fi
    done
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}ALL TESTS PASSED${NC}: $PASS/$TOTAL"
else
    echo -e "  ${RED}FAILURES${NC}: $FAIL/$TOTAL failed"
fi
echo "════════════════════════════════════════════════════════"
echo ""

exit "$FAIL"
