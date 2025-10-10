# GitHub Organization Rulesets

This directory contains GitHub organization-level rulesets for DeliveryKick.

## Overview

Organization rulesets allow you to enforce branch protection rules across all repositories in your GitHub organization automatically. This ensures consistent policies without having to configure each repository individually.

## Current Rulesets

### Protected main/develop
**File**: `ruleset.json`

Protects `main`, `develop`, and default branches across all repositories with the following rules:

#### Branch Protection Rules
- **Required Linear History**: Prevents merge commits
- **Required Conversation Resolution**: All PR comments must be resolved before merging
- **Pull Request Requirements**:
  - 2 required approving reviews
  - Code owner review required
  - Dismiss stale reviews when new commits are pushed
  - Require approval on the last push
  - Block direct branch creation
- **Required Status Checks**:
  - `build` - Must pass before merging
  - `test` - Must pass before merging
  - `lint` - Must pass before merging
  - Strict mode: Branch must be up-to-date with base branch

#### Bypass Actors
- Organization administrators can bypass these rules when necessary

## Deployment

### Prerequisites
1. **GitHub CLI (gh)** - [Install instructions](https://cli.github.com/)
2. **Authentication** - Run `gh auth login`
3. **Organization Admin Access** - You need admin rights to the DeliveryKick organization
4. **jq** - JSON processor for validation (optional but recommended)

### Deploy the Ruleset

```bash
cd /home/ec2-user/deliverykick-infrastructure/github
./deploy-ruleset.sh
```

The script will:
1. Validate your GitHub CLI authentication
2. Check the ruleset JSON syntax
3. Display a summary of the ruleset configuration
4. Check for existing rulesets with the same name
5. Create a new ruleset or update an existing one
6. Display the management URL

### Manual Deployment

If you prefer to deploy manually:

```bash
gh api --method POST /orgs/DeliveryKick/rulesets \
  --input ruleset.json
```

### View Rulesets

List all organization rulesets:
```bash
gh api /orgs/DeliveryKick/rulesets
```

View in GitHub UI:
```
https://github.com/orgs/DeliveryKick/settings/rules
```

## Modifying Rulesets

### Update Protection Rules

Edit `ruleset.json` and run the deployment script again. If a ruleset with the same name exists, you'll be prompted to update it.

### Common Modifications

**Change required reviewers:**
```json
"required_approving_review_count": 1  // Change from 2 to 1
```

**Add additional status checks:**
```json
"required_status_checks": [
  { "context": "build" },
  { "context": "test" },
  { "context": "lint" },
  { "context": "security-scan" }  // Add new check
]
```

**Change enforcement mode:**
```json
"enforcement": "active"  // Options: "active", "evaluate", "disabled"
```

**Protect additional branches:**
```json
"include": ["~DEFAULT_BRANCH", "develop", "main", "staging"]
```

### Remove Code Owner Requirement

If you don't have a CODEOWNERS file set up yet:

```json
{
  "type": "pull_request",
  "parameters": {
    "require_code_owner_review": false  // Change to false
  }
}
```

## Testing

### Evaluate Mode

Before enforcing rules, you can test them in evaluation mode:

```json
"enforcement": "evaluate"
```

This will report violations without blocking actions, allowing you to see the impact.

### Bypass Mode

Organization admins can always bypass rules. To add specific teams or users as bypass actors:

```json
"bypass_actors": [
  { "actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "always" },
  { "actor_id": 123, "actor_type": "Team", "bypass_mode": "pull_request" }
]
```

## Troubleshooting

### Authentication Issues
```bash
gh auth status
gh auth login --web
```

### Permission Errors
Ensure you have organization admin privileges:
```bash
gh api /orgs/DeliveryKick/memberships/$(gh api /user --jq .login)
```

### JSON Validation
```bash
jq empty ruleset.json && echo "Valid JSON" || echo "Invalid JSON"
```

### View Ruleset Details
```bash
gh api /orgs/DeliveryKick/rulesets/{RULESET_ID}
```

## Best Practices

1. **Start with Evaluate Mode**: Test rulesets in evaluate mode before enforcing
2. **Incremental Rollout**: Start with fewer rules and add more gradually
3. **Status Check Names**: Ensure your CI/CD pipeline uses the exact status check names specified
4. **CODEOWNERS File**: Create a `.github/CODEOWNERS` file in repositories if requiring code owner reviews
5. **Team Communication**: Notify teams before deploying strict rulesets
6. **Bypass Actors**: Keep bypass actors minimal for security

## Resources

- [GitHub Rulesets Documentation](https://docs.github.com/en/organizations/managing-organization-settings/managing-rulesets-for-repositories-in-your-organization)
- [GitHub API - Rulesets](https://docs.github.com/en/rest/orgs/rules)
- [GitHub CLI Documentation](https://cli.github.com/manual/)

## Support

For issues or questions about these rulesets, contact the DeliveryKick DevOps team.
