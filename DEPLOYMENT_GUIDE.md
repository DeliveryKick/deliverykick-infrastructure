# DeliveryKick Infrastructure Deployment Guide

Complete step-by-step guide to deploy DeliveryKick infrastructure from scratch.

## Overview

This guide will help you:
1. Set up AWS prerequisites
2. Deploy Aurora database using bash script OR Terraform
3. Deploy ECS infrastructure with Terraform
4. Configure CI/CD for automatic deployments

## Prerequisites Checklist

- [ ] AWS Account with admin access
- [ ] AWS CLI installed and configured
- [ ] Terraform >= 1.5.0 installed
- [ ] Docker installed (for building images)
- [ ] Git repository cloned locally

## Deployment Options

### Option 1: Quick Setup (Bash Script + Terraform)

**Best for:** Getting started quickly, production-ready

1. Run bash script to create Aurora + secrets
2. Use Terraform for ECS infrastructure only

### Option 2: Full Terraform (Recommended for Production)

**Best for:** Infrastructure as Code, version control, reproducibility

1. Use Terraform to create everything
2. More control and visibility

---

## Option 1: Quick Setup (Bash + Terraform)

### Step 1: Create Aurora Database

```bash
cd scripts/deployment

# Set passwords (or will be prompted)
export AURORA_MASTER_PASSWORD="your-secure-password"
export ORDERING_ADMIN_PASSWORD="ordering-admin-pass"
export ORDERING_APP_PASSWORD="ordering-app-pass"
export ORDERING_READONLY_PASSWORD="ordering-readonly-pass"
export RESTAURANT_ADMIN_PASSWORD="restaurant-admin-pass"
export RESTAURANT_APP_PASSWORD="restaurant-app-pass"
export RESTAURANT_READONLY_PASSWORD="restaurant-readonly-pass"

# Run setup (creates Aurora + secrets)
./setup-deliverykick-secure.sh

# This creates:
# ✓ Aurora Serverless v2 cluster
# ✓ 2 databases (ordering, restaurant)
# ✓ 8 database users (4 per database)
# ✓ All credentials in AWS Secrets Manager
# ✓ Configuration files in aurora-config-secure/
```

**Expected time:** 15-20 minutes

### Step 2: Set Up Terraform Backend

```bash
# Create S3 bucket for Terraform state
aws s3 mb s3://deliverykick-terraform-state-prod --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket deliverykick-terraform-state-prod \
  --versioning-configuration Status=Enabled

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name deliverykick-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region us-east-1
```

### Step 3: Deploy ECS Infrastructure with Terraform

```bash
cd terraform/environments/prod

# Initialize Terraform
terraform init

# Create variables file
cat > terraform.tfvars <<EOF
aws_region = "us-east-1"

# Aurora cluster (already exists from bash script)
aurora_cluster_identifier = "deliverykick-prod-cluster"
aurora_master_username    = "postgres"
# aurora_master_password set via environment variable

# Network configuration
vpc_cidr             = "10.0.0.0/16"
availability_zones   = ["us-east-1a", "us-east-1b"]
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]

# SSL (optional)
certificate_arn       = null
enable_https_redirect = false

# Django settings
allowed_hosts = "*.deliverykick.com,deliverykick.com"
EOF

# Set Aurora password
export TF_VAR_aurora_master_password="your-secure-password"

# Review plan
terraform plan

# Apply configuration
terraform apply

# Save outputs
terraform output > outputs.txt
```

**Expected time:** 10-15 minutes

### Step 4: Build and Push Docker Images

```bash
# Get ECR repository URLs
ORDERING_REPO=$(cd terraform/environments/prod && terraform output -raw ordering_repository_url)
RESTAURANT_REPO=$(cd terraform/environments/prod && terraform output -raw restaurant_repository_url)

# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $(echo $ORDERING_REPO | cut -d/ -f1)

# Build and push ordering app
cd /path/to/Ordering-Delivery-and-Payment-Backend
docker build -t deliverykick-ordering .
docker tag deliverykick-ordering:latest $ORDERING_REPO:latest
docker push $ORDERING_REPO:latest

# Build and push restaurant app (when ready)
# cd /path/to/restaurant-backend
# docker build -t deliverykick-restaurant .
# docker tag deliverykick-restaurant:latest $RESTAURANT_REPO:latest
# docker push $RESTAURANT_REPO:latest
```

### Step 5: Run Database Migrations

```bash
# Option A: Run migration task in ECS
CLUSTER_NAME=$(cd terraform/environments/prod && terraform output -raw ecs_cluster_name)
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=deliverykick-prod-private*" --query 'Subnets[0].SubnetId' --output text)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=deliverykick-prod-ecs-tasks*" --query 'SecurityGroups[0].GroupId' --output text)

# Create a migration task definition (one-time)
# This should use the ADMIN user credentials for migrations

# Option B: Use ECS Exec to run in running container
aws ecs execute-command \
  --cluster $CLUSTER_NAME \
  --task <task-id> \
  --container ordering \
  --interactive \
  --command "/bin/bash"

# Inside container:
# python manage.py migrate
```

### Step 6: Verify Deployment

```bash
# Get ALB DNS name
ALB_DNS=$(cd terraform/environments/prod && terraform output -raw alb_dns_name)

# Test ordering API
curl http://$ALB_DNS/health/
curl http://$ALB_DNS/admin/

# Test restaurant API
curl http://$ALB_DNS/restaurant/health/
```

---

## Option 2: Full Terraform Deployment

### Step 1: Set Up Terraform Backend

