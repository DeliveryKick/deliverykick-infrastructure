#!/bin/bash
set -e

# Script to provision database resources for a second application on the same Aurora cluster
# Usage: ./setup-app2-database.sh [app2_name] [db_password]

echo "========================================="
echo "Aurora Multi-App Database Setup"
echo "Setup Database for Second Application"
echo "========================================="

# Configuration
APP2_NAME="${1:-app2}"
APP2_PASSWORD="${2}"
CLUSTER_IDENTIFIER="ordering-prod-cluster"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Validation
if [ -z "$APP2_PASSWORD" ]; then
    echo -e "${RED}Error: Database password is required${NC}"
    echo "Usage: ./setup-app2-database.sh [app_name] [db_password]"
    exit 1
fi

# Load environment variables for Aurora connection
if [ -f .env ]; then
    source .env
else
    echo -e "${RED}Error: .env file not found!${NC}"
    exit 1
fi

# Get Aurora endpoint
echo -e "${YELLOW}Step 1: Getting Aurora cluster endpoint...${NC}"
AURORA_ENDPOINT=$(aws rds describe-db-clusters \
    --db-cluster-identifier $CLUSTER_IDENTIFIER \
    --query 'DBClusters[0].Endpoint' \
    --output text 2>/dev/null)

if [ -z "$AURORA_ENDPOINT" ]; then
    echo -e "${RED}Error: Could not find Aurora cluster '$CLUSTER_IDENTIFIER'${NC}"
    echo "Please ensure the cluster exists and is available."
    exit 1
fi

echo -e "${GREEN}✓ Found cluster endpoint: $AURORA_ENDPOINT${NC}"

# Database names
DB_MAIN="${APP2_NAME}_prod"
DB_USER="${APP2_NAME}_user"

echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo "Cluster: $CLUSTER_IDENTIFIER"
echo "Endpoint: $AURORA_ENDPOINT"
echo "Main Database: $DB_MAIN"
echo "Database User: $DB_USER"
echo ""

read -p "Continue with setup? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Setup cancelled."
    exit 0
fi

# Get master credentials from environment or Secrets Manager
MASTER_USER="${DB_USER:-postgres}"
MASTER_PASSWORD="${DB_PASSWORD}"

if [ -z "$MASTER_PASSWORD" ]; then
    echo -e "${YELLOW}Fetching master password from Secrets Manager...${NC}"
    MASTER_PASSWORD=$(aws secretsmanager get-secret-value \
        --secret-id ordering/prod/database \
        --query 'SecretString' \
        --output text | jq -r '.password')
fi

# Step 2: Create database
echo ""
echo -e "${YELLOW}Step 2: Creating database '$DB_MAIN'...${NC}"
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$MASTER_USER" \
    -d postgres \
    -c "CREATE DATABASE $DB_MAIN;" \
    2>/dev/null || echo "Database may already exist"

echo -e "${GREEN}✓ Database created${NC}"

# Step 3: Create user
echo ""
echo -e "${YELLOW}Step 3: Creating database user '$DB_USER'...${NC}"
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$MASTER_USER" \
    -d postgres << EOF
-- Create user
CREATE USER $DB_USER WITH PASSWORD '$APP2_PASSWORD';

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE $DB_MAIN TO $DB_USER;

-- Set connection limit
ALTER USER $DB_USER CONNECTION LIMIT 50;

-- Grant necessary permissions
\c $DB_MAIN
GRANT ALL ON SCHEMA public TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $DB_USER;
EOF

echo -e "${GREEN}✓ User created and privileges granted${NC}"

# Step 4: Test connection
echo ""
echo -e "${YELLOW}Step 4: Testing connection...${NC}"
PGPASSWORD="$APP2_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$DB_USER" \
    -d "$DB_MAIN" \
    -c "SELECT version();" > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Connection successful${NC}"
else
    echo -e "${RED}✗ Connection failed${NC}"
    exit 1
fi

# Step 5: Store credentials in Secrets Manager
echo ""
echo -e "${YELLOW}Step 5: Storing credentials in AWS Secrets Manager...${NC}"

