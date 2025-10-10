# Quick Start for Amazon Linux / EC2

Super fast setup guide for Amazon Linux users.

## One-Command Setup

```bash
# Install all prerequisites
./scripts/setup-prerequisites-linux.sh

# Load environment
source ~/.deliverykick-env

# If docker was installed, reload group membership
newgrp docker
```

## Deploy Infrastructure (3 Commands)

### 1. Create Aurora Database (15-20 min)

```bash
cd scripts/deployment

# Generate secure passwords
export AURORA_MASTER_PASSWORD="$(openssl rand -base64 32)"
export ORDERING_ADMIN_PASSWORD="$(openssl rand -base64 32)"
export ORDERING_APP_PASSWORD="$(openssl rand -base64 32)"
export ORDERING_READONLY_PASSWORD="$(openssl rand -base64 32)"
export RESTAURANT_ADMIN_PASSWORD="$(openssl rand -base64 32)"
export RESTAURANT_APP_PASSWORD="$(openssl rand -base64 32)"
export RESTAURANT_READONLY_PASSWORD="$(openssl rand -base64 32)"

# Save passwords (IMPORTANT!)
cat > ~/aurora-passwords.txt << EOF
Master: $AURORA_MASTER_PASSWORD
Ordering Admin: $ORDERING_ADMIN_PASSWORD
Ordering App: $ORDERING_APP_PASSWORD
Ordering ReadOnly: $ORDERING_READONLY_PASSWORD
Restaurant Admin: $RESTAURANT_ADMIN_PASSWORD
Restaurant App: $RESTAURANT_APP_PASSWORD
Restaurant ReadOnly: $RESTAURANT_READONLY_PASSWORD
EOF
chmod 600 ~/aurora-passwords.txt

# Run setup
./setup-deliverykick-secure.sh
```

### 2. Deploy Terraform Infrastructure (10-15 min)

```bash
cd ../../terraform/environments/prod

# Create backend
aws s3 mb s3://deliverykick-terraform-state-prod
aws dynamodb create-table \
  --table-name deliverykick-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5

# Initialize Terraform
terraform init

# Create config
cat > terraform.tfvars << EOF
aws_region = "us-east-1"
aurora_cluster_identifier = "deliverykick-prod-cluster"
aurora_master_username    = "postgres"
allowed_hosts = "*.deliverykick.com,deliverykick.com"
EOF

# Deploy
export TF_VAR_aurora_master_password="$AURORA_MASTER_PASSWORD"
terraform apply -auto-approve

# Save outputs
terraform output > ~/terraform-outputs.txt
```

### 3. Build and Deploy Apps

```bash
# Get repository URLs
ORDERING_REPO=$(terraform output -raw ordering_repository_url)

# Login to ECR
aws ecr get-login-password | docker login --username AWS --password-stdin $(echo $ORDERING_REPO | cut -d/ -f1)

# Clone and build ordering app (adjust path as needed)
cd ~
git clone <your-ordering-repo-url> Ordering-Delivery-and-Payment-Backend
cd Ordering-Delivery-and-Payment-Backend

# Build and push
docker build -t ordering .
docker tag ordering:latest $ORDERING_REPO:latest
docker push $ORDERING_REPO:latest

# Wait for ECS to start (2-3 minutes)
watch -n 5 "aws ecs describe-services --cluster deliverykick-prod-cluster --services deliverykick-prod-ordering --query 'services[0].[serviceName,runningCount,desiredCount]' --output table"

# Run migrations
cd ~/deliverykick-infrastructure
./scripts/deployment/run-migrations.sh prod ordering
```

## Test Deployment

```bash
# Get ALB URL
ALB=$(cd ~/deliverykick-infrastructure/terraform/environments/prod && terraform output -raw alb_dns_name)

# Test
curl http://$ALB/health/
```

## Daily Operations

```bash
# View logs
dk-logs-ordering

# Check status
dk-status

# Deploy updates
cd ~/Ordering-Delivery-and-Payment-Backend
git pull
APP_DIR=$(pwd) ~/deliverykick-infrastructure/scripts/deployment/deploy-ordering-app.sh prod

# Run migrations
cd ~/deliverykick-infrastructure
./scripts/deployment/run-migrations.sh prod ordering
```

## Troubleshooting

### AWS CLI not configured
```bash
aws configure
```

### Docker permission denied
```bash
newgrp docker
# Or logout/login
```

### ECR login expired
```bash
aws ecr get-login-password | docker login --username AWS --password-stdin $(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
```

## Full Documentation

- **Detailed Linux Setup:** [docs/SETUP_AMAZON_LINUX.md](docs/SETUP_AMAZON_LINUX.md)
- **Complete Deployment Guide:** [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md)
- **CI/CD Setup:** [docs/CI_CD_SETUP.md](docs/CI_CD_SETUP.md)
- **Quick Reference:** [QUICK_REFERENCE.md](QUICK_REFERENCE.md)

---

**Total setup time: ~30-45 minutes** 🚀
