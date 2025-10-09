# Aurora Multi-Application Setup 🚀

One Aurora Serverless v2 cluster serving multiple applications across different repositories.

## 📚 Documentation Index

| Document | Purpose | Audience |
|----------|---------|----------|
| **[THIS FILE]** | Quick start & overview | Everyone |
| [AURORA_SETUP_WORKFLOW.md](docs/AURORA_SETUP_WORKFLOW.md) | Visual workflow & commands | DevOps, Developers |
| [MULTI_REPO_AURORA_SETUP.md](docs/MULTI_REPO_AURORA_SETUP.md) | Complete multi-repo guide | All teams |
| [AURORA_SHARED_DATABASE_PLAN.md](docs/AURORA_SHARED_DATABASE_PLAN.md) | Detailed architecture & planning | Architects, DevOps |
| [AURORA_QUICK_REFERENCE.md](docs/AURORA_QUICK_REFERENCE.md) | Commands & troubleshooting | Developers, DevOps |

## 🎯 What This Does

**Single Aurora cluster** → **Multiple isolated databases** → **Multiple applications/repos**

```
Aurora Cluster (ordering-prod-cluster)
├── ordering_prod    → Repo 1 (This repo)
├── restaurant_prod  → Repo 1 (This repo)
└── app2_prod        → Repo 2 (Other repo)

💰 Cost: ~$86-172/month for ALL apps (vs $172-344 for separate clusters)
✅ 50% cost savings
✅ Full data isolation
✅ Shared infrastructure
```

## 🚀 Quick Start (3 Steps)

### Step 1: Create Shared Cluster (Run Once)

```bash
# In this repo
export AURORA_MASTER_PASSWORD="YourSecurePassword123!"
./scripts/deployment/setup-shared-aurora.sh

# Outputs:
# ✓ Aurora endpoint: ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com
# ✓ Config saved to: ~/.aurora-shared/
```

**Time**: ~15 minutes
**Cost**: Starts at ~$43/month (0.5 ACU idle)

---

### Step 2: Add This Application (Repo 1)

```bash
# Add ordering application
~/.aurora-shared/setup-scripts/add-application.sh ordering SecurePass123

# Copy config
cp ~/.aurora-shared/apps/ordering.env .env

# Run migrations
python manage.py migrate

# ✓ ordering_prod database created
# ✓ ordering_user created with limited access
# ✓ Application connected
```

**Time**: ~5 minutes

---

### Step 3: Add Other Application (Repo 2)

**Option A: Share the script** (Recommended)
```bash
# Copy script to Repo 2
scp ~/.aurora-shared/setup-scripts/add-application.sh user@repo2:/path/

# In Repo 2, run:
./add-application.sh app2 App2SecurePass456
cp ~/.aurora-shared/apps/app2.env .env
python manage.py migrate
```

**Option B: Share connection details**
```bash
# Share these with Repo 2 team:
- Aurora Endpoint: ordering-prod-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com
- Region: us-east-1
- Master Secret: ordering-prod-cluster/master

# Repo 2 team manually creates their database using the endpoint
```

**Time**: ~5 minutes per additional application

---

## 📦 What Gets Created

### Infrastructure
- ✅ Aurora Serverless v2 cluster (PostgreSQL 15.4)
- ✅ VPC subnet group
- ✅ Security group with PostgreSQL access
- ✅ Automatic backups (7 days)
- ✅ CloudWatch monitoring

### Per Application
- ✅ Dedicated database (e.g., `ordering_prod`, `app2_prod`)
- ✅ Dedicated user with limited permissions
- ✅ Connection limit (50 per user)
- ✅ Credentials stored in AWS Secrets Manager
- ✅ Configuration file (`.env` format)

### Shared Resources
- ✅ Configuration: `~/.aurora-shared/cluster-config.sh`
- ✅ Setup script: `~/.aurora-shared/setup-scripts/add-application.sh`
- ✅ Per-app configs: `~/.aurora-shared/apps/<app_name>.env`

---

## 🔐 Security & Isolation

Each application is **fully isolated**:

| Feature | Implementation |
|---------|----------------|
| **Database** | Separate database per app |
| **User** | Separate user with specific grants |
| **Connections** | Limited to 50 per user |
| **Credentials** | Stored separately in Secrets Manager |
| **Network** | Shared security group (adjustable) |

