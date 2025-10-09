# Aurora Multi-Repo Setup Workflow
## Visual Guide for Setting Up Shared Aurora Cluster

## 🎬 Complete Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│                    PHASE 1: CLUSTER CREATION                     │
│                         (Run Once)                               │
└─────────────────────────────────────────────────────────────────┘

                    ┌─────────────────────┐
                    │     Repo 1          │
                    │  (This Repo)        │
                    └──────────┬──────────┘
                               │
                               ▼
         ./scripts/deployment/setup-shared-aurora.sh
                               │
                               ▼
                    ┌──────────────────────┐
                    │  Creates:            │
                    │  • Aurora Cluster    │
                    │  • VPC/Security      │
                    │  • Secrets Manager   │
                    │  • Config Files      │
                    └──────────┬───────────┘
                               │
                               ▼
              ┌────────────────────────────────┐
              │   Aurora Serverless v2 Cluster  │
              │   ordering-prod-cluster         │
              │   (Empty - No databases yet)    │
              └────────────────┬───────────────┘
                               │
                               ▼
                   ~/.aurora-shared/
                   ├── cluster-config.sh
                   └── setup-scripts/
                       └── add-application.sh

┌─────────────────────────────────────────────────────────────────┐
│                  PHASE 2: ADD REPO 1 (ORDERING)                  │
└─────────────────────────────────────────────────────────────────┘

       ~/.aurora-shared/setup-scripts/add-application.sh ordering <pass>
                               │
                               ▼
              ┌────────────────────────────────┐
              │   Aurora Cluster                │
              │   ┌──────────────────────┐     │
              │   │  ordering_prod       │     │
              │   │  (User: ordering_user)│     │
              │   └──────────────────────┘     │
              └────────────────┬───────────────┘
                               │
                               ▼
              Generated: ~/.aurora-shared/apps/ordering.env
                               │
                               ▼
                 Copy to Repo 1: cp ... .env
                               │
                               ▼
                    Update database.py
                               │
                               ▼
                  python manage.py migrate
                               │
                               ▼
                    ┌──────────────────────┐
                    │  Repo 1 Connected!   │
                    │  ✓ ordering_prod     │
                    │  ✓ restaurant_prod   │
                    └──────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                  PHASE 3: ADD REPO 2 (OTHER APP)                 │
└─────────────────────────────────────────────────────────────────┘

                    ┌─────────────────────┐
                    │     Repo 2          │
                    │  (Other Repo)       │
                    └──────────┬──────────┘
                               │
                  ┌────────────┴─────────────┐
                  │                          │
         Option A: Copy Script      Option B: Manual Setup
                  │                          │
                  ▼                          ▼
    ~/.aurora-shared/setup-scripts/   Share endpoint
         add-application.sh           and create DB
                  │                          │
                  └────────────┬─────────────┘
                               │
           add-application.sh app2 <pass>
                               │
                               ▼
              ┌────────────────────────────────┐
              │   Aurora Cluster                │
              │   ┌──────────────────────┐     │
              │   │  ordering_prod       │     │
              │   │  (ordering_user)     │     │
              │   └──────────────────────┘     │
              │   ┌──────────────────────┐     │
              │   │  app2_prod           │     │
              │   │  (app2_user)         │     │
              │   └──────────────────────┘     │
              └────────────────┬───────────────┘
                               │
                               ▼
              Generated: ~/.aurora-shared/apps/app2.env
                               │
                               ▼
                 Copy to Repo 2: cp ... .env
                               │
                               ▼
                    Update database.py
                               │
                               ▼
                  python manage.py migrate
                               │
                               ▼
                    ┌──────────────────────┐
                    │  Repo 2 Connected!   │
                    │  ✓ app2_prod         │
                    └──────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                  FINAL STATE: SHARED CLUSTER                     │
└─────────────────────────────────────────────────────────────────┘

              ┌────────────────────────────────────────┐
              │   Aurora Serverless v2 Cluster         │
              │   ordering-prod-cluster                │
              │   • Scales: 0.5-2 ACU                  │
              │   • Cost: ~$43-172/month shared        │
              │   • Backup: 7 days automated           │
              │                                        │
              │   ┌──────────────┐  ┌──────────────┐ │
              │   │ordering_prod │  │  app2_prod   │ │
              │   │50 conn limit │  │50 conn limit │ │
              │   │ordering_user │  │ app2_user    │ │
              │   └──────┬───────┘  └──────┬───────┘ │
              └──────────┼──────────────────┼─────────┘
                         │                  │
                         │                  │
              ┌──────────▼──────┐  ┌───────▼────────┐
              │   Repo 1        │  │   Repo 2       │
              │   (Ordering)    │  │   (Other App)  │
              │                 │  │                │
              │ Django App      │  │ Django App     │
              │ ordering_prod   │  │ app2_prod      │
              │ restaurant_prod │  │                │
              └─────────────────┘  └────────────────┘
