# Ultra Low-Cost Production Deployment
## Optimized for 2-3 Testers with Shared Aurora

**Monthly Cost Target:** $30-60
**Use Case:** Production testing environment with minimal traffic
**Infrastructure:** Shared Aurora + Minimal ECS Fargate

---

## 💰 Cost Breakdown (Ultra-Low Config)

| Service | Configuration | Monthly Cost |
|---------|---------------|---------------|
| **Aurora Serverless v2** | 0.5 ACU minimum (shared) | **$43** |
| **ECS Fargate** | 1 task @ 0.25 vCPU, 512MB | **$7** |
| **Application Load Balancer** | Standard ALB | **$16** |
| **NAT Gateway** | Single AZ (optional) | **$0-32** |
| **CloudWatch Logs** | 1GB retention | **$0.50** |
| **Data Transfer** | Minimal | **$2** |
| **TOTAL (No NAT)** | | **$68.50/month** |
| **TOTAL (With NAT)** | | **$100.50/month** |

### Skip NAT Gateway (Save $32/month)
Use public subnets for ECS tasks to avoid NAT Gateway costs

---

## 🏗️ Shared Aurora Architecture

```
┌────────────────────────────────────────────────┐
│       Aurora Serverless v2 Cluster             │
│         (Single Shared Instance)                │
│                                                 │
│  ┌──────────────────┐  ┌──────────────────┐   │
│  │  ordering_prod   │  │ restaurant_prod  │   │
│  │  (Database 1)    │  │  (Database 2)    │   │
│  └──────────────────┘  └──────────────────┘   │
│                                                 │
│  Min: 0.5 ACU  |  Max: 1 ACU                   │
│  Cost: ~$43/month                               │
└────────────────────────────────────────────────┘
                    ↑
                    │
        ┌───────────┴───────────┐
        │                       │
  ECS Task (Ordering)    Development EC2
  $7/month              (Keep for dev work)
```

---

## 📝 Minimal Cost Setup Script

Create `/home/ec2-user/Ordering-Delivery-and-Payment-Backend/scripts/deployment/deploy-minimal-cost.sh`:

