# Restaurant App - Deployment Setup Guide

**Copy this file to:** `restaurant-backend/DEPLOYMENT_SETUP.md`

This guide prepares your Restaurant service for deployment to AWS ECS with the DeliveryKick infrastructure.

## Overview

Your Restaurant app will:
- Connect to `deliverykick_restaurant_prod` database on Aurora
- Run as Docker containers in ECS Fargate
- Automatically receive database credentials from AWS Secrets Manager
- Auto-deploy via GitHub Actions when you push to `main`
- Manage restaurant catalog data (restaurants, menus, hours, etc.)

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
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('DB_NAME'),            # deliverykick_restaurant_prod
        'USER': os.getenv('DB_USER'),            # dk_restaurant_app
        'PASSWORD': os.getenv('DB_PASSWORD'),    # From Secrets Manager
        'HOST': os.getenv('DB_HOST'),            # Aurora endpoint
        'PORT': os.getenv('DB_PORT', '5432'),
        'CONN_MAX_AGE': 600,
        'OPTIONS': {
            'connect_timeout': 10,
            'sslmode': 'prefer',
        }
    }
}

# Security settings
ALLOWED_HOSTS = os.getenv('ALLOWED_HOSTS', '*').split(',')
DEBUG = os.getenv('DEBUG', 'False') == 'True'
SECRET_KEY = os.getenv('SECRET_KEY', 'change-me-in-production')

# Static files
STATIC_ROOT = '/app/staticfiles'
STATIC_URL = '/static/'

# CORS settings (for ordering app to access restaurant API)
CORS_ALLOWED_ORIGINS = [
    'http://localhost:8000',
    # Add your ordering app URL
]

# REST Framework settings
REST_FRAMEWORK = {
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticatedOrReadOnly',
    ],
    'DEFAULT_PAGINATION_CLASS': 'rest_framework.pagination.PageNumberPagination',
    'PAGE_SIZE': 50,
}
```

## Step 2: Environment Variables Reference

**These are automatically injected by ECS from Secrets Manager:**

| Environment Variable | Source | Example Value |
|---------------------|--------|---------------|
| `DB_HOST` | restaurant/app secret | `deliverykick-prod-cluster.cluster-xxx.us-east-1.rds.amazonaws.com` |
| `DB_PORT` | restaurant/app secret | `5432` |
| `DB_NAME` | restaurant/app secret | `deliverykick_restaurant_prod` |
| `DB_USER` | restaurant/app secret | `dk_restaurant_app` |
| `DB_PASSWORD` | restaurant/app secret | `[from secrets manager]` |

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
from django.db import connection
from django.db.utils import OperationalError

def health_check(request):
    """
    Health check endpoint for ALB.
    Checks database connectivity.
    """
    status = {
        'status': 'healthy',
        'service': 'restaurant-api'
    }

    # Check database connection
    try:
        connection.cursor()
        status['database'] = 'connected'
    except OperationalError:
        status['status'] = 'unhealthy'
        status['database'] = 'disconnected'

    status_code = 200 if status['status'] == 'healthy' else 503
    return JsonResponse(status, status=status_code)

urlpatterns = [
    path('health/', health_check),
    path('restaurant/', include('restaurants.urls')),  # Your restaurant API
    # ... other URLs
]
```

## Step 5: Set Up GitHub Actions

**File: `.github/workflows/deploy.yml`**

Copy the workflow from infrastructure repo:

```bash
# From infrastructure repo
cp ../deliverykick-infrastructure/docs/ci-cd/restaurant-app-github-actions.yml \
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

## Step 7: Models for Restaurant Data

**File: `restaurants/models.py`**

```python
from django.db import models

class Restaurant(models.Model):
    """Restaurant catalog - managed by this service"""
    name = models.CharField(max_length=255, db_index=True)
    slug = models.SlugField(unique=True)
    address = models.TextField()
    city = models.CharField(max_length=100)
    state = models.CharField(max_length=2)
    zip_code = models.CharField(max_length=10)
    phone = models.CharField(max_length=20)
    email = models.EmailField(blank=True)
    description = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'restaurants'
        ordering = ['name']
        indexes = [
            models.Index(fields=['city', 'state']),
            models.Index(fields=['is_active']),
        ]

    def __str__(self):
        return self.name


class MenuItem(models.Model):
    """Menu items for restaurants"""
    restaurant = models.ForeignKey(Restaurant, on_delete=models.CASCADE, related_name='menu_items')
    name = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    price = models.DecimalField(max_digits=10, decimal_places=2)
    category = models.CharField(max_length=100, db_index=True)
    is_available = models.BooleanField(default=True)
    image_url = models.URLField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'menu_items'
        ordering = ['category', 'name']
        indexes = [
            models.Index(fields=['restaurant', 'category']),
            models.Index(fields=['is_available']),
        ]

    def __str__(self):
        return f"{self.restaurant.name} - {self.name}"