```

## 📋 Step-by-Step Commands

### 1️⃣ Create Shared Cluster (Once)

```bash
# In Repo 1
cd /path/to/Ordering-Delivery-and-Payment-Backend

# Set master password
export AURORA_MASTER_PASSWORD="YourSecurePassword123!"

# Run setup
./scripts/deployment/setup-shared-aurora.sh

# ✓ Creates cluster
# ✓ Saves config to ~/.aurora-shared/
# ✓ Stores credentials in AWS Secrets Manager
```

**Output to save:**
```
Cluster Endpoints:
Writer: ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com
Reader: ordering-prod-cluster.cluster-ro-xxxxx.us-east-1.rds.amazonaws.com

Configuration saved to: /home/user/.aurora-shared/cluster-config.sh
Add app script: /home/user/.aurora-shared/setup-scripts/add-application.sh
```

---

### 2️⃣ Setup Repo 1 (Ordering App)

```bash
# Add ordering application to cluster
~/.aurora-shared/setup-scripts/add-application.sh ordering SecurePass123

# ✓ Creates ordering_prod database
# ✓ Creates ordering_user with limited permissions
# ✓ Generates ~/.aurora-shared/apps/ordering.env

# Copy config to your repo
cp ~/.aurora-shared/apps/ordering.env .env.aurora

# Add to your .env (or merge)
cat .env.aurora >> .env

# Or edit .env manually with these values:
cat .env.aurora
```

**Update `core/settings/database.py`:**
```python
# Should already have DB_HOST_SERVER, etc. from .env
# Just verify it points to Aurora endpoint
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('DB_NAME'),  # ordering_prod
        'USER': os.getenv('DB_USER'),  # ordering_user
        'PASSWORD': os.getenv('DB_PASSWORD'),
        'HOST': os.getenv('DB_HOST_SERVER'),  # Aurora endpoint
        'PORT': os.getenv('DB_PORT', '5432'),
        'OPTIONS': {
            'sslmode': 'require',
        },
        'CONN_MAX_AGE': 600,
    }
}
```

**Run migrations:**
```bash
python manage.py migrate
python manage.py migrate --database=restaurant_db

# Test
python manage.py dbshell
\dt
\q
```

---

### 3️⃣ Setup Repo 2 (Other App)

**Method A: Use shared script (Recommended)**

```bash
# In Repo 2
# First, get the add-application script

# Option 1: Copy from Repo 1 server
scp user@repo1-server:~/.aurora-shared/setup-scripts/add-application.sh .
scp user@repo1-server:~/.aurora-shared/cluster-config.sh .

mkdir -p ~/.aurora-shared/setup-scripts
mv add-application.sh ~/.aurora-shared/setup-scripts/
mv cluster-config.sh ~/.aurora-shared/

# Option 2: If you have access to same AWS account
# The files are already in ~/.aurora-shared/

# Add your application
~/.aurora-shared/setup-scripts/add-application.sh app2 App2SecurePass456

# Copy config
cp ~/.aurora-shared/apps/app2.env .env

# Update your Django settings (similar to Repo 1)
# Run migrations
python manage.py migrate
```

**Method B: Manual with endpoint** (if you can't copy scripts)

```bash
# In Repo 2, create .env with Aurora details from Repo 1
cat > .env << EOF
DB_HOST_SERVER=ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com
DB_PORT=5432
DB_NAME=app2_prod
DB_USER=app2_user
DB_PASSWORD=App2SecurePass456
AWS_REGION=us-east-1
EOF

# Manually create the database
# Get master password from Repo 1 or Secrets Manager
MASTER_PASS=$(aws secretsmanager get-secret-value \
    --secret-id ordering-prod-cluster/master \
    --query 'SecretString' --output text | jq -r '.password')

# Create database and user
PGPASSWORD="$MASTER_PASS" psql \
    -h ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com \
    -U postgres \
    -d postgres << EOSQL
CREATE DATABASE app2_prod;
CREATE USER app2_user WITH PASSWORD 'App2SecurePass456';
GRANT ALL PRIVILEGES ON DATABASE app2_prod TO app2_user;
ALTER USER app2_user CONNECTION LIMIT 50;

\c app2_prod
GRANT ALL ON SCHEMA public TO app2_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO app2_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO app2_user;
EOSQL

# Update Django settings
# Run migrations
python manage.py migrate
```

---

## 🔄 Data Flow

```
┌──────────────┐
│  Repo 1      │
│  Requests    │
└──────┬───────┘
       │
       │ Connection String:
       │ postgresql://ordering_user:***@aurora-endpoint:5432/ordering_prod
       │
       ▼
