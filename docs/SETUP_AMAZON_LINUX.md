# Setup Guide for Amazon Linux / EC2

Complete setup instructions for Amazon Linux 2023 / Amazon Linux 2.

## Prerequisites Installation

### 1. Update System

```bash
sudo yum update -y
```

### 2. Install Terraform

```bash
# Download Terraform
TERRAFORM_VERSION="1.6.6"
wget https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip

# Install unzip if needed
sudo yum install -y unzip

# Extract and install
unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip
sudo mv terraform /usr/local/bin/

# Verify installation
terraform --version

# Clean up
rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip
```

### 3. Install/Verify AWS CLI

AWS CLI is pre-installed on Amazon Linux. Verify:

```bash
aws --version

# If not installed or outdated, install latest:
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install --update

# Clean up
rm -rf aws awscliv2.zip
```

### 4. Configure AWS Credentials

```bash
# Configure AWS CLI
aws configure

# Enter your credentials:
# AWS Access Key ID: AKIA...
# AWS Secret Access Key: xxxxx...
# Default region name: us-east-1
# Default output format: json

# Verify configuration
aws sts get-caller-identity
```

### 5. Install Docker

```bash
# Install Docker
sudo yum install -y docker

# Start Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Add your user to docker group (avoid using sudo)
sudo usermod -aG docker $USER

# Apply group changes (logout/login or run)
newgrp docker

# Verify installation
docker --version
docker run hello-world
```

### 6. Install Git (if needed)

```bash
# Git is usually pre-installed, but verify:
git --version

# If not installed:
sudo yum install -y git

# Configure git
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

### 7. Install PostgreSQL Client (for database access)

```bash
# Amazon Linux 2023
sudo dnf install -y postgresql15

# Amazon Linux 2
sudo amazon-linux-extras enable postgresql14
sudo yum install -y postgresql

# Verify
psql --version
```

### 8. Install jq (JSON processor - useful for scripts)

```bash
sudo yum install -y jq

# Verify
jq --version
```

## Initial Setup

### 1. Clone Infrastructure Repository

```bash
cd ~
git clone <your-repo-url> deliverykick-infrastructure
cd deliverykick-infrastructure
```

### 2. Set Up Environment Variables

Create a file to store environment variables:

```bash
cat > ~/.deliverykick-env << 'EOF'
# AWS Configuration
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Aurora Configuration
export AURORA_CLUSTER_ID=deliverykick-prod-cluster
export AURORA_MASTER_USER=postgres

# Terraform
export TF_VAR_aws_region=us-east-1

# Add to PATH
export PATH=$PATH:/usr/local/bin
EOF

# Load environment variables
source ~/.deliverykick-env

# Add to .bashrc for persistence
echo "source ~/.deliverykick-env" >> ~/.bashrc
```

### 3. Create Terraform State Backend

```bash
# Create S3 bucket
aws s3 mb s3://deliverykick-terraform-state-prod --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket deliverykick-terraform-state-prod \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket deliverykick-terraform-state-prod \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name deliverykick-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region us-east-1

# Verify resources
aws s3 ls | grep deliverykick-terraform
aws dynamodb list-tables | grep deliverykick-terraform
```

## Deploy Infrastructure

### Step 1: Create Aurora Database

```bash
cd ~/deliverykick-infrastructure/scripts/deployment

# Set passwords as environment variables
export AURORA_MASTER_PASSWORD="$(openssl rand -base64 32)"
export ORDERING_ADMIN_PASSWORD="$(openssl rand -base64 32)"
export ORDERING_APP_PASSWORD="$(openssl rand -base64 32)"
export ORDERING_READONLY_PASSWORD="$(openssl rand -base64 32)"
export RESTAURANT_ADMIN_PASSWORD="$(openssl rand -base64 32)"
export RESTAURANT_APP_PASSWORD="$(openssl rand -base64 32)"
export RESTAURANT_READONLY_PASSWORD="$(openssl rand -base64 32)"

# Save passwords to secure file (important!)
cat > ~/aurora-passwords.txt << EOF
Master Password: $AURORA_MASTER_PASSWORD
Ordering Admin: $ORDERING_ADMIN_PASSWORD
Ordering App: $ORDERING_APP_PASSWORD
Ordering ReadOnly: $ORDERING_READONLY_PASSWORD
Restaurant Admin: $RESTAURANT_ADMIN_PASSWORD
Restaurant App: $RESTAURANT_APP_PASSWORD
Restaurant ReadOnly: $RESTAURANT_READONLY_PASSWORD
EOF

# Secure the file
chmod 600 ~/aurora-passwords.txt

echo "Passwords saved to ~/aurora-passwords.txt"
echo "KEEP THIS FILE SECURE!"

# Run setup script (15-20 minutes)
./setup-deliverykick-secure.sh

# Verify Aurora cluster is created
aws rds describe-db-clusters \
  --db-cluster-identifier deliverykick-prod-cluster \
  --query 'DBClusters[0].[DBClusterIdentifier,Status,Endpoint]' \
  --output table
