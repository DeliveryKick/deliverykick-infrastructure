#!/bin/bash
set -e

# DeliveryKick Secure Aurora Cluster Setup
# Creates Aurora cluster with proper PostgreSQL security model:
# - Master user (emergency only)
# - Admin user (migrations/schema changes)
# - Application user (runtime read/write)
# - Read-only user (analytics/BI)
#
# Usage: ./setup-deliverykick-secure.sh

echo "========================================="
echo "DeliveryKick Secure Aurora Setup"
echo "PostgreSQL 4-User Security Model"
echo "========================================="

# Configuration
CLUSTER_IDENTIFIER="${AURORA_CLUSTER_ID:-deliverykick-prod-cluster}"
MASTER_USERNAME="${AURORA_MASTER_USER:-postgres}"
MASTER_PASSWORD="${AURORA_MASTER_PASSWORD}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MIN_CAPACITY="${AURORA_MIN_CAPACITY:-0.5}"
MAX_CAPACITY="${AURORA_MAX_CAPACITY:-2}"

# User passwords (can be set via environment variables)
ORDERING_ADMIN_PASSWORD="${ORDERING_ADMIN_PASSWORD}"
ORDERING_APP_PASSWORD="${ORDERING_APP_PASSWORD}"
ORDERING_READONLY_PASSWORD="${ORDERING_READONLY_PASSWORD}"

RESTAURANT_ADMIN_PASSWORD="${RESTAURANT_ADMIN_PASSWORD}"
RESTAURANT_APP_PASSWORD="${RESTAURANT_APP_PASSWORD}"
RESTAURANT_READONLY_PASSWORD="${RESTAURANT_READONLY_PASSWORD}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${BLUE}Security Model (Per Database):${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Master User    - Emergency only (NEVER in Django)"
echo "2. Admin User     - Migrations only (CREATE/ALTER/DROP)"
echo "3. Application User - Runtime (SELECT/INSERT/UPDATE/DELETE)"
echo "4. Read-Only User - Analytics (SELECT only)"
echo ""
echo -e "${CYAN}This creates 8 users total (4 per database)${NC}"
echo ""

# Prompt for passwords if not set
if [ -z "$MASTER_PASSWORD" ]; then
    read -sp "Enter Aurora master password: " MASTER_PASSWORD
    echo
fi

if [ -z "$ORDERING_ADMIN_PASSWORD" ]; then
    read -sp "Enter ordering admin password (migrations): " ORDERING_ADMIN_PASSWORD
    echo
fi

if [ -z "$ORDERING_APP_PASSWORD" ]; then
    read -sp "Enter ordering app password (runtime): " ORDERING_APP_PASSWORD
    echo
fi

if [ -z "$ORDERING_READONLY_PASSWORD" ]; then
    read -sp "Enter ordering readonly password (analytics): " ORDERING_READONLY_PASSWORD
    echo
fi

if [ -z "$RESTAURANT_ADMIN_PASSWORD" ]; then
    read -sp "Enter restaurant admin password (migrations): " RESTAURANT_ADMIN_PASSWORD
    echo
fi

if [ -z "$RESTAURANT_APP_PASSWORD" ]; then
    read -sp "Enter restaurant app password (runtime): " RESTAURANT_APP_PASSWORD
    echo
fi

if [ -z "$RESTAURANT_READONLY_PASSWORD" ]; then
    read -sp "Enter restaurant readonly password (analytics): " RESTAURANT_READONLY_PASSWORD
    echo
fi

echo ""
read -p "Continue with setup? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Setup cancelled."
    exit 0
fi

#==============================================================================
# PHASE 1: CREATE AURORA CLUSTER
#==============================================================================

