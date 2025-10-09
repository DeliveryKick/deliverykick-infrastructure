# Multi-Repo Aurora Setup Guide
## Using One Aurora Cluster for Multiple Applications/Repositories

## 🎯 Overview

This guide explains how to set up a **single Aurora Serverless v2 cluster** that serves **multiple applications** across **different repositories**.

### What This Does

```
┌─────────────────────────────────────────┐
│   Aurora Cluster (ordering-prod-cluster) │
│                                          │
│   ┌──────────────┐  ┌──────────────┐  │
│   │ ordering_prod│  │  app2_prod   │  │
│   │ (Repo 1)     │  │  (Repo 2)    │  │
│   └──────────────┘  └──────────────┘  │
└─────────────────────────────────────────┘
         │                    │
         ▼                    ▼
    ┌─────────┐          ┌─────────┐
    │ Repo 1  │          │ Repo 2  │
    │ (This)  │          │ (Other) │
    └─────────┘          └─────────┘
```

## 🚀 Quick Start

### One-Time Setup: Create Shared Cluster

```bash
# In Repo 1 (this repo)
cd /home/ec2-user/Ordering-Delivery-and-Payment-Backend

# Set environment variables (or add to .env)
export AURORA_MASTER_PASSWORD="YourSecurePassword123!"
export AURORA_CLUSTER_ID="ordering-prod-cluster"
export AWS_REGION="us-east-1"

# Create the shared Aurora cluster
./scripts/deployment/setup-shared-aurora.sh
```

**This script will:**
- ✅ Create Aurora Serverless v2 cluster (or use existing)
- ✅ Configure VPC, subnets, and security groups
- ✅ Store master credentials in AWS Secrets Manager
- ✅ Create shared configuration files in `~/.aurora-shared/`
- ✅ Generate a helper script to add applications

**Output:**
- Cluster endpoint (e.g., `ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com`)
- Shared config: `~/.aurora-shared/cluster-config.sh`
- Add app script: `~/.aurora-shared/setup-scripts/add-application.sh`

---

## 📦 Per-Application Setup

### For Repo 1 (This Repository)

```bash
# Add this application to the cluster
~/.aurora-shared/setup-scripts/add-application.sh ordering YourAppPassword123

# This creates:
# - Database: ordering_prod
# - User: ordering_user
# - Config file: ~/.aurora-shared/apps/ordering.env
```

**Copy the generated config to your repo:**
```bash
cp ~/.aurora-shared/apps/ordering.env .env.aurora

# Merge with your existing .env or source it
cat .env.aurora >> .env
```

**Update your `core/settings/database.py`:**
```python
# Use Aurora endpoints from environment
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('DB_NAME', 'ordering_prod'),
        'USER': os.getenv('DB_USER', 'ordering_user'),
        'PASSWORD': os.getenv('DB_PASSWORD'),
        'HOST': os.getenv('DB_HOST_SERVER'),  # Aurora endpoint
        'PORT': os.getenv('DB_PORT', '5432'),
        'OPTIONS': {
            'sslmode': 'require',
            'connect_timeout': 10,
        },
        'CONN_MAX_AGE': 600,
    },
    'restaurant_db': {
        # Similar configuration...
    }
}
```

**Run migrations:**
```bash
python manage.py migrate
python manage.py migrate --database=restaurant_db
```

---

### For Repo 2 (Other Repository)

**Option 1: Use the shared script (Recommended)**

```bash
# In Repo 2, get the shared script
# Copy from Repo 1 or regenerate
scp user@repo1-server:~/.aurora-shared/setup-scripts/add-application.sh .

# Or load the cluster config
source ~/.aurora-shared/cluster-config.sh

# Add App 2
~/.aurora-shared/setup-scripts/add-application.sh app2 App2SecurePassword456

# Copy generated config
cp ~/.aurora-shared/apps/app2.env .env
```

**Option 2: Manual setup with connection details**

Share these details from Repo 1 to Repo 2 team:

```bash
# Get cluster endpoint
aws rds describe-db-clusters \
    --db-cluster-identifier ordering-prod-cluster \
    --query 'DBClusters[0].Endpoint' \
    --output text

# Share this information:
# - Cluster endpoint: ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com
# - Region: us-east-1
# - Master credentials secret: ordering-prod-cluster/master
```

Then in Repo 2, create a `.env.aurora` file:

```bash
# Create configuration in Repo 2
cat > .env.aurora << EOF
DB_HOST_SERVER=<aurora-endpoint-from-repo1>
DB_PORT=5432
DB_NAME=app2_prod
DB_USER=app2_user
DB_PASSWORD=<app2-password>
AWS_REGION=us-east-1
EOF
```

Manually create the database:

