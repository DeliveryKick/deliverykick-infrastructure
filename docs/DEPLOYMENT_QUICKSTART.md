# Production Deployment Quick Start
## Ultra Low-Cost Setup for 2-3 Testers

**Time to Deploy:** 30-45 minutes
**Monthly Cost:** $68-100
**Requirements:** AWS CLI configured, Docker installed

---

## 🎯 What You're Deploying

- **Aurora Serverless v2**: Shared database for both ordering & restaurant data (0.5-1 ACU)
- **ECS Fargate**: Single container running your Django app (0.25 vCPU, 512MB RAM)
- **Application Load Balancer**: HTTP endpoint for your app
- **No NAT Gateway**: Using public subnets to save $32/month

---

## 📋 Prerequisites

### 1. Set Aurora Password
```bash
export AURORA_PASSWORD="your-secure-password-here"
```

### 2. Verify AWS CLI
```bash
aws sts get-caller-identity
# Should show your AWS account
```

### 3. Install PostgreSQL Client (if not installed)
```bash
# Ubuntu/Debian
sudo apt-get install postgresql-client

# macOS
brew install postgresql
```

---

## 🚀 Deployment Steps

### Step 1: Infrastructure Setup (15-20 minutes)

This creates Aurora, ECS cluster, ALB, and security groups:

```bash
cd /home/ec2-user/Ordering-Delivery-and-Payment-Backend

# Run the infrastructure setup script
export AURORA_PASSWORD="your-secure-password"
./scripts/deployment/deploy-minimal-cost.sh
```

**What this does:**
- ✅ Creates Aurora Serverless v2 cluster
- ✅ Creates `ordering_prod` and `restaurant_prod` databases
- ✅ Migrates data from existing RDS
- ✅ Creates ECS cluster
- ✅ Creates Application Load Balancer
- ✅ Stores secrets in AWS Secrets Manager

**Output:** Aurora endpoint and ALB DNS name

---

### Step 2: Application Deployment (10-15 minutes)

This builds your Docker image and deploys to ECS:

```bash
# Deploy the application
./scripts/deployment/deploy-minimal-app.sh
```

**What this does:**
- ✅ Creates ECR repository
- ✅ Builds Docker image from `Dockerfile.prod`
- ✅ Pushes image to ECR
- ✅ Creates ECS task definition
- ✅ Deploys ECS service with 1 task
- ✅ Connects to ALB

**Output:** Application URL (ALB DNS name)

---

### Step 3: Verify Deployment (5 minutes)

```bash
# Get your ALB URL
ALB_URL=$(aws elbv2 describe-load-balancers \
    --names ordering-minimal-alb \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

# Test health endpoint
curl http://$ALB_URL/health/

# Test admin (should redirect to login)
curl -I http://$ALB_URL/admin/

# View application logs
aws logs tail /ecs/ordering-minimal --follow
```

---

## 🔧 Post-Deployment Configuration

### Create Superuser

```bash
# Get ECS task ID
TASK_ARN=$(aws ecs list-tasks \
    --cluster ordering-prod-minimal \
    --service-name ordering-service \
    --query 'taskArns[0]' \
    --output text)

# Execute command in running container
aws ecs execute-command \
    --cluster ordering-prod-minimal \
    --task $TASK_ARN \
    --container web \
    --interactive \
    --command "python manage.py createsuperuser"
```

### Update CloudFront (Optional)

Point your existing CloudFront distribution to the new ALB:

```bash
# Get ALB DNS
echo $ALB_URL

# Update CloudFront origin to point to this ALB
# Via AWS Console: CloudFront > Distributions > Origins > Edit
```

---

## 💾 Database Access

### Connect to Aurora from Local Machine

```bash
# Get Aurora endpoint
AURORA_HOST=$(aws secretsmanager get-secret-value \
    --secret-id ordering/prod-minimal/database \
    --query 'SecretString' \
    --output text | python3 -c "import sys, json; print(json.load(sys.stdin)['host'])")

# Connect to ordering database
PGPASSWORD="$AURORA_PASSWORD" psql \
    -h $AURORA_HOST \
    -U postgres \
    -d ordering_prod

# Connect to restaurant database
PGPASSWORD="$AURORA_PASSWORD" psql \
    -h $AURORA_HOST \
    -U postgres \
    -d restaurant_prod
```

### Run Migrations

```bash
# If you add new models, run migrations
aws ecs execute-command \
    --cluster ordering-prod-minimal \
    --task $TASK_ARN \
    --container web \
    --interactive \
    --command "python manage.py migrate"
```

---

## 🔄 Updating Your Application

### Deploy New Code

```bash
# Make your code changes, commit to git
git add .
git commit -m "feat: your changes"

# Redeploy (rebuilds and pushes new image)
./scripts/deployment/deploy-minimal-app.sh
```

This will:
1. Build new Docker image
2. Push to ECR with git hash tag
3. Update ECS service
4. Wait for deployment to complete

---

## 📊 Monitoring

### View Logs

```bash
# Real-time logs
aws logs tail /ecs/ordering-minimal --follow

# Recent logs
aws logs tail /ecs/ordering-minimal --since 1h
```

### Check Service Health

```bash
# ECS service status
aws ecs describe-services \
    --cluster ordering-prod-minimal \
    --services ordering-service \
    --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}'

# Check tasks
aws ecs list-tasks \
    --cluster ordering-prod-minimal \
    --service-name ordering-service
```

### Database Metrics

```bash
# Aurora CloudWatch metrics
aws cloudwatch get-metric-statistics \
    --namespace AWS/RDS \
    --metric-name ServerlessDatabaseCapacity \
    --dimensions Name=DBClusterIdentifier,Value=ordering-prod-minimal \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Average
```