**Verification:**
```sql
-- App 1 cannot access App 2's database
psql -h <endpoint> -U ordering_user -d app2_prod
-- ERROR: permission denied
```

---

## 💰 Cost Breakdown

### Shared Cluster Pricing (us-east-1)

| Usage | ACU Average | Monthly Cost | Per-App Cost |
|-------|-------------|--------------|--------------|
| **Idle** | 0.5 | ~$43 | ~$21 |
| **Low** | 1.0 | ~$86 | ~$43 |
| **Medium** | 2.0 | ~$172 | ~$86 |
| **High** | 4.0 | ~$344 | ~$172 |

**Pricing**: $0.12/ACU-hour (~$86/month for 1 ACU continuously)

### Comparison

```
Two Separate Clusters:
Cluster 1: $86/month
Cluster 2: $86/month
Total: $172/month

Shared Cluster:
Single Cluster: $86/month
Savings: $86/month (50%)
```

---

## 🛠️ Scripts Reference

### Main Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `setup-shared-aurora.sh` | Create/configure Aurora cluster | `./scripts/deployment/setup-shared-aurora.sh` |
| `add-application.sh` | Add new app to cluster | `~/.aurora-shared/setup-scripts/add-application.sh <app_name> <password>` |
| `migrate-to-aurora.sh` | Migrate existing RDS to Aurora | `./scripts/deployment/migrate-to-aurora.sh` |
| `setup-app2-database.sh` | Standalone app2 setup | `./scripts/deployment/setup-app2-database.sh app2 <password>` |

### Helper Functions

```bash
# Load shared configuration
source ~/.aurora-shared/cluster-config.sh

# Get master password
get_aurora_master_password

# Get full credentials
get_aurora_credentials

# Test connection
test_aurora_connection
```

---

## 📊 Monitoring

### Quick Checks

```bash
# View all connections
psql -h <endpoint> -U postgres -d postgres << EOF
SELECT datname, usename, state, COUNT(*)
FROM pg_stat_activity
WHERE datname IN ('ordering_prod', 'app2_prod')
GROUP BY datname, usename, state;
EOF

# Database sizes
psql -h <endpoint> -U postgres -d postgres -c "\l+"

# Active queries
psql -h <endpoint> -U postgres -d postgres -c "SELECT * FROM pg_stat_activity WHERE state = 'active';"
```

### CloudWatch Metrics

- CPU Utilization: Should be < 60%
- Database Connections: Monitor per-app limits
- ACU Utilization: Should stay within configured range
- Query Duration: Average < 100ms

---

## 🔧 Common Operations

### Add a New Application

```bash
~/.aurora-shared/setup-scripts/add-application.sh newapp SecurePass789
cp ~/.aurora-shared/apps/newapp.env /path/to/newapp/.env
```

### Get Connection Details

```bash
# From config file
cat ~/.aurora-shared/apps/ordering.env

# From Secrets Manager
aws secretsmanager get-secret-value \
    --secret-id ordering-prod-cluster/ordering \
    --query 'SecretString' --output text | jq
```

### Scale the Cluster

```bash
# Increase capacity
aws rds modify-db-cluster \
    --db-cluster-identifier ordering-prod-cluster \
    --serverless-v2-scaling-configuration MinCapacity=1,MaxCapacity=4 \
    --apply-immediately
```

### Create Manual Backup

```bash
aws rds create-db-cluster-snapshot \
    --db-cluster-identifier ordering-prod-cluster \
    --db-cluster-snapshot-identifier backup-$(date +%Y%m%d)
```

---

## 🎓 For Different Roles

### For DevOps Team
1. Review: [AURORA_SHARED_DATABASE_PLAN.md](docs/AURORA_SHARED_DATABASE_PLAN.md)
2. Run: `setup-shared-aurora.sh`
3. Share endpoint with development teams
4. Set up CloudWatch alarms
5. Monitor ACU usage and costs

### For Repo 1 Team (This Repo)
1. Review: [AURORA_SETUP_WORKFLOW.md](docs/AURORA_SETUP_WORKFLOW.md)
2. Run: `add-application.sh ordering <password>`
3. Update `core/settings/database.py`
4. Run migrations
5. Test application

### For Repo 2 Team (Other Repo)
1. Review: [MULTI_REPO_AURORA_SETUP.md](docs/MULTI_REPO_AURORA_SETUP.md)
2. Get endpoint from Repo 1 team
3. Run: `add-application.sh app2 <password>` (or manual setup)
4. Configure application
5. Run migrations

