

# PostgreSQL User Security Model for Django
## Production-Ready Database Access Control

## 🎯 Overview

This document explains the **4-user security model** for PostgreSQL with Django applications, following the **principle of least privilege**.

### Why Multiple Users?

**Single user with all permissions (BAD)**:
```
❌ One Django user with SUPERUSER or CREATE/DROP permissions
   - Can accidentally drop production tables
   - No separation of duties
   - Security risk if credentials compromised
   - No audit trail
```

**Multiple users with specific permissions (GOOD)**:
```
✅ Separate users for different operations
   - Application cannot drop tables
   - Clear audit trail
   - Reduced attack surface
   - Follows security best practices
```

---

## 👥 The 4-User Model

```
┌─────────────────────────────────────────────────────┐
│              PostgreSQL Database                     │
│                                                      │
│  1. Master User (postgres)                          │
│     ├─ SUPERUSER                                    │
│     ├─ Emergency only                               │
│     └─ ❌ NEVER used in Django                      │
│                                                      │
│  2. Admin User (dk_ordering_admin)                  │
│     ├─ CREATE/ALTER/DROP tables                     │
│     ├─ Migrations only                              │
│     ├─ Connection limit: 5                          │
│     └─ ✅ python manage.py migrate                  │
│                                                      │
│  3. Application User (dk_ordering_app)              │
│     ├─ SELECT/INSERT/UPDATE/DELETE                  │
│     ├─ NO schema changes                            │
│     ├─ Connection limit: 50                         │
│     └─ ✅ Django runtime (main user)                │
│                                                      │
│  4. Read-Only User (dk_ordering_readonly)           │
│     ├─ SELECT only                                  │
│     ├─ Analytics/BI                                 │
│     ├─ Connection limit: 20                         │
│     └─ ✅ Reporting tools                           │
└─────────────────────────────────────────────────────┘
```

---

## 1️⃣ Master User (`postgres`)

### Purpose
Emergency database administration only. **Never used by Django**.

### Permissions
```sql
-- Full superuser access
SUPERUSER
CREATEDB
CREATEROLE
LOGIN
```

### When to Use
- Creating databases
- Creating users
- Emergency recovery
- Manual schema fixes (rare)

### When NOT to Use
- ❌ Django settings
- ❌ Application runtime
- ❌ Migrations
- ❌ Automated scripts

### Security
- Store in AWS Secrets Manager: `deliverykick/prod/master`
- Share with DBAs only
- Rotate password quarterly
- Log all usage

### Example
```bash
# Emergency: Fix broken sequence
psql -h $ENDPOINT -U postgres -d mydb -c "SELECT setval('id_seq', 1000);"
```

---

## 2️⃣ Admin User (`dk_ordering_admin`)

### Purpose
Run Django migrations and manage database schema.

### Permissions
```sql
-- Can create and modify objects
GRANT CREATE ON SCHEMA public TO dk_ordering_admin;
GRANT USAGE ON SCHEMA public TO dk_ordering_admin;

-- Full access to tables/sequences/functions
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO dk_ordering_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO dk_ordering_admin;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO dk_ordering_admin;

-- Ensure admin owns future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO dk_ordering_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON SEQUENCES TO dk_ordering_admin;
```

### Can Do
✅ CREATE TABLE
✅ ALTER TABLE (add/drop columns)
✅ DROP TABLE
✅ CREATE INDEX
✅ DROP INDEX
✅ CREATE SEQUENCE
✅ ALTER SEQUENCE

### Cannot Do
❌ Drop database (only master can)
❌ Create new databases
❌ Manage users

### Connection Limit
```sql
ALTER USER dk_ordering_admin CONNECTION LIMIT 5;
```
Low limit because only used for migrations (not concurrent).

### When to Use
```bash
# Local development
export DB_USER=dk_ordering_admin
python manage.py makemigrations
python manage.py migrate

# CI/CD Pipeline
DB_USER=dk_ordering_admin DB_PASSWORD=$ADMIN_PASS python manage.py migrate

# Deployment scripts
docker run -e DB_USER=dk_ordering_admin myapp python manage.py migrate
```

### When NOT to Use
- ❌ Running Django application (use app user)
- ❌ Web servers
- ❌ API servers
- ❌ Celery workers

### Django Settings (Migrations)
```python
# settings/migration.py (for CI/CD)
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'deliverykick_ordering_prod',
        'USER': 'dk_ordering_admin',  # Admin user
        'PASSWORD': os.getenv('ADMIN_PASSWORD'),
        'HOST': os.getenv('DB_HOST'),
        'PORT': '5432',
    }
}
```