Same as Option 1, Step 2

### Step 2: Configure Secrets Manager

Create secrets manually or use the bash script first to generate them.

```bash
# Master secret
aws secretsmanager create-secret \
  --name deliverykick/prod/master \
  --secret-string '{"username":"postgres","password":"MASTER_PASSWORD","host":"","port":5432}' \
  --region us-east-1

# Ordering app secret
aws secretsmanager create-secret \
  --name deliverykick/prod/ordering/app \
  --secret-string '{"username":"dk_ordering_app","password":"APP_PASSWORD","host":"","port":5432,"dbname":"deliverykick_ordering_prod"}' \
  --region us-east-1

# Repeat for other secrets...
```

### Step 3: Deploy Everything with Terraform

```bash
cd terraform/environments/prod

# Initialize
terraform init

# Configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars

# Set password
export TF_VAR_aurora_master_password="your-password"

# Deploy
terraform plan
terraform apply
```

### Step 4-6: Same as Option 1

---

## Environment-Specific Configurations

### Development Environment

```bash
cd terraform/environments/dev

# Simpler, lower cost configuration
# - No NAT Gateway
# - Public subnets for ECS
# - Minimal Aurora capacity (0.5 ACU)
# - Single task instance
# - No alarms

terraform init
export TF_VAR_aurora_master_password="dev-password"
terraform apply
```

**Monthly cost: ~$50-80**

### Production Environment

```bash
cd terraform/environments/prod

# Production-ready configuration
# - NAT Gateway for private subnets
# - Aurora Serverless v2 (0.5-2 ACU)
# - Multiple task instances
# - Auto-scaling enabled
# - CloudWatch alarms

terraform apply
```

**Monthly cost: ~$100-200**

---

## Post-Deployment Checklist

- [ ] Aurora cluster is running
- [ ] All secrets exist in Secrets Manager
- [ ] ECS cluster has running tasks
- [ ] ALB health checks are passing
- [ ] Can access APIs via ALB DNS
- [ ] Database migrations completed
- [ ] CloudWatch logs are populating
- [ ] Set up Route53 DNS (if using custom domain)
- [ ] Configure SSL certificate (if using HTTPS)
- [ ] Set up CloudWatch alarms
- [ ] Configure backup notifications
- [ ] Document credentials location
- [ ] Set up CI/CD pipeline

---

## CI/CD Integration

### GitHub Actions Example

Create `.github/workflows/deploy.yml` in your app repo:

```yaml
name: Deploy to ECS

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v1

      - name: Build and push Docker image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: deliverykick-ordering
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker tag $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG $ECR_REGISTRY/$ECR_REPOSITORY:latest
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest

      - name: Deploy to ECS
        run: |
          aws ecs update-service \
            --cluster deliverykick-prod-cluster \
            --service deliverykick-prod-ordering \
            --force-new-deployment
```

---

## Troubleshooting

### Aurora Connection Issues

```bash
# Check security group allows connection
aws ec2 describe-security-groups --group-ids sg-xxx

# Test connection from ECS task
aws ecs execute-command --cluster xxx --task xxx --container xxx --interactive --command "/bin/bash"
# Inside: psql -h <aurora-endpoint> -U dk_ordering_app -d deliverykick_ordering_prod
```

### ECS Tasks Not Starting

```bash
# Check task logs
aws logs tail /ecs/deliverykick-prod/ordering --follow

# Check task definition
aws ecs describe-task-definition --task-definition deliverykick-prod-ordering

# Check service events
aws ecs describe-services --cluster deliverykick-prod-cluster --services deliverykick-prod-ordering
```

### ALB Health Checks Failing

```bash
# Check target health
aws elbv2 describe-target-health --target-group-arn <arn>

# Verify health endpoint
curl http://<task-ip>:8000/health/
```

---

## Rollback Procedures

### Rollback ECS Deployment

```bash
# Get previous task definition revision
aws ecs describe-task-definition --task-definition deliverykick-prod-ordering

# Update service to previous revision
aws ecs update-service \
  --cluster deliverykick-prod-cluster \
  --service deliverykick-prod-ordering \
  --task-definition deliverykick-prod-ordering:PREVIOUS_REVISION
```

### Rollback Terraform Changes

```bash
cd terraform/environments/prod

# Revert .tf files
git checkout HEAD~1 -- main.tf

# Apply previous state
terraform apply
```

---

## Maintenance

### Update Docker Images

```bash
# Build new image with tag
docker build -t $REPO:v1.2.3 .
docker push $REPO:v1.2.3

# Update ECS service
aws ecs update-service --cluster xxx --service xxx --force-new-deployment
```

### Scale ECS Services

```bash
# Manually scale
aws ecs update-service \
  --cluster deliverykick-prod-cluster \
  --service deliverykick-prod-ordering \
  --desired-count 4

# Or update auto-scaling
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/deliverykick-prod-cluster/deliverykick-prod-ordering \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 2 \
  --max-capacity 10
```

### Backup Aurora

```bash
# Manual snapshot
aws rds create-db-cluster-snapshot \
  --db-cluster-identifier deliverykick-prod-cluster \
  --db-cluster-snapshot-identifier manual-backup-$(date +%Y%m%d)
```

---

## Support

- **Infrastructure Issues:** Check CloudWatch logs and metrics
- **Database Issues:** Check Aurora logs and Performance Insights
- **Application Issues:** Check ECS task logs
- **AWS Support:** https://console.aws.amazon.com/support/

---

**Version:** 1.0
**Last Updated:** 2025-10-09
