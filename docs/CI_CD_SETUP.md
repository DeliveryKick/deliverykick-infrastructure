# CI/CD Setup Guide for DeliveryKick

Complete guide to set up automated deployments for your applications.

## Overview

This guide covers:
1. Setting up GitHub Actions for automated deployments
2. Configuring AWS credentials
3. Manual deployment scripts
4. Database migration workflows

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Developer pushes code to GitHub                         │
└────────────────┬────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│  GitHub Actions Workflow Triggers                        │
│  1. Run tests                                            │
│  2. Build Docker image                                   │
│  3. Push to ECR                                          │
│  4. Update ECS service                                   │
│  5. Run migrations (optional)                            │
└────────────────┬────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│  ECS pulls new image and deploys                         │
│  - Blue/green deployment                                 │
│  - Health checks                                         │
│  - Automatic rollback if failed                          │
└─────────────────────────────────────────────────────────┘
```

## Part 1: GitHub Actions Setup

### Step 1: Create AWS IAM User for CI/CD

```bash
# Create IAM user
aws iam create-user --user-name github-actions-deployer

# Create access key
aws iam create-access-key --user-name github-actions-deployer

# Save the output - you'll need this for GitHub Secrets
# AccessKeyId: AKIA...
# SecretAccessKey: xxxxx...
```

### Step 2: Attach Permissions Policy

Create a policy file `github-actions-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:UpdateService",
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks",
        "ecs:ListTasks",
        "ecs:RegisterTaskDefinition",
        "ecs:ExecuteCommand"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": [
        "arn:aws:iam::*:role/deliverykick-*-ecs-task-execution",
        "arn:aws:iam::*:role/deliverykick-*-ordering-task",
        "arn:aws:iam::*:role/deliverykick-*-restaurant-task"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/ecs/*"
    }
  ]
}
```

Attach the policy:

```bash
aws iam put-user-policy \
  --user-name github-actions-deployer \
  --policy-name GitHubActionsDeployPolicy \
  --policy-document file://github-actions-policy.json
```

### Step 3: Configure GitHub Secrets

In each app repository, go to Settings > Secrets and variables > Actions

Add these secrets:

| Secret Name | Value | Description |
|-------------|-------|-------------|
| `AWS_ACCESS_KEY_ID` | AKIA... | From Step 1 |
| `AWS_SECRET_ACCESS_KEY` | xxxxx... | From Step 1 |
| `SLACK_WEBHOOK_URL` | https://hooks.slack.com/... | Optional: For notifications |

### Step 4: Add Workflow File to App Repositories

**For Ordering App:**

```bash
cd Ordering-Delivery-and-Payment-Backend
mkdir -p .github/workflows

# Copy the workflow file
cp ../deliverykick-infrastructure/docs/ci-cd/ordering-app-github-actions.yml \
   .github/workflows/deploy.yml

# Commit and push
git add .github/workflows/deploy.yml
git commit -m "Add CI/CD workflow"
git push
```

**For Restaurant App:**

```bash
cd restaurant-backend
mkdir -p .github/workflows

# Copy the workflow file
cp ../deliverykick-infrastructure/docs/ci-cd/restaurant-app-github-actions.yml \
   .github/workflows/deploy.yml

# Commit and push
git add .github/workflows/deploy.yml
git commit -m "Add CI/CD workflow"
git push
```

### Step 5: Enable ECS Exec for Migrations

Update your ECS services to enable exec:

```bash
# For ordering app
aws ecs update-service \
  --cluster deliverykick-prod-cluster \
  --service deliverykick-prod-ordering \
  --enable-execute-command

# For restaurant app
aws ecs update-service \
  --cluster deliverykick-prod-cluster \
  --service deliverykick-prod-restaurant \
  --enable-execute-command
```

## Part 2: Workflow Behavior

### Branch-Based Deployments

| Branch | Environment | Behavior |
|--------|-------------|----------|
| `main` | Production | Full deployment + migrations |
| `develop` | Development | Fast deployment, no migrations |
| Pull Requests | None | Tests only, no deployment |

### Workflow Stages

**1. Test Stage:**
- Install dependencies
- Run linting (flake8)
- Run unit tests
- Fails fast if tests fail

**2. Build Stage:**
- Build Docker image
- Tag with Git SHA
- Tag with `latest`
- Push to ECR

**3. Deploy Stage:**
- Download current task definition
- Update image in task definition
- Register new task definition
- Update ECS service
- Wait for service stability

**4. Migration Stage (prod only):**
- Find running task
- Execute `python manage.py migrate`
- Run only after successful deployment

**5. Notify Stage:**
- Send Slack notification
- Include deployment status
- Include commit info

## Part 3: Manual Deployment Scripts

For situations when you need to deploy manually without CI/CD.

### Deploy Ordering App

```bash
cd deliverykick-infrastructure

# Deploy to production
APP_DIR=/path/to/Ordering-Delivery-and-Payment-Backend \
  ./scripts/deployment/deploy-ordering-app.sh prod

# Deploy to development
APP_DIR=/path/to/Ordering-Delivery-and-Payment-Backend \
  ./scripts/deployment/deploy-ordering-app.sh dev

# Deploy specific version
APP_DIR=/path/to/Ordering-Delivery-and-Payment-Backend \
  ./scripts/deployment/deploy-ordering-app.sh prod v1.2.3
```

### Deploy Restaurant App

```bash
cd deliverykick-infrastructure

# Deploy to production
APP_DIR=/path/to/restaurant-backend \
  ./scripts/deployment/deploy-restaurant-app.sh prod

# Deploy to development
APP_DIR=/path/to/restaurant-backend \
  ./scripts/deployment/deploy-restaurant-app.sh dev
```

### Run Migrations

```bash
# Ordering app - production
./scripts/deployment/run-migrations.sh prod ordering

# Restaurant app - production
./scripts/deployment/run-migrations.sh prod restaurant

# Development environment
./scripts/deployment/run-migrations.sh dev ordering
```

## Part 4: Docker Configuration

### Dockerfile Requirements

Your app repositories need a `Dockerfile`. Example:

```dockerfile
FROM python:3.11-slim

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Set work directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    postgresql-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy project
COPY . .

# Collect static files
RUN python manage.py collectstatic --noinput

# Run gunicorn
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "3", "core.wsgi:application"]
```

### Health Check Endpoint

Your Django app needs a health check endpoint at `/health/`:

```python
# In your urls.py
from django.http import JsonResponse

def health_check(request):
    return JsonResponse({"status": "healthy"})

urlpatterns = [
    path('health/', health_check),
    # ... other paths
]
```

## Part 5: Monitoring Deployments

### View Deployment Progress

```bash
# Watch GitHub Actions
# Go to: https://github.com/<org>/<repo>/actions

# Watch ECS service
watch -n 5 "aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering \
  --query 'services[0].events[0:5]' \
  --output table"

# Watch logs in real-time
aws logs tail /ecs/deliverykick-prod/ordering --follow
```

### Check Deployment Status

```bash
# Get service status
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering \
  --query 'services[0].[serviceName,status,runningCount,desiredCount,deployments[0].status]' \
  --output table

# Get running tasks
aws ecs list-tasks \
  --cluster deliverykick-prod-cluster \
  --service-name deliverykick-prod-ordering \
  --desired-status RUNNING

# Get task details
aws ecs describe-tasks \
  --cluster deliverykick-prod-cluster \
  --tasks <task-arn>
```

## Part 6: Rollback Procedures

### Automatic Rollback

ECS has circuit breaker enabled, which automatically rolls back if:
- Health checks fail
- Tasks cannot start
- Deployment exceeds time limit

### Manual Rollback

**Option 1: Revert Git Commit**

```bash
# In your app repo
git revert HEAD
git push

# GitHub Actions will automatically deploy the reverted code
```

**Option 2: Deploy Previous Image**

```bash
# List available images
aws ecr describe-images \
  --repository-name deliverykick-ordering \
  --query 'sort_by(imageDetails,& imagePushedAt)[-5:]' \
  --output table

# Deploy specific image
APP_DIR=/path/to/app \
  ./scripts/deployment/deploy-ordering-app.sh prod <image-tag>
```

**Option 3: Use Previous Task Definition**

```bash
# List task definitions
aws ecs list-task-definitions \
  --family-prefix deliverykick-prod-ordering \
  --sort DESC \
  --max-items 5

# Update service to previous task definition
aws ecs update-service \
  --cluster deliverykick-prod-cluster \
  --service deliverykick-prod-ordering \
  --task-definition deliverykick-prod-ordering:PREVIOUS_REVISION
```

## Part 7: Troubleshooting

### Deployment Fails at Build Stage

**Issue:** Docker build fails

**Solutions:**
- Check Dockerfile syntax
- Ensure requirements.txt is up to date
- Check for missing files
- Review GitHub Actions logs

### Deployment Fails at Push Stage

**Issue:** Cannot push to ECR

**Solutions:**
```bash
# Verify repository exists
aws ecr describe-repositories --repository-names deliverykick-ordering

# Check IAM permissions
aws ecr get-authorization-token

# Verify AWS credentials in GitHub Secrets
```

### Deployment Fails at ECS Update Stage

**Issue:** ECS service update fails

**Solutions:**
```bash
# Check service status
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering

# Check task definition is valid
aws ecs describe-task-definition \
  --task-definition deliverykick-prod-ordering

# Check ECS events
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering \
  --query 'services[0].events[0:10]'
```

### Tasks Keep Restarting

**Issue:** ECS tasks start but immediately fail

**Solutions:**
```bash
# Check logs
aws logs tail /ecs/deliverykick-prod/ordering --follow

# Common causes:
# 1. Database connection errors (check secrets)
# 2. Missing environment variables
# 3. Health check failing
# 4. Application crashes on startup
```

### Migrations Fail

**Issue:** Migration job fails

**Solutions:**
```bash
# Check task is running
aws ecs list-tasks \
  --cluster deliverykick-prod-cluster \
  --service-name deliverykick-prod-ordering

# Run migrations manually
./scripts/deployment/run-migrations.sh prod ordering

# Check migration status
aws ecs execute-command \
  --cluster deliverykick-prod-cluster \
  --task <task-arn> \
  --container ordering \
  --interactive \
  --command "python manage.py showmigrations"
```

## Part 8: Best Practices

### Development Workflow

1. **Create feature branch**
   ```bash
   git checkout -b feature/new-feature
   ```

2. **Make changes and test locally**
   ```bash
   python manage.py test
   ```

3. **Push and create PR**
   ```bash
   git push origin feature/new-feature
   # Create PR on GitHub
   ```

4. **CI runs tests automatically**
   - Wait for tests to pass
   - Fix any issues

5. **Merge to develop**
   - Automatically deploys to dev environment
   - Test in dev environment

6. **Merge to main**
   - Automatically deploys to production
   - Migrations run automatically

### Database Migrations

**Best Practices:**
- Always test migrations in dev first
- Never edit old migrations
- Use `--noinput` in production
- Backup database before major migrations
- Review migration SQL before applying

**Safe Migration Pattern:**
```bash
# 1. Deploy code without migrations
git push origin main  # Let CI/CD deploy

# 2. Test in production (without DB changes)
curl https://api.deliverykick.com/health/

# 3. Run migrations manually
./scripts/deployment/run-migrations.sh prod ordering

# 4. Verify
curl https://api.deliverykick.com/health/
```

### Image Tagging Strategy

- `latest` - Current production version
- `<git-sha>` - Specific commit version
- `v1.2.3` - Semantic version tags

### Secret Management

- Never commit secrets to git
- Use AWS Secrets Manager
- Rotate credentials regularly
- Use different credentials per environment

## Part 9: Slack Notifications (Optional)

### Set Up Slack Webhook

1. Go to Slack App Directory
2. Search for "Incoming Webhooks"
3. Add to your workspace
4. Create webhook for channel
5. Copy webhook URL
6. Add to GitHub Secrets as `SLACK_WEBHOOK_URL`

### Customize Notifications

Edit the `notify` job in your workflow file to customize the message format.

## Summary

You now have:
- ✅ Automated CI/CD with GitHub Actions
- ✅ Manual deployment scripts as backup
- ✅ Database migration automation
- ✅ Monitoring and rollback procedures
- ✅ Best practices for safe deployments

### Quick Reference

```bash
# Deploy manually
./scripts/deployment/deploy-ordering-app.sh prod

# Run migrations
./scripts/deployment/run-migrations.sh prod ordering

# Watch logs
aws logs tail /ecs/deliverykick-prod/ordering --follow

# Rollback
git revert HEAD && git push
```

---

**Ready to deploy!** Push code to `main` branch and watch GitHub Actions deploy automatically.