### Security
- Store in: `deliverykick/prod/ordering/admin`
- Use only in CI/CD pipelines
- Never expose to application runtime
- Rotate password quarterly

---

## 3️⃣ Application User (`dk_ordering_app`) ⭐ MAIN USER

### Purpose
**Primary user for Django application runtime**. Handles all normal operations.

### Permissions
```sql
-- Can use schema but NOT create objects
GRANT USAGE ON SCHEMA public TO dk_ordering_app;

-- Read/write data (NO schema changes)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO dk_ordering_app;

-- Use sequences (for auto-increment IDs)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dk_ordering_app;

-- Execute functions
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO dk_ordering_app;

-- Ensure permissions on future tables created by admin
ALTER DEFAULT PRIVILEGES FOR ROLE dk_ordering_admin IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dk_ordering_app;

ALTER DEFAULT PRIVILEGES FOR ROLE dk_ordering_admin IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO dk_ordering_app;
```

### Can Do
✅ SELECT (read data)
✅ INSERT (create records)
✅ UPDATE (modify records)
✅ DELETE (remove records)
✅ USAGE on sequences (for auto-increment)

### Cannot Do
❌ CREATE TABLE
❌ ALTER TABLE
❌ DROP TABLE
❌ CREATE INDEX
❌ DROP INDEX
❌ TRUNCATE TABLE
❌ CREATE SCHEMA

### Connection Limit
```sql
ALTER USER dk_ordering_app CONNECTION LIMIT 50;
```
Standard limit for application servers.

### When to Use
```bash
# Production runtime (main usage)
export DB_USER=dk_ordering_app
python manage.py runserver

# Gunicorn
DB_USER=dk_ordering_app gunicorn core.wsgi:application

# Celery workers
DB_USER=dk_ordering_app celery -A core worker

# Django shell
DB_USER=dk_ordering_app python manage.py shell
```

### Django Settings (Production)
```python
# settings/production.py
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'deliverykick_ordering_prod',
        'USER': 'dk_ordering_app',  # Application user
        'PASSWORD': os.getenv('APP_PASSWORD'),
        'HOST': os.getenv('DB_HOST'),
        'PORT': '5432',
        'OPTIONS': {
            'sslmode': 'require',
        },
        'CONN_MAX_AGE': 600,
    }
}
```

### Security Benefits
**Prevents accidental disasters:**
```python
# This code won't work with app user (good!)
from django.db import connection
cursor = connection.cursor()
cursor.execute("DROP TABLE orders;")  # ERROR: permission denied
```

**But normal operations work:**
```python
# This works fine
order = Order.objects.create(customer="John", total=100)
order.save()
order.delete()
```

### Security
- Store in: `deliverykick/prod/ordering/app`
- Primary user for production
- Rotate password quarterly
- Monitor connection usage

---

## 4️⃣ Read-Only User (`dk_ordering_readonly`)

### Purpose
Analytics, reporting, BI tools, data science. **Cannot modify data**.

### Permissions
```sql
-- Can use schema
GRANT USAGE ON SCHEMA public TO dk_ordering_readonly;

-- Read-only access
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dk_ordering_readonly;

-- Ensure SELECT on future tables
ALTER DEFAULT PRIVILEGES FOR ROLE dk_ordering_admin IN SCHEMA public
  GRANT SELECT ON TABLES TO dk_ordering_readonly;
```

### Can Do
✅ SELECT (read data)
✅ JOIN tables
✅ Run complex queries
✅ Export data

### Cannot Do
❌ INSERT
❌ UPDATE
❌ DELETE
❌ TRUNCATE
❌ CREATE anything

### Connection Limit
```sql
ALTER USER dk_ordering_readonly CONNECTION LIMIT 20;
```
Moderate limit for BI tools and analysts.

### When to Use
- Tableau, Metabase, Looker connections
- Data science notebooks (Jupyter)
- Analytics scripts
- Reporting dashboards
- External partners needing read access

### BI Tool Configuration
```ini
# Metabase connection
Host: deliverykick-prod-cluster.cluster-xxxxx.rds.amazonaws.com
Port: 5432
Database: deliverykick_ordering_prod
User: dk_ordering_readonly
Password: <readonly_password>
```

