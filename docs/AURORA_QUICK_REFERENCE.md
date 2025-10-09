# Aurora Serverless Multi-App Quick Reference

## 🎯 Overview
Single Aurora Serverless v2 cluster serving multiple applications with isolated databases.

## 🏗️ Architecture

```
Aurora Cluster: ordering-prod-cluster
├── ordering_prod (App 1 - Main)
├── restaurant_prod (App 1 - Restaurant data)
├── app2_prod (App 2 - Main)
└── app2_secondary (App 2 - Optional)

Users:
├── ordering_app (App 1 access)
└── app2_user (App 2 access)
```

## 📊 Resource Configuration

| Parameter | Value | Notes |
|-----------|-------|-------|
| **Cluster ID** | ordering-prod-cluster | Shared cluster |
| **Engine** | aurora-postgresql | Version 15.4 |
| **Min ACUs** | 0.5 | Scales to zero during idle |
| **Max ACUs** | 2 | Adjust based on load |
| **Backup Retention** | 7 days | Automated backups |
| **Multi-AZ** | Yes | High availability |

## 💰 Cost Estimates

| Usage Pattern | Monthly Cost | Description |
|---------------|--------------|-------------|
| **Minimal** | $43-86 | 0.5 ACU average |
| **Low** | $86-172 | 0.5-2 ACU range |
| **Medium** | $172-344 | 2-4 ACU range |
| **High** | $344-688 | 4-8 ACU range |

*Prices based on us-east-1 region, Aurora Serverless v2 pricing*

## 🚀 Quick Start

### For App 1 (Current - Ordering Backend)

```bash
# 1. Run migration script
./scripts/deployment/migrate-to-aurora.sh

# 2. Update .env
DB_HOST_SERVER=<aurora-endpoint>
DB_NAME=ordering_prod
RESTAURANT_DB_HOST_SERVER=<aurora-endpoint>
RESTAURANT_DB_NAME=restaurant_prod

# 3. Test connection
python manage.py migrate
python manage.py test
```

### For App 2 (New Application)

```bash
# 1. Create database and user
./scripts/deployment/setup-app2-database.sh app2 <password>

# 2. Configure App 2 with provided credentials

# 3. Run migrations
python manage.py migrate
```

## 🔐 Security

### Connection Requirements
- **SSL/TLS**: Required for all connections
- **Network**: VPC security group restricts access
- **Authentication**: User-based isolation
- **Secrets**: Store credentials in AWS Secrets Manager

### Per-App Isolation
```sql
-- Each app has its own:
✓ Dedicated database(s)
✓ Dedicated user with specific permissions
✓ Connection limits (50 per user)
✓ Separate schema (optional)
```

## 📈 Monitoring

### Key Metrics (CloudWatch)

| Metric | Normal Range | Alert Threshold |
|--------|--------------|-----------------|
| **CPU Utilization** | < 60% | > 80% |
| **Database Connections** | < 80 | > 90 |
| **ACU Utilization** | 0.5-2 | > 1.5 (sustained) |
| **Query Duration** | < 100ms avg | > 500ms avg |

### Monitoring Queries

```sql
-- Connection count per app
SELECT datname, usename, COUNT(*)
FROM pg_stat_activity
WHERE datname IN ('ordering_prod', 'restaurant_prod', 'app2_prod')
GROUP BY datname, usename;

-- Database sizes
SELECT datname, pg_size_pretty(pg_database_size(datname))
FROM pg_database
WHERE datname LIKE '%prod';

-- Active queries
SELECT pid, usename, state, query
FROM pg_stat_activity
WHERE state = 'active';
```

## 🔧 Common Operations

### Get Aurora Endpoint
```bash
aws rds describe-db-clusters \
    --db-cluster-identifier ordering-prod-cluster \
    --query 'DBClusters[0].Endpoint' \
    --output text
```

### Get Credentials from Secrets Manager
```bash
# App 1
aws secretsmanager get-secret-value \
    --secret-id ordering/prod/database \
    --query 'SecretString' --output text | jq

# App 2
aws secretsmanager get-secret-value \
    --secret-id ordering/prod/app2-database \
    --query 'SecretString' --output text | jq
```

### Create Manual Snapshot
```bash
aws rds create-db-cluster-snapshot \
    --db-cluster-identifier ordering-prod-cluster \
    --db-cluster-snapshot-identifier manual-backup-$(date +%Y%m%d)
```

### Scale Aurora
```bash
aws rds modify-db-cluster \
    --db-cluster-identifier ordering-prod-cluster \
    --serverless-v2-scaling-configuration MinCapacity=1,MaxCapacity=4 \
    --apply-immediately
```

