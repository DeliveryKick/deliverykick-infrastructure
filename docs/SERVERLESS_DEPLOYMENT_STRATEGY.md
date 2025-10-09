# Serverless Production Deployment Strategy
## Cost-Effective Aurora + ECS Fargate with Environment Isolation

**Goal:** Deploy to production serverless infrastructure while keeping development separate and costs low

---

## 🎯 Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    PRODUCTION ENVIRONMENT                    │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  CloudFront CDN                                             │
│       │                                                      │
│       ↓                                                      │
│  Application Load Balancer (ALB)                            │
│       │                                                      │
│       ↓                                                      │
│  ECS Fargate (Auto-scale 1-4 tasks)                         │
│       │                                                      │
│       ├──→ Aurora Serverless v2 (Production DB)             │
│       ├──→ ElastiCache Redis (cache.t3.micro)               │
│       └──→ Elasticsearch (Existing)                         │
│                                                              │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                   DEVELOPMENT ENVIRONMENT                    │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Current EC2 Instance (Keep running)                        │
│       │                                                      │
│       ├──→ Existing RDS (ordering database)                 │
│       ├──→ Existing RDS (restaurant database)               │
│       └──→ Elasticsearch (Shared or separate)               │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 💰 Cost-Optimized Configuration

### Monthly Cost Breakdown

| Service | Configuration | Monthly Cost |
|---------|--------------|--------------|
| **Aurora Serverless v2** | 0.5-2 ACU (auto-scaling) | $43-172 |
| **ECS Fargate** | 1-4 tasks (0.5 vCPU, 1GB RAM) | $15-60 |
| **ElastiCache Redis** | cache.t3.micro (0.5GB) | $12 |
| **Application Load Balancer** | Shared ALB | $16 |
| **CloudFront** | 500GB transfer | $42 |
| **NAT Gateway** | 2 AZs (optional) | $65 |
| **Secrets Manager** | 3-5 secrets | $1.20 |
| **CloudWatch Logs** | 10GB retention | $5 |
| **Data Transfer** | Estimate | $20 |
| **TOTAL (Low traffic)** | | **$219/month** |
| **TOTAL (Medium traffic)** | | **$393/month** |

### Cost-Saving Strategies

1. **Aurora Serverless v2**: Scales to zero-like pricing (0.5 ACU minimum = $43/month)
2. **Fargate Spot**: Use Spot capacity for 70% savings on non-critical tasks
3. **Single NAT Gateway**: Use 1 NAT instead of 2 for dev/staging ($32 savings)
4. **CloudFront**: Aggressive caching reduces origin requests
5. **Auto-scaling**: Scale down to 1 task during off-hours

---

## 📋 Step-by-Step Migration Plan

### Phase 1: Database Migration (Week 1)

#### Step 1.1: Create Aurora Serverless v2 Cluster

```bash
# Create the Aurora Serverless v2 cluster
aws rds create-db-cluster \
  --db-cluster-identifier ordering-prod-cluster \
  --engine aurora-postgresql \
  --engine-version 15.4 \
  --master-username postgres \
  --master-user-password 'YOUR_SECURE_PASSWORD' \
  --database-name ordering_prod \
  --vpc-security-group-ids sg-YOUR_SECURITY_GROUP \
  --db-subnet-group-name your-db-subnet-group \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=2 \
  --backup-retention-period 7 \
  --preferred-backup-window "03:00-04:00" \
  --preferred-maintenance-window "mon:04:00-mon:05:00" \
  --enable-http-endpoint \
  --tags Key=Environment,Value=production Key=Project,Value=ordering-backend

# Create the primary instance
aws rds create-db-instance \
  --db-instance-identifier ordering-prod-instance-1 \
  --db-instance-class db.serverless \
  --engine aurora-postgresql \
  --db-cluster-identifier ordering-prod-cluster
```

#### Step 1.2: Data Migration Script

Create `/home/ec2-user/Ordering-Delivery-and-Payment-Backend/scripts/deployment/migrate-to-aurora.sh`:

```bash
#!/bin/bash
set -e

# Configuration
SOURCE_HOST="ordering.csng0mkyc8zv.us-east-1.rds.amazonaws.com"
SOURCE_DB="ordering"
SOURCE_USER="postgres"
TARGET_HOST="ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com"
TARGET_DB="ordering_prod"
TARGET_USER="postgres"

echo "=== Starting Database Migration to Aurora Serverless ==="

# 1. Dump source database
echo "Step 1: Dumping source database..."
PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
  -h "$SOURCE_HOST" \
  -U "$SOURCE_USER" \
  -d "$SOURCE_DB" \
  --no-owner \
  --no-acl \
  --format=custom \
  -f /tmp/ordering_backup.dump

echo "Backup size: $(du -sh /tmp/ordering_backup.dump | cut -f1)"

# 2. Restore to Aurora
echo "Step 2: Restoring to Aurora Serverless..."
PGPASSWORD="$TARGET_PASSWORD" pg_restore \
  -h "$TARGET_HOST" \
  -U "$TARGET_USER" \
  -d "$TARGET_DB" \
  --no-owner \
  --no-acl \
  -j 4 \
  /tmp/ordering_backup.dump

# 3. Verify migration
echo "Step 3: Verifying data migration..."
SOURCE_COUNT=$(PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -U "$SOURCE_USER" -d "$SOURCE_DB" -t -c "SELECT COUNT(*) FROM orders_order;")
TARGET_COUNT=$(PGPASSWORD="$TARGET_PASSWORD" psql -h "$TARGET_HOST" -U "$TARGET_USER" -d "$TARGET_DB" -t -c "SELECT COUNT(*) FROM orders_order;")

echo "Source orders count: $SOURCE_COUNT"
echo "Target orders count: $TARGET_COUNT"

if [ "$SOURCE_COUNT" -eq "$TARGET_COUNT" ]; then
  echo "✓ Migration verified successfully!"
else
  echo "✗ Warning: Record counts don't match!"
  exit 1
fi

# 4. Update sequences
echo "Step 4: Updating sequences..."
PGPASSWORD="$TARGET_PASSWORD" psql -h "$TARGET_HOST" -U "$TARGET_USER" -d "$TARGET_DB" << 'EOF'
DO $$
DECLARE
  seq_record RECORD;
BEGIN
  FOR seq_record IN
    SELECT sequence_name FROM information_schema.sequences
  LOOP
    EXECUTE 'SELECT setval(''' || seq_record.sequence_name || ''', ' ||
            '(SELECT COALESCE(MAX(id), 1) FROM ' ||
            replace(seq_record.sequence_name, '_id_seq', '') || '))';
  END LOOP;
END $$;
EOF

echo "=== Migration Complete! ==="
rm /tmp/ordering_backup.dump
```

#### Step 1.3: Create Secrets in AWS Secrets Manager

```bash
# Store Aurora credentials
aws secretsmanager create-secret \
  --name ordering/prod/database \
  --description "Aurora database credentials for ordering production" \
  --secret-string '{
    "username": "postgres",
    "password": "YOUR_SECURE_PASSWORD",
    "engine": "postgres",
    "host": "ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com",
    "port": 5432,
    "dbname": "ordering_prod"
  }'

# Store Django secret key
aws secretsmanager create-secret \
  --name ordering/prod/django-secret-key \
  --secret-string "$(python -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())')"

# Store AWS credentials
aws secretsmanager create-secret \
  --name ordering/prod/aws-credentials \
  --secret-string '{
    "access_key_id": "YOUR_ACCESS_KEY",
    "secret_access_key": "YOUR_SECRET_KEY"
  }'
```

---

### Phase 2: Docker & ECR Setup (Week 1)

#### Step 2.1: Create Production Dockerfile

Create `/home/ec2-user/Ordering-Delivery-and-Payment-Backend/Dockerfile.prod`:

```dockerfile
FROM python:3.9-slim

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install system dependencies
RUN apt-get update && apt-get install -y \
    postgresql-client \
    libpq-dev \
    gcc \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt gunicorn

# Copy application code
COPY . .

# Collect static files
RUN python manage.py collectstatic --noinput

# Create non-root user
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD curl -f http://localhost:8000/health/ || exit 1

# Expose port
EXPOSE 8000

# Run Gunicorn
CMD ["gunicorn", "core.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "2", \
     "--threads", "4", \
     "--worker-class", "gthread", \
     "--timeout", "120", \
     "--access-logfile", "-", \
     "--error-logfile", "-"]
```