```bash
# Get master password
MASTER_PASS=$(aws secretsmanager get-secret-value \
    --secret-id ordering-prod-cluster/master \
    --query 'SecretString' --output text | jq -r '.password')

# Connect and create
psql -h <aurora-endpoint> -U postgres -d postgres << EOF
CREATE DATABASE app2_prod;
CREATE USER app2_user WITH PASSWORD '<app2-password>';
GRANT ALL PRIVILEGES ON DATABASE app2_prod TO app2_user;
ALTER USER app2_user CONNECTION LIMIT 50;

\c app2_prod
GRANT ALL ON SCHEMA public TO app2_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO app2_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO app2_user;
EOF
```

---

## 📋 Step-by-Step Workflow

### Initial Setup (Do Once)

1. **In Repo 1**, run the cluster setup:
   ```bash
   ./scripts/deployment/setup-shared-aurora.sh
   ```

2. **Save the output**, especially:
   - Aurora endpoint
   - AWS region
   - Secrets Manager name

### For Each Application/Repo

1. **Run the add-application script**:
   ```bash
   ~/.aurora-shared/setup-scripts/add-application.sh <app_name> <password>
   ```

2. **Copy the generated .env file**:
   ```bash
   cp ~/.aurora-shared/apps/<app_name>.env /path/to/repo/.env
   ```

3. **Update database settings** in your application

4. **Run migrations**:
   ```bash
   python manage.py migrate
   ```

5. **Test connection**:
   ```bash
   python manage.py dbshell
   ```

---

## 🔐 Security & Isolation

### Per-Application Isolation

Each application gets:
- ✅ Dedicated database (`app1_prod`, `app2_prod`)
- ✅ Dedicated user (`app1_user`, `app2_user`)
- ✅ Connection limit (50 per user)
- ✅ Separate credentials in Secrets Manager
- ✅ No access to other apps' data

### Access Control

```sql
-- App 1 can only access ordering_prod
-- App 2 can only access app2_prod

-- Verify isolation:
\c ordering_prod
SELECT current_database(), current_user;
-- Cannot access app2_prod without proper credentials
```

### Network Security

- Security group restricts access to VPC CIDR (10.0.0.0/8)
- SSL/TLS required for all connections
- Master credentials stored in AWS Secrets Manager
- Per-app credentials stored separately

---

## 📦 Sharing Between Repos

### Method 1: Copy Configuration Files

```bash
# From Repo 1, copy to Repo 2
scp ~/.aurora-shared/cluster-config.sh user@repo2-server:~/.aurora-shared/
scp ~/.aurora-shared/setup-scripts/add-application.sh user@repo2-server:~/.aurora-shared/setup-scripts/
```

### Method 2: Share Cluster Details

Create a shared document with:

```yaml
Aurora Cluster:
  Cluster ID: ordering-prod-cluster
  Region: us-east-1
  Writer Endpoint: ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com
  Reader Endpoint: ordering-prod-cluster.cluster-ro-xxxxx.us-east-1.rds.amazonaws.com
  Port: 5432
  Master Secret: ordering-prod-cluster/master

To Add New Application:
  1. Get master credentials from Secrets Manager
  2. Run setup script or manually create database/user
  3. Store app credentials in Secrets Manager: ordering-prod-cluster/<app_name>
```

### Method 3: Git Repository (Not Recommended for Production)

```bash
# Create a shared config repo (for non-sensitive data only)
git init aurora-config
cd aurora-config

# Add only non-sensitive files
cp ~/.aurora-shared/cluster-config.sh .
cp ~/.aurora-shared/setup-scripts/add-application.sh setup-scripts/

# DO NOT commit passwords or .env files
echo "*.env" >> .gitignore
echo "*password*" >> .gitignore

git add .
git commit -m "Shared Aurora cluster configuration"
```

---

## 🧪 Testing & Verification

### Test Cluster Access

```bash
# Source the shared config
source ~/.aurora-shared/cluster-config.sh

# Test connection
test_aurora_connection

# Or manually
MASTER_PASS=$(get_aurora_master_password)
psql -h $AURORA_ENDPOINT -U $AURORA_MASTER_USER -d postgres -c "SELECT version();"
```

### Verify Per-App Setup

```bash
# App 1
psql -h <aurora-endpoint> -U ordering_user -d ordering_prod -c "\dt"

# App 2
psql -h <aurora-endpoint> -U app2_user -d app2_prod -c "\dt"
```

### Check Connections

```sql
-- Connect as master user
psql -h <aurora-endpoint> -U postgres -d postgres

-- View all connections
SELECT
    datname,
    usename,
    application_name,
    client_addr,
    state,
    COUNT(*) as connection_count
FROM pg_stat_activity
WHERE datname IN ('ordering_prod', 'app2_prod')
GROUP BY datname, usename, application_name, client_addr, state
ORDER BY datname, connection_count DESC;
```

