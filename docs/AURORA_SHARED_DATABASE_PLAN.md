# Aurora Serverless Shared Database Plan
## Multi-Application Database Strategy

## Overview
This document outlines the architecture and implementation plan for using a single Aurora Serverless v2 PostgreSQL cluster to serve two applications:
1. **Ordering-Delivery-Payment Backend** (Current application)
2. **Second Application** (Future application)

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│         Aurora Serverless v2 Cluster                │
│         (ordering-prod-cluster)                      │
├─────────────────────────────────────────────────────┤
│                                                      │
│  ┌──────────────────┐    ┌──────────────────┐     │
│  │  ordering_prod   │    │  restaurant_prod │     │
│  │  (Main DB)       │    │  (Restaurant DB) │     │
│  └──────────────────┘    └──────────────────┘     │
│                                                      │
│  ┌──────────────────┐    ┌──────────────────┐     │
│  │  app2_prod       │    │  app2_secondary  │     │
│  │  (App 2 Main)    │    │  (Optional)      │     │
│  └──────────────────┘    └──────────────────┘     │
│                                                      │
└─────────────────────────────────────────────────────┘
           │                           │
           │                           │
    ┌──────▼──────┐            ┌──────▼──────┐
    │   App 1     │            │   App 2     │
    │  (Current)  │            │  (Future)   │
    └─────────────┘            └─────────────┘
```

## Benefits of Shared Aurora Cluster

### Cost Efficiency
- **Single cluster overhead**: One set of Aurora infrastructure costs
- **Serverless v2 auto-scaling**: 0.5-2 ACUs shared across all databases
- **Pay per use**: Scale to zero during idle periods
- **No redundant backups**: One backup strategy for all databases

### Operational Benefits
- **Centralized management**: Single cluster to monitor and maintain
- **Unified security**: One set of security groups and IAM policies
- **Simplified networking**: Single VPC configuration
- **Consistent performance**: Shared resource pool optimizes utilization

### Technical Advantages
- **Cross-database queries**: Ability to join data across applications (when needed)
- **Shared connection pool**: Better resource utilization
- **Unified disaster recovery**: Single backup/restore strategy
- **Consistent PostgreSQL version**: No version mismatch issues

## Database Isolation Strategy

### 1. Separate Databases per Application
Each application gets its own logical database(s) within the cluster:

```sql
-- App 1 (Current)
CREATE DATABASE ordering_prod;
CREATE DATABASE restaurant_prod;

-- App 2 (Future)
CREATE DATABASE app2_prod;
CREATE DATABASE app2_secondary;
```

### 2. Dedicated Database Users
Create separate users with specific permissions:

```sql
-- App 1 user
CREATE USER ordering_app WITH PASSWORD 'secure_password_1';
GRANT ALL PRIVILEGES ON DATABASE ordering_prod TO ordering_app;
GRANT ALL PRIVILEGES ON DATABASE restaurant_prod TO ordering_app;

-- App 2 user
CREATE USER app2_user WITH PASSWORD 'secure_password_2';
GRANT ALL PRIVILEGES ON DATABASE app2_prod TO app2_user;
GRANT ALL PRIVILEGES ON DATABASE app2_secondary TO app2_user;
```

### 3. Schema-Level Isolation (Optional)
For additional isolation within a database:

```sql
-- Create application-specific schemas
CREATE SCHEMA app1_core;
CREATE SCHEMA app1_analytics;

