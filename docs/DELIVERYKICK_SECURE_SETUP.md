# DeliveryKick Secure Aurora Setup
## Production-Ready Database with 4-User Security Model

## 🎯 What This Does

Creates **ONE Aurora cluster** with **TWO databases** (ordering & restaurant), each with **4 security users**:

```
Aurora Cluster: deliverykick-prod-cluster
├── deliverykick_ordering_prod
│   ├── postgres (master) - Emergency only
│   ├── dk_ordering_admin - Migrations (5 connections)
│   ├── dk_ordering_app - Runtime (50 connections) ⭐ Main
│   └── dk_ordering_readonly - Analytics (20 connections)
│
└── deliverykick_restaurant_prod
    ├── postgres (master) - Emergency only
    ├── dk_restaurant_admin - Migrations (5 connections)
    ├── dk_restaurant_app - Runtime (50 connections) ⭐ Main
    └── dk_restaurant_readonly - Analytics (20 connections)
```

## 🔐 Security Benefits

✅ **Application cannot drop tables** (app user has no CREATE/DROP)
✅ **Clear separation of duties** (migrations vs runtime)
✅ **Audit trail** (know which user did what)
✅ **Analytics access** (dedicated read-only user)
✅ **Least privilege** (each user has minimum permissions)
✅ **Connection limits** (prevents resource exhaustion)

---

## 🚀 One-Command Setup

### Run This Once

```bash
# Set passwords (or script will prompt)
export AURORA_MASTER_PASSWORD="MasterSecurePass123!"
export ORDERING_ADMIN_PASSWORD="OrderingAdminPass456"
export ORDERING_APP_PASSWORD="OrderingAppPass789"
export ORDERING_READONLY_PASSWORD="OrderingReadonlyPass012"
export RESTAURANT_ADMIN_PASSWORD="RestaurantAdminPass345"
export RESTAURANT_APP_PASSWORD="RestaurantAppPass678"
export RESTAURANT_READONLY_PASSWORD="RestaurantReadonlyPass901"

# Create everything
./scripts/deployment/setup-deliverykick-secure.sh
```

**Time**: ~20 minutes
**Creates**: 1 cluster + 2 databases + 8 users + all configs

---

## 📦 What Gets Created

### Infrastructure
✅ Aurora Serverless v2 cluster (PostgreSQL 15.4)
✅ VPC, subnets, security groups
✅ 7-day automated backups
✅ CloudWatch monitoring

### Users & Permissions

| User Type | Purpose | Permissions | Connections |
|-----------|---------|-------------|-------------|
| **Master** | Emergency | SUPERUSER | Unlimited |
| **Admin** | Migrations | CREATE/ALTER/DROP | 5 |
| **Application** | Runtime | SELECT/INSERT/UPDATE/DELETE | 50 |
| **Read-Only** | Analytics | SELECT only | 20 |

### Secrets Stored (AWS Secrets Manager)
- `deliverykick/prod/master`
- `deliverykick/prod/ordering/admin`
- `deliverykick/prod/ordering/app`
- `deliverykick/prod/ordering/readonly`
- `deliverykick/prod/restaurant/admin`
- `deliverykick/prod/restaurant/app`
- `deliverykick/prod/restaurant/readonly`

### Config Files Generated (`aurora-config-secure/`)
- `ordering-admin.env` - For migrations
- `ordering-app.env` - For Django runtime ⭐
- `ordering-readonly.env` - For analytics
- `restaurant-admin.env` - For migrations
- `restaurant-app.env` - For Django runtime ⭐
- `restaurant-readonly.env` - For analytics
- `CONNECTION_DETAILS_SECURE.md` - Complete guide

---

## 🔧 Usage in This Repo (Ordering)

### Step 1: Run Migrations (Admin User)

```bash
# Use admin user for migrations
cp aurora-config-secure/ordering-admin.env .env.migrations

# Run migrations
export $(cat .env.migrations | xargs)
python manage.py migrate

# Or inline:
DB_USER=dk_ordering_admin DB_PASSWORD=$ORDERING_ADMIN_PASSWORD python manage.py migrate
```