```

### Step 2: Deploy Terraform Infrastructure

```bash
cd ~/deliverykick-infrastructure/terraform/environments/prod

# Initialize Terraform
terraform init

# Create terraform.tfvars
cat > terraform.tfvars << EOF
aws_region = "us-east-1"

# Network configuration
vpc_cidr             = "10.0.0.0/16"
availability_zones   = ["us-east-1a", "us-east-1b"]
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]

# Aurora configuration
aurora_cluster_identifier = "deliverykick-prod-cluster"
aurora_master_username    = "postgres"
aurora_min_capacity       = 0.5
aurora_max_capacity       = 2

# SSL (set to null for now, add later)
certificate_arn       = null
enable_https_redirect = false

# Django settings
allowed_hosts = "*.deliverykick.com,deliverykick.com"
EOF

# Set Aurora master password
export TF_VAR_aurora_master_password="$AURORA_MASTER_PASSWORD"

# Review the plan
terraform plan

# Apply (will take 10-15 minutes)
terraform apply

# Save outputs
terraform output > ~/terraform-outputs.txt
cat ~/terraform-outputs.txt
```

### Step 3: Build and Push Docker Images

```bash
# Get ECR repository URLs
ORDERING_REPO=$(cd ~/deliverykick-infrastructure/terraform/environments/prod && terraform output -raw ordering_repository_url)
RESTAURANT_REPO=$(cd ~/deliverykick-infrastructure/terraform/environments/prod && terraform output -raw restaurant_repository_url)

echo "Ordering repository: $ORDERING_REPO"
echo "Restaurant repository: $RESTAURANT_REPO"

# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $(echo $ORDERING_REPO | cut -d/ -f1)

# Navigate to your app directory
# If app repo is not on this EC2 instance, you need to clone it first

# Clone ordering app (if needed)
cd ~
git clone <ordering-app-repo-url> Ordering-Delivery-and-Payment-Backend
cd Ordering-Delivery-and-Payment-Backend

# Build and push ordering app
docker build -t deliverykick-ordering .
docker tag deliverykick-ordering:latest $ORDERING_REPO:latest
docker push $ORDERING_REPO:latest

# Verify image is in ECR
aws ecr describe-images \
  --repository-name deliverykick-ordering \
  --query 'imageDetails[0].[imageTags[0],imagePushedAt]' \
  --output table
```

### Step 4: Wait for ECS Tasks to Start

```bash
# Check ECS service status
watch -n 5 "aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering \
  --query 'services[0].[serviceName,status,runningCount,desiredCount]' \
  --output table"

# Press Ctrl+C when runningCount matches desiredCount

# Check task logs
aws logs tail /ecs/deliverykick-prod/ordering --follow
```

### Step 5: Run Database Migrations

```bash
cd ~/deliverykick-infrastructure

# Run migrations
./scripts/deployment/run-migrations.sh prod ordering

# Verify migrations completed
aws logs tail /ecs/deliverykick-prod/ordering --since 5m | grep migrate
```

### Step 6: Test Deployment

```bash
# Get ALB DNS name
ALB_DNS=$(cd ~/deliverykick-infrastructure/terraform/environments/prod && \
  terraform output -raw alb_dns_name)

echo "ALB DNS: $ALB_DNS"

# Test health endpoint
curl http://$ALB_DNS/health/

# Test admin (if enabled)
curl -I http://$ALB_DNS/admin/

# Save ALB URL for easy access
echo "export ALB_URL=http://$ALB_DNS" >> ~/.deliverykick-env
```

## Daily Operations on EC2

### Deploy Updates

```bash
# Navigate to app directory
cd ~/Ordering-Delivery-and-Payment-Backend

# Pull latest code
git pull

# Build and deploy
APP_DIR=$(pwd) ~/deliverykick-infrastructure/scripts/deployment/deploy-ordering-app.sh prod
```

### View Logs

```bash
# Real-time logs
aws logs tail /ecs/deliverykick-prod/ordering --follow

# Last 10 minutes
aws logs tail /ecs/deliverykick-prod/ordering --since 10m

# Filter logs
aws logs tail /ecs/deliverykick-prod/ordering --since 1h --filter-pattern "ERROR"
```

### Run Migrations

```bash
cd ~/deliverykick-infrastructure
./scripts/deployment/run-migrations.sh prod ordering
```

### Check Service Status

```bash
# Quick status
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering deliverykick-prod-restaurant \
  --query 'services[].[serviceName,status,runningCount,desiredCount]' \
  --output table

# Detailed status with events
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering \
  --query 'services[0].events[0:5]' \
  --output table
```

## Useful Aliases

Add to `~/.bashrc`:

```bash
cat >> ~/.bashrc << 'EOF'