-- Grant schema permissions
GRANT ALL ON SCHEMA app1_core TO ordering_app;
REVOKE ALL ON SCHEMA app1_analytics FROM app2_user;
```

## Implementation Plan

### Phase 1: Provision Aurora Cluster ✓
**Status**: Can use existing migration script

**Tasks**:
- [x] Create Aurora Serverless v2 cluster
- [x] Configure security groups
- [x] Set up VPC and subnets
- [x] Enable HTTP endpoint for Data API
- [x] Configure backup retention

**Script**: `scripts/deployment/migrate-to-aurora.sh`

### Phase 2: Migrate Current Application
**Duration**: 2-3 hours

**Tasks**:
1. **Backup current databases**
   ```bash
   ./scripts/deployment/migrate-to-aurora.sh
   ```

2. **Verify migration**
   ```bash
   # Test connections
   psql -h <aurora-endpoint> -U ordering_app -d ordering_prod
   psql -h <aurora-endpoint> -U ordering_app -d restaurant_prod
   ```

3. **Update application configuration**
   ```bash
   # Update .env
   DB_HOST_SERVER=<aurora-endpoint>
   DB_NAME=ordering_prod
   RESTAURANT_DB_HOST_SERVER=<aurora-endpoint>
   RESTAURANT_DB_NAME=restaurant_prod
   ```

4. **Deploy and test**
   ```bash
   python manage.py migrate --database=default
   python manage.py migrate --database=restaurant_db
   python manage.py test
   ```

### Phase 3: Prepare for Second Application
**Duration**: 1-2 hours

**Tasks**:
1. **Create databases for App 2**
   ```sql
   CREATE DATABASE app2_prod;
   CREATE DATABASE app2_secondary; -- if needed
   ```

2. **Create dedicated user**
   ```sql
   CREATE USER app2_user WITH PASSWORD '<secure_password>';
   GRANT ALL PRIVILEGES ON DATABASE app2_prod TO app2_user;
   ```

3. **Store credentials in Secrets Manager**
   ```bash
   aws secretsmanager create-secret \
       --name ordering/prod/app2-database \
       --secret-string '{
           "username": "app2_user",
           "password": "<secure_password>",
           "host": "<aurora-endpoint>",
           "port": 5432,
           "dbname": "app2_prod"
       }'
   ```

4. **Document connection details**
   - Add to deployment docs
   - Update network diagrams
   - Share with App 2 team

### Phase 4: Monitoring and Optimization
**Ongoing**

**Tasks**:
1. **Set up CloudWatch monitoring**
   - CPU utilization
   - Database connections
   - Query performance
   - Storage usage

2. **Configure alarms**
   ```bash
   aws cloudwatch put-metric-alarm \
       --alarm-name aurora-high-cpu \
       --alarm-description "Aurora CPU > 80%" \
       --metric-name CPUUtilization \
       --namespace AWS/RDS \
       --statistic Average \
       --period 300 \
       --threshold 80 \
       --comparison-operator GreaterThanThreshold
   ```

3. **Implement connection pooling**
   - Use PgBouncer or RDS Proxy
   - Optimize connection limits per app

4. **Performance tuning**
   - Query optimization
   - Index management
   - Vacuum scheduling

## Security Configuration

### 1. Network Security

```bash
# Security group configuration
aws ec2 authorize-security-group-ingress \
    --group-id <sg-id> \
    --protocol tcp \
    --port 5432 \
    --source-group <app1-sg-id> \
    --description "App 1 access"

aws ec2 authorize-security-group-ingress \
    --group-id <sg-id> \
    --protocol tcp \
    --port 5432 \
    --source-group <app2-sg-id> \
    --description "App 2 access"
```

### 2. IAM Database Authentication (Optional)

```python
# Enable IAM authentication for passwordless access
import boto3

rds = boto3.client('rds')
token = rds.generate_db_auth_token(
    DBHostname='<aurora-endpoint>',
    Port=5432,
    DBUsername='ordering_app'
)
```

### 3. Encryption

- **At Rest**: Enable encryption using AWS KMS
- **In Transit**: Force SSL connections
- **Backup Encryption**: Automatic with cluster encryption

```python
# Django settings for SSL
DATABASES = {
    'default': {
        'OPTIONS': {
            'sslmode': 'require',
        }
    }
}
```

## Resource Allocation

### Current Configuration
```yaml
Cluster: ordering-prod-cluster
Engine: aurora-postgresql 15.4
Scaling:
  Min ACUs: 0.5
  Max ACUs: 2
Backup Retention: 7 days
Multi-AZ: Yes
```

### Recommended Scaling Based on Load

| Scenario | Min ACUs | Max ACUs | Est. Cost/Month |
|----------|----------|----------|-----------------|
| Dev/Test | 0.5 | 1 | $43-86 |
| Production (Low) | 0.5 | 2 | $43-172 |
| Production (Med) | 1 | 4 | $86-344 |
| Production (High) | 2 | 8 | $172-688 |

### Per-Application Resource Limits

```sql
-- Set connection limits per user
ALTER USER ordering_app CONNECTION LIMIT 50;
ALTER USER app2_user CONNECTION LIMIT 50;

-- Monitor connections
SELECT
    usename,
    COUNT(*) as connections,
    state
FROM pg_stat_activity
WHERE usename IN ('ordering_app', 'app2_user')
GROUP BY usename, state;
```

## Connection Configuration

### App 1 (Current Django App)

```python
# core/settings/database.py
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('DB_NAME', 'ordering_prod'),
        'USER': os.getenv('DB_USER', 'ordering_app'),
        'PASSWORD': os.getenv('DB_PASSWORD'),
        'HOST': os.getenv('DB_HOST_SERVER'),
        'PORT': os.getenv('DB_PORT', '5432'),
        'OPTIONS': {
            'sslmode': 'require',
            'connect_timeout': 10,
        },
        'CONN_MAX_AGE': 600,
    },
    'restaurant_db': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('RESTAURANT_DB_NAME', 'restaurant_prod'),
        'USER': os.getenv('RESTAURANT_DB_USER', 'ordering_app'),
        'PASSWORD': os.getenv('RESTAURANT_DB_PASSWORD'),
        'HOST': os.getenv('RESTAURANT_DB_HOST_SERVER'),
        'PORT': os.getenv('RESTAURANT_DB_PORT', '5432'),
        'OPTIONS': {
            'sslmode': 'require',
        },
        'CONN_MAX_AGE': 600,
    }
}
```

### App 2 Configuration Template

```python
# App 2 database configuration
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('DB_NAME', 'app2_prod'),
        'USER': os.getenv('DB_USER', 'app2_user'),
        'PASSWORD': os.getenv('DB_PASSWORD'),
        'HOST': os.getenv('DB_HOST_SERVER'),  # Same Aurora endpoint
        'PORT': os.getenv('DB_PORT', '5432'),
        'OPTIONS': {
            'sslmode': 'require',
            'connect_timeout': 10,
        },
        'CONN_MAX_AGE': 600,
    }
}
```

## Disaster Recovery

### Backup Strategy

```bash
# Automated backups (7 days retention)
# Configured during cluster creation

