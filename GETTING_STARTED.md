# Getting Started with DeliveryKick Infrastructure

Quick start guide to get your infrastructure up and running.

## What This Repository Provides

This infrastructure repository creates a **complete production-ready AWS environment** for your DeliveryKick applications:

### Infrastructure Components

```
┌─────────────────────────────────────────────────────────────┐
│                    Internet / Users                          │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Application Load    │  ← Routes traffic
              │     Balancer (ALB)   │
              └──────────┬───────────┘
                         │
         ┌───────────────┴───────────────┐
         │                               │
         ▼                               ▼
  ┌─────────────┐                ┌─────────────┐
  │   ECS Task  │                │   ECS Task  │
  │  (Ordering  │                │ (Restaurant │
  │    App)     │                │    App)     │
  └──────┬──────┘                └──────┬──────┘
         │                               │
         └───────────────┬───────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │   Aurora Serverless  │  ← Shared database
              │   v2 PostgreSQL      │
              │  (2 databases)       │
              └──────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  AWS Secrets Manager │  ← Credentials
              └──────────────────────┘
```

### Key Features

- **VPC with Public/Private Subnets** - Network isolation
- **Aurora Serverless v2** - Auto-scaling PostgreSQL database
- **ECS Fargate** - Serverless container orchestration
- **Application Load Balancer** - Intelligent traffic routing
- **ECR Repositories** - Private Docker image registry
- **Secrets Manager** - Secure credential storage
- **CloudWatch** - Logging and monitoring
- **Auto-Scaling** - Automatic capacity adjustment

## Two Deployment Approaches

### Approach 1: Bash Script + Terraform (Recommended for Quick Start)

**Best for:** Getting started quickly, small teams

1. **Bash script creates:** Aurora cluster + database users + secrets
2. **Terraform creates:** VPC, ECS, ALB, ECR

**Pros:**
- Fastest to get running
- Simple database setup
- Script handles user permissions correctly

**Cons:**
- Database not in Terraform state
- Two tools to manage

### Approach 2: Pure Terraform (Recommended for Production)

**Best for:** Large teams, full IaC, reproducibility

1. **Terraform creates:** Everything

**Pros:**
- Full infrastructure as code
- Everything in version control
- Easy to reproduce environments

**Cons:**
- More initial setup
- Requires understanding of Terraform

## Quick Start (5 Steps)

### 1. Install Prerequisites

> **Amazon Linux / EC2 Users:** See **[docs/SETUP_AMAZON_LINUX.md](docs/SETUP_AMAZON_LINUX.md)** for complete Linux setup.

**macOS:**
```bash
# Install Terraform
brew install terraform

# Install AWS CLI
brew install awscli
```

**Linux:**
```bash
# Install Terraform
wget https://releases.hashicorp.com/terraform/1.6.6/terraform_1.6.6_linux_amd64.zip
unzip terraform_1.6.6_linux_amd64.zip
sudo mv terraform /usr/local/bin/

# AWS CLI (usually pre-installed on Amazon Linux)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**Configure AWS:**
```bash
aws configure
# Enter: Access Key ID, Secret Access Key, Region (us-east-1)
```

### 2. Create Terraform Backend

```bash
# Create S3 bucket for state
aws s3 mb s3://deliverykick-terraform-state-prod --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket deliverykick-terraform-state-prod \
  --versioning-configuration Status=Enabled

# Create DynamoDB for locking
aws dynamodb create-table \
  --table-name deliverykick-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region us-east-1
```

### 3. Create Aurora Database

```bash
cd scripts/deployment

# Set passwords
export AURORA_MASTER_PASSWORD="YourSecurePassword123!"
export ORDERING_ADMIN_PASSWORD="ordering-admin-pass"
export ORDERING_APP_PASSWORD="ordering-app-pass"
export ORDERING_READONLY_PASSWORD="ordering-readonly-pass"
export RESTAURANT_ADMIN_PASSWORD="restaurant-admin-pass"
export RESTAURANT_APP_PASSWORD="restaurant-app-pass"
export RESTAURANT_READONLY_PASSWORD="restaurant-readonly-pass"

# Run setup (15-20 minutes)
./setup-deliverykick-secure.sh
```

**This creates:**
- Aurora Serverless v2 cluster
- 2 databases: `deliverykick_ordering_prod`, `deliverykick_restaurant_prod`
- 8 users (4 per database: master, admin, app, readonly)
- All credentials stored in AWS Secrets Manager
- Configuration files in `aurora-config-secure/`

### 4. Deploy ECS Infrastructure

```bash
cd terraform/environments/prod

# Initialize Terraform
terraform init

# Copy example config
cp terraform.tfvars.example terraform.tfvars

# Edit if needed (defaults should work)
vim terraform.tfvars

# Set Aurora password
export TF_VAR_aurora_master_password="YourSecurePassword123!"

# Deploy (10-15 minutes)
terraform apply

# Get ALB URL
terraform output alb_dns_name
```

### 5. Build and Deploy Applications

```bash
# Get ECR URLs
ORDERING_REPO=$(cd terraform/environments/prod && terraform output -raw ordering_repository_url)

# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $(echo $ORDERING_REPO | cut -d/ -f1)

# Build and push (from your app repo)
cd /path/to/Ordering-Delivery-and-Payment-Backend
docker build -t deliverykick-ordering .
docker tag deliverykick-ordering:latest $ORDERING_REPO:latest
docker push $ORDERING_REPO:latest