#### Step 2.2: Create ECR Repository and Push Image

```bash
# Create ECR repository
aws ecr create-repository \
  --repository-name ordering-backend/web \
  --image-scanning-configuration scanOnPush=true \
  --tags Key=Environment,Value=production

# Build and push image
cd /home/ec2-user/Ordering-Delivery-and-Payment-Backend

# Get ECR login
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin 609064513827.dkr.ecr.us-east-1.amazonaws.com

# Build image
docker build -f Dockerfile.prod -t ordering-backend:latest .

# Tag image
docker tag ordering-backend:latest \
  609064513827.dkr.ecr.us-east-1.amazonaws.com/ordering-backend/web:latest

# Push image
docker push 609064513827.dkr.ecr.us-east-1.amazonaws.com/ordering-backend/web:latest
```

---

### Phase 3: ECS Fargate Setup (Week 2)

#### Step 3.1: Create ECS Task Definition

Create `/home/ec2-user/Ordering-Delivery-and-Payment-Backend/infrastructure/ecs-task-definition.json`:

```json
{
  "family": "ordering-backend-prod",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::609064513827:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::609064513827:role/ecsTaskRole",
  "containerDefinitions": [
    {
      "name": "web",
      "image": "609064513827.dkr.ecr.us-east-1.amazonaws.com/ordering-backend/web:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {"name": "DJANGO_SETTINGS_MODULE", "value": "core.settings.production"},
        {"name": "DEBUG", "value": "False"},
        {"name": "AWS_REGION", "value": "us-east-1"},
        {"name": "ENVIRONMENT", "value": "production"}
      ],
      "secrets": [
        {
          "name": "SECRET_KEY",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:609064513827:secret:ordering/prod/django-secret-key"
        },
        {
          "name": "DB_HOST",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:609064513827:secret:ordering/prod/database:host::"
        },
        {
          "name": "DB_NAME",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:609064513827:secret:ordering/prod/database:dbname::"
        },
        {
          "name": "DB_USER",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:609064513827:secret:ordering/prod/database:username::"
        },
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:609064513827:secret:ordering/prod/database:password::"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/ordering-backend-prod",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8000/health/ || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
```

#### Step 3.2: Create Deployment Script

Create `/home/ec2-user/Ordering-Delivery-and-Payment-Backend/scripts/deployment/deploy-to-prod.sh`:

```bash
#!/bin/bash
set -e

CLUSTER_NAME="ordering-prod-cluster"
SERVICE_NAME="ordering-backend-service"
TASK_FAMILY="ordering-backend-prod"
REGION="us-east-1"
ECR_REPO="609064513827.dkr.ecr.us-east-1.amazonaws.com/ordering-backend/web"

echo "=== Production Deployment Script ==="

# Step 1: Build and push Docker image
echo "Step 1: Building Docker image..."
docker build -f Dockerfile.prod -t ordering-backend:latest .

echo "Step 2: Logging into ECR..."
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin 609064513827.dkr.ecr.$REGION.amazonaws.com

echo "Step 3: Tagging image..."
GIT_HASH=$(git rev-parse --short HEAD)
docker tag ordering-backend:latest $ECR_REPO:latest
docker tag ordering-backend:latest $ECR_REPO:$GIT_HASH

echo "Step 4: Pushing to ECR..."
docker push $ECR_REPO:latest
docker push $ECR_REPO:$GIT_HASH

# Step 2: Register new task definition
echo "Step 5: Registering new task definition..."
TASK_DEFINITION=$(aws ecs register-task-definition \
  --cli-input-json file://infrastructure/ecs-task-definition.json \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

echo "New task definition: $TASK_DEFINITION"

# Step 3: Update ECS service
echo "Step 6: Updating ECS service..."
aws ecs update-service \
  --cluster $CLUSTER_NAME \
  --service $SERVICE_NAME \
  --task-definition $TASK_DEFINITION \
  --force-new-deployment \
  --region $REGION

# Step 4: Wait for deployment
echo "Step 7: Waiting for deployment to complete..."
aws ecs wait services-stable \
  --cluster $CLUSTER_NAME \
  --services $SERVICE_NAME \
  --region $REGION

echo "=== Deployment Complete! ==="
echo "Service URL: https://your-cloudfront-domain.cloudfront.net"
```