### View Current Scaling Configuration
```bash
aws rds describe-db-clusters \
    --db-cluster-identifier ordering-prod-cluster \
    --query 'DBClusters[0].ServerlessV2ScalingConfiguration'
```

## 🔄 Connection Configuration

### Django (App 1)
```python
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('DB_NAME', 'ordering_prod'),
        'USER': os.getenv('DB_USER', 'ordering_app'),
        'PASSWORD': os.getenv('DB_PASSWORD'),
        'HOST': os.getenv('DB_HOST_SERVER'),
        'PORT': '5432',
        'OPTIONS': {
            'sslmode': 'require',
            'connect_timeout': 10,
        },
        'CONN_MAX_AGE': 600,
    },
    'restaurant_db': {
        # Same configuration for restaurant_prod
    }
}
```

### Django (App 2)
```python
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'app2_prod',
        'USER': 'app2_user',
        'PASSWORD': os.getenv('DB_PASSWORD'),
        'HOST': '<aurora-endpoint>',  # Same endpoint
        'PORT': '5432',
        'OPTIONS': {
            'sslmode': 'require',
            'connect_timeout': 10,
        },
        'CONN_MAX_AGE': 600,
    }
}
```

## 🚨 Troubleshooting

### Issue: Too Many Connections
```sql
-- Check connection count
SELECT COUNT(*) FROM pg_stat_activity;

-- Kill idle connections (>10 minutes)
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND state_change < NOW() - INTERVAL '10 minutes';
```

### Issue: Slow Performance
```sql
-- Top 10 slowest queries
SELECT query, calls, mean_time, total_time
FROM pg_stat_statements
ORDER BY mean_time DESC
LIMIT 10;

-- Check for locks
SELECT * FROM pg_locks WHERE NOT granted;
```

### Issue: High ACU Usage
```bash
# Check CloudWatch metrics
aws cloudwatch get-metric-statistics \
    --namespace AWS/RDS \
    --metric-name ServerlessDatabaseCapacity \
    --dimensions Name=DBClusterIdentifier,Value=ordering-prod-cluster \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Average
```

## 📋 Pre-Flight Checklist

### Before Migration
- [ ] Backup current databases
- [ ] Test Aurora cluster creation in non-prod
- [ ] Review connection pooling settings
- [ ] Update documentation
- [ ] Notify team of maintenance window

### After Migration
- [ ] Verify all data migrated
- [ ] Test application functionality
- [ ] Monitor performance for 24 hours
- [ ] Update connection strings in all environments
- [ ] Configure CloudWatch alarms

### Before Adding App 2
- [ ] Run setup-app2-database.sh script
- [ ] Store credentials in Secrets Manager
- [ ] Update security groups if needed
- [ ] Document connection details for App 2 team
- [ ] Test connection from App 2 environment

## 📚 Resources

| Resource | Location |
|----------|----------|
| **Detailed Plan** | docs/AURORA_SHARED_DATABASE_PLAN.md |
| **Migration Script** | scripts/deployment/migrate-to-aurora.sh |
| **App 2 Setup** | scripts/deployment/setup-app2-database.sh |
| **Deployment Guide** | docs/DEPLOYMENT.md |

## 🆘 Support

### Escalation Path
1. Check CloudWatch logs: `/aws/rds/cluster/ordering-prod-cluster`
2. Review RDS Events in AWS Console
3. Run diagnostic queries (see Troubleshooting section)
4. Contact DevOps team
5. Escalate to database administrator

### Useful AWS Console Links
- **RDS Dashboard**: Services → RDS → Databases → ordering-prod-cluster
- **CloudWatch Metrics**: CloudWatch → Metrics → RDS
- **Secrets Manager**: Secrets Manager → Secrets → ordering/prod/*

## 🎯 Best Practices

1. **Connection Pooling**: Use connection pooling (PgBouncer or RDS Proxy)
2. **Query Optimization**: Index properly, avoid N+1 queries
3. **Resource Monitoring**: Set up CloudWatch alarms
4. **Regular Backups**: Manual snapshots before major changes
5. **Cost Monitoring**: Review ACU usage weekly
6. **Security**: Rotate passwords quarterly
7. **Performance**: Run VACUUM and ANALYZE regularly
8. **Isolation**: Never grant cross-app permissions unless required

## 📊 Decision Matrix: When to Scale

| Indicator | Action |
|-----------|--------|
| **CPU > 80% for 15+ min** | Increase Max ACUs |
| **Connections > 80** | Implement connection pooling |
| **Query time > 500ms avg** | Optimize queries, add indexes |
| **Storage > 80%** | Archive old data |
| **Cost > budget** | Optimize queries, reduce ACUs |

---

**Last Updated**: 2025-10-09
**Version**: 1.0
**Owner**: DevOps Team