# Wait for ECS to pull and start (2-3 minutes)
# Check status
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering
```

## Verify Deployment

```bash
# Get ALB URL
ALB_DNS=$(cd terraform/environments/prod && terraform output -raw alb_dns_name)

# Test health endpoint
curl http://$ALB_DNS/health/

# Test admin (if enabled)
curl http://$ALB_DNS/admin/

# Test ordering API
curl http://$ALB_DNS/api/v1/

# Test restaurant API
curl http://$ALB_DNS/restaurant/api/v1/
```

## What Gets Created

### AWS Resources

| Resource | Quantity | Purpose |
|----------|----------|---------|
| VPC | 1 | Network isolation |
| Subnets | 4 (2 public, 2 private) | Multi-AZ deployment |
| NAT Gateway | 1 | Outbound internet for private subnets |
| Security Groups | 3 (ALB, ECS, Aurora) | Network security |
| Aurora Cluster | 1 | Shared database |
| Aurora Instance | 1 | Serverless v2 |
| Databases | 2 | ordering, restaurant |
| Database Users | 8 | 4 per database |
| ALB | 1 | Traffic routing |
| Target Groups | 2 | One per app |
| ECS Cluster | 1 | Container orchestration |
| ECS Services | 2 | One per app |
| ECS Tasks | 2+ | Running containers |
| ECR Repositories | 2 | Docker images |
| Secrets | 7 | Database credentials |
| CloudWatch Log Groups | 3 | Logs (ALB, ordering, restaurant) |

### Estimated Costs

**Development Environment:**
- Aurora: ~$20-40/month (0.5 ACU min)
- ECS: ~$15-25/month (1 task per app)
- ALB: ~$16/month
- NAT: $0 (disabled in dev)
- **Total: ~$50-80/month**

**Production Environment:**
- Aurora: ~$40-80/month (0.5-2 ACU)
- ECS: ~$30-60/month (2+ tasks per app)
- ALB: ~$16/month
- NAT: ~$32/month
- **Total: ~$120-190/month**

## Next Steps

### Set Up Custom Domain (Optional)

```bash
# In Route53, create A record (alias)
# Point to ALB: terraform output alb_dns_name

# Example:
api.deliverykick.com -> ALB
```

### Set Up SSL Certificate (Optional)

```bash
# Request certificate in ACM
aws acm request-certificate \
  --domain-name api.deliverykick.com \
  --validation-method DNS

# Add to terraform.tfvars:
# certificate_arn = "arn:aws:acm:us-east-1:xxx:certificate/xxx"
# enable_https_redirect = true

# Apply changes
terraform apply
```

### Set Up CI/CD

See `DEPLOYMENT_GUIDE.md` for GitHub Actions / GitLab CI examples.

### Run Database Migrations

```bash
# From your app repo
# Use the ADMIN credentials for migrations

# Copy ordering admin config
cp aurora-config-secure/ordering-admin.env .env.migrations

# Run migrations
source .env.migrations
python manage.py migrate

# Switch to APP credentials for runtime
cp aurora-config-secure/ordering-app.env .env
```

### Monitor Your Applications

```bash
# CloudWatch Logs
aws logs tail /ecs/deliverykick-prod/ordering --follow

# ECS Service Status
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering

# Aurora Metrics
# Go to: AWS Console > RDS > deliverykick-prod-cluster > Monitoring
```

## Common Issues

### "Cannot connect to database"

**Solution:** Check security groups allow traffic from ECS to Aurora:

```bash
aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=deliverykick-prod-aurora-sg"
```

### "ECS tasks keep restarting"

**Solution:** Check CloudWatch logs:

```bash
aws logs tail /ecs/deliverykick-prod/ordering --follow
```

Common causes:
- Health check failing (no `/health/` endpoint)
- Database connection error (wrong credentials)
- Missing environment variables

### "Cannot push to ECR"

**Solution:** Login to ECR first:

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  $(aws ecr describe-repositories --repository-names deliverykick-ordering --query 'repositories[0].repositoryUri' --output text | cut -d/ -f1)
```

## Architecture Decisions

### Why Terraform?
- Infrastructure as Code
- Version controlled
- Reproducible across environments
- Widely adopted standard

### Why Aurora Serverless v2?
- Auto-scaling (pay for what you use)
- PostgreSQL compatible
- Shared cluster (50% cost savings)
- Production-ready performance

### Why ECS Fargate?
- No EC2 instances to manage
- Auto-scaling
- Pay per task
- Simpler than Kubernetes

### Why Application Load Balancer?
- Path-based routing (multiple apps)
- Health checks
- SSL termination
- WebSocket support

### Why Secrets Manager vs Parameter Store?
- Automatic rotation
- Fine-grained permissions
- Versioning
- Integration with RDS

## Documentation

- **terraform/README.md** - Detailed Terraform usage
- **DEPLOYMENT_GUIDE.md** - Complete deployment walkthrough
- **docs/SECURE_AURORA_COMPLETE.md** - Database security model
- **docs/POSTGRES_USER_SECURITY.md** - User permissions explained

## Getting Help

1. Check CloudWatch logs first
2. Review security group rules
3. Verify secrets in Secrets Manager
4. Check ECS task definition
5. Review this documentation
6. Create GitHub issue

## What's Next?

After deployment:
1. Set up monitoring and alarms
2. Configure auto-scaling policies
3. Set up CI/CD pipelines
4. Add custom domain and SSL
5. Configure backups
6. Set up disaster recovery
7. Performance tuning
8. Security hardening

---

**You're now ready to deploy DeliveryKick!** 🚀

Follow the Quick Start steps above and you'll have a production-ready infrastructure in ~30-40 minutes.