**Why admin user?**
- Can CREATE/ALTER/DROP tables
- Django migrations need these permissions
- Only used during deployment

### Step 2: Run Application (App User)

```bash
# Use application user for runtime
cp aurora-config-secure/ordering-app.env .env

# Run Django
python manage.py runserver

# Or production
gunicorn core.wsgi:application
```

**Why app user?**
- Can SELECT/INSERT/UPDATE/DELETE data
- **Cannot drop tables** (safer!)
- Main user for production

### Step 3: Update Django Settings

Your `core/settings/database.py` already uses environment variables:

```python
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('DB_NAME'),  # deliverykick_ordering_prod
        'USER': os.getenv('DB_USER'),  # dk_ordering_app (runtime)
        'PASSWORD': os.getenv('DB_PASSWORD'),
        'HOST': os.getenv('DB_HOST_SERVER'),
        'PORT': os.getenv('DB_PORT', '5432'),
        'OPTIONS': {
            'sslmode': 'require',
        },
        'CONN_MAX_AGE': 600,
    }
}
```

**No code changes needed!** Just use different `.env` files.

---

## 📤 Share with Restaurant Repo

### Send These Files

```bash
# Securely share these with restaurant team
aurora-config-secure/restaurant-admin.env
aurora-config-secure/restaurant-app.env
aurora-config-secure/restaurant-readonly.env
aurora-config-secure/CONNECTION_DETAILS_SECURE.md
```

### In Restaurant Repo

```bash
# Step 1: Migrations (admin user)
cp restaurant-admin.env .env.migrations
export $(cat .env.migrations | xargs)
python manage.py migrate

# Step 2: Runtime (app user)
cp restaurant-app.env .env
python manage.py runserver
```

---

## 🎭 Different Users for Different Tasks

### Migrations (Admin User)
```bash
# LOCAL: Making schema changes
export DB_USER=dk_ordering_admin
export DB_PASSWORD=$ORDERING_ADMIN_PASSWORD
python manage.py makemigrations
python manage.py migrate
```

### Production Runtime (App User)
```bash
# PRODUCTION: Running the application
export DB_USER=dk_ordering_app
export DB_PASSWORD=$ORDERING_APP_PASSWORD
gunicorn core.wsgi:application
```

### Analytics (Read-Only User)
```bash
# ANALYTICS: Safe reporting
export DB_USER=dk_ordering_readonly
export DB_PASSWORD=$ORDERING_READONLY_PASSWORD
python manage.py report_sales
```

### Emergency (Master User)
```bash
# EMERGENCY ONLY: Manual fixes (rare!)
psql -h $AURORA_ENDPOINT -U postgres -d deliverykick_ordering_prod
```

---

## 🔐 Security in Action

### Application User Cannot Drop Tables

```python
# This code is SAFE with app user
from django.db import connection

# This will FAIL (permission denied) ✅
cursor = connection.cursor()
cursor.execute("DROP TABLE orders;")
# ERROR: permission denied for table orders

# But normal operations work fine ✅
order = Order.objects.create(customer="John", total=100)
order.save()  # Works
order.delete()  # Works
```

### Read-Only User Cannot Write

```python
# With readonly user, writes fail ✅
order = Order.objects.create(customer="John", total=100)
# ERROR: permission denied for table orders

# But reads work ✅
orders = Order.objects.all()  # Works
total = Order.objects.aggregate(Sum('total'))  # Works
```

---

## 🚀 CI/CD Pipeline Example

### GitHub Actions

```yaml
name: Deploy Ordering App

on:
  push:
    branches: [main]

jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2

      - name: Run Migrations
        env:
          DB_USER: dk_ordering_admin
          DB_PASSWORD: ${{ secrets.DB_ADMIN_PASSWORD }}
          DB_HOST_SERVER: ${{ secrets.DB_HOST }}
          DB_NAME: deliverykick_ordering_prod
        run: |
          python manage.py migrate

  deploy:
    needs: migrate
    runs-on: ubuntu-latest
    steps:
      - name: Deploy Application
        env:
          DB_USER: dk_ordering_app  # Different user!
          DB_PASSWORD: ${{ secrets.DB_APP_PASSWORD }}
          DB_HOST_SERVER: ${{ secrets.DB_HOST }}
          DB_NAME: deliverykick_ordering_prod
        run: |
          # Build and deploy with app user
          docker build -t ordering-app .
          docker push ordering-app:latest
          kubectl rollout restart deployment/ordering-app
```

