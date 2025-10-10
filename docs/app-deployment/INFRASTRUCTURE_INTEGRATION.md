# Infrastructure Integration Reference

How the DeliveryKick infrastructure provides services to your applications.

## Overview

The infrastructure repository creates AWS resources that your application repositories consume. This document explains how they integrate.

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────┐
│  Infrastructure Repo (deliverykick-infrastructure)            │
│  Terraform manages:                                           │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ VPC, Subnets, Security Groups                          │  │
│  │ Aurora Cluster with 2 databases                        │  │
│  │ Secrets Manager with credentials                       │  │
│  │ ECS Cluster with task definitions                      │  │
│  │ Application Load Balancer                              │  │
│  │ ECR Repositories for Docker images                     │  │
│  └────────────────────────────────────────────────────────┘  │
└────────────────┬───────────────────────────────┬─────────────┘
                 │                               │
    ┌────────────┴────────────┐     ┌────────────┴─────────────┐
    │ Ordering App Repo       │     │ Restaurant App Repo      │
    │ - Django code           │     │ - Django code            │
    │ - Dockerfile            │     │ - Dockerfile             │
    │ - GitHub Actions        │     │ - GitHub Actions         │
    │ Reads from infra:       │     │ Reads from infra:        │
    │ • ECR URL               │     │ • ECR URL                │
    │ • ECS cluster name      │     │ • ECS cluster name       │
    │ • ALB target group      │     │ • ALB target group       │
    │ • Secrets from AWS      │     │ • Secrets from AWS       │
    └─────────────────────────┘     └──────────────────────────┘
```

## How Environment Variables Are Injected

### The Flow

```
1. Setup Script creates secrets in AWS Secrets Manager
   ↓
2. Terraform references those secrets in ECS task definitions
   ↓
3. ECS task starts and injects secrets as environment variables
   ↓
4. Your Django app reads from os.getenv()
   ↓
