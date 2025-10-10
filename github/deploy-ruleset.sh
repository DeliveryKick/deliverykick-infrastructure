#!/bin/bash
set -e

# GitHub Organization Ruleset Deployment Script
# Organization: DeliveryKick
# Purpose: Deploy branch protection ruleset for main/develop branches across all repos

ORG_NAME="DeliveryKick"
RULESET_FILE="ruleset.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "GitHub Ruleset Deployment for ${ORG_NAME}"
echo "=========================================="
echo ""

# Check if gh CLI is installed
if ! command -v gh &> /dev/null; then
    echo -e "${RED}Error: GitHub CLI (gh) is not installed${NC}"
    echo "Install it from: https://cli.github.com/"
    exit 1
fi

# Check if authenticated
if ! gh auth status &> /dev/null; then
    echo -e "${RED}Error: Not authenticated with GitHub CLI${NC}"
    echo "Run: gh auth login"
    exit 1
fi

# Check if ruleset file exists
if [ ! -f "$RULESET_FILE" ]; then
    echo -e "${RED}Error: Ruleset file '$RULESET_FILE' not found${NC}"
    exit 1
fi

# Validate JSON syntax
if ! jq empty "$RULESET_FILE" 2>/dev/null; then
    echo -e "${RED}Error: Invalid JSON in ruleset file${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} GitHub CLI is installed and authenticated"
echo -e "${GREEN}✓${NC} Ruleset file found and validated"
echo ""

# Display ruleset summary
RULESET_NAME=$(jq -r '.name' "$RULESET_FILE")
echo "Ruleset Details:"
echo "  Name: $RULESET_NAME"
echo "  Target: $(jq -r '.target' "$RULESET_FILE")"
echo "  Enforcement: $(jq -r '.enforcement' "$RULESET_FILE")"
echo "  Protected branches: $(jq -r '.conditions.ref_name.include | join(", ")' "$RULESET_FILE")"
echo ""

# Check for existing rulesets
echo "Checking for existing rulesets..."
EXISTING_RULESETS=$(gh api "/orgs/${ORG_NAME}/rulesets" --jq '.[].name' 2>/dev/null || echo "")

if echo "$EXISTING_RULESETS" | grep -q "^${RULESET_NAME}$"; then
    echo -e "${YELLOW}Warning: A ruleset named '${RULESET_NAME}' already exists${NC}"
    read -p "Do you want to update it? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Get the ID of the existing ruleset
        RULESET_ID=$(gh api "/orgs/${ORG_NAME}/rulesets" --jq ".[] | select(.name==\"${RULESET_NAME}\") | .id")
        echo "Updating ruleset (ID: $RULESET_ID)..."

        gh api --method PUT "/orgs/${ORG_NAME}/rulesets/${RULESET_ID}" \
            --input "$RULESET_FILE" > /dev/null

        echo -e "${GREEN}✓${NC} Ruleset updated successfully!"
    else
        echo "Deployment cancelled"
        exit 0
    fi
else
    # Create new ruleset
    echo "Creating new ruleset..."

    RESPONSE=$(gh api --method POST "/orgs/${ORG_NAME}/rulesets" \
        --input "$RULESET_FILE" 2>&1)

    if [ $? -eq 0 ]; then
        RULESET_ID=$(echo "$RESPONSE" | jq -r '.id')
        echo -e "${GREEN}✓${NC} Ruleset created successfully!"
        echo "  Ruleset ID: $RULESET_ID"
    else
        echo -e "${RED}Error creating ruleset:${NC}"
        echo "$RESPONSE"
        exit 1
    fi
fi

echo ""
echo "=========================================="
echo "Deployment Summary"
echo "=========================================="
echo "Organization: $ORG_NAME"
echo "Ruleset: $RULESET_NAME"
echo "Status: Active"
echo ""
echo "This ruleset will protect the following branches:"
echo "  - main"
echo "  - develop"
echo "  - Default branch (if different)"
echo ""
echo "Across ALL repositories in the organization"
echo ""
echo "To view the ruleset in GitHub:"
echo "https://github.com/orgs/${ORG_NAME}/settings/rules"
echo ""
