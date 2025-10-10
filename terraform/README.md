# DeliveryKick Terraform Infrastructure

Complete Terraform configuration for deploying DeliveryKick applications on AWS.

## Overview

This Terraform setup creates:
- **VPC** with public/private subnets across multiple AZs
- **Aurora Serverless v2** PostgreSQL cluster (shared by both apps)
- **ECS Fargate** cluster for running containerized Django apps
- **Application Load Balancer** for routing traffic
- **ECR repositories** for Docker images
- **Secrets Manager** integration for database credentials
- **CloudWatch** monitoring and alarms

## Directory Structure

```
terraform/
├── modules/              # Reusable Terraform modules
│   ├── networking/      # VPC, subnets, security groups
│   ├── aurora/          # Aurora Serverless v2 PostgreSQL
│   ├── secrets/         # Secrets Manager integration
│   ├── ecr/             # Container Registry
│   ├── ecs/             # ECS Fargate cluster and services
│   └── alb/             # Application Load Balancer
├── environments/
│   ├── dev/             # Development environment
│   ├── staging/         # Staging environment (TODO)
│   └── prod/            # Production environment
└── README.md            # This file
```

## Prerequisites

### 1. Install Required Tools

```bash
# Terraform
brew install terraform  # macOS
# or download from https://www.terraform.io/downloads

# AWS CLI
brew install awscli  # macOS
# or download from https://aws.amazon.com/cli/

# Configure AWS credentials
aws configure
```

### 2. Create Terraform State Backend

Terraform needs an S3 bucket and DynamoDB table to store state:

```bash
# For production
aws s3 mb s3://deliverykick-terraform-state-prod --region us-east-1
aws dynamodb create-table \
  --table-name deliverykick-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region us-east-1

# Enable versioning on S3 bucket
aws s3api put-bucket-versioning \
  --bucket deliverykick-terraform-state-prod \
  --versioning-configuration Status=Enabled

# For development
aws s3 mb s3://deliverykick-terraform-state-dev --region us-east-1
```

### 3. Set Up Database Credentials

**Option A: Use existing secrets (created by setup script)**

If you already ran `scripts/deployment/setup-deliverykick-secure.sh`, the secrets are already in AWS Secrets Manager. Terraform will reference them.

**Option B: Create secrets manually**

```bash
# Production master password
aws secretsmanager create-secret \
  --name deliverykick/prod/master \
  --secret-string '{"username":"postgres","password":"YOUR_PASSWORD","host":"","port":5432}' \
  --region us-east-1

# Repeat for other secrets: ordering/admin, ordering/app, etc.
```

## Deployment Guide

### Deploy Development Environment

```bash
cd terraform/environments/dev

# Initialize Terraform
terraform init

# Set the Aurora master password
export TF_VAR_aurora_master_password="your-dev-password"

# Review the plan
terraform plan

# Apply the configuration
terraform apply

# Get outputs
terraform output
```

### Deploy Production Environment

```bash
cd terraform/environments/prod

# Initialize Terraform
terraform init

# Create terraform.tfvars from example
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# Set sensitive variables
export TF_VAR_aurora_master_password="your-prod-password"

# Review the plan
terraform plan

# Apply the configuration
terraform apply

# Get the ALB DNS name
terraform output alb_dns_name
```

## Post-Deployment Steps

### 1. Run Database Migrations

After infrastructure is deployed, run migrations using the admin user:

```bash
# Get the ECS cluster name
CLUSTER_NAME=$(terraform output -raw ecs_cluster_name)

# Run migration task (one-time)
aws ecs run-task \
  --cluster $CLUSTER_NAME \
  --task-definition deliverykick-prod-ordering-migration \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx],assignPublicIp=DISABLED}"

# Or SSH into a running task and run:
# python manage.py migrate
```

### 2. Deploy Application Code

Push Docker images to ECR:

```bash
# Get ECR repository URL
REPO_URL=$(terraform output -raw ordering_repository_url)

# Login to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $REPO_URL

# Build and push
docker build -t deliverykick-ordering .
docker tag deliverykick-ordering:latest $REPO_URL:latest
docker push $REPO_URL:latest

# Update ECS service to pull new image
aws ecs update-service \
  --cluster deliverykick-prod-cluster \
  --service deliverykick-prod-ordering \
  --force-new-deployment
```