---

## 💰 Cost Management

### Current Costs

```bash
# Estimate current month's cost
aws ce get-cost-and-usage \
    --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
    --granularity MONTHLY \
    --metrics BlendedCost \
    --group-by Type=SERVICE
```

### Cost-Saving Tips

1. **Scale down during off-hours:**
   ```bash
   # Set desired count to 0 (stops ECS tasks)
   aws ecs update-service \
       --cluster ordering-prod-minimal \
       --service ordering-service \
       --desired-count 0

   # Scale back up
   aws ecs update-service \
       --cluster ordering-prod-minimal \
       --service ordering-service \
       --desired-count 1
   ```

2. **Pause Aurora (stops billing):**
   ```bash
   # Stop Aurora cluster
   aws rds stop-db-cluster --db-cluster-identifier ordering-prod-minimal

   # Start Aurora cluster
   aws rds start-db-cluster --db-cluster-identifier ordering-prod-minimal
   ```

3. **Delete ALB when not testing:**
   ```bash
   # Delete ALB (saves $16/month)
   ALB_ARN=$(aws elbv2 describe-load-balancers \
       --names ordering-minimal-alb \
       --query 'LoadBalancers[0].LoadBalancerArn' \
       --output text)
   aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
   ```

---

## 🛡️ Security Improvements

### Add HTTPS (Recommended)

```bash
# Request certificate in ACM
aws acm request-certificate \
    --domain-name yourdomain.com \
    --validation-method DNS

# Add HTTPS listener to ALB (after certificate validation)
aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTPS \
    --port 443 \
    --certificates CertificateArn=arn:aws:acm:REGION:ACCOUNT:certificate/ID \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN
```

### Restrict Database Access

```bash
# Update Aurora security group to only allow ECS tasks
ECS_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=ordering-ecs-minimal-sg" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

AURORA_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=ordering-aurora-minimal-sg" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

# Remove public access
aws ec2 revoke-security-group-ingress \
    --group-id $AURORA_SG \
    --protocol tcp \
    --port 5432 \
    --cidr 0.0.0.0/0

# Add ECS access only
aws ec2 authorize-security-group-ingress \
    --group-id $AURORA_SG \
    --protocol tcp \
    --port 5432 \
    --source-group $ECS_SG
```

---

## 🚨 Troubleshooting

### ECS Task Won't Start

```bash
# Check task failures
aws ecs describe-tasks \
    --cluster ordering-prod-minimal \
    --tasks $(aws ecs list-tasks --cluster ordering-prod-minimal --query 'taskArns[0]' --output text) \
    --query 'tasks[0].{Status:lastStatus,StopReason:stoppedReason,Containers:containers[*].{Name:name,Reason:reason}}'

# View task logs
aws logs tail /ecs/ordering-minimal --since 30m
```

### Health Check Failing

```bash
# Test health endpoint directly
curl http://$ALB_URL/health/

# Check if /health/ endpoint exists
# Add to core/urls.py:
# path('health/', lambda request: HttpResponse('OK'), name='health')
```

### Can't Connect to Database

```bash
# Verify Aurora is running
aws rds describe-db-clusters \
    --db-cluster-identifier ordering-prod-minimal \
    --query 'DBClusters[0].Status'

# Test connection from local
PGPASSWORD="$AURORA_PASSWORD" psql \
    -h $AURORA_HOST \
    -U postgres \
    -d ordering_prod \
    -c "SELECT version();"
```

---

## 🧹 Cleanup (Delete Everything)

**Warning:** This deletes all resources and data!

```bash
# Delete ECS service
aws ecs update-service \
    --cluster ordering-prod-minimal \
    --service ordering-service \
    --desired-count 0

aws ecs delete-service \
    --cluster ordering-prod-minimal \
    --service ordering-service \
    --force

# Delete ECS cluster
aws ecs delete-cluster --cluster ordering-prod-minimal

# Delete ALB
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names ordering-minimal-alb \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN

# Delete target group
TG_ARN=$(aws elbv2 describe-target-groups \
    --names ordering-minimal-tg \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)
aws elbv2 delete-target-group --target-group-arn $TG_ARN

# Delete Aurora cluster
aws rds delete-db-instance \
    --db-instance-identifier ordering-prod-minimal-instance \
    --skip-final-snapshot

aws rds delete-db-cluster \
    --db-cluster-identifier ordering-prod-minimal \
    --skip-final-snapshot

# Delete ECR repository
aws ecr delete-repository \
    --repository-name ordering-backend \
    --force

# Delete secrets
aws secretsmanager delete-secret \
    --secret-id ordering/prod-minimal/database \
    --force-delete-without-recovery

aws secretsmanager delete-secret \
    --secret-id ordering/prod-minimal/django-secret \
    --force-delete-without-recovery
```

---

## 📞 Support

### Useful Commands

```bash
# View all resources
aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=Environment,Values=production

# Check monthly costs
aws ce get-cost-and-usage \
    --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
    --granularity MONTHLY \
    --metrics BlendedCost
```

### Documentation

- [docs/SERVERLESS_DEPLOYMENT_STRATEGY.md](./docs/SERVERLESS_DEPLOYMENT_STRATEGY.md) - Full architecture
- [docs/ULTRA_LOW_COST_DEPLOYMENT.md](./docs/ULTRA_LOW_COST_DEPLOYMENT.md) - Cost optimization
- [docs/BRANCHING_STRATEGY.md](./docs/BRANCHING_STRATEGY.md) - Git workflow

---

**That's it!** You now have a production environment running for ~$68/month that's completely isolated from your development work.