# Manual snapshot before major changes
aws rds create-db-cluster-snapshot \
    --db-cluster-identifier ordering-prod-cluster \
    --db-cluster-snapshot-identifier pre-migration-snapshot
```

### Point-in-Time Recovery

```bash
# Restore to specific time
aws rds restore-db-cluster-to-point-in-time \
    --source-db-cluster-identifier ordering-prod-cluster \
    --db-cluster-identifier ordering-prod-cluster-restored \
    --restore-to-time 2024-10-09T10:00:00Z
```

### Cross-Region Replication (Optional)

```bash
# Create read replica in different region
aws rds create-db-cluster \
    --db-cluster-identifier ordering-prod-cluster-replica \
    --engine aurora-postgresql \
    --replication-source-identifier arn:aws:rds:us-east-1:123456789012:cluster:ordering-prod-cluster \
    --region us-west-2
```

## Monitoring Queries

### Connection Monitoring

```sql
-- Current connections by database
SELECT
    datname,
    usename,
    COUNT(*) as connections,
    state
FROM pg_stat_activity
WHERE datname IN ('ordering_prod', 'restaurant_prod', 'app2_prod')
GROUP BY datname, usename, state
ORDER BY datname, connections DESC;
```

### Performance Monitoring

```sql
-- Slow queries
SELECT
    query,
    calls,
    total_time,
    mean_time,
    max_time
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'ordering_prod')
ORDER BY mean_time DESC
LIMIT 10;
```

### Storage Monitoring

```sql
-- Database sizes
SELECT
    pg_database.datname,
    pg_size_pretty(pg_database_size(pg_database.datname)) AS size
FROM pg_database
WHERE datname IN ('ordering_prod', 'restaurant_prod', 'app2_prod')
ORDER BY pg_database_size(pg_database.datname) DESC;
```

## Migration Checklist

### Pre-Migration
- [ ] Backup current databases
- [ ] Document current connection strings
- [ ] Review application connection pooling
- [ ] Test Aurora cluster creation
- [ ] Verify VPC and security group configuration

### Migration
- [ ] Create Aurora Serverless v2 cluster
- [ ] Migrate App 1 databases (ordering_prod, restaurant_prod)
- [ ] Update App 1 connection strings
- [ ] Run migrations on Aurora
- [ ] Test App 1 functionality
- [ ] Monitor performance

### Post-Migration
- [ ] Update documentation
- [ ] Configure CloudWatch alarms
- [ ] Set up automated backups
- [ ] Create runbook for common operations
- [ ] Document App 2 onboarding process

### App 2 Preparation
- [ ] Create App 2 databases
- [ ] Create App 2 database user
- [ ] Store credentials in Secrets Manager
- [ ] Document connection details
- [ ] Provide sample configuration

## Cost Optimization Tips

1. **Right-size ACU limits**: Start with 0.5-2 ACUs, monitor and adjust
2. **Connection pooling**: Use PgBouncer or RDS Proxy to reduce connections
3. **Query optimization**: Index properly, avoid N+1 queries
4. **Scheduled scaling**: Scale down during off-peak hours (if needed)
5. **Data archival**: Archive old data to S3 using pg_dump
6. **Monitor idle connections**: Set `idle_in_transaction_session_timeout`

## Troubleshooting

### Issue: Connection limit reached
```sql
-- Check current connections
SELECT COUNT(*) FROM pg_stat_activity;

-- Kill idle connections
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND state_change < NOW() - INTERVAL '10 minutes';
```

### Issue: Slow queries affecting both apps
```sql
-- Identify blocking queries
SELECT
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocked_activity.query AS blocked_statement,
    blocking_activity.query AS blocking_statement
FROM pg_locks blocked_locks
JOIN pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype
JOIN pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;
```

### Issue: Need to isolate App 1 from App 2 impact
Consider using RDS Proxy with separate proxy endpoints per application.

## Next Steps

1. **Review this plan** with the team
2. **Run migration script** for App 1: `./scripts/deployment/migrate-to-aurora.sh`
3. **Test and validate** App 1 on Aurora
4. **Document lessons learned** from migration
5. **Prepare App 2 databases** when ready
6. **Set up monitoring** and alerting
7. **Schedule regular reviews** of resource utilization

## Additional Resources

- [AWS Aurora Serverless v2 Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.html)
- [PostgreSQL Multi-Database Best Practices](https://www.postgresql.org/docs/current/managing-databases.html)
- [Django Multiple Database Support](https://docs.djangoproject.com/en/stable/topics/db/multi-db/)
- [AWS RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-proxy.html)

## Support

For questions or issues:
- Check CloudWatch logs: `/aws/rds/cluster/ordering-prod-cluster`
- Review RDS Events in AWS Console
- Contact DevOps team
- Escalate to database administrator