### 3. Configure DNS (Optional)

```bash
# Get ALB details
ALB_DNS=$(terraform output -raw alb_dns_name)
ALB_ZONE=$(terraform output -raw alb_zone_id)

# Create Route53 record (example)
aws route53 change-resource-record-sets \
  --hosted-zone-id YOUR_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "api.deliverykick.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "'$ALB_ZONE'",
          "DNSName": "'$ALB_DNS'",
          "EvaluateTargetHealth": true
        }
      }
    }]
  }'
```

## Cost Optimization

### Development Environment
- No NAT Gateway (~$32/month saved)
- Public IPs for ECS tasks
- Minimal Aurora capacity (0.5-1 ACU)
- Shorter log retention
- No Container Insights

**Estimated cost: ~$50-80/month**

### Production Environment
- NAT Gateway for private subnets
- Aurora Serverless v2 (0.5-2 ACU)
- CloudWatch monitoring
- Container Insights enabled

**Estimated cost: ~$100-200/month**

## Secrets Manager Integration

The Terraform modules integrate with secrets created by the bash setup script:

```
deliverykick/prod/master            # Master credentials (emergency)
deliverykick/prod/ordering/admin    # Migrations only
deliverykick/prod/ordering/app      # Runtime (ECS uses this)
deliverykick/prod/ordering/readonly # Analytics
deliverykick/prod/restaurant/admin  # Migrations only
deliverykick/prod/restaurant/app    # Runtime (ECS uses this)
deliverykick/prod/restaurant/readonly # Analytics
```

ECS tasks automatically inject these as environment variables:
- `DB_HOST`
- `DB_PORT`
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`

## Updating Infrastructure

```bash
# Make changes to .tf files
vim main.tf

# Review changes
terraform plan

# Apply changes
terraform apply

# Note: ECS services have lifecycle ignore_changes on desired_count
# This allows auto-scaling without Terraform reverting it
```

## Destroying Resources

```bash
# Development
cd terraform/environments/dev
terraform destroy

# Production (be careful!)
cd terraform/environments/prod
terraform destroy
```

## Troubleshooting

### Issue: "Error creating ECS Service"

**Solution:** Ensure the ALB target groups are created first. The `depends_on` should handle this.

### Issue: "Cannot pull ECR image"

**Solution:** Check that:
1. ECR repository exists
2. Image has been pushed
3. ECS task execution role has `ecr_pull_policy_arn` attached

### Issue: "Database connection failed"

**Solution:** Verify:
1. Secrets exist in Secrets Manager
2. ECS task role has permission to read secrets
3. Security groups allow traffic from ECS to Aurora
4. Secret ARN format is correct: `arn:secret-name:json-key::`

### Issue: "Terraform state is locked"

**Solution:**
```bash
# Force unlock (use with caution)
terraform force-unlock LOCK_ID
```

## Security Best Practices

1. **Never commit secrets** to git
2. **Use Secrets Manager** for all sensitive data
3. **Enable MFA** on AWS accounts
4. **Restrict IAM permissions** to minimum required
5. **Enable CloudTrail** for audit logging
6. **Use private subnets** for production ECS tasks
7. **Enable encryption** at rest and in transit
8. **Regular security updates** for Docker images
9. **Scan images** with ECR vulnerability scanning

## CI/CD Integration

See `docs/CI_CD_SETUP.md` for GitHub Actions / GitLab CI integration.

## Monitoring

Access CloudWatch dashboards:
```bash
# ECS metrics
https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:

# Aurora metrics
https://console.aws.amazon.com/rds/home?region=us-east-1#database:id=deliverykick-prod-cluster

# ALB metrics
https://console.aws.amazon.com/ec2/v2/home?region=us-east-1#LoadBalancers:
```

## Support

- **Issues:** Create GitHub issues in this repo
- **Documentation:** See `docs/` directory
- **AWS Support:** https://console.aws.amazon.com/support/

## Contributing

1. Create feature branch
2. Make infrastructure changes
3. Test in dev environment first
4. Create PR with detailed description
5. Apply to prod after approval

---

**Version:** 1.0
**Created:** 2025-10-09
**Last Updated:** 2025-10-09