---

### Phase 4: Infrastructure as Code (Week 2)

#### Step 4.1: Create CloudFormation Template

Create `/home/ec2-user/Ordering-Delivery-and-Payment-Backend/infrastructure/cloudformation-stack.yaml`:

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: 'Ordering Backend Production Infrastructure'

Parameters:
  Environment:
    Type: String
    Default: production
    AllowedValues: [development, staging, production]

  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC ID for deployment

  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: Private subnet IDs for ECS tasks

  PublicSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: Public subnet IDs for ALB

Resources:
  # ECS Cluster
  ECSCluster:
    Type: AWS::ECS::Cluster
    Properties:
      ClusterName: !Sub '${Environment}-ordering-cluster'
      CapacityProviders:
        - FARGATE
        - FARGATE_SPOT
      DefaultCapacityProviderStrategy:
        - CapacityProvider: FARGATE
          Weight: 1
          Base: 1
        - CapacityProvider: FARGATE_SPOT
          Weight: 4

  # Application Load Balancer
  ALB:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${Environment}-ordering-alb'
      Type: application
      Scheme: internet-facing
      Subnets: !Ref PublicSubnetIds
      SecurityGroups:
        - !Ref ALBSecurityGroup

  ALBSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: ALB Security Group
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: 0.0.0.0/0
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0

  # Target Group
  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub '${Environment}-ordering-tg'
      Port: 8000
      Protocol: HTTP
      VpcId: !Ref VpcId
      TargetType: ip
      HealthCheckPath: /health/
      HealthCheckIntervalSeconds: 30
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 3

  # ALB Listener
  ALBListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref ALB
      Port: 80
      Protocol: HTTP
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroup

  # ECS Service
  ECSService:
    Type: AWS::ECS::Service
    DependsOn: ALBListener
    Properties:
      ServiceName: !Sub '${Environment}-ordering-service'
      Cluster: !Ref ECSCluster
      TaskDefinition: !Ref ECSTaskDefinition
      DesiredCount: 1
      LaunchType: FARGATE
      NetworkConfiguration:
        AwsvpcConfiguration:
          AssignPublicIp: DISABLED
          Subnets: !Ref PrivateSubnetIds
          SecurityGroups:
            - !Ref ECSSecurityGroup
      LoadBalancers:
        - ContainerName: web
          ContainerPort: 8000
          TargetGroupArn: !Ref TargetGroup

  ECSSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: ECS Tasks Security Group
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 8000
          ToPort: 8000
          SourceSecurityGroupId: !Ref ALBSecurityGroup

  # CloudWatch Log Group
  LogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub '/ecs/${Environment}-ordering-backend'
      RetentionInDays: 30

  # Auto Scaling
  AutoScalingTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      MaxCapacity: 4
      MinCapacity: 1
      ResourceId: !Sub 'service/${ECSCluster}/${ECSService.Name}'
      RoleARN: !Sub 'arn:aws:iam::${AWS::AccountId}:role/aws-service-role/ecs.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_ECSService'
      ScalableDimension: ecs:service:DesiredCount
      ServiceNamespace: ecs

  AutoScalingPolicy:
    Type: AWS::ApplicationAutoScaling::ScalingPolicy
    Properties:
      PolicyName: !Sub '${Environment}-ordering-scaling-policy'
      PolicyType: TargetTrackingScaling
      ScalingTargetId: !Ref AutoScalingTarget
      TargetTrackingScalingPolicyConfiguration:
        PredefinedMetricSpecification:
          PredefinedMetricType: ECSServiceAverageCPUUtilization
        TargetValue: 70.0
        ScaleInCooldown: 300
        ScaleOutCooldown: 60

Outputs:
  ALBDNSName:
    Description: ALB DNS Name
    Value: !GetAtt ALB.DNSName
    Export:
      Name: !Sub '${Environment}-ordering-alb-dns'

  ECSClusterName:
    Description: ECS Cluster Name
    Value: !Ref ECSCluster
    Export:
      Name: !Sub '${Environment}-ordering-cluster-name'