### Django Settings (Analytics)
```python
# For Django management commands that only read
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'deliverykick_ordering_prod',
        'USER': 'dk_ordering_readonly',  # Read-only user
        'PASSWORD': os.getenv('READONLY_PASSWORD'),
        'HOST': os.getenv('DB_HOST'),
        'PORT': '5432',
    }
}

# Safe analytics
python manage.py report_sales  # Can read orders
python manage.py export_users  # Can read users
```

### Security
- Store in: `deliverykick/prod/ordering/readonly`
- Share with analytics team
- Safe to use for reports
- Cannot accidentally modify production data

---

## 🔒 Security Best Practices

### 1. Never Use Master in Django
```python
# ❌ NEVER DO THIS
DATABASES = {
    'default': {
        'USER': 'postgres',  # DANGEROUS!
    }
}
```

### 2. Separate Migration and Runtime Users
```bash
# ✅ GOOD: Different users for different purposes
# Migrations
DB_USER=dk_ordering_admin python manage.py migrate

# Runtime
DB_USER=dk_ordering_app gunicorn core.wsgi:application
```

### 3. Use Environment Variables
```python
# ✅ GOOD: Never hardcode credentials
DATABASES = {
    'default': {
        'USER': os.getenv('DB_USER'),
        'PASSWORD': os.getenv('DB_PASSWORD'),
    }
}
```

### 4. Store in AWS Secrets Manager
```bash
# Store all credentials securely
aws secretsmanager create-secret \
    --name deliverykick/prod/ordering/app \
    --secret-string '{"username":"dk_ordering_app","password":"..."}'
```

### 5. Connection Limits
```sql
-- Prevent resource exhaustion
ALTER USER dk_ordering_admin CONNECTION LIMIT 5;   -- Low for migrations
ALTER USER dk_ordering_app CONNECTION LIMIT 50;    -- Standard for app
ALTER USER dk_ordering_readonly CONNECTION LIMIT 20; -- Moderate for BI
```

### 6. Monitor User Activity
```sql
-- See who's connected
SELECT
    usename,
    application_name,
    client_addr,
    state,
    COUNT(*) as connections
FROM pg_stat_activity
WHERE datname = 'deliverykick_ordering_prod'
GROUP BY usename, application_name, client_addr, state
ORDER BY connections DESC;
```

### 7. Regular Password Rotation
```bash
# Rotate every 90 days
# 1. Generate new password
# 2. Update in database
ALTER USER dk_ordering_app WITH PASSWORD 'new_password';

# 3. Update in Secrets Manager
aws secretsmanager update-secret --secret-id deliverykick/prod/ordering/app

# 4. Redeploy application with new secret
```

---

## 📋 Deployment Workflows

### CI/CD Pipeline (GitHub Actions)
```yaml
name: Deploy

jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - name: Run Migrations
        env:
          DB_USER: dk_ordering_admin
          DB_PASSWORD: ${{ secrets.DB_ADMIN_PASSWORD }}
        run: python manage.py migrate

  deploy:
    needs: migrate
    runs-on: ubuntu-latest
    steps:
      - name: Deploy Application
        env:
          DB_USER: dk_ordering_app
          DB_PASSWORD: ${{ secrets.DB_APP_PASSWORD }}
        run: |
          docker build -t myapp .
          docker push myapp
          kubectl set env deployment/myapp \
            DB_USER=dk_ordering_app \
            DB_PASSWORD=${{ secrets.DB_APP_PASSWORD }}
```

### Docker Compose
```yaml
version: '3.8'
services:
  migrate:
    image: myapp
    environment:
      DB_USER: dk_ordering_admin
      DB_PASSWORD_FILE: /run/secrets/db_admin_password
    command: python manage.py migrate
    secrets:
      - db_admin_password

  web:
    image: myapp
    environment:
      DB_USER: dk_ordering_app
      DB_PASSWORD_FILE: /run/secrets/db_app_password
    command: gunicorn core.wsgi:application
    secrets:
      - db_app_password

secrets:
  db_admin_password:
    external: true
  db_app_password:
    external: true
```

### Kubernetes
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-admin-credentials
stringData:
  username: dk_ordering_admin
  password: <admin-password>
---
apiVersion: v1
kind: Secret
metadata:
  name: db-app-credentials
stringData:
  username: dk_ordering_app
  password: <app-password>
---
apiVersion: batch/v1
kind: Job
metadata:
  name: django-migrate