┌──────────────────────────────────────┐
│     Aurora Cluster (Shared)          │
│                                      │
│  ┌─────────────────┐                │
│  │ ordering_prod   │                │
│  │ ✓ Isolated      │                │
│  │ ✓ 50 conn limit │                │
│  └─────────────────┘                │
│                                      │
│  Connection Pool (Shared)            │
│  0.5-2 ACU (Auto-scaling)           │
│                                      │
│  ┌─────────────────┐                │
│  │ app2_prod       │                │
│  │ ✓ Isolated      │                │
│  │ ✓ 50 conn limit │                │
│  └─────────────────┘                │
│                                      │
└──────────────┬───────────────────────┘
               │
               │ Connection String:
               │ postgresql://app2_user:***@aurora-endpoint:5432/app2_prod
               │
               ▼
       ┌──────────────┐
       │  Repo 2      │
       │  Requests    │
       └──────────────┘
```

## 🔐 Security Isolation

```
┌────────────────────────────────────────────────┐
│          Aurora Cluster                        │
│                                                │
│  Master User (postgres)                        │
│  └── Can access all databases                 │
│      └── Stored in: ordering-prod-cluster/master│
│                                                │
│  ┌──────────────────────┐                     │
│  │ ordering_prod        │                     │
│  │ Owner: postgres      │                     │
│  │ Access: ordering_user│                     │
│  │ Secret: .../ordering │                     │
│  │                      │                     │
│  │ ✓ GRANT to ordering_user only             │
│  │ ✗ app2_user CANNOT access                 │
│  └──────────────────────┘                     │
│                                                │
│  ┌──────────────────────┐                     │
│  │ app2_prod            │                     │
│  │ Owner: postgres      │                     │
│  │ Access: app2_user    │                     │
│  │ Secret: .../app2     │                     │
│  │                      │                     │
│  │ ✓ GRANT to app2_user only                 │
│  │ ✗ ordering_user CANNOT access             │
│  └──────────────────────┘                     │
└────────────────────────────────────────────────┘

Each repo only gets credentials for their own database
```

## 📊 Cost Comparison

```
Separate Clusters (Before):
┌─────────────────┐  ┌─────────────────┐
│ Cluster 1       │  │ Cluster 2       │
│ ordering        │  │ app2            │
│ $86-172/month   │  │ $86-172/month   │
└─────────────────┘  └─────────────────┘
Total: $172-344/month

Shared Cluster (After):
┌─────────────────────────────────────┐
│   Single Cluster                    │
│   ordering_prod + app2_prod         │
│   $86-172/month                     │
└─────────────────────────────────────┘
Total: $86-172/month

💰 Savings: 50% ($86-172/month)
```

## 🎯 Quick Reference

| Task | Command |
|------|---------|
| **Create cluster** | `./scripts/deployment/setup-shared-aurora.sh` |
| **Add Repo 1** | `~/.aurora-shared/setup-scripts/add-application.sh ordering <pass>` |
| **Add Repo 2** | `~/.aurora-shared/setup-scripts/add-application.sh app2 <pass>` |
| **Get endpoint** | `aws rds describe-db-clusters --db-cluster-identifier ordering-prod-cluster` |
| **Get credentials** | `aws secretsmanager get-secret-value --secret-id ordering-prod-cluster/ordering` |
| **Test connection** | `source ~/.aurora-shared/cluster-config.sh && test_aurora_connection` |
| **View databases** | `psql -h <endpoint> -U postgres -d postgres -c "\l"` |
| **Monitor connections** | `psql -h <endpoint> -U postgres -d postgres -c "SELECT datname, usename, COUNT(*) FROM pg_stat_activity GROUP BY 1,2;"` |

## ✅ Success Checklist

### After Cluster Creation
- [ ] Cluster endpoint saved
- [ ] Master credentials in Secrets Manager
- [ ] Config files in ~/.aurora-shared/
- [ ] Can connect with psql

### After Repo 1 Setup
- [ ] ordering_prod database exists
- [ ] ordering_user can connect
- [ ] Migrations completed
- [ ] Application runs successfully

### After Repo 2 Setup
- [ ] app2_prod database exists
- [ ] app2_user can connect
- [ ] Migrations completed
- [ ] Application runs successfully

### Both Applications Working
- [ ] Both apps can connect simultaneously
- [ ] No cross-database access
- [ ] Connection limits respected
- [ ] CloudWatch monitoring active

---

**Next Steps:**
1. Follow Phase 1 to create the cluster
2. Follow Phase 2 to setup Repo 1
3. Share endpoint with Repo 2 team
4. Follow Phase 3 to setup Repo 2
5. Monitor and optimize

**Questions?** See [MULTI_REPO_AURORA_SETUP.md](./MULTI_REPO_AURORA_SETUP.md) for detailed instructions.