# DeliveryKick aliases
alias dk-logs-ordering='aws logs tail /ecs/deliverykick-prod/ordering --follow'
alias dk-logs-restaurant='aws logs tail /ecs/deliverykick-prod/restaurant --follow'
alias dk-status='aws ecs describe-services --cluster deliverykick-prod-cluster --services deliverykick-prod-ordering deliverykick-prod-restaurant --query "services[].[serviceName,status,runningCount,desiredCount]" --output table'
alias dk-deploy-ordering='cd ~/deliverykick-infrastructure && APP_DIR=~/Ordering-Delivery-and-Payment-Backend ./scripts/deployment/deploy-ordering-app.sh prod'
alias dk-migrate-ordering='cd ~/deliverykick-infrastructure && ./scripts/deployment/run-migrations.sh prod ordering'
alias dk-tf='cd ~/deliverykick-infrastructure/terraform/environments/prod'

EOF

# Reload bashrc
source ~/.bashrc
```

Now you can use:
```bash
dk-logs-ordering      # View ordering app logs
dk-status             # Check service status
dk-deploy-ordering    # Deploy ordering app
dk-migrate-ordering   # Run migrations
dk-tf                 # Go to terraform directory
```

## Troubleshooting on EC2

### Docker Permission Issues

```bash
# If you get "permission denied" errors with docker:
sudo usermod -aG docker $USER
newgrp docker

# Or logout and login again
exit
# SSH back in
```

### AWS CLI Not Finding Credentials

```bash
# Verify credentials
aws sts get-caller-identity

# If error, reconfigure
aws configure

# Check credentials file
cat ~/.aws/credentials
```

### Terraform Backend Issues

```bash
# If terraform init fails with S3 backend error:
cd ~/deliverykick-infrastructure/terraform/environments/prod

# Verify S3 bucket exists
aws s3 ls s3://deliverykick-terraform-state-prod

# If not, create it
aws s3 mb s3://deliverykick-terraform-state-prod
```

### Out of Disk Space

```bash
# Check disk usage
df -h

# Clean up Docker
docker system prune -a -f

# Clean up old images
docker image prune -a -f

# Remove old logs
sudo journalctl --vacuum-time=3d
```

### ECR Login Expires

```bash
# ECR login expires after 12 hours, re-login:
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  $(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
```

## Security Best Practices

### 1. Secure Your EC2 Instance

```bash
# Update regularly
sudo yum update -y

# Enable automatic security updates (Amazon Linux 2023)
sudo dnf install -y dnf-automatic
sudo systemctl enable --now dnf-automatic.timer

# For Amazon Linux 2
sudo yum install -y yum-cron
sudo systemctl enable --now yum-cron
```

### 2. Protect Sensitive Files

```bash
# Secure password file
chmod 600 ~/aurora-passwords.txt

# Secure AWS credentials
chmod 600 ~/.aws/credentials

# Never commit these files to git
```

### 3. Use IAM Roles (Recommended)

Instead of using AWS access keys, attach an IAM role to your EC2 instance:

```bash
# Check if instance has IAM role
aws sts get-caller-identity

# If using IAM role, remove access keys from ~/.aws/credentials
rm ~/.aws/credentials

# Instance role should have these policies:
# - AmazonEC2ContainerRegistryFullAccess
# - AmazonECS_FullAccess
# - SecretsManagerReadWrite
# - RDSFullAccess (for Aurora setup)
```

## Monitoring from EC2

### Set Up CloudWatch Dashboards

```bash
# Install CloudWatch agent (optional - for EC2 metrics)
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
sudo rpm -U ./amazon-cloudwatch-agent.rpm
```

### Create Simple Monitoring Script

```bash
cat > ~/monitor-services.sh << 'EOF'
#!/bin/bash

echo "DeliveryKick Service Status - $(date)"
echo "=========================================="
echo ""

# ECS Services
echo "ECS Services:"
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering deliverykick-prod-restaurant \
  --query 'services[].[serviceName,status,runningCount,desiredCount]' \
  --output table

echo ""

# Aurora Status
echo "Aurora Cluster:"
aws rds describe-db-clusters \
  --db-cluster-identifier deliverykick-prod-cluster \
  --query 'DBClusters[0].[DBClusterIdentifier,Status,ServerlessDatabaseCapacity]' \
  --output table

echo ""

# ALB Health
echo "Target Health:"
for tg in $(aws elbv2 describe-target-groups --query 'TargetGroups[?contains(TargetGroupName, `deliverykick`)].TargetGroupArn' --output text); do
  aws elbv2 describe-target-health --target-group-arn $tg --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
done
EOF

chmod +x ~/monitor-services.sh

# Run it
~/monitor-services.sh

# Add to cron for regular checks (optional)
# Run every 5 minutes
(crontab -l 2>/dev/null; echo "*/5 * * * * ~/monitor-services.sh >> ~/service-status.log 2>&1") | crontab -
```

## Next Steps

1. **Set up CI/CD from GitHub** (see docs/CI_CD_SETUP.md)
2. **Configure custom domain** (Route53 + ACM certificate)
3. **Set up monitoring alerts** (CloudWatch alarms)
4. **Configure backups** (Aurora snapshots)
5. **Set up log rotation** (CloudWatch log retention)

---

**You're all set on Amazon Linux!** 🚀

Use the aliases and scripts above for daily operations.