echo ""
echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}PHASE 1: Aurora Cluster Setup${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"

# Check if cluster exists
CLUSTER_STATUS=$(aws rds describe-db-clusters \
    --db-cluster-identifier $CLUSTER_IDENTIFIER \
    --region $AWS_REGION \
    --query 'DBClusters[0].Status' \
    --output text 2>/dev/null || echo "not-found")

if [ "$CLUSTER_STATUS" = "not-found" ]; then
    echo -e "${BLUE}Creating Aurora Serverless v2 cluster...${NC}"

    # Get VPC
    VPC_ID=$(aws ec2 describe-vpcs \
        --region $AWS_REGION \
        --filters "Name=isDefault,Values=false" \
        --query 'Vpcs[0].VpcId' \
        --output text)

    if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
        VPC_ID=$(aws ec2 describe-vpcs \
            --region $AWS_REGION \
            --filters "Name=isDefault,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text)
    fi

    # Get subnets
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --region $AWS_REGION \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[*].SubnetId' \
        --output text)

    # Create subnet group
    SUBNET_GROUP="${CLUSTER_IDENTIFIER}-subnet-group"
    aws rds create-db-subnet-group \
        --db-subnet-group-name $SUBNET_GROUP \
        --db-subnet-group-description "DeliveryKick subnet group" \
        --subnet-ids $SUBNET_IDS \
        --region $AWS_REGION \
        2>/dev/null || echo "Subnet group exists"

    # Create security group
    SECURITY_GROUP="${CLUSTER_IDENTIFIER}-sg"
    SG_ID=$(aws ec2 create-security-group \
        --group-name $SECURITY_GROUP \
        --description "DeliveryKick Aurora security group" \
        --vpc-id $VPC_ID \
        --region $AWS_REGION \
        --query 'GroupId' \
        --output text 2>/dev/null || \
        aws ec2 describe-security-groups \
            --region $AWS_REGION \
            --filters "Name=group-name,Values=$SECURITY_GROUP" \
            --query 'SecurityGroups[0].GroupId' \
            --output text)

    # Configure security group
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 5432 \
        --cidr 10.0.0.0/8 \
        --region $AWS_REGION \
        2>/dev/null || echo "VPC rule exists"

    CURRENT_IP=$(curl -s https://checkip.amazonaws.com)
    if [ ! -z "$CURRENT_IP" ]; then
        aws ec2 authorize-security-group-ingress \
            --group-id $SG_ID \
            --protocol tcp \
            --port 5432 \
            --cidr "$CURRENT_IP/32" \
            --region $AWS_REGION \
            2>/dev/null || echo "Current IP rule exists"
    fi

    # Create cluster
    echo -e "${YELLOW}Creating cluster (10-15 minutes)...${NC}"
    aws rds create-db-cluster \
        --db-cluster-identifier $CLUSTER_IDENTIFIER \
        --engine aurora-postgresql \
        --engine-version 15.4 \
        --master-username $MASTER_USERNAME \
        --master-user-password "$MASTER_PASSWORD" \
        --vpc-security-group-ids $SG_ID \
        --db-subnet-group-name $SUBNET_GROUP \
        --serverless-v2-scaling-configuration MinCapacity=$MIN_CAPACITY,MaxCapacity=$MAX_CAPACITY \
        --backup-retention-period 7 \
        --enable-http-endpoint \
        --region $AWS_REGION \
        --tags Key=Environment,Value=production Key=Project,Value=deliverykick

    aws rds wait db-cluster-available \
        --db-cluster-identifier $CLUSTER_IDENTIFIER \
        --region $AWS_REGION

    # Create instance
    aws rds create-db-instance \
        --db-instance-identifier "${CLUSTER_IDENTIFIER}-instance-1" \
        --db-instance-class db.serverless \
        --engine aurora-postgresql \
        --db-cluster-identifier $CLUSTER_IDENTIFIER \
        --publicly-accessible \
        --region $AWS_REGION

    aws rds wait db-instance-available \
        --db-instance-identifier "${CLUSTER_IDENTIFIER}-instance-1" \
        --region $AWS_REGION

    echo -e "${GREEN}✓ Cluster created${NC}"
else
    echo -e "${GREEN}✓ Cluster exists (Status: $CLUSTER_STATUS)${NC}"
fi

# Get endpoints
AURORA_ENDPOINT=$(aws rds describe-db-clusters \
    --db-cluster-identifier $CLUSTER_IDENTIFIER \
    --region $AWS_REGION \
    --query 'DBClusters[0].Endpoint' \
    --output text)

READER_ENDPOINT=$(aws rds describe-db-clusters \
    --db-cluster-identifier $CLUSTER_IDENTIFIER \
    --region $AWS_REGION \
    --query 'DBClusters[0].ReaderEndpoint' \
    --output text)

echo "Writer: $AURORA_ENDPOINT"
echo "Reader: $READER_ENDPOINT"

#==============================================================================
# PHASE 2: SETUP ORDERING DATABASE WITH SECURE USERS
#==============================================================================

echo ""
echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}PHASE 2: Ordering Database (Secure)${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"

DB_ORDERING="deliverykick_ordering_prod"
USER_ADMIN="dk_ordering_admin"
USER_APP="dk_ordering_app"
USER_READONLY="dk_ordering_readonly"

# Create database
echo "Creating database: $DB_ORDERING"
PGPASSWORD="$MASTER_PASSWORD" psql -h "$AURORA_ENDPOINT" -U "$MASTER_USERNAME" -d postgres << EOF
CREATE DATABASE $DB_ORDERING;
EOF

# Create admin user (for migrations)
echo "Creating admin user: $USER_ADMIN (migrations)"
PGPASSWORD="$MASTER_PASSWORD" psql -h "$AURORA_ENDPOINT" -U "$MASTER_USERNAME" -d postgres << EOF
-- Admin user for migrations
CREATE USER $USER_ADMIN WITH PASSWORD '$ORDERING_ADMIN_PASSWORD';
GRANT CONNECT ON DATABASE $DB_ORDERING TO $USER_ADMIN;
ALTER USER $USER_ADMIN CONNECTION LIMIT 5;  -- Low limit, only for migrations
COMMENT ON ROLE $USER_ADMIN IS 'Admin user for running migrations - can CREATE/ALTER/DROP tables';
EOF

# Create application user (for runtime)
echo "Creating application user: $USER_APP (runtime)"
PGPASSWORD="$MASTER_PASSWORD" psql -h "$AURORA_ENDPOINT" -U "$MASTER_USERNAME" -d postgres << EOF
-- Application user for runtime
CREATE USER $USER_APP WITH PASSWORD '$ORDERING_APP_PASSWORD';
GRANT CONNECT ON DATABASE $DB_ORDERING TO $USER_APP;
ALTER USER $USER_APP CONNECTION LIMIT 50;  -- Standard limit for application
COMMENT ON ROLE $USER_APP IS 'Application user for Django runtime - SELECT/INSERT/UPDATE/DELETE only';
EOF

# Create read-only user (for analytics)
echo "Creating read-only user: $USER_READONLY (analytics)"
PGPASSWORD="$MASTER_PASSWORD" psql -h "$AURORA_ENDPOINT" -U "$MASTER_USERNAME" -d postgres << EOF
-- Read-only user for analytics
CREATE USER $USER_READONLY WITH PASSWORD '$ORDERING_READONLY_PASSWORD';
GRANT CONNECT ON DATABASE $DB_ORDERING TO $USER_READONLY;
ALTER USER $USER_READONLY CONNECTION LIMIT 20;  -- Moderate limit for BI tools
COMMENT ON ROLE $USER_READONLY IS 'Read-only user for analytics - SELECT only';
EOF

# Set permissions in the database
echo "Configuring permissions..."
PGPASSWORD="$MASTER_PASSWORD" psql -h "$AURORA_ENDPOINT" -U "$MASTER_USERNAME" -d "$DB_ORDERING" << 'EOF'
-- Revoke default public permissions for security
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE ${DB_ORDERING} FROM PUBLIC;

-- ADMIN USER PERMISSIONS (for migrations)
-- Can create/alter/drop tables, indexes, sequences
GRANT CREATE, USAGE ON SCHEMA public TO ${USER_ADMIN};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${USER_ADMIN};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${USER_ADMIN};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${USER_ADMIN};

-- Ensure admin owns future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${USER_ADMIN};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${USER_ADMIN};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${USER_ADMIN};

-- APPLICATION USER PERMISSIONS (for runtime)
-- Can read/write data but NOT alter schema
GRANT USAGE ON SCHEMA public TO ${USER_APP};
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${USER_APP};
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${USER_APP};
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO ${USER_APP};

-- Ensure app user gets permissions on future tables created by admin
ALTER DEFAULT PRIVILEGES FOR ROLE ${USER_ADMIN} IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${USER_APP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${USER_ADMIN} IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO ${USER_APP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${USER_ADMIN} IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO ${USER_APP};

-- READ-ONLY USER PERMISSIONS (for analytics)
-- Can only SELECT data
GRANT USAGE ON SCHEMA public TO ${USER_READONLY};
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${USER_READONLY};

-- Ensure readonly gets SELECT on future tables
ALTER DEFAULT PRIVILEGES FOR ROLE ${USER_ADMIN} IN SCHEMA public
  GRANT SELECT ON TABLES TO ${USER_READONLY};

-- Create monitoring view
CREATE OR REPLACE VIEW db_user_connections AS
SELECT
    usename as username,
    state,
    COUNT(*) as connections,
    MAX(state_change) as last_activity
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY usename, state
ORDER BY connections DESC;

GRANT SELECT ON db_user_connections TO ${USER_APP}, ${USER_READONLY};
EOF

# Replace variables in SQL
PGPASSWORD="$MASTER_PASSWORD" psql -h "$AURORA_ENDPOINT" -U "$MASTER_USERNAME" -d "$DB_ORDERING" \
    -v USER_ADMIN="$USER_ADMIN" \
    -v USER_APP="$USER_APP" \
    -v USER_READONLY="$USER_READONLY" \
    -v DB_ORDERING="$DB_ORDERING" << 'EOF'
-- Apply variables
DO $$
BEGIN
    -- Revoke public
    EXECUTE 'REVOKE CREATE ON SCHEMA public FROM PUBLIC';

    -- Admin permissions
    EXECUTE 'GRANT CREATE, USAGE ON SCHEMA public TO ' || quote_ident(:'USER_ADMIN');
    EXECUTE 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ' || quote_ident(:'USER_ADMIN');
    EXECUTE 'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ' || quote_ident(:'USER_ADMIN');
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ' || quote_ident(:'USER_ADMIN');
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ' || quote_ident(:'USER_ADMIN');

    -- App permissions
    EXECUTE 'GRANT USAGE ON SCHEMA public TO ' || quote_ident(:'USER_APP');
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ' || quote_ident(:'USER_APP');
    EXECUTE 'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ' || quote_ident(:'USER_APP');
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE ' || quote_ident(:'USER_ADMIN') || ' IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ' || quote_ident(:'USER_APP');
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE ' || quote_ident(:'USER_ADMIN') || ' IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ' || quote_ident(:'USER_APP');

    -- Readonly permissions
    EXECUTE 'GRANT USAGE ON SCHEMA public TO ' || quote_ident(:'USER_READONLY');
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO ' || quote_ident(:'USER_READONLY');
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE ' || quote_ident(:'USER_ADMIN') || ' IN SCHEMA public GRANT SELECT ON TABLES TO ' || quote_ident(:'USER_READONLY');
END $$;

-- Monitoring view
CREATE OR REPLACE VIEW db_user_connections AS
SELECT usename, state, COUNT(*) as connections
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY usename, state;
EOF

echo -e "${GREEN}✓ Ordering database configured with secure users${NC}"

#==============================================================================
# PHASE 3: SETUP RESTAURANT DATABASE WITH SECURE USERS
#==============================================================================

echo ""
echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}PHASE 3: Restaurant Database (Secure)${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"

DB_RESTAURANT="deliverykick_restaurant_prod"
USER_ADMIN_REST="dk_restaurant_admin"
USER_APP_REST="dk_restaurant_app"
USER_READONLY_REST="dk_restaurant_readonly"

# Create database
echo "Creating database: $DB_RESTAURANT"
PGPASSWORD="$MASTER_PASSWORD" psql -h "$AURORA_ENDPOINT" -U "$MASTER_USERNAME" -d postgres << EOF
CREATE DATABASE $DB_RESTAURANT;
EOF

# Create users
echo "Creating users for restaurant database..."
PGPASSWORD="$MASTER_PASSWORD" psql -h "$AURORA_ENDPOINT" -U "$MASTER_USERNAME" -d postgres << EOF
CREATE USER $USER_ADMIN_REST WITH PASSWORD '$RESTAURANT_ADMIN_PASSWORD';
GRANT CONNECT ON DATABASE $DB_RESTAURANT TO $USER_ADMIN_REST;
ALTER USER $USER_ADMIN_REST CONNECTION LIMIT 5;

CREATE USER $USER_APP_REST WITH PASSWORD '$RESTAURANT_APP_PASSWORD';
GRANT CONNECT ON DATABASE $DB_RESTAURANT TO $USER_APP_REST;
ALTER USER $USER_APP_REST CONNECTION LIMIT 50;

CREATE USER $USER_READONLY_REST WITH PASSWORD '$RESTAURANT_READONLY_PASSWORD';
GRANT CONNECT ON DATABASE $DB_RESTAURANT TO $USER_READONLY_REST;
ALTER USER $USER_READONLY_REST CONNECTION LIMIT 20;
EOF

# Set permissions
echo "Configuring permissions..."
PGPASSWORD="$MASTER_PASSWORD" psql -h "$AURORA_ENDPOINT" -U "$MASTER_USERNAME" -d "$DB_RESTAURANT" \
    -v USER_ADMIN="$USER_ADMIN_REST" \
    -v USER_APP="$USER_APP_REST" \
    -v USER_READONLY="$USER_READONLY_REST" << 'EOF'
DO $$
BEGIN
    EXECUTE 'REVOKE CREATE ON SCHEMA public FROM PUBLIC';
    EXECUTE 'GRANT CREATE, USAGE ON SCHEMA public TO ' || quote_ident(:'USER_ADMIN');
    EXECUTE 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ' || quote_ident(:'USER_ADMIN');
    EXECUTE 'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ' || quote_ident(:'USER_ADMIN');
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ' || quote_ident(:'USER_ADMIN');
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ' || quote_ident(:'USER_ADMIN');

    EXECUTE 'GRANT USAGE ON SCHEMA public TO ' || quote_ident(:'USER_APP');
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ' || quote_ident(:'USER_APP');
    EXECUTE 'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ' || quote_ident(:'USER_APP');
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE ' || quote_ident(:'USER_ADMIN') || ' IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ' || quote_ident(:'USER_APP');
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE ' || quote_ident(:'USER_ADMIN') || ' IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ' || quote_ident(:'USER_APP');

    EXECUTE 'GRANT USAGE ON SCHEMA public TO ' || quote_ident(:'USER_READONLY');
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO ' || quote_ident(:'USER_READONLY');
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE ' || quote_ident(:'USER_ADMIN') || ' IN SCHEMA public GRANT SELECT ON TABLES TO ' || quote_ident(:'USER_READONLY');
END $$;

CREATE OR REPLACE VIEW db_user_connections AS
SELECT usename, state, COUNT(*) as connections
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY usename, state;
EOF

echo -e "${GREEN}✓ Restaurant database configured with secure users${NC}"

#==============================================================================
# PHASE 4: STORE CREDENTIALS IN SECRETS MANAGER
#==============================================================================

echo ""
echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}PHASE 4: Storing Credentials${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"

# Function to store secret
store_secret() {
    local secret_name=$1
    local secret_json=$2

    aws secretsmanager create-secret \
        --name "$secret_name" \
        --region $AWS_REGION \
        --secret-string "$secret_json" \
        2>/dev/null || \
        aws secretsmanager update-secret \
            --secret-id "$secret_name" \
            --region $AWS_REGION \
            --secret-string "$secret_json"
}

# Master
store_secret "deliverykick/prod/master" "{\"username\":\"$MASTER_USERNAME\",\"password\":\"$MASTER_PASSWORD\",\"host\":\"$AURORA_ENDPOINT\",\"port\":5432}"

# Ordering
store_secret "deliverykick/prod/ordering/admin" "{\"username\":\"$USER_ADMIN\",\"password\":\"$ORDERING_ADMIN_PASSWORD\",\"host\":\"$AURORA_ENDPOINT\",\"port\":5432,\"dbname\":\"$DB_ORDERING\"}"
store_secret "deliverykick/prod/ordering/app" "{\"username\":\"$USER_APP\",\"password\":\"$ORDERING_APP_PASSWORD\",\"host\":\"$AURORA_ENDPOINT\",\"port\":5432,\"dbname\":\"$DB_ORDERING\"}"
store_secret "deliverykick/prod/ordering/readonly" "{\"username\":\"$USER_READONLY\",\"password\":\"$ORDERING_READONLY_PASSWORD\",\"host\":\"$AURORA_ENDPOINT\",\"port\":5432,\"dbname\":\"$DB_ORDERING\"}"

# Restaurant
store_secret "deliverykick/prod/restaurant/admin" "{\"username\":\"$USER_ADMIN_REST\",\"password\":\"$RESTAURANT_ADMIN_PASSWORD\",\"host\":\"$AURORA_ENDPOINT\",\"port\":5432,\"dbname\":\"$DB_RESTAURANT\"}"
store_secret "deliverykick/prod/restaurant/app" "{\"username\":\"$USER_APP_REST\",\"password\":\"$RESTAURANT_APP_PASSWORD\",\"host\":\"$AURORA_ENDPOINT\",\"port\":5432,\"dbname\":\"$DB_RESTAURANT\"}"
store_secret "deliverykick/prod/restaurant/readonly" "{\"username\":\"$USER_READONLY_REST\",\"password\":\"$RESTAURANT_READONLY_PASSWORD\",\"host\":\"$AURORA_ENDPOINT\",\"port\":5432,\"dbname\":\"$DB_RESTAURANT\"}"

echo -e "${GREEN}✓ All credentials stored in Secrets Manager${NC}"

#==============================================================================
# PHASE 5: GENERATE CONFIGURATION FILES
#==============================================================================

echo ""
echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}PHASE 5: Generating Configuration Files${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"

CONFIG_DIR="./aurora-config-secure"
mkdir -p "$CONFIG_DIR"

# Ordering - Admin
cat > "$CONFIG_DIR/ordering-admin.env" << EOF
# Ordering App - ADMIN USER (Migrations Only)
# ⚠️  USE ONLY FOR: python manage.py migrate
# ❌ DO NOT USE FOR: Running Django application

DB_HOST_SERVER=$AURORA_ENDPOINT
DB_PORT=5432
DB_NAME=$DB_ORDERING
DB_USER=$USER_ADMIN
DB_PASSWORD=$ORDERING_ADMIN_PASSWORD
AWS_SECRET_MANAGER_ARN=deliverykick/prod/ordering/admin
EOF

# Ordering - App
cat > "$CONFIG_DIR/ordering-app.env" << EOF
# Ordering App - APPLICATION USER (Runtime)
# ✅ USE FOR: Running Django application in production
# ✅ Permissions: SELECT, INSERT, UPDATE, DELETE (NO schema changes)

DB_HOST_SERVER=$AURORA_ENDPOINT
DB_PORT=5432
DB_NAME=$DB_ORDERING
DB_USER=$USER_APP
DB_PASSWORD=$ORDERING_APP_PASSWORD
AWS_SECRET_MANAGER_ARN=deliverykick/prod/ordering/app
DATABASE_URL=postgresql://$USER_APP:$ORDERING_APP_PASSWORD@$AURORA_ENDPOINT:5432/$DB_ORDERING
EOF

# Ordering - Readonly
cat > "$CONFIG_DIR/ordering-readonly.env" << EOF
# Ordering App - READ-ONLY USER (Analytics)
# ✅ USE FOR: BI tools, analytics, reporting
# ✅ Permissions: SELECT only

DB_HOST_SERVER=$AURORA_ENDPOINT
DB_PORT=5432
DB_NAME=$DB_ORDERING
DB_USER=$USER_READONLY
DB_PASSWORD=$ORDERING_READONLY_PASSWORD
AWS_SECRET_MANAGER_ARN=deliverykick/prod/ordering/readonly
DATABASE_URL=postgresql://$USER_READONLY:$ORDERING_READONLY_PASSWORD@$AURORA_ENDPOINT:5432/$DB_ORDERING
EOF

# Restaurant - Admin
cat > "$CONFIG_DIR/restaurant-admin.env" << EOF
# Restaurant App - ADMIN USER (Migrations Only)
DB_HOST_SERVER=$AURORA_ENDPOINT
DB_PORT=5432
DB_NAME=$DB_RESTAURANT
DB_USER=$USER_ADMIN_REST
DB_PASSWORD=$RESTAURANT_ADMIN_PASSWORD
AWS_SECRET_MANAGER_ARN=deliverykick/prod/restaurant/admin
EOF

# Restaurant - App
cat > "$CONFIG_DIR/restaurant-app.env" << EOF
# Restaurant App - APPLICATION USER (Runtime)
DB_HOST_SERVER=$AURORA_ENDPOINT
DB_PORT=5432
DB_NAME=$DB_RESTAURANT
DB_USER=$USER_APP_REST
DB_PASSWORD=$RESTAURANT_APP_PASSWORD
AWS_SECRET_MANAGER_ARN=deliverykick/prod/restaurant/app
DATABASE_URL=postgresql://$USER_APP_REST:$RESTAURANT_APP_PASSWORD@$AURORA_ENDPOINT:5432/$DB_RESTAURANT
EOF

# Restaurant - Readonly
cat > "$CONFIG_DIR/restaurant-readonly.env" << EOF
# Restaurant App - READ-ONLY USER (Analytics)
DB_HOST_SERVER=$AURORA_ENDPOINT
DB_PORT=5432
DB_NAME=$DB_RESTAURANT
DB_USER=$USER_READONLY_REST
DB_PASSWORD=$RESTAURANT_READONLY_PASSWORD
AWS_SECRET_MANAGER_ARN=deliverykick/prod/restaurant/readonly
DATABASE_URL=postgresql://$USER_READONLY_REST:$RESTAURANT_READONLY_PASSWORD@$AURORA_ENDPOINT:5432/$DB_RESTAURANT
EOF

# Connection details
cat > "$CONFIG_DIR/CONNECTION_DETAILS_SECURE.md" << EOF
# DeliveryKick Secure Aurora Setup - Connection Details

## Cluster Information
- **Cluster**: $CLUSTER_IDENTIFIER
- **Region**: $AWS_REGION
- **Writer**: $AURORA_ENDPOINT
- **Reader**: $READER_ENDPOINT

## Security Model

### 4 Users Per Database:
1. **Master** (\`postgres\`) - Emergency only, NEVER in Django
2. **Admin** - Migrations only (CREATE/ALTER/DROP tables)
3. **Application** - Django runtime (SELECT/INSERT/UPDATE/DELETE)
4. **Read-Only** - Analytics/BI (SELECT only)

---

## Ordering Database

### 1. Admin User (Migrations)
- **User**: \`$USER_ADMIN\`
- **Database**: \`$DB_ORDERING\`
- **Connection Limit**: 5
- **Permissions**: Can CREATE/ALTER/DROP tables
- **Secret**: \`deliverykick/prod/ordering/admin\`

**When to use:**
\`\`\`bash
# For running migrations
cp $CONFIG_DIR/ordering-admin.env .env.migrations
DB_USER=$USER_ADMIN python manage.py migrate
\`\`\`

### 2. Application User (Runtime) ⭐ MAIN USER
- **User**: \`$USER_APP\`
- **Database**: \`$DB_ORDERING\`
- **Connection Limit**: 50
- **Permissions**: SELECT, INSERT, UPDATE, DELETE (NO schema changes)
- **Secret**: \`deliverykick/prod/ordering/app\`

**When to use:**
\`\`\`bash
# For running Django application
cp $CONFIG_DIR/ordering-app.env .env
python manage.py runserver  # or gunicorn, etc.
\`\`\`

### 3. Read-Only User (Analytics)
- **User**: \`$USER_READONLY\`
- **Database**: \`$DB_ORDERING\`
- **Connection Limit**: 20
- **Permissions**: SELECT only
- **Secret**: \`deliverykick/prod/ordering/readonly\`

**When to use:**
\`\`\`bash
# For BI tools, data science, reporting
# Connect read-only tools with these credentials
\`\`\`

---

## Restaurant Database

### 1. Admin User (Migrations)
- **User**: \`$USER_ADMIN_REST\`
- **Secret**: \`deliverykick/prod/restaurant/admin\`
- **Config**: \`$CONFIG_DIR/restaurant-admin.env\`

### 2. Application User (Runtime) ⭐ MAIN USER
- **User**: \`$USER_APP_REST\`
- **Secret**: \`deliverykick/prod/restaurant/app\`
- **Config**: \`$CONFIG_DIR/restaurant-app.env\`

### 3. Read-Only User (Analytics)
- **User**: \`$USER_READONLY_REST\`
- **Secret**: \`deliverykick/prod/restaurant/readonly\`
- **Config**: \`$CONFIG_DIR/restaurant-readonly.env\`

---

## Usage in Django

### Development/Testing
\`\`\`python
# Use admin user for schema changes
DATABASES = {
    'default': {
        'USER': os.getenv('DB_USER'),  # Set to admin user
    }
}
\`\`\`

### Production Runtime
\`\`\`python
# Use application user (cannot drop tables)
DATABASES = {
    'default': {
        'USER': os.getenv('DB_USER'),  # Set to app user
    }
}
\`\`\`

### CI/CD Pipeline
\`\`\`bash
# Step 1: Run migrations (admin user)
export DB_USER=$USER_ADMIN
export DB_PASSWORD=\$ORDERING_ADMIN_PASSWORD
python manage.py migrate

# Step 2: Deploy app (application user)
export DB_USER=$USER_APP
export DB_PASSWORD=\$ORDERING_APP_PASSWORD
gunicorn core.wsgi:application
\`\`\`

---

## Security Benefits

✅ **Application Safety**: Runtime user CANNOT drop tables accidentally
✅ **Audit Trail**: Clear separation between migrations and runtime
✅ **Analytics Access**: Dedicated read-only user for BI tools
✅ **Connection Limits**: Prevents resource exhaustion per user type
✅ **Least Privilege**: Each user has only what they need

---

## Testing Permissions

\`\`\`bash
# Test app user cannot drop tables (should fail)
psql -h $AURORA_ENDPOINT -U $USER_APP -d $DB_ORDERING -c "DROP TABLE test;"
# ERROR: permission denied

# Test readonly user cannot insert (should fail)
psql -h $AURORA_ENDPOINT -U $USER_READONLY -d $DB_ORDERING -c "INSERT INTO test VALUES (1);"
# ERROR: permission denied

# Test admin user can create tables (should succeed)
psql -h $AURORA_ENDPOINT -U $USER_ADMIN -d $DB_ORDERING -c "CREATE TABLE test (id INT);"
# CREATE TABLE
\`\`\`

---

## Monitoring

\`\`\`sql
-- View connections by user
SELECT * FROM db_user_connections;

-- Full activity
SELECT usename, state, query
FROM pg_stat_activity
WHERE datname IN ('$DB_ORDERING', '$DB_RESTAURANT');
\`\`\`

Generated: $(date)
EOF

echo -e "${GREEN}✓ Configuration files created in: $CONFIG_DIR/${NC}"

#==============================================================================
# FINAL SUMMARY
#==============================================================================

echo ""
echo "========================================="
echo -e "${GREEN}✓ Secure Setup Complete!${NC}"
echo "========================================="
echo ""
echo -e "${BLUE}Cluster:${NC} $CLUSTER_IDENTIFIER"
echo -e "${BLUE}Endpoint:${NC} $AURORA_ENDPOINT"
echo ""
echo -e "${CYAN}Users Created (per database):${NC}"
echo "  1. Master      - Emergency only"
echo "  2. Admin       - Migrations (5 connections)"
echo "  3. Application - Runtime (50 connections)"
echo "  4. Read-Only   - Analytics (20 connections)"
echo ""
echo -e "${YELLOW}Configuration Files:${NC}"
ls -1 "$CONFIG_DIR/"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo ""
echo "📦 For Ordering App (this repo):"
echo "  # Migrations:"
echo "  cp $CONFIG_DIR/ordering-admin.env .env.migrations"
echo "  python manage.py migrate"
echo ""
echo "  # Runtime:"
echo "  cp $CONFIG_DIR/ordering-app.env .env"
echo "  python manage.py runserver"
echo ""
echo "📤 For Restaurant App (other repo):"
echo "  Share: $CONFIG_DIR/restaurant-*.env files"
echo ""
echo "📖 Read: $CONFIG_DIR/CONNECTION_DETAILS_SECURE.md"
echo ""
echo -e "${GREEN}Secure Aurora cluster ready! 🔐${NC}"
echo ""
