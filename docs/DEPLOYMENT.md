# Deployment Guide

## Overview
This document provides detailed instructions for deploying the Ordering, Delivery, and Payment Backend application across different environments.

## Prerequisites

### Required Tools
- Git
- Python 3.9+
- PostgreSQL 13+
- Redis (for caching)
- Docker & Docker Compose (for containerized deployment)
- AWS CLI (for AWS deployments)

### Environment Variables
Ensure the following environment variables are configured in your `.env` file:

```bash
# Django Settings
SECRET_KEY=<your-secret-key>
DEBUG=False
ALLOWED_HOSTS=<your-domain>

# Database
DB_NAME=<database-name>
DB_USER=<database-user>
DB_PASSWORD=<database-password>
DB_HOST=<database-host>
DB_PORT=5432

# Redis
REDIS_HOST=<redis-host>
REDIS_PORT=6379

# Elasticsearch
ELASTICSEARCH_HOST=<elasticsearch-host>
ELASTICSEARCH_PORT=9200

# Payment Gateway
STRIPE_SECRET_KEY=<stripe-secret>
STRIPE_PUBLIC_KEY=<stripe-public>

# AWS S3 (for media files)
AWS_ACCESS_KEY_ID=<aws-key>
AWS_SECRET_ACCESS_KEY=<aws-secret>
AWS_STORAGE_BUCKET_NAME=<bucket-name>
AWS_S3_REGION_NAME=<region>

# Email
EMAIL_HOST=<smtp-host>
EMAIL_PORT=587
EMAIL_HOST_USER=<email-user>
EMAIL_HOST_PASSWORD=<email-password>
```

## Deployment Methods

### 1. Standard Deployment (Production Server)

#### Step 1: Prepare the Server

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install Python and dependencies
sudo apt install python3.9 python3.9-venv python3-pip postgresql-client redis-tools -y

# Install Nginx
sudo apt install nginx -y

# Install Supervisor (for process management)
sudo apt install supervisor -y
```

#### Step 2: Clone and Setup Repository

```bash
# Clone repository
cd /var/www
sudo git clone <repository-url> ordering-backend
cd ordering-backend

# Checkout the main branch
git checkout main
git pull origin main

# Create virtual environment
python3.9 -m venv venv
source venv/bin/activate

# Install dependencies
pip install --upgrade pip
pip install -r requirements.txt
```

#### Step 3: Configure Application

```bash
# Copy environment file
cp .env.example .env
nano .env  # Edit with production values

# Run migrations
python manage.py migrate

# Collect static files
python manage.py collectstatic --noinput