---

## 🔧 Common Operations

### Add a New Application

```bash
~/.aurora-shared/setup-scripts/add-application.sh myapp MySecurePass789
```

### Get Application Credentials

```bash
# From Secrets Manager
aws secretsmanager get-secret-value \
    --secret-id ordering-prod-cluster/ordering \
    --query 'SecretString' --output text | jq

# From local config file
cat ~/.aurora-shared/apps/ordering.env
```

### Update Application Password

```sql
-- As master user
ALTER USER ordering_user WITH PASSWORD 'NewSecurePassword';
```

```bash
# Update in Secrets Manager
aws secretsmanager update-secret \
    --secret-id ordering-prod-cluster/ordering \
    --secret-string '{"username":"ordering_user","password":"NewSecurePassword",...}'
```

### Scale Aurora Cluster

```bash
# Increase capacity for both apps
aws rds modify-db-cluster \
    --db-cluster-identifier ordering-prod-cluster \
    --serverless-v2-scaling-configuration MinCapacity=1,MaxCapacity=4 \
    --apply-immediately
```

### Monitor All Applications

```bash
# CloudWatch metrics
aws cloudwatch get-metric-statistics \
    --namespace AWS/RDS \
    --metric-name DatabaseConnections \
    --dimensions Name=DBClusterIdentifier,Value=ordering-prod-cluster \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Sum
```

---

## 💡 Example: Complete Setup for 2 Repos

### Step 1: Create Cluster (Run Once)

```bash
# In Repo 1
export AURORA_MASTER_PASSWORD="MasterPass123!"
./scripts/deployment/setup-shared-aurora.sh

# Save the endpoint from output
# ordering-prod-cluster.cluster-abc123.us-east-1.rds.amazonaws.com
```

### Step 2: Setup Repo 1

```bash
# Still in Repo 1
~/.aurora-shared/setup-scripts/add-application.sh ordering OrderingPass456

# Copy config
cp ~/.aurora-shared/apps/ordering.env .env

# Update database.py to use Aurora
# Run migrations
python manage.py migrate
```

### Step 3: Setup Repo 2

```bash
# In Repo 2
# Copy the add-application script from Repo 1
# Or share the Aurora endpoint

# Add App 2
~/.aurora-shared/setup-scripts/add-application.sh app2 App2Pass789

# Copy config
cp ~/.aurora-shared/apps/app2.env .env

# Update database.py
# Run migrations
python manage.py migrate
```

### Step 4: Verify

```bash
# Check both databases exist
psql -h <aurora-endpoint> -U postgres -d postgres -c "\l" | grep prod

# Check connections
psql -h <aurora-endpoint> -U postgres -d postgres -c "SELECT datname, usename, COUNT(*) FROM pg_stat_activity GROUP BY datname, usename;"
```

---

## 📊 Cost Sharing

With a shared cluster:

| Scenario | Shared Cost | Per-App Cost |
|----------|-------------|--------------|
| **Idle** | $43/month | $21.50 each |
| **Low usage** | $86/month | $43 each |
| **Medium usage** | $172/month | $86 each |
| **High usage** | $344/month | $172 each |

**Savings**: ~50% compared to two separate clusters!

---

## ⚠️ Important Notes

1. **Master credentials**: Only share with trusted DevOps team
2. **App credentials**: Each team gets only their app credentials
3. **Security groups**: Ensure both repos' servers can reach Aurora
4. **Connection limits**: Monitor to avoid exhausting the pool
5. **Backups**: Automatic backups cover ALL databases
6. **Monitoring**: Set up CloudWatch alarms for the cluster

---

## 🆘 Troubleshooting

### Can't connect from Repo 2

```bash
# Check security group
aws ec2 describe-security-groups \
    --group-ids <sg-id> \
    --query 'SecurityGroups[0].IpPermissions'

# Add Repo 2's CIDR or security group
aws ec2 authorize-security-group-ingress \
    --group-id <sg-id> \
    --protocol tcp \
    --port 5432 \
    --source-group <repo2-sg-id>
```

### Lost cluster endpoint

```bash
aws rds describe-db-clusters \
    --db-cluster-identifier ordering-prod-cluster \
    --query 'DBClusters[0].[Endpoint,ReaderEndpoint]' \
    --output text
```

### Forgot which databases exist

```sql
psql -h <aurora-endpoint> -U postgres -d postgres -c "\l"
```

---

## 📚 Related Documentation

- [Detailed Plan](./AURORA_SHARED_DATABASE_PLAN.md)
- [Quick Reference](./AURORA_QUICK_REFERENCE.md)
- [Deployment Guide](./DEPLOYMENT.md)

---

**Created**: 2025-10-09
**Version**: 1.0
**For Questions**: Contact DevOps team