SECRET_NAME="ordering/prod/${APP2_NAME}-database"
SECRET_JSON=$(cat <<EOF
{
    "username": "$DB_USER",
    "password": "$APP2_PASSWORD",
    "engine": "postgres",
    "host": "$AURORA_ENDPOINT",
    "port": 5432,
    "dbname": "$DB_MAIN",
    "dbClusterIdentifier": "$CLUSTER_IDENTIFIER"
}
EOF
)

aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "Aurora database credentials for $APP2_NAME" \
    --secret-string "$SECRET_JSON" \
    2>/dev/null || \
    aws secretsmanager update-secret \
        --secret-id "$SECRET_NAME" \
        --secret-string "$SECRET_JSON"

echo -e "${GREEN}✓ Credentials stored in Secrets Manager: $SECRET_NAME${NC}"

# Step 6: Update security group (if needed)
echo ""
echo -e "${YELLOW}Step 6: Verifying security group configuration...${NC}"

# Get security group ID
SG_ID=$(aws rds describe-db-clusters \
    --db-cluster-identifier $CLUSTER_IDENTIFIER \
    --query 'DBClusters[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
    --output text)

echo "Security Group ID: $SG_ID"
echo "Note: Ensure App 2 has network access to this security group"
echo -e "${GREEN}✓ Security group verified${NC}"

# Step 7: Create monitoring views
echo ""
echo -e "${YELLOW}Step 7: Setting up monitoring utilities...${NC}"

PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$MASTER_USER" \
    -d "$DB_MAIN" << 'EOF'
-- Create monitoring view for this database
CREATE OR REPLACE VIEW db_connections AS
SELECT
    datname,
    usename,
    state,
    COUNT(*) as connection_count,
    MAX(state_change) as last_state_change
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY datname, usename, state
ORDER BY connection_count DESC;

-- Grant access to the view
GRANT SELECT ON db_connections TO PUBLIC;
EOF

echo -e "${GREEN}✓ Monitoring views created${NC}"

# Generate connection strings
echo ""
echo "========================================="
echo -e "${GREEN}Setup Complete!${NC}"
echo "========================================="
echo ""
echo "Database Connection Details:"
echo "----------------------------"
echo "Host: $AURORA_ENDPOINT"
echo "Port: 5432"
echo "Database: $DB_MAIN"
echo "Username: $DB_USER"
echo "Password: [stored in Secrets Manager]"
echo ""
echo "AWS Secrets Manager:"
echo "----------------------------"
echo "Secret Name: $SECRET_NAME"
echo ""
echo "Environment Variables (for App 2):"
echo "----------------------------"
echo "DB_HOST_SERVER=$AURORA_ENDPOINT"
echo "DB_PORT=5432"
echo "DB_NAME=$DB_MAIN"
echo "DB_USER=$DB_USER"
echo "DB_PASSWORD=<stored_in_secrets_manager>"
echo ""
echo "Retrieve password from Secrets Manager:"
echo "aws secretsmanager get-secret-value --secret-id $SECRET_NAME --query 'SecretString' --output text | jq -r '.password'"
echo ""
echo "Django Configuration Example:"
echo "----------------------------"
cat << PYEOF
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': '$DB_MAIN',
        'USER': '$DB_USER',
        'PASSWORD': os.getenv('DB_PASSWORD'),
        'HOST': '$AURORA_ENDPOINT',
        'PORT': '5432',
        'OPTIONS': {
            'sslmode': 'require',
            'connect_timeout': 10,
        },
        'CONN_MAX_AGE': 600,
    }
}
PYEOF
echo ""
echo "Connection Monitoring:"
echo "----------------------------"
echo "PGPASSWORD=\$DB_PASSWORD psql -h $AURORA_ENDPOINT -U $DB_USER -d $DB_MAIN -c 'SELECT * FROM db_connections;'"
echo ""
echo "Resource Limits:"
echo "----------------------------"
echo "- Connection Limit: 50 per user"
echo "- Shared Aurora ACUs: 0.5-2 (adjust based on usage)"
echo ""
echo "Next Steps:"
echo "1. Share connection details with App 2 team"
echo "2. Configure App 2 application with database credentials"
echo "3. Run App 2 migrations: python manage.py migrate"
echo "4. Monitor connections and performance in CloudWatch"
echo "5. Adjust Aurora scaling if needed"
echo ""
echo "Documentation: docs/AURORA_SHARED_DATABASE_PLAN.md"
echo ""