# Create superuser (if needed)
python manage.py createsuperuser
```

#### Step 4: Configure Nginx

```nginx
# /etc/nginx/sites-available/ordering-backend
server {
    listen 80;
    server_name api.yourdomain.com;

    location /static/ {
        alias /var/www/ordering-backend/staticfiles/;
    }

    location /media/ {
        alias /var/www/ordering-backend/media/;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```bash
# Enable site
sudo ln -s /etc/nginx/sites-available/ordering-backend /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

#### Step 5: Configure Supervisor

```ini
# /etc/supervisor/conf.d/ordering-backend.conf
[program:ordering-backend]
command=/var/www/ordering-backend/venv/bin/gunicorn core.wsgi:application --bind 127.0.0.1:8000 --workers 4
directory=/var/www/ordering-backend
user=www-data
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/www/ordering-backend/logs/gunicorn.log
```

```bash
# Update supervisor
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start ordering-backend
```

#### Step 6: Setup SSL (Optional but Recommended)

```bash
# Install Certbot
sudo apt install certbot python3-certbot-nginx -y

# Obtain SSL certificate
sudo certbot --nginx -d api.yourdomain.com

# Auto-renewal is configured automatically
```

### 2. Docker Deployment

#### Using Docker Compose

```bash
# Navigate to project directory
cd /path/to/ordering-backend

# Build and start containers
docker-compose up -d --build

# Run migrations
docker-compose exec web python manage.py migrate

# Collect static files
docker-compose exec web python manage.py collectstatic --noinput

# Create superuser
docker-compose exec web python manage.py createsuperuser
```

#### Using Deployment Script

```bash
# Make script executable
chmod +x scripts/deployment/deploy-docker.sh

# Run deployment
./scripts/deployment/deploy-docker.sh production
```

### 3. AWS Deployment

#### Using Elastic Beanstalk

```bash
# Install EB CLI
pip install awsebcli

# Initialize EB application
eb init -p python-3.9 ordering-backend --region us-east-1

# Create environment
eb create production-env --database.engine postgres --database.username dbuser

# Deploy
eb deploy

# Open application
eb open
```

#### Using EC2 with Auto-Scaling

See AWS deployment scripts in `/aws` directory for detailed configuration.

## Deployment Automation

### CI/CD Pipeline (GitHub Actions Example)

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy to Production

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v2

    - name: Setup Python
      uses: actions/setup-python@v2
      with:
        python-version: 3.9

    - name: Install dependencies
      run: |
        pip install -r requirements.txt

    - name: Run tests
      run: |
        python manage.py test

    - name: Deploy to server
      uses: appleboy/ssh-action@master
      with:
        host: ${{ secrets.HOST }}
        username: ${{ secrets.USERNAME }}
        key: ${{ secrets.SSH_KEY }}
        script: |
          cd /var/www/ordering-backend
          git pull origin main
          source venv/bin/activate
          pip install -r requirements.txt
          python manage.py migrate
          python manage.py collectstatic --noinput
          sudo supervisorctl restart ordering-backend
```

## Environment-Specific Deployments

### Development Environment

```bash
# Checkout develop branch
git checkout develop
git pull origin develop

# Install dependencies
pip install -r requirements.txt

# Run migrations
python manage.py migrate

# Run development server
python manage.py runserver 0.0.0.0:8000
```

### Staging Environment

```bash
# Use staging deployment script
./scripts/deployment/deploy.sh staging

# Or manually:
git checkout staging
git pull origin staging
source venv/bin/activate
pip install -r requirements.txt
python manage.py migrate
python manage.py collectstatic --noinput
sudo supervisorctl restart ordering-backend-staging
```

### Production Environment

```bash
# Use production deployment script
./scripts/deployment/deploy.sh production

# Or manually (same as Standard Deployment above)
```

## Post-Deployment Checks

### Health Check Endpoints

```bash
# Check application health
curl https://api.yourdomain.com/health/

# Check database connection
curl https://api.yourdomain.com/health/db/

# Check Redis connection
curl https://api.yourdomain.com/health/cache/
```

### Verification Steps

1. **Database Migrations**
   ```bash
   python manage.py showmigrations
   ```

2. **Static Files**
   ```bash
   curl https://api.yourdomain.com/static/admin/css/base.css
   ```

3. **API Endpoints**
   ```bash
   curl https://api.yourdomain.com/api/v1/restaurants/
   ```

4. **Admin Panel**
   - Navigate to `https://api.yourdomain.com/admin/`
   - Login with superuser credentials

5. **Application Logs**
   ```bash
   tail -f logs/gunicorn.log
   tail -f logs/django.log
   ```

## Rollback Procedures

### Rollback to Previous Version

```bash
# Find previous stable tag
git tag -l | tail -5

# Checkout previous version
git checkout v1.2.3

# Run deployment
./scripts/deployment/deploy.sh production

# Or rollback specific commit
git revert <commit-hash>
git push origin main
```

### Database Rollback

```bash
# List migrations
python manage.py showmigrations

# Rollback to specific migration
python manage.py migrate app_name migration_name

# Example:
python manage.py migrate orders 0008_previous_migration
```

## Monitoring and Logging

### Application Logs

- **Gunicorn Logs**: `/var/www/ordering-backend/logs/gunicorn.log`
- **Django Logs**: `/var/www/ordering-backend/logs/django.log`
- **Nginx Logs**: `/var/log/nginx/access.log` and `/var/log/nginx/error.log`

### Monitoring Tools

- **System Monitoring**: Use tools like Datadog, New Relic, or Prometheus
- **Error Tracking**: Sentry integration configured in `core/settings/base.py`
- **Performance**: Django Debug Toolbar (development only)

### Log Rotation

```bash
# Configure logrotate
sudo nano /etc/logrotate.d/ordering-backend
```

```
/var/www/ordering-backend/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data www-data
    sharedscripts
    postrotate
        supervisorctl restart ordering-backend
    endscript
}
```

## Troubleshooting

### Common Issues

**Issue: Static files not loading**
```bash
# Solution:
python manage.py collectstatic --noinput --clear
sudo systemctl restart nginx
```

**Issue: Database connection errors**
```bash
# Check PostgreSQL status
sudo systemctl status postgresql

# Test connection
psql -h <host> -U <user> -d <database>
```

**Issue: Application won't start**
```bash
# Check supervisor logs
sudo supervisorctl tail ordering-backend

# Restart application
sudo supervisorctl restart ordering-backend
```

**Issue: 502 Bad Gateway**
```bash
# Check if Gunicorn is running
sudo supervisorctl status ordering-backend

# Check Nginx configuration
sudo nginx -t
```

## Security Checklist

- [ ] `DEBUG=False` in production
- [ ] `SECRET_KEY` is unique and secure
- [ ] `ALLOWED_HOSTS` is properly configured
- [ ] SSL certificate is installed and valid
- [ ] Database credentials are secure
- [ ] Firewall rules are configured
- [ ] Security headers are enabled
- [ ] CORS settings are properly configured
- [ ] Rate limiting is enabled
- [ ] Regular security updates are scheduled

## Maintenance Windows

Recommended maintenance schedule:
- **Minor updates**: Tuesday/Thursday 2-4 AM
- **Major updates**: Sunday 2-6 AM
- **Emergency patches**: As needed with notification

## Support and Escalation

For deployment issues:
1. Check this documentation
2. Review application logs
3. Contact DevOps team
4. Escalate to development team lead

## Additional Resources

- [Branching Strategy](./BRANCHING_STRATEGY.md)
- [AWS Deployment Guide](../aws/README.md)
- [API Documentation](../README.md)
- [Environment Configuration](./ENVIRONMENT.md)
