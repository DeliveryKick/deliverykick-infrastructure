# Ordering App - Deployment Setup Guide

**Copy this file to:** `Ordering-Delivery-and-Payment-Backend/DEPLOYMENT_SETUP.md`

This guide prepares your Ordering app for deployment to AWS ECS with the DeliveryKick infrastructure.

## Overview

Your Ordering app will:
- Connect to **TWO databases** on the same Aurora cluster:
  - `deliverykick_ordering_prod` - Your primary database (orders, payments, users)
  - `deliverykick_restaurant_prod` - Restaurant catalog (read-only)
- Run as Docker containers in ECS Fargate
- Automatically receive database credentials from AWS Secrets Manager
- Auto-deploy via GitHub Actions when you push to `main`

## Prerequisites Checklist

Before deploying, ensure:
- [ ] Infrastructure is deployed (Aurora, ECS, ALB created)
- [ ] You have the Terraform outputs from infrastructure repo
- [ ] GitHub repository has AWS credentials configured
- [ ] App has health check endpoint at `/health/`

## Step 1: Configure Database Settings

### Update Django Settings

**File: `core/settings/production.py` (or `settings.py`)**

```python
import os

# Database configuration - credentials injected by ECS from Secrets Manager
DATABASES = {
    # Primary database - orders, payments, deliveries, users
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('DB_NAME'),                    # deliverykick_ordering_prod
        'USER': os.getenv('DB_USER'),                    # dk_ordering_app
        'PASSWORD': os.getenv('DB_PASSWORD'),            # From Secrets Manager
        'HOST': os.getenv('DB_HOST'),                    # Aurora endpoint
        'PORT': os.getenv('DB_PORT', '5432'),
        'CONN_MAX_AGE': 600,
        'OPTIONS': {
            'connect_timeout': 10,
        }
    },

    # Restaurant database - read-only access to restaurant catalog
    'restaurants': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('RESTAURANT_DB_NAME'),         # deliverykick_restaurant_prod
        'USER': os.getenv('RESTAURANT_DB_USER'),         # dk_restaurant_readonly
        'PASSWORD': os.getenv('RESTAURANT_DB_PASSWORD'), # From Secrets Manager
        'HOST': os.getenv('RESTAURANT_DB_HOST'),         # Same Aurora endpoint
        'PORT': os.getenv('RESTAURANT_DB_PORT', '5432'),
        'CONN_MAX_AGE': 600,
    }
}

# Database router for restaurant models (if using unmanaged models)
DATABASE_ROUTERS = ['core.routers.RestaurantRouter']

# Security settings
ALLOWED_HOSTS = os.getenv('ALLOWED_HOSTS', '*').split(',')
DEBUG = os.getenv('DEBUG', 'False') == 'True'
SECRET_KEY = os.getenv('SECRET_KEY', 'change-me-in-production')

# Static files
STATIC_ROOT = '/app/staticfiles'
STATIC_URL = '/static/'
```

### Create Database Router (if using unmanaged models)

**File: `core/routers.py`**

```python
class RestaurantRouter:
    """
    Route restaurant-related models to the 'restaurants' database.
    All other models use 'default' database.
    """

    restaurant_app_labels = {'restaurants'}  # Add your restaurant app label here

    def db_for_read(self, model, **hints):
        """Route reads for restaurant models to 'restaurants' database"""
        if model._meta.app_label in self.restaurant_app_labels:
            return 'restaurants'
        return 'default'

    def db_for_write(self, model, **hints):
        """Route writes for restaurant models to 'restaurants' database"""
        if model._meta.app_label in self.restaurant_app_labels:
            return 'restaurants'
        return 'default'

    def allow_relation(self, obj1, obj2, **hints):
        """Allow relations between models in the same database"""
        db_set = {'default', 'restaurants'}
        if obj1._state.db in db_set and obj2._state.db in db_set:
            return True
        return None

    def allow_migrate(self, db, app_label, model_name=None, **hints):
        """Only run migrations for appropriate database"""
        if app_label in self.restaurant_app_labels:
            return db == 'restaurants'
        return db == 'default'
```

### Unmanaged Models for Restaurant Data

**File: `restaurants/models.py` (or your restaurant app)**