### Key Points:
1. **Migrations use admin user** (can modify schema)
2. **Application uses app user** (cannot drop tables)
3. **Different secrets for different users**

---

## 📊 Monitoring

### View Connections by User

```sql
-- Connect as master user
psql -h <aurora-endpoint> -U postgres -d deliverykick_ordering_prod

-- View who's connected
SELECT
    usename as user,
    state,
    COUNT(*) as connections,
    MAX(state_change) as last_activity
FROM pg_stat_activity
WHERE datname = 'deliverykick_ordering_prod'
GROUP BY usename, state
ORDER BY connections DESC;

-- Expected output:
-- user              | state  | connections | last_activity
-- dk_ordering_app   | active | 45          | 2025-10-09 12:00:00
-- dk_ordering_admin | idle   | 0           | 2025-10-08 10:00:00
-- dk_ordering_readonly | active | 5        | 2025-10-09 11:55:00
```

### Check Connection Limits

```sql
SELECT
    rolname as user,
    rolconnlimit as limit,
    (SELECT COUNT(*) FROM pg_stat_activity WHERE usename = rolname) as current
FROM pg_roles
WHERE rolname LIKE 'dk_ordering%'
ORDER BY rolname;

-- user               | limit | current
-- dk_ordering_admin  | 5     | 0
-- dk_ordering_app    | 50    | 45
-- dk_ordering_readonly | 20   | 5
```

---

## 🧪 Testing Permissions

### Test Script Generated

After setup, use the test script:

```bash
# Test all users have correct permissions
./scripts/utilities/test-db-permissions.sh
```

### Manual Testing

```bash
# Test app user CANNOT drop tables (should fail)
psql -h <endpoint> -U dk_ordering_app -d deliverykick_ordering_prod \
  -c "DROP TABLE django_migrations;"
# ERROR: permission denied ✅

# Test app user CAN read/write (should succeed)
psql -h <endpoint> -U dk_ordering_app -d deliverykick_ordering_prod \
  -c "SELECT COUNT(*) FROM django_migrations;"
# (count) ✅

# Test readonly CANNOT write (should fail)
psql -h <endpoint> -U dk_ordering_readonly -d deliverykick_ordering_prod \
  -c "DELETE FROM django_migrations WHERE id = 1;"
# ERROR: permission denied ✅

# Test admin CAN create tables (should succeed)
psql -h <endpoint> -U dk_ordering_admin -d deliverykick_ordering_prod \
  -c "CREATE TABLE test_table (id INT);"
# CREATE TABLE ✅
```

---

## 💰 Cost

Same as non-secure version - just better security!

| Usage | Monthly Cost |
|-------|--------------|
| **Idle** (0.5 ACU) | ~$43 |
| **Low** (1 ACU) | ~$86 |
| **Medium** (2 ACU) | ~$172 |

**Shared between both apps** = ~$43-86 per app

---

## 🔄 Password Rotation

### Quarterly Password Rotation

```bash
# 1. Generate new password
NEW_PASSWORD=$(openssl rand -base64 32)

# 2. Update in database
psql -h <endpoint> -U postgres -d postgres -c \
  "ALTER USER dk_ordering_app WITH PASSWORD '$NEW_PASSWORD';"

# 3. Update in Secrets Manager
aws secretsmanager update-secret \
    --secret-id deliverykick/prod/ordering/app \
    --secret-string "{\"username\":\"dk_ordering_app\",\"password\":\"$NEW_PASSWORD\",\"host\":\"...\",\"port\":5432,\"dbname\":\"deliverykick_ordering_prod\"}"

# 4. Update application config and redeploy
kubectl set env deployment/ordering-app DB_PASSWORD=$NEW_PASSWORD
kubectl rollout restart deployment/ordering-app
```