### For Developers
- Quick commands: [AURORA_QUICK_REFERENCE.md](docs/AURORA_QUICK_REFERENCE.md)
- Troubleshooting: See "Troubleshooting" section in any doc
- Connection strings: Check `~/.aurora-shared/apps/<app_name>.env`

---

## ⚠️ Important Notes

### Before You Start
- ✅ Have AWS CLI configured
- ✅ Have PostgreSQL client (psql) installed
- ✅ Have appropriate AWS IAM permissions
- ✅ Choose a strong master password
- ✅ Decide on cluster ID and region

### Security Best Practices
- 🔐 Never commit passwords to Git
- 🔐 Use Secrets Manager for credentials
- 🔐 Enable SSL/TLS for all connections
- 🔐 Restrict security group to VPC only (not 0.0.0.0/0)
- 🔐 Rotate passwords quarterly

### Cost Management
- 💰 Start with 0.5-2 ACU range
- 💰 Monitor actual usage in CloudWatch
- 💰 Scale up only when needed
- 💰 Use connection pooling to reduce load
- 💰 Archive old data to reduce storage costs

---

## 🆘 Troubleshooting

### Can't Connect

```bash
# Check cluster status
aws rds describe-db-clusters \
    --db-cluster-identifier ordering-prod-cluster \
    --query 'DBClusters[0].Status'

# Check security group
aws ec2 describe-security-groups --group-ids <sg-id>

# Test from EC2 instance
psql -h <endpoint> -U postgres -d postgres
```

### Too Many Connections

```sql
-- View connections
SELECT COUNT(*) FROM pg_stat_activity;

-- Kill idle connections
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND state_change < NOW() - INTERVAL '10 minutes';
```

### Forgot Credentials

```bash
# Get from Secrets Manager
aws secretsmanager get-secret-value \
    --secret-id ordering-prod-cluster/ordering \
    --query 'SecretString' --output text | jq -r '.password'
```

---

## 📞 Support

### Documentation
- 📖 Detailed architecture: [AURORA_SHARED_DATABASE_PLAN.md](docs/AURORA_SHARED_DATABASE_PLAN.md)
- 📖 Step-by-step guide: [MULTI_REPO_AURORA_SETUP.md](docs/MULTI_REPO_AURORA_SETUP.md)
- 📖 Visual workflow: [AURORA_SETUP_WORKFLOW.md](docs/AURORA_SETUP_WORKFLOW.md)
- 📖 Quick reference: [AURORA_QUICK_REFERENCE.md](docs/AURORA_QUICK_REFERENCE.md)

### AWS Resources
- CloudWatch Logs: `/aws/rds/cluster/ordering-prod-cluster`
- RDS Console: Services → RDS → Databases
- Secrets Manager: Services → Secrets Manager

### Escalation
1. Check documentation above
2. Review CloudWatch logs
3. Contact DevOps team
4. Escalate to database administrator

---

## 🎉 Success Criteria

Your setup is complete when:

- ✅ Aurora cluster is running
- ✅ All applications can connect
- ✅ Migrations have completed
- ✅ Applications are working correctly
- ✅ No cross-app access (verified)
- ✅ CloudWatch monitoring is active
- ✅ Credentials are in Secrets Manager
- ✅ Documentation is updated

---

## 📝 Next Steps After Setup

1. **Monitor for 24 hours**: Watch CloudWatch metrics
2. **Optimize queries**: Use `pg_stat_statements`
3. **Set up alerts**: CPU, connections, storage
4. **Document your config**: Update team wiki
5. **Train team**: Share documentation
6. **Plan scaling**: Review ACU usage weekly
7. **Schedule backups**: Test restore procedures

---

**Created**: 2025-10-09
**Version**: 1.0
**Maintainer**: DevOps Team
**License**: Internal Use

---

## 🔗 Quick Links

- [Setup Workflow](docs/AURORA_SETUP_WORKFLOW.md)
- [Multi-Repo Guide](docs/MULTI_REPO_AURORA_SETUP.md)
- [Architecture Plan](docs/AURORA_SHARED_DATABASE_PLAN.md)
- [Quick Reference](docs/AURORA_QUICK_REFERENCE.md)
- [AWS Aurora Docs](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/)