```python
from django.db import models

class Restaurant(models.Model):
    """
    Unmanaged model - points to restaurant database.
    Schema managed by restaurant service.
    """
    id = models.AutoField(primary_key=True)
    name = models.CharField(max_length=255)
    address = models.TextField()
    phone = models.CharField(max_length=20)
    # ... other fields matching restaurant DB schema

    class Meta:
        managed = False  # Don't run migrations on this table
        db_table = 'restaurants'
        app_label = 'restaurants'  # Must match router config

class MenuItem(models.Model):
    restaurant = models.ForeignKey(Restaurant, on_delete=models.CASCADE)
    name = models.CharField(max_length=255)
    price = models.DecimalField(max_digits=10, decimal_places=2)
    # ... other fields

    class Meta:
        managed = False
        db_table = 'menu_items'
        app_label = 'restaurants'
```

## Step 2: Environment Variables Reference

**These are automatically injected by ECS from Secrets Manager:**

| Environment Variable | Source | Example Value |
|---------------------|--------|---------------|
| `DB_HOST` | ordering/app secret | `deliverykick-prod-cluster.cluster-xxx.us-east-1.rds.amazonaws.com` |
| `DB_PORT` | ordering/app secret | `5432` |
| `DB_NAME` | ordering/app secret | `deliverykick_ordering_prod` |
| `DB_USER` | ordering/app secret | `dk_ordering_app` |
| `DB_PASSWORD` | ordering/app secret | `[from secrets manager]` |
| `RESTAURANT_DB_HOST` | restaurant/readonly secret | `[same as DB_HOST]` |
| `RESTAURANT_DB_PORT` | restaurant/readonly secret | `5432` |
| `RESTAURANT_DB_NAME` | restaurant/readonly secret | `deliverykick_restaurant_prod` |
| `RESTAURANT_DB_USER` | restaurant/readonly secret | `dk_restaurant_readonly` |
| `RESTAURANT_DB_PASSWORD` | restaurant/readonly secret | `[from secrets manager]` |

**Additional variables set by Terraform:**

| Variable | Value |
|----------|-------|
| `ENVIRONMENT` | `production` or `development` |
| `DJANGO_SETTINGS_MODULE` | `core.settings.production` |
| `ALLOWED_HOSTS` | `*.deliverykick.com,deliverykick.com` |

## Step 3: Create Dockerfile

**File: `Dockerfile`**

```dockerfile
FROM python:3.11-slim

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install system dependencies
RUN apt-get update && apt-get install -y \
    gcc \
    postgresql-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Set work directory
WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy project
COPY . .

# Collect static files
RUN python manage.py collectstatic --noinput --settings=core.settings.production

# Create non-root user
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8000/health/ || exit 1

# Run gunicorn
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "3", "--timeout", "60", "core.wsgi:application"]
```

## Step 4: Create Health Check Endpoint

**File: `core/urls.py`**

```python
from django.http import JsonResponse
from django.db import connections
from django.db.utils import OperationalError

def health_check(request):
    """
    Health check endpoint for ALB.
    Checks database connectivity.
    """
    status = {
        'status': 'healthy',
        'databases': {}
    }

    # Check default database
    try:
        connections['default'].cursor()
        status['databases']['default'] = 'connected'
    except OperationalError:
        status['status'] = 'unhealthy'
        status['databases']['default'] = 'disconnected'

    # Check restaurant database
    try:
        connections['restaurants'].cursor()
        status['databases']['restaurants'] = 'connected'
    except OperationalError:
        status['status'] = 'unhealthy'
        status['databases']['restaurants'] = 'disconnected'

    status_code = 200 if status['status'] == 'healthy' else 503
    return JsonResponse(status, status=status_code)

urlpatterns = [
    path('health/', health_check),
    # ... your other URLs
]
```

## Step 5: Set Up GitHub Actions

**File: `.github/workflows/deploy.yml`**

Copy the workflow from infrastructure repo:

```bash
# From infrastructure repo
cp ../deliverykick-infrastructure/docs/ci-cd/ordering-app-github-actions.yml \
   .github/workflows/deploy.yml
```

**Configure GitHub Secrets:**

1. Go to your repo: Settings > Secrets and variables > Actions
2. Add these secrets:

| Secret Name | Value | How to Get |
|-------------|-------|------------|
| `AWS_ACCESS_KEY_ID` | `AKIA...` | From IAM user created in infrastructure setup |
| `AWS_SECRET_ACCESS_KEY` | `xxxxx...` | From same IAM user |
| `SLACK_WEBHOOK_URL` | `https://hooks.slack.com/...` | Optional: For notifications |

## Step 6: Update requirements.txt

**Ensure these are included:**

