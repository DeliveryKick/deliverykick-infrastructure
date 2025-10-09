# Environment Variables for Production Deployment

## Required Environment Variables

### For Running Deployment Scripts

```bash
# Required for all deployment scripts
export AURORA_PASSWORD="YourSecurePassword123!"

# Optional - only if you want to migrate existing data
export DB_PASSWORD="your-current-rds-password"
export RESTAURANT_DB_PASSWORD="your-current-restaurant-db-password"

# AWS Configuration (usually set via aws configure)
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCOUNT_ID="609064513827"
```

---

## Step-by-Step Setup

### 1. Set Aurora Password (Required)

This will be the master password for your new Aurora cluster:

```bash
export AURORA_PASSWORD="ChangeMe_SecurePassword123!"
```

**Requirements:**
- At least 8 characters
- Mix of uppercase, lowercase, numbers
- Special characters recommended
- **Remember this password** - you'll need it to access the database

---

### 2. Configure AWS CLI (Required)

You need AWS CLI configured with credentials that have permissions for:
- RDS (Aurora)
- ECS (Fargate)
- EC2 (VPC, Security Groups, ALB)
- ECR (Docker Registry)
- Secrets Manager
- CloudWatch Logs
- IAM (for creating roles)

#### Check if AWS CLI is configured:

```bash
aws sts get-caller-identity
```

**Expected output:**
```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "609064513827",
    "Arn": "arn:aws:iam::609064513827:user/your-username"
}
```

#### If not configured, run:

```bash
aws configure
```

Enter:
- AWS Access Key ID: `[Your Access Key]`
- AWS Secret Access Key: `[Your Secret Key]`
- Default region name: `us-east-1`
- Default output format: `json`

---

### 3. Set Optional Variables (For Data Migration)

Only needed if you want to migrate data from your existing RDS databases:

```bash
# Get from your current .env file
source .env

# Or set manually
export DB_PASSWORD="your-existing-ordering-db-password"
export RESTAURANT_DB_PASSWORD="your-existing-restaurant-db-password"
```

---

## Complete Setup Script

Create this file and run it before deployment:

**File: `setup-deployment-env.sh`**

```bash
#!/bin/bash

echo "========================================="
echo "Production Deployment Environment Setup"
echo "========================================="
echo ""

# 1. Set Aurora password
read -sp "Enter Aurora master password (min 8 chars): " AURORA_PASSWORD
echo ""
export AURORA_PASSWORD

# Validate password length
if [ ${#AURORA_PASSWORD} -lt 8 ]; then
    echo "❌ Password must be at least 8 characters"
    exit 1
fi

# 2. Check AWS CLI
echo "Checking AWS CLI configuration..."
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI not installed"
    echo "Install: https://aws.amazon.com/cli/"
    exit 1
fi

# 3. Verify AWS credentials
echo "Verifying AWS credentials..."
AWS_ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "❌ AWS credentials not configured"
    echo "Run: aws configure"
    exit 1
fi

echo "✓ AWS Account: $AWS_ACCOUNT"

# 4. Set region
export AWS_DEFAULT_REGION="us-east-1"
echo "✓ Region: $AWS_DEFAULT_REGION"

# 5. Load existing .env if available (for migration)
if [ -f .env ]; then
    echo "Loading existing .env for data migration..."
    source .env
    echo "✓ Existing environment loaded"
else
    echo "⚠ No .env file found (skip if not migrating data)"
fi

# 6. Check required tools
echo ""
echo "Checking required tools..."

# Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker not installed"
    exit 1
fi
echo "✓ Docker: $(docker --version)"

# PostgreSQL client
if ! command -v psql &> /dev/null; then
    echo "⚠ PostgreSQL client not installed (needed for data migration)"
    echo "Install: sudo apt-get install postgresql-client"
else
    echo "✓ PostgreSQL: $(psql --version)"
fi

# Python
if ! command -v python3 &> /dev/null; then
    echo "❌ Python3 not installed"
    exit 1
fi
echo "✓ Python: $(python3 --version)"

# Git
if ! command -v git &> /dev/null; then
    echo "❌ Git not installed"
    exit 1
fi
echo "✓ Git: $(git --version)"

echo ""
echo "========================================="
echo "✅ Environment Setup Complete!"
echo "========================================="
echo ""
echo "Environment variables set:"
echo "  AURORA_PASSWORD: ********"
echo "  AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
echo "  AWS_ACCOUNT_ID: $AWS_ACCOUNT"
echo ""
echo "You can now run:"
echo "  ./scripts/deployment/deploy-minimal-cost.sh"
echo "  ./scripts/deployment/deploy-minimal-app.sh"
echo ""
echo "Note: These variables are only set for this terminal session."
echo "To persist, add to ~/.bashrc or ~/.bash_profile"
echo ""