spec:
  template:
    spec:
      containers:
      - name: migrate
        image: myapp
        env:
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: db-admin-credentials
              key: username
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-admin-credentials
              key: password
        command: ["python", "manage.py", "migrate"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: django-app
spec:
  containers:
  - name: app
    image: myapp
    env:
    - name: DB_USER
      valueFrom:
        secretKeyRef:
          name: db-app-credentials
          key: username
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-app-credentials
          key: password
```

---

## 🧪 Testing Permissions

### Test Admin User (Should Succeed)
```bash
psql -h $ENDPOINT -U dk_ordering_admin -d deliverykick_ordering_prod << EOF
-- Should work
CREATE TABLE test_admin (id INT);
ALTER TABLE test_admin ADD COLUMN name VARCHAR(100);
DROP TABLE test_admin;
EOF
```

### Test App User (Should Fail)
```bash
psql -h $ENDPOINT -U dk_ordering_app -d deliverykick_ordering_prod << EOF
-- Should fail with "permission denied"
CREATE TABLE test_fail (id INT);
-- ERROR: permission denied for schema public

-- Should work
INSERT INTO orders (customer, total) VALUES ('Test', 100);
SELECT * FROM orders WHERE customer = 'Test';
DELETE FROM orders WHERE customer = 'Test';
EOF
```

### Test Read-Only User (Should Fail)
```bash
psql -h $ENDPOINT -U dk_ordering_readonly -d deliverykick_ordering_prod << EOF
-- Should work
SELECT * FROM orders LIMIT 10;

-- Should fail
INSERT INTO orders (customer, total) VALUES ('Test', 100);
-- ERROR: permission denied for table orders

UPDATE orders SET total = 200 WHERE id = 1;
-- ERROR: permission denied for table orders

DELETE FROM orders WHERE id = 1;
-- ERROR: permission denied for table orders
EOF
```

---

## 📊 Monitoring & Auditing

### View Current Connections
```sql
SELECT
    usename as user,
    application_name,
    client_addr,
    state,
    COUNT(*) as connections
FROM pg_stat_activity
WHERE datname = 'deliverykick_ordering_prod'
GROUP BY usename, application_name, client_addr, state;
```

### Check Connection Limits
```sql
SELECT
    rolname as user,
    rolconnlimit as connection_limit,
    (SELECT COUNT(*) FROM pg_stat_activity WHERE usename = rolname) as current_connections
FROM pg_roles
WHERE rolname IN ('dk_ordering_admin', 'dk_ordering_app', 'dk_ordering_readonly');
```

### Audit User Permissions
```sql
-- Check table permissions
SELECT
    grantee,
    table_schema,
    table_name,
    privilege_type
FROM information_schema.table_privileges
WHERE grantee IN ('dk_ordering_admin', 'dk_ordering_app', 'dk_ordering_readonly')
  AND table_schema = 'public'
ORDER BY grantee, table_name;
```

---

## ⚠️ Common Mistakes

### Mistake 1: Using Admin User in Production
```python
# ❌ WRONG
DATABASES = {
    'default': {
        'USER': 'dk_ordering_admin',  # DON'T USE ADMIN IN PRODUCTION!
    }
}

# ✅ CORRECT
DATABASES = {
    'default': {
        'USER': 'dk_ordering_app',  # Use application user
    }
}
```

### Mistake 2: Granting Too Many Permissions
```sql
-- ❌ WRONG
GRANT ALL PRIVILEGES ON ALL TABLES TO dk_ordering_app;

-- ✅ CORRECT
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES TO dk_ordering_app;
```

### Mistake 3: Not Setting Connection Limits
```sql
-- ❌ WRONG
CREATE USER dk_ordering_app;

-- ✅ CORRECT
CREATE USER dk_ordering_app;
ALTER USER dk_ordering_app CONNECTION LIMIT 50;
```

### Mistake 4: Hardcoding Credentials
```python
# ❌ WRONG
DATABASES = {
    'default': {
        'PASSWORD': 'my_password_123',  # Never hardcode!
    }
}

# ✅ CORRECT
DATABASES = {
    'default': {
        'PASSWORD': os.getenv('DB_PASSWORD'),
    }
}
```

---

## 📚 Resources

- [PostgreSQL Role Management](https://www.postgresql.org/docs/current/user-manag.html)
- [AWS RDS IAM Authentication](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html)
- [Django Multiple Databases](https://docs.djangoproject.com/en/stable/topics/db/multi-db/)
- [PostgreSQL Security Best Practices](https://www.postgresql.org/docs/current/ddl-priv.html)

---

**Version**: 1.0
**Last Updated**: 2025-10-09
**Maintained By**: DevOps Team