```txt
Django>=4.2,<5.0
djangorestframework>=3.14
psycopg2-binary>=2.9
gunicorn>=21.0
django-cors-headers>=4.0
python-decouple>=3.8
# ... your other dependencies
```

## Step 7: Test Locally (Optional)

**Create `.env` file for local testing:**

```bash
# Local development
DB_HOST=localhost
DB_PORT=5432
DB_NAME=deliverykick_ordering_local
DB_USER=postgres
DB_PASSWORD=postgres

RESTAURANT_DB_HOST=localhost
RESTAURANT_DB_PORT=5432
RESTAURANT_DB_NAME=deliverykick_restaurant_local
RESTAURANT_DB_USER=postgres
RESTAURANT_DB_PASSWORD=postgres

DJANGO_SETTINGS_MODULE=core.settings.development
DEBUG=True
```

**Test the app:**

```bash
python manage.py migrate
python manage.py runserver

# In another terminal
curl http://localhost:8000/health/
```

## Step 8: Deploy to AWS

### First Deployment (Manual)

```bash
# From infrastructure repo EC2 instance

# Set app directory
export APP_DIR=/path/to/Ordering-Delivery-and-Payment-Backend

# Deploy to production
cd ~/deliverykick-infrastructure
./scripts/deployment/deploy-ordering-app.sh prod

# Wait for deployment (2-5 minutes)

# Run migrations
./scripts/deployment/run-migrations.sh prod ordering

# Test
ALB_DNS=$(cd terraform/environments/prod && terraform output -raw alb_dns_name)
curl http://$ALB_DNS/health/
```

### Automated Deployments (After GitHub Actions setup)

```bash
# Just push to main branch
git add .
git commit -m "Configure for ECS deployment"
git push origin main

# GitHub Actions will:
# 1. Run tests
# 2. Build Docker image
# 3. Push to ECR
# 4. Deploy to ECS
# 5. Run migrations
```

## Step 9: Verify Deployment

```bash
# Check ECS service
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering \
  --query 'services[0].[serviceName,status,runningCount,desiredCount]' \
  --output table

# Check logs
aws logs tail /ecs/deliverykick-prod/ordering --follow

# Test health endpoint
curl http://$ALB_DNS/health/

# Test API endpoints
curl http://$ALB_DNS/api/v1/restaurants/
curl http://$ALB_DNS/api/v1/orders/
```

## Troubleshooting

### Database Connection Errors

**Check secrets are configured:**
```bash
aws secretsmanager get-secret-value \
  --secret-id deliverykick/prod/ordering/app \
  --query SecretString --output text | jq .
```

**Check ECS task has correct environment variables:**
```bash
aws ecs describe-task-definition \
  --task-definition deliverykick-prod-ordering \
  --query 'taskDefinition.containerDefinitions[0].secrets' \
  --output table
```

### Tasks Keep Restarting

**Check logs for errors:**
```bash
aws logs tail /ecs/deliverykick-prod/ordering --since 10m
```

**Common issues:**
- Missing environment variables
- Database connection timeout (check security groups)
- Health check failing
- Application crashes on startup

### Migrations Not Running

**Run manually:**
```bash
cd ~/deliverykick-infrastructure
./scripts/deployment/run-migrations.sh prod ordering
```

**Check migration status:**
```bash
# Get task ARN
TASK_ARN=$(aws ecs list-tasks --cluster deliverykick-prod-cluster --service-name deliverykick-prod-ordering --query 'taskArns[0]' --output text)

# Connect to container
aws ecs execute-command \
  --cluster deliverykick-prod-cluster \
  --task $TASK_ARN \
  --container ordering \
  --interactive \
  --command "python manage.py showmigrations"
```

## Next Steps

1. ✅ Configure dual database connections
2. ✅ Create Dockerfile
3. ✅ Add health check endpoint
4. ✅ Set up GitHub Actions
5. ✅ Deploy to ECS
6. ✅ Run migrations
7. 🔜 Configure custom domain (optional)
8. 🔜 Set up SSL certificate (optional)
9. 🔜 Configure monitoring and alerts

## Reference

- **Infrastructure Repo:** `deliverykick-infrastructure`
- **CI/CD Guide:** `deliverykick-infrastructure/docs/CI_CD_SETUP.md`
- **Quick Reference:** `deliverykick-infrastructure/QUICK_REFERENCE.md`

---

**Questions?** Check the infrastructure repo documentation or create an issue.