---

## ⚠️ Common Mistakes to Avoid

### ❌ Mistake 1: Using Admin User in Production

```python
# WRONG - Admin user in production
DATABASES = {
    'default': {
        'USER': 'dk_ordering_admin',  # DON'T DO THIS!
    }
}
```

**Why wrong?** Admin user can drop tables. Use app user instead.

### ❌ Mistake 2: Not Separating Migration and Runtime

```bash
# WRONG - Same user for everything
DB_USER=dk_ordering_app python manage.py migrate  # Will fail!
```

**Why wrong?** App user cannot CREATE tables. Use admin user for migrations.

### ❌ Mistake 3: Hardcoding Passwords

```python
# WRONG
DATABASES = {
    'default': {
        'PASSWORD': 'my_password_123',  # Never hardcode!
    }
}

# RIGHT
DATABASES = {
    'default': {
        'PASSWORD': os.getenv('DB_PASSWORD'),
    }
}
```

---

## 📋 Checklist

### After Running Setup

- [ ] Aurora cluster created
- [ ] 8 users created (4 per database)
- [ ] Credentials stored in Secrets Manager
- [ ] Config files generated in `aurora-config-secure/`
- [ ] Can connect with admin user
- [ ] Can connect with app user
- [ ] Can connect with readonly user

### In This Repo (Ordering)

- [ ] Run migrations with admin user
- [ ] Migrations succeed
- [ ] Copy app user config to `.env`
- [ ] Django runs with app user
- [ ] Tested CRUD operations work
- [ ] Verified app user cannot drop tables

### In Restaurant Repo

- [ ] Shared config files with team
- [ ] Restaurant team ran migrations (admin user)
- [ ] Restaurant team configured runtime (app user)
- [ ] Restaurant app running successfully

### Production Readiness

- [ ] CloudWatch alarms configured
- [ ] Connection monitoring set up
- [ ] Backup retention verified (7 days)
- [ ] Password rotation scheduled (quarterly)
- [ ] Security documentation reviewed
- [ ] Team trained on user types

---

## 📚 Documentation

| Document | Purpose |
|----------|---------|
| **[This File]** | Quick start guide |
| [POSTGRES_USER_SECURITY.md](docs/POSTGRES_USER_SECURITY.md) | Detailed security model |
| [CONNECTION_DETAILS_SECURE.md](aurora-config-secure/CONNECTION_DETAILS_SECURE.md) | All connection details |
| [AURORA_QUICK_REFERENCE.md](docs/AURORA_QUICK_REFERENCE.md) | Quick commands |

---

## 🆘 Troubleshooting

### Cannot Run Migrations

**Error**: `permission denied for schema public`

**Solution**: Use admin user for migrations:
```bash
DB_USER=dk_ordering_admin python manage.py migrate
```

### Application Cannot Drop Tables

**Error**: `permission denied for table orders`

**This is CORRECT!** App user should not drop tables. This is a security feature.

### Too Many Connections

**Error**: `FATAL: too many connections for user "dk_ordering_app"`

**Solution**: Check connection limit:
```sql
ALTER USER dk_ordering_app CONNECTION LIMIT 100;
```

Or use connection pooling (PgBouncer, RDS Proxy).

### Lost Credentials

Get from Secrets Manager:
```bash
aws secretsmanager get-secret-value \
    --secret-id deliverykick/prod/ordering/app \
    --query 'SecretString' --output text | jq
```

---

## 🎉 Success!

When complete, you have:

✅ Secure Aurora cluster with proper user permissions
✅ Application cannot accidentally drop tables
✅ Clear separation between migrations and runtime
✅ Dedicated read-only access for analytics
✅ All credentials securely stored
✅ Both apps ready to stream data to production

**Next Steps:**
1. Test in staging environment first
2. Run migrations
3. Deploy application
4. Monitor connections and performance
5. Set up alerts

---

**Questions?** See [POSTGRES_USER_SECURITY.md](docs/POSTGRES_USER_SECURITY.md) for detailed security information.

**Support**: CloudWatch logs at `/aws/rds/cluster/deliverykick-prod-cluster`