```bash
#!/bin/bash
set -e

echo "======================================"
echo "Ultra Low-Cost Production Setup"
echo "For 2-3 Testers | $60-100/month"
echo "======================================"

CLUSTER_NAME="ordering-prod-minimal"
TARGET_PASSWORD="${AURORA_PASSWORD:?Error: Set AURORA_PASSWORD env variable}"
REGION="us-east-1"

# Step 1: Create Aurora Serverless v2 (Shared for both DBs)
echo "Step 1: Creating shared Aurora cluster..."

# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text)
echo "Using VPC: $VPC_ID"

# Get public subnets (to avoid NAT Gateway cost)
PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
    --query 'Subnets[*].SubnetId' \
    --output text | tr '\t' ' ')

echo "Using public subnets: $PUBLIC_SUBNETS"

# Create DB subnet group
aws rds create-db-subnet-group \
    --db-subnet-group-name ordering-minimal-subnet-group \
    --db-subnet-group-description "Minimal cost subnet group" \
    --subnet-ids $PUBLIC_SUBNETS \
    2>/dev/null || echo "Subnet group exists"

# Create security group for Aurora
SG_ID=$(aws ec2 create-security-group \
    --group-name ordering-aurora-minimal-sg \
    --description "Aurora security group - minimal cost" \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=ordering-aurora-minimal-sg" \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

# Allow PostgreSQL from anywhere (adjust for production security)
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 5432 \
    --cidr 0.0.0.0/0 \
    2>/dev/null || echo "Security group rule exists"

# Create Aurora Serverless v2 cluster with MINIMAL settings
echo "Creating Aurora cluster (this takes 10-15 min)..."
aws rds create-db-cluster \
    --db-cluster-identifier $CLUSTER_NAME \
    --engine aurora-postgresql \
    --engine-version 15.4 \
    --master-username postgres \
    --master-user-password "$TARGET_PASSWORD" \
    --vpc-security-group-ids $SG_ID \
    --db-subnet-group-name ordering-minimal-subnet-group \
    --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=1 \
    --backup-retention-period 1 \
    --skip-final-snapshot \
    --publicly-accessible \
    --tags Key=Environment,Value=production Key=Cost,Value=minimal

aws rds wait db-cluster-available --db-cluster-identifier $CLUSTER_NAME

# Create single instance
echo "Creating Aurora instance..."
aws rds create-db-instance \
    --db-instance-identifier "${CLUSTER_NAME}-instance" \
    --db-instance-class db.serverless \
    --engine aurora-postgresql \
    --db-cluster-identifier $CLUSTER_NAME \
    --publicly-accessible

aws rds wait db-instance-available --db-instance-identifier "${CLUSTER_NAME}-instance"

# Get endpoint
AURORA_ENDPOINT=$(aws rds describe-db-clusters \
    --db-cluster-identifier $CLUSTER_NAME \
    --query 'DBClusters[0].Endpoint' \
    --output text)

echo "✓ Aurora created: $AURORA_ENDPOINT"

# Step 2: Create both databases in single Aurora cluster
echo "Step 2: Creating databases..."
PGPASSWORD="$TARGET_PASSWORD" psql -h "$AURORA_ENDPOINT" -U postgres -d postgres << EOF
CREATE DATABASE ordering_prod;
CREATE DATABASE restaurant_prod;
\l
EOF

echo "✓ Both databases created in shared Aurora cluster"

# Step 3: Migrate data (if existing databases)
echo "Step 3: Migrating data..."
if [ -f .env ]; then
    source .env

    # Migrate ordering DB
    echo "Migrating ordering database..."
    PGPASSWORD="${DB_PASSWORD}" pg_dump \
        -h "${DB_HOST_SERVER}" \
        -U "${DB_USER}" \
        -d "${DB_NAME}" \
        --no-owner --no-acl \
        | PGPASSWORD="$TARGET_PASSWORD" psql \
            -h "$AURORA_ENDPOINT" \
            -U postgres \
            -d ordering_prod

    # Migrate restaurant DB
    echo "Migrating restaurant database..."
    PGPASSWORD="${RESTAURANT_DB_PASSWORD}" pg_dump \
        -h "${RESTAURANT_DB_HOST_SERVER}" \
        -U "${RESTAURANT_DB_USER}" \
        -d "${RESTAURANT_DB_NAME}" \
        --no-owner --no-acl \
        | PGPASSWORD="$TARGET_PASSWORD" psql \
            -h "$AURORA_ENDPOINT" \
            -U postgres \
            -d restaurant_prod

    echo "✓ Data migration complete"
fi

# Step 4: Create minimal ECS infrastructure
echo "Step 4: Setting up ECS..."

# Create ECS cluster
aws ecs create-cluster \
    --cluster-name $CLUSTER_NAME \
    --capacity-providers FARGATE \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1

# Create log group
aws logs create-log-group \
    --log-group-name /ecs/ordering-minimal \
    2>/dev/null || echo "Log group exists"

aws logs put-retention-policy \
    --log-group-name /ecs/ordering-minimal \
    --retention-in-days 3

echo "✓ ECS cluster created"

# Step 5: Create ALB
echo "Step 5: Creating Application Load Balancer..."

# Create ALB security group
ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name ordering-alb-minimal-sg \
    --description "ALB security group - minimal cost" \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=ordering-alb-minimal-sg" \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

# Allow HTTP/HTTPS
aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SG_ID \
    --ip-permissions \
        IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=0.0.0.0/0}]' \
        IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0}]' \
    2>/dev/null || echo "ALB security group rules exist"

# Create ALB
PUBLIC_SUBNET_ARRAY=($(echo $PUBLIC_SUBNETS | tr ' ' '\n' | head -2))
ALB_ARN=$(aws elbv2 create-load-balancer \
    --name ordering-minimal-alb \
    --subnets ${PUBLIC_SUBNET_ARRAY[@]} \
    --security-groups $ALB_SG_ID \
    --scheme internet-facing \
    --type application \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null || \
    aws elbv2 describe-load-balancers \
        --names ordering-minimal-alb \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text)

# Create target group
TG_ARN=$(aws elbv2 create-target-group \
    --name ordering-minimal-tg \
    --protocol HTTP \
    --port 8000 \
    --vpc-id $VPC_ID \
    --target-type ip \
    --health-check-path /health/ \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null || \
    aws elbv2 describe-target-groups \
        --names ordering-minimal-tg \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)

# Create listener
aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN \
    2>/dev/null || echo "Listener exists"

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

echo "✓ ALB created: $ALB_DNS"

# Step 6: Store secrets
echo "Step 6: Storing secrets..."
aws secretsmanager create-secret \
    --name ordering/prod-minimal/database \
    --secret-string "{
        \"username\": \"postgres\",
        \"password\": \"$TARGET_PASSWORD\",
        \"host\": \"$AURORA_ENDPOINT\",
        \"port\": 5432,
        \"dbname_ordering\": \"ordering_prod\",
        \"dbname_restaurant\": \"restaurant_prod\"
    }" \
    2>/dev/null || \
    aws secretsmanager update-secret \
        --secret-id ordering/prod-minimal/database \
        --secret-string "{
            \"username\": \"postgres\",
            \"password\": \"$TARGET_PASSWORD\",
            \"host\": \"$AURORA_ENDPOINT\",
            \"port\": 5432,
            \"dbname_ordering\": \"ordering_prod\",
            \"dbname_restaurant\": \"restaurant_prod\"
        }"

# Generate Django secret key
DJANGO_SECRET=$(python3 -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())')
aws secretsmanager create-secret \
    --name ordering/prod-minimal/django-secret \
    --secret-string "$DJANGO_SECRET" \
    2>/dev/null || \
    aws secretsmanager update-secret \
        --secret-id ordering/prod-minimal/django-secret \
        --secret-string "$DJANGO_SECRET"

echo "✓ Secrets stored"

# Final output
echo ""
echo "======================================"
echo "✓ Setup Complete!"
echo "======================================"
echo ""
echo "Aurora Endpoint: $AURORA_ENDPOINT"
echo "Databases: ordering_prod, restaurant_prod"
echo "ALB DNS: $ALB_DNS"
echo ""
echo "Monthly Cost Estimate: \$68-100"
echo "  - Aurora: \$43 (0.5-1 ACU)"
echo "  - ECS: \$7 (1 minimal task)"
echo "  - ALB: \$16"
echo "  - Logs: \$0.50"
echo "  - Data: \$2"
echo ""
echo "Next Steps:"
echo "1. Build and push Docker image"
echo "2. Create ECS task definition"
echo "3. Deploy ECS service"
echo ""
echo "Run: ./scripts/deployment/deploy-minimal-app.sh"
echo ""