class OperatingHours(models.Model):
    """Restaurant operating hours"""
    DAYS_OF_WEEK = [
        (0, 'Monday'),
        (1, 'Tuesday'),
        (2, 'Wednesday'),
        (3, 'Thursday'),
        (4, 'Friday'),
        (5, 'Saturday'),
        (6, 'Sunday'),
    ]

    restaurant = models.ForeignKey(Restaurant, on_delete=models.CASCADE, related_name='operating_hours')
    day_of_week = models.IntegerField(choices=DAYS_OF_WEEK)
    open_time = models.TimeField()
    close_time = models.TimeField()
    is_closed = models.BooleanField(default=False)

    class Meta:
        db_table = 'operating_hours'
        unique_together = ['restaurant', 'day_of_week']
        ordering = ['restaurant', 'day_of_week']

    def __str__(self):
        return f"{self.restaurant.name} - {self.get_day_of_week_display()}"
```

## Step 8: Test Locally (Optional)

**Create `.env` file for local testing:**

```bash
# Local development
DB_HOST=localhost
DB_PORT=5432
DB_NAME=deliverykick_restaurant_local
DB_USER=postgres
DB_PASSWORD=postgres

DJANGO_SETTINGS_MODULE=core.settings.development
DEBUG=True
```

**Test the app:**

```bash
# Run migrations
python manage.py migrate

# Create superuser
python manage.py createsuperuser

# Run server
python manage.py runserver

# Test endpoints
curl http://localhost:8000/health/
curl http://localhost:8000/restaurant/api/v1/restaurants/
```

## Step 9: Deploy to AWS

### First Deployment (Manual)

```bash
# From infrastructure repo EC2 instance

# Set app directory
export APP_DIR=/path/to/restaurant-backend

# Deploy to production
cd ~/deliverykick-infrastructure
./scripts/deployment/deploy-restaurant-app.sh prod

# Wait for deployment (2-5 minutes)

# Run migrations
./scripts/deployment/run-migrations.sh prod restaurant

# Test
ALB_DNS=$(cd terraform/environments/prod && terraform output -raw alb_dns_name)
curl http://$ALB_DNS/restaurant/health/
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

## Step 10: Migrate Existing Data (One-Time)

**If you have existing restaurant data to migrate:**

```bash
# On old database server
pg_dump -h old-restaurant-db \
  -U restaurant_user \
  -d restaurant_service_db \
  --data-only \
  --table=restaurants \
  --table=menu_items \
  --table=operating_hours \
  > restaurant_data.sql

# Copy to infrastructure EC2 instance
scp restaurant_data.sql ec2-user@infrastructure-ec2:~/

# On infrastructure EC2
# Get Aurora endpoint
AURORA_ENDPOINT=$(cd ~/deliverykick-infrastructure/terraform/environments/prod && terraform output -raw aurora_cluster_endpoint)

# Get admin password from secrets
ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id deliverykick/prod/restaurant/admin \
  --query SecretString --output text | jq -r .password)

# Import data
psql -h $AURORA_ENDPOINT \
  -U dk_restaurant_admin \
  -d deliverykick_restaurant_prod \
  < ~/restaurant_data.sql
```

## Step 11: Verify Deployment

```bash
# Check ECS service
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-restaurant \
  --query 'services[0].[serviceName,status,runningCount,desiredCount]' \
  --output table

# Check logs
aws logs tail /ecs/deliverykick-prod/restaurant --follow

# Test health endpoint
curl http://$ALB_DNS/restaurant/health/

# Test API endpoints
curl http://$ALB_DNS/restaurant/api/v1/restaurants/
curl http://$ALB_DNS/restaurant/api/v1/menu-items/
```

## Troubleshooting

### Database Connection Errors

**Check secrets are configured:**
```bash
aws secretsmanager get-secret-value \
  --secret-id deliverykick/prod/restaurant/app \
  --query SecretString --output text | jq .
```

### Tasks Keep Restarting

**Check logs for errors:**
```bash
aws logs tail /ecs/deliverykick-prod/restaurant --since 10m
```

**Common issues:**
- Missing environment variables
- Database connection timeout
- Health check failing
- Port 8000 already in use (in Dockerfile)

### Migrations Not Running

**Run manually:**
```bash
cd ~/deliverykick-infrastructure
./scripts/deployment/run-migrations.sh prod restaurant
```

## API Endpoints

**Restaurant API endpoints (accessed via ALB):**

```
GET  http://$ALB_DNS/restaurant/health/
GET  http://$ALB_DNS/restaurant/api/v1/restaurants/
GET  http://$ALB_DNS/restaurant/api/v1/restaurants/{id}/
GET  http://$ALB_DNS/restaurant/api/v1/menu-items/
GET  http://$ALB_DNS/restaurant/api/v1/menu-items/?restaurant={id}
```

**Accessed by Ordering App:**

The ordering app will call these endpoints to fetch restaurant data for display to users.

## Next Steps

1. ✅ Configure database connection
2. ✅ Create Dockerfile
3. ✅ Add health check endpoint
4. ✅ Set up GitHub Actions
5. ✅ Deploy to ECS
6. ✅ Run migrations
7. ✅ Migrate existing data (one-time)
8. 🔜 Set up scraper service (future)
9. 🔜 Configure custom domain (optional)
10. 🔜 Set up SSL certificate (optional)

## Reference

- **Infrastructure Repo:** `deliverykick-infrastructure`
- **CI/CD Guide:** `deliverykick-infrastructure/docs/CI_CD_SETUP.md`
- **Quick Reference:** `deliverykick-infrastructure/QUICK_REFERENCE.md`

---

**Questions?** Check the infrastructure repo documentation or create an issue.