5. App connects to database automatically
```

### Example: Ordering App

**In Infrastructure (Terraform):**
```hcl
# terraform/environments/prod/main.tf
module "ecs" {
  applications = {
    ordering = {
      secret_arns = {
        DB_HOST     = "${module.secrets.ordering_app_secret_arn}:host::"
        DB_PORT     = "${module.secrets.ordering_app_secret_arn}:port::"
        DB_NAME     = "${module.secrets.ordering_app_secret_arn}:dbname::"
        DB_USER     = "${module.secrets.ordering_app_secret_arn}:username::"
        DB_PASSWORD = "${module.secrets.ordering_app_secret_arn}:password::"

        RESTAURANT_DB_HOST     = "${module.secrets.restaurant_readonly_secret_arn}:host::"
        RESTAURANT_DB_PORT     = "${module.secrets.restaurant_readonly_secret_arn}:port::"
        RESTAURANT_DB_NAME     = "${module.secrets.restaurant_readonly_secret_arn}:dbname::"
        RESTAURANT_DB_USER     = "${module.secrets.restaurant_readonly_secret_arn}:username::"
        RESTAURANT_DB_PASSWORD = "${module.secrets.restaurant_readonly_secret_arn}:password::"
      }
    }
  }
}
```

**In Your App (Django):**
```python
# Just read from environment
DATABASES = {
    'default': {
        'HOST': os.getenv('DB_HOST'),
        'PORT': os.getenv('DB_PORT'),
        'NAME': os.getenv('DB_NAME'),
        'USER': os.getenv('DB_USER'),
        'PASSWORD': os.getenv('DB_PASSWORD'),
    }
}
```

**You never manually set these values!** ECS injects them automatically.

## Database User Permissions

### Security Model (4 Users Per Database)

**Each database has:**

1. **Master User** (`postgres`)
   - Emergency use only
   - Full database superuser
   - **Never use in applications**

2. **Admin User** (`dk_ordering_admin` / `dk_restaurant_admin`)
   - For running migrations
   - Can CREATE/ALTER/DROP tables
   - Connection limit: 5
   - Use when: `python manage.py migrate`

3. **Application User** (`dk_ordering_app` / `dk_restaurant_app`) ⭐ **MAIN USER**
   - For Django runtime
   - Can SELECT/INSERT/UPDATE/DELETE
   - **Cannot drop tables** (safety!)
   - Connection limit: 50
   - Use when: Running the application

4. **Read-Only User** (`dk_ordering_readonly` / `dk_restaurant_readonly`)
   - For analytics/BI tools
   - Can only SELECT
   - Connection limit: 20

### Which User Does What?

| Operation | User to Use | Secret Name |
|-----------|------------|-------------|
| Run migrations | Admin | `deliverykick/prod/ordering/admin` |
| Django runtime | App | `deliverykick/prod/ordering/app` |
| Read restaurant data (from ordering app) | Readonly | `deliverykick/prod/restaurant/readonly` |
| Analytics queries | Readonly | `deliverykick/prod/*/readonly` |

### ECS Task Configuration

**Ordering App Task:**
- Uses `dk_ordering_app` for primary database
- Uses `dk_restaurant_readonly` for restaurant database (read-only)

**Restaurant App Task:**
- Uses `dk_restaurant_app` for restaurant database

**Migration Jobs:**
- Use admin credentials (`dk_*_admin`)
- Run via `./scripts/deployment/run-migrations.sh`

## Secrets Manager Structure

### Secret Format

Each secret in Secrets Manager is JSON:

```json
{
  "username": "dk_ordering_app",
  "password": "secure-random-password",
  "host": "deliverykick-prod-cluster.cluster-xxx.us-east-1.rds.amazonaws.com",
  "port": 5432,
  "dbname": "deliverykick_ordering_prod"
}
```

### Secret Names

```
deliverykick/prod/master                    # Emergency only
deliverykick/prod/ordering/admin            # Migrations
deliverykick/prod/ordering/app              # Runtime
deliverykick/prod/ordering/readonly         # Analytics
deliverykick/prod/restaurant/admin          # Migrations
deliverykick/prod/restaurant/app            # Runtime
deliverykick/prod/restaurant/readonly       # Analytics
```

### How Terraform References Secrets

**Syntax:**
```
${secret_arn}:json-key::
```

**Example:**
```hcl
DB_HOST = "${module.secrets.ordering_app_secret_arn}:host::"
```

This tells ECS to:
1. Fetch the secret at that ARN
2. Parse it as JSON
3. Extract the `host` key
4. Set it as `DB_HOST` environment variable

## ECS Task Definition Structure

### What Terraform Creates

```json
{
  "family": "deliverykick-prod-ordering",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::xxx:role/deliverykick-prod-ecs-task-execution",
  "taskRoleArn": "arn:aws:iam::xxx:role/deliverykick-prod-ordering-task",
  "containerDefinitions": [
    {
      "name": "ordering",
      "image": "123456.dkr.ecr.us-east-1.amazonaws.com/deliverykick-ordering:latest",
      "portMappings": [{"containerPort": 8000}],

      "environment": [
        {"name": "ENVIRONMENT", "value": "production"},
        {"name": "DJANGO_SETTINGS_MODULE", "value": "core.settings.production"}
      ],

      "secrets": [
        {"name": "DB_HOST", "valueFrom": "arn:aws:secretsmanager:...:host::"},
        {"name": "DB_PASSWORD", "valueFrom": "arn:aws:secretsmanager:...:password::"}
      ],

      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/deliverykick-prod/ordering",
          "awslogs-region": "us-east-1"
        }
      },

      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8000/health/ || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3
      }
    }
  ]
}
```

### IAM Roles

**Task Execution Role:**
- Used by ECS agent to start task
- Permissions:
  - Pull images from ECR
  - Write logs to CloudWatch
  - Read secrets from Secrets Manager

**Task Role:**
- Used by your application
- Permissions:
  - Read secrets (for runtime)
  - Any AWS services your app needs (S3, SQS, etc.)

## Application Load Balancer Routing

### How Traffic Flows

```
User Request
    ↓
Internet → ALB (port 80/443)
    ↓
Path-based routing:
    ├─ /                      → Ordering App (default)
    ├─ /api/*                 → Ordering App
    ├─ /admin/                → Ordering App
    └─ /restaurant/*          → Restaurant App

ALB → Target Group → ECS Tasks (private subnet)
```

### Health Checks

**ALB checks each target:**
- Path: `/health/` (ordering) or `/restaurant/health/` (restaurant)
- Interval: 30 seconds
- Healthy threshold: 2 consecutive successes
- Unhealthy threshold: 3 consecutive failures

**If health check fails:**
- Task marked unhealthy
- No traffic sent to that task
- ECS starts replacement task
- Circuit breaker triggers rollback if deployment failing

## Deployment Process

### Manual Deployment

```bash
# 1. Build Docker image locally
docker build -t ordering .

# 2. Tag with ECR repository
docker tag ordering:latest 123456.dkr.ecr.us-east-1.amazonaws.com/deliverykick-ordering:latest

# 3. Push to ECR
docker push 123456.dkr.ecr.us-east-1.amazonaws.com/deliverykick-ordering:latest

# 4. Update ECS service (force new deployment)
aws ecs update-service \
  --cluster deliverykick-prod-cluster \
  --service deliverykick-prod-ordering \
  --force-new-deployment

# 5. ECS pulls new image and deploys
# - Starts new tasks
# - Waits for health checks to pass
# - Drains old tasks
# - Completes deployment
```

### Automated Deployment (GitHub Actions)

```bash
# Developer pushes code
git push origin main

# GitHub Actions:
# 1. Runs tests
# 2. Builds Docker image
# 3. Tags with commit SHA
# 4. Pushes to ECR
# 5. Updates task definition
# 6. Updates ECS service
# 7. Waits for stable deployment
# 8. Runs migrations (prod only)
```

## Logging

### CloudWatch Log Groups

**Created by Terraform:**
```
/ecs/deliverykick-prod/ordering
/ecs/deliverykick-prod/restaurant
/aws/rds/cluster/deliverykick-prod-cluster/postgresql
```

### Viewing Logs

```bash
# Real-time logs
aws logs tail /ecs/deliverykick-prod/ordering --follow

# Last hour
aws logs tail /ecs/deliverykick-prod/ordering --since 1h

# Filter for errors
aws logs tail /ecs/deliverykick-prod/ordering --filter-pattern ERROR
```

### Log Retention

- Dev: 3 days
- Prod: 30 days

## Monitoring

### CloudWatch Metrics

**ECS Metrics:**
- CPUUtilization
- MemoryUtilization
- RunningTaskCount
- DesiredTaskCount

**Aurora Metrics:**
- DatabaseConnections
- ServerlessDatabaseCapacity (ACU)
- CPUUtilization
- FreeableMemory

**ALB Metrics:**
- HealthyHostCount
- UnHealthyHostCount
- TargetResponseTime
- HTTPCode_Target_5XX_Count

### Alarms

**Production environment has alarms for:**
- High CPU (>80%)
- High memory (>80%)
- Unhealthy targets (<1)
- High response time (>1s)
- 5XX errors (>10 in 5 min)

## Troubleshooting Integration Issues

### App Can't Connect to Database

**Check security groups:**
```bash
# ECS security group should allow outbound to Aurora port 5432
# Aurora security group should allow inbound from ECS security group

aws ec2 describe-security-groups \
  --group-ids sg-xxx \
  --query 'SecurityGroups[0].IpPermissions'
```

**Check secrets:**
```bash
aws secretsmanager get-secret-value \
  --secret-id deliverykick/prod/ordering/app \
  --query SecretString --output text | jq .
```

### App Not Receiving Environment Variables

**Check task definition:**
```bash
aws ecs describe-task-definition \
  --task-definition deliverykick-prod-ordering \
  --query 'taskDefinition.containerDefinitions[0].secrets'
```

**Check task role has permission:**
```bash
aws iam get-role-policy \
  --role-name deliverykick-prod-ecs-task-execution \
  --policy-name SecretsAccess
```

### Tasks Keep Restarting

**Check CloudWatch logs:**
```bash
aws logs tail /ecs/deliverykick-prod/ordering --since 10m
```

**Common causes:**
1. Health check failing (no `/health/` endpoint)
2. Database connection error (wrong credentials)
3. Missing environment variable
4. Application crash on startup
5. Port 8000 not listening

### Deployment Stuck

**Check service events:**
```bash
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering \
  --query 'services[0].events[0:10]'
```

**Common issues:**
1. New tasks failing health checks
2. Not enough capacity (scale up)
3. Image pull error (check ECR permissions)
4. Task definition error

## Best Practices

### Do's
✅ Use environment variables for configuration
✅ Use health check endpoints
✅ Use application user (not admin) for runtime
✅ Log to stdout/stderr (goes to CloudWatch)
✅ Test locally with `.env` file first
✅ Use database routers for multi-database apps
✅ Run migrations with admin user

### Don'ts
❌ Don't hardcode credentials
❌ Don't use master database user
❌ Don't commit `.env` files
❌ Don't run migrations with app user
❌ Don't use Django's `DEBUG=True` in production
❌ Don't write to local filesystem (containers are ephemeral)

## Summary

**Infrastructure provides:**
- Aurora databases with proper users
- Secrets Manager with all credentials
- ECS cluster ready to run containers
- ALB routing traffic
- CloudWatch logging and monitoring

**Your app consumes:**
- Environment variables (auto-injected)
- Database connections (credentials provided)
- HTTP traffic (via ALB)
- Logging (stdout goes to CloudWatch)

**You don't manage:**
- Database credentials (Secrets Manager)
- SSL certificates (optional, handled by ALB)
- Scaling policies (Terraform configures)
- Security groups (Terraform manages)

**You do manage:**
- Application code
- Django migrations
- Business logic
- API endpoints

---

**The infrastructure is the foundation. Your app is the building. They integrate seamlessly through environment variables and AWS services.**