```

---

### Phase 5: Environment Separation Strategy

#### Development Environment (.env.development)
```bash
# Keep using existing RDS instances
DB_HOST_SERVER=ordering.csng0mkyc8zv.us-east-1.rds.amazonaws.com
DB_NAME=ordering
RESTAURANT_DB_HOST_SERVER=restaurant-repo.csng0mkyc8zv.us-east-1.rds.amazonaws.com
ENVIRONMENT=development
DEBUG=True
```

#### Production Environment (.env.production)
```bash
# Use Aurora Serverless
DB_HOST_SERVER=ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com
DB_NAME=ordering_prod
RESTAURANT_DB_HOST_SERVER=ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com
ENVIRONMENT=production
DEBUG=False
ALLOWED_HOSTS=.cloudfront.net,.elb.amazonaws.com
```

#### Create Settings Override

Create `/home/ec2-user/Ordering-Delivery-and-Payment-Backend/core/settings/production.py`:

```python
from .base import *
import os

DEBUG = False
ALLOWED_HOSTS = os.getenv('ALLOWED_HOSTS', '').split(',')

# Use Aurora Serverless
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('DB_NAME'),
        'USER': os.getenv('DB_USER'),
        'PASSWORD': os.getenv('DB_PASSWORD'),
        'HOST': os.getenv('DB_HOST'),
        'PORT': '5432',
        'OPTIONS': {
            'connect_timeout': 10,
        },
        'CONN_MAX_AGE': 600,
    }
}

# Security settings
SECURE_SSL_REDIRECT = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_BROWSER_XSS_FILTER = True
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = 'DENY'

# Static files (CloudFront)
AWS_S3_CUSTOM_DOMAIN = os.getenv('CLOUDFRONT_DOMAIN')
STATIC_URL = f'https://{AWS_S3_CUSTOM_DOMAIN}/static/'
```

---

## 🚀 Quick Deployment Guide

### One-Time Setup (Do Once)

```bash
cd /home/ec2-user/Ordering-Delivery-and-Payment-Backend

# 1. Create Aurora cluster
aws rds create-db-cluster \
  --db-cluster-identifier ordering-prod-cluster \
  --engine aurora-postgresql \
  --engine-version 15.4 \
  --master-username postgres \
  --master-user-password 'CHANGE_ME' \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=2

# 2. Migrate data
./scripts/deployment/migrate-to-aurora.sh

# 3. Deploy infrastructure
aws cloudformation create-stack \
  --stack-name ordering-prod-infrastructure \
  --template-body file://infrastructure/cloudformation-stack.yaml \
  --parameters file://infrastructure/prod-parameters.json \
  --capabilities CAPABILITY_IAM
```

### Regular Deployments

```bash
# Deploy new version
./scripts/deployment/deploy-to-prod.sh

# Rollback if needed
aws ecs update-service \
  --cluster ordering-prod-cluster \
  --service ordering-backend-service \
  --task-definition ordering-backend-prod:PREVIOUS_VERSION
```

---

## 📊 Monitoring & Observability

### CloudWatch Dashboard

Create a dashboard to monitor:
- ECS task count
- CPU/Memory utilization
- Aurora ACU usage
- ALB request count
- Error rates

### Alerts

Set up CloudWatch alarms for:
- High CPU (>80%)
- High memory (>85%)
- 5xx errors (>10/min)
- Aurora scaling events
- Task failures

---

## ✅ Checklist

### Pre-Deployment
- [ ] Aurora cluster created and accessible
- [ ] Secrets stored in Secrets Manager
- [ ] ECR repository created
- [ ] Docker image built and pushed
- [ ] CloudFormation stack deployed
- [ ] Data migrated to Aurora
- [ ] Environment variables configured

### Post-Deployment
- [ ] ECS service running healthy
- [ ] ALB health checks passing
- [ ] Database connections working
- [ ] CloudFront distribution active
- [ ] Auto-scaling tested
- [ ] Monitoring dashboards created
- [ ] Development environment isolated

---

**Total Setup Time:** 1-2 weeks
**Monthly Cost:** $220-400 (depending on traffic)
**Development Impact:** Zero (separate environments)

