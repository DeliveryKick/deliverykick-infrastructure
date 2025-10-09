#!/bin/bash
set -e

# DeliveryKick Complete Cluster Setup
# This script creates the Aurora cluster and ALL databases for both applications at once
# Usage: ./setup-deliverykick-cluster.sh

echo "========================================="
echo "DeliveryKick Aurora Cluster Setup"
echo "Creating cluster + all databases"
echo "========================================="

# Configuration
CLUSTER_IDENTIFIER="${AURORA_CLUSTER_ID:-deliverykick-prod-cluster}"
MASTER_USERNAME="${AURORA_MASTER_USER:-postgres}"
MASTER_PASSWORD="${AURORA_MASTER_PASSWORD}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MIN_CAPACITY="${AURORA_MIN_CAPACITY:-0.5}"
MAX_CAPACITY="${AURORA_MAX_CAPACITY:-2}"

# Application-specific passwords (can be set via environment variables)
ORDERING_PASSWORD="${ORDERING_DB_PASSWORD}"
RESTAURANT_PASSWORD="${RESTAURANT_DB_PASSWORD}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}This script will create:${NC}"
echo "1. Aurora Serverless v2 cluster: $CLUSTER_IDENTIFIER"
echo "2. DeliveryKick Ordering database + user"
echo "3. DeliveryKick Restaurant database + user"
echo ""

# Validation
if [ -z "$MASTER_PASSWORD" ]; then
    echo -e "${YELLOW}Master password not set in environment.${NC}"
    read -sp "Enter Aurora master password: " MASTER_PASSWORD
    echo
    if [ -z "$MASTER_PASSWORD" ]; then
        echo -e "${RED}Master password is required!${NC}"
        exit 1
    fi
fi

if [ -z "$ORDERING_PASSWORD" ]; then
    read -sp "Enter password for ordering app: " ORDERING_PASSWORD
    echo
fi

if [ -z "$RESTAURANT_PASSWORD" ]; then
    read -sp "Enter password for restaurant app: " RESTAURANT_PASSWORD
    echo
fi

echo ""
echo -e "${YELLOW}Configuration Summary:${NC}"
echo "Cluster ID: $CLUSTER_IDENTIFIER"
echo "Region: $AWS_REGION"
echo "Scaling: $MIN_CAPACITY-$MAX_CAPACITY ACU"
echo ""
echo "Databases to create:"
echo "  1. deliverykick_ordering_prod (user: dk_ordering_user)"
echo "  2. deliverykick_restaurant_prod (user: dk_restaurant_user)"
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

# Check if cluster already exists
echo -e "${YELLOW}Checking if Aurora cluster exists...${NC}"
CLUSTER_STATUS=$(aws rds describe-db-clusters \
    --db-cluster-identifier $CLUSTER_IDENTIFIER \
    --region $AWS_REGION \
    --query 'DBClusters[0].Status' \
    --output text 2>/dev/null || echo "not-found")

if [ "$CLUSTER_STATUS" = "not-found" ]; then
    echo -e "${BLUE}Creating new Aurora Serverless v2 cluster...${NC}"

    # Get VPC info
    echo "Discovering VPC configuration..."
    VPC_ID=$(aws ec2 describe-vpcs \
        --region $AWS_REGION \
        --filters "Name=isDefault,Values=false" \
        --query 'Vpcs[0].VpcId' \
        --output text)

    if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
        echo "Using default VPC..."
        VPC_ID=$(aws ec2 describe-vpcs \
            --region $AWS_REGION \
            --filters "Name=isDefault,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text)
    fi

    echo "VPC ID: $VPC_ID"

    # Get subnets
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --region $AWS_REGION \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[*].SubnetId' \
        --output text)

    # Create DB subnet group
    SUBNET_GROUP="${CLUSTER_IDENTIFIER}-subnet-group"
    echo "Creating DB subnet group..."

    aws rds create-db-subnet-group \
        --db-subnet-group-name $SUBNET_GROUP \
        --db-subnet-group-description "Subnet group for DeliveryKick cluster" \
        --subnet-ids $SUBNET_IDS \
        --region $AWS_REGION \
        2>/dev/null || echo "Subnet group already exists"

    # Create security group
    SECURITY_GROUP="${CLUSTER_IDENTIFIER}-sg"
    echo "Creating security group..."

    SG_ID=$(aws ec2 create-security-group \
        --group-name $SECURITY_GROUP \
        --description "Security group for DeliveryKick Aurora cluster" \
        --vpc-id $VPC_ID \
        --region $AWS_REGION \
        --query 'GroupId' \
        --output text 2>/dev/null || \
        aws ec2 describe-security-groups \
            --region $AWS_REGION \
            --filters "Name=group-name,Values=$SECURITY_GROUP" \
            --query 'SecurityGroups[0].GroupId' \
            --output text)

    echo "Security Group ID: $SG_ID"

    # Configure security group rules
    echo "Configuring security group rules..."

    # Allow from VPC
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 5432 \
        --cidr 10.0.0.0/8 \
        --region $AWS_REGION \
        2>/dev/null || echo "VPC rule exists"

    # Allow from current IP
    CURRENT_IP=$(curl -s https://checkip.amazonaws.com)
    if [ ! -z "$CURRENT_IP" ]; then
        echo "Adding current IP: $CURRENT_IP"
        aws ec2 authorize-security-group-ingress \
            --group-id $SG_ID \
            --protocol tcp \
            --port 5432 \
            --cidr "$CURRENT_IP/32" \
            --region $AWS_REGION \
            2>/dev/null || echo "Current IP rule exists"
    fi

    # Create Aurora Serverless v2 cluster
    echo -e "${YELLOW}Creating Aurora Serverless v2 cluster (10-15 minutes)...${NC}"
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
        --preferred-backup-window "03:00-04:00" \
        --preferred-maintenance-window "mon:04:00-mon:05:00" \
        --enable-http-endpoint \
        --region $AWS_REGION \
        --tags Key=Environment,Value=production Key=Project,Value=deliverykick Key=ManagedBy,Value=ordering-repo

    echo -e "${YELLOW}Waiting for cluster to be available...${NC}"
    aws rds wait db-cluster-available \
        --db-cluster-identifier $CLUSTER_IDENTIFIER \
        --region $AWS_REGION

    # Create primary instance
    echo -e "${YELLOW}Creating primary instance...${NC}"
    aws rds create-db-instance \
        --db-instance-identifier "${CLUSTER_IDENTIFIER}-instance-1" \
        --db-instance-class db.serverless \
        --engine aurora-postgresql \
        --db-cluster-identifier $CLUSTER_IDENTIFIER \
        --publicly-accessible \
        --region $AWS_REGION

    echo -e "${YELLOW}Waiting for instance to be available...${NC}"
    aws rds wait db-instance-available \
        --db-instance-identifier "${CLUSTER_IDENTIFIER}-instance-1" \
        --region $AWS_REGION

    echo -e "${GREEN}✓ Aurora cluster created successfully!${NC}"
else
    echo -e "${GREEN}✓ Aurora cluster already exists (Status: $CLUSTER_STATUS)${NC}"
fi

# Get Aurora endpoints
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

echo ""
echo -e "${GREEN}Cluster Endpoints:${NC}"
echo "Writer: $AURORA_ENDPOINT"
echo "Reader: $READER_ENDPOINT"

#==============================================================================
# PHASE 2: CREATE ORDERING DATABASE
#==============================================================================

echo ""
echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}PHASE 2: Ordering Database Setup${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"

DB_ORDERING="deliverykick_ordering_prod"
USER_ORDERING="dk_ordering_user"

echo "Creating database: $DB_ORDERING"
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$MASTER_USERNAME" \
    -d postgres \
    -c "CREATE DATABASE $DB_ORDERING;" \
    2>/dev/null || echo "Database may already exist"

echo "Creating user: $USER_ORDERING"
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$MASTER_USERNAME" \
    -d postgres << EOF
-- Create user
CREATE USER $USER_ORDERING WITH PASSWORD '$ORDERING_PASSWORD';

-- Grant database privileges
GRANT ALL PRIVILEGES ON DATABASE $DB_ORDERING TO $USER_ORDERING;

-- Set connection limit
ALTER USER $USER_ORDERING CONNECTION LIMIT 50;
EOF

echo "Setting up schema permissions..."
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$MASTER_USERNAME" \
    -d "$DB_ORDERING" << EOF
-- Grant schema permissions
GRANT ALL ON SCHEMA public TO $USER_ORDERING;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $USER_ORDERING;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $USER_ORDERING;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO $USER_ORDERING;

-- Create monitoring view
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

GRANT SELECT ON db_connections TO $USER_ORDERING;
EOF

# Test connection
echo "Testing connection..."
PGPASSWORD="$ORDERING_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$USER_ORDERING" \
    -d "$DB_ORDERING" \
    -c "SELECT version();" > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Ordering database setup complete!${NC}"
else
    echo -e "${RED}✗ Ordering database connection failed${NC}"
    exit 1
fi

#==============================================================================
# PHASE 3: CREATE RESTAURANT DATABASE
#==============================================================================

echo ""
echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}PHASE 3: Restaurant Database Setup${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"

DB_RESTAURANT="deliverykick_restaurant_prod"
USER_RESTAURANT="dk_restaurant_user"

echo "Creating database: $DB_RESTAURANT"
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$MASTER_USERNAME" \
    -d postgres \
    -c "CREATE DATABASE $DB_RESTAURANT;" \
    2>/dev/null || echo "Database may already exist"

echo "Creating user: $USER_RESTAURANT"
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$MASTER_USERNAME" \
    -d postgres << EOF
-- Create user
CREATE USER $USER_RESTAURANT WITH PASSWORD '$RESTAURANT_PASSWORD';

-- Grant database privileges
GRANT ALL PRIVILEGES ON DATABASE $DB_RESTAURANT TO $USER_RESTAURANT;

-- Set connection limit
ALTER USER $USER_RESTAURANT CONNECTION LIMIT 50;
EOF

echo "Setting up schema permissions..."
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$MASTER_USERNAME" \
    -d "$DB_RESTAURANT" << EOF
-- Grant schema permissions
GRANT ALL ON SCHEMA public TO $USER_RESTAURANT;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $USER_RESTAURANT;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $USER_RESTAURANT;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO $USER_RESTAURANT;

-- Create monitoring view
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

GRANT SELECT ON db_connections TO $USER_RESTAURANT;
EOF

# Test connection
echo "Testing connection..."
PGPASSWORD="$RESTAURANT_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$USER_RESTAURANT" \
    -d "$DB_RESTAURANT" \
    -c "SELECT version();" > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Restaurant database setup complete!${NC}"
else
    echo -e "${RED}✗ Restaurant database connection failed${NC}"
    exit 1
fi

#==============================================================================
# PHASE 4: STORE CREDENTIALS IN AWS SECRETS MANAGER
#==============================================================================

echo ""
echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}PHASE 4: Storing Credentials${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"

# Master credentials
SECRET_MASTER="deliverykick/prod/master"
echo "Storing master credentials..."

aws secretsmanager create-secret \
    --name "$SECRET_MASTER" \
    --description "Master credentials for DeliveryKick Aurora cluster" \
    --region $AWS_REGION \
    --secret-string "{
        \"username\": \"$MASTER_USERNAME\",
        \"password\": \"$MASTER_PASSWORD\",
        \"engine\": \"postgres\",
        \"host\": \"$AURORA_ENDPOINT\",
        \"readerHost\": \"$READER_ENDPOINT\",
        \"port\": 5432,
        \"clusterIdentifier\": \"$CLUSTER_IDENTIFIER\"
    }" \
    2>/dev/null || \
    aws secretsmanager update-secret \
        --secret-id "$SECRET_MASTER" \
        --region $AWS_REGION \
        --secret-string "{
            \"username\": \"$MASTER_USERNAME\",
            \"password\": \"$MASTER_PASSWORD\",
            \"engine\": \"postgres\",
            \"host\": \"$AURORA_ENDPOINT\",
            \"readerHost\": \"$READER_ENDPOINT\",
            \"port\": 5432,
            \"clusterIdentifier\": \"$CLUSTER_IDENTIFIER\"
        }"

echo -e "${GREEN}✓ Master credentials stored${NC}"

# Ordering app credentials
SECRET_ORDERING="deliverykick/prod/ordering"
echo "Storing ordering app credentials..."

aws secretsmanager create-secret \
    --name "$SECRET_ORDERING" \
    --description "DeliveryKick Ordering App credentials" \
    --region $AWS_REGION \
    --secret-string "{
        \"username\": \"$USER_ORDERING\",
        \"password\": \"$ORDERING_PASSWORD\",
        \"engine\": \"postgres\",
        \"host\": \"$AURORA_ENDPOINT\",
        \"readerHost\": \"$READER_ENDPOINT\",
        \"port\": 5432,
        \"dbname\": \"$DB_ORDERING\",
        \"clusterIdentifier\": \"$CLUSTER_IDENTIFIER\"
    }" \
    2>/dev/null || \
    aws secretsmanager update-secret \
        --secret-id "$SECRET_ORDERING" \
        --region $AWS_REGION \
        --secret-string "{
            \"username\": \"$USER_ORDERING\",
            \"password\": \"$ORDERING_PASSWORD\",
            \"engine\": \"postgres\",
            \"host\": \"$AURORA_ENDPOINT\",
            \"readerHost\": \"$READER_ENDPOINT\",
            \"port\": 5432,
            \"dbname\": \"$DB_ORDERING\",
            \"clusterIdentifier\": \"$CLUSTER_IDENTIFIER\"
        }"

echo -e "${GREEN}✓ Ordering credentials stored${NC}"

# Restaurant app credentials
SECRET_RESTAURANT="deliverykick/prod/restaurant"
echo "Storing restaurant app credentials..."

aws secretsmanager create-secret \
    --name "$SECRET_RESTAURANT" \
    --description "DeliveryKick Restaurant App credentials" \
    --region $AWS_REGION \
    --secret-string "{
        \"username\": \"$USER_RESTAURANT\",
        \"password\": \"$RESTAURANT_PASSWORD\",
        \"engine\": \"postgres\",
        \"host\": \"$AURORA_ENDPOINT\",
        \"readerHost\": \"$READER_ENDPOINT\",
        \"port\": 5432,
        \"dbname\": \"$DB_RESTAURANT\",
        \"clusterIdentifier\": \"$CLUSTER_IDENTIFIER\"
    }" \
    2>/dev/null || \
    aws secretsmanager update-secret \
        --secret-id "$SECRET_RESTAURANT" \
        --region $AWS_REGION \
        --secret-string "{
            \"username\": \"$USER_RESTAURANT\",
            \"password\": \"$RESTAURANT_PASSWORD\",
            \"engine\": \"postgres\",
            \"host\": \"$AURORA_ENDPOINT\",
            \"readerHost\": \"$READER_ENDPOINT\",
            \"port\": 5432,
            \"dbname\": \"$DB_RESTAURANT\",
            \"clusterIdentifier\": \"$CLUSTER_IDENTIFIER\"
        }"

echo -e "${GREEN}✓ Restaurant credentials stored${NC}"

#==============================================================================
# PHASE 5: GENERATE CONFIGURATION FILES
#==============================================================================

echo ""
echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}PHASE 5: Generating Configuration Files${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"

CONFIG_DIR="./aurora-config"
mkdir -p "$CONFIG_DIR"

# Ordering app config
cat > "$CONFIG_DIR/ordering-app.env" << EOF
# DeliveryKick Ordering App - Aurora Configuration
# Generated: $(date)
# Secret: $SECRET_ORDERING

# Database Configuration
DB_HOST_SERVER=$AURORA_ENDPOINT
DB_HOST_SERVER_READER=$READER_ENDPOINT
DB_PORT=5432
DB_NAME=$DB_ORDERING
DB_USER=$USER_ORDERING
DB_PASSWORD=$ORDERING_PASSWORD

# AWS Configuration
AWS_REGION=$AWS_REGION
DEFAULT_AWS_SECRET_MANAGER_ARN=$SECRET_ORDERING

# Connection String
DATABASE_URL=postgresql://$USER_ORDERING:$ORDERING_PASSWORD@$AURORA_ENDPOINT:5432/$DB_ORDERING

# Django Settings
DATABASES_DEFAULT_ENGINE=django.db.backends.postgresql
DATABASES_DEFAULT_NAME=$DB_ORDERING
DATABASES_DEFAULT_USER=$USER_ORDERING
DATABASES_DEFAULT_HOST=$AURORA_ENDPOINT
DATABASES_DEFAULT_PORT=5432
DATABASES_DEFAULT_OPTIONS_SSLMODE=require
DATABASES_DEFAULT_CONN_MAX_AGE=600
EOF

echo -e "${GREEN}✓ Created: $CONFIG_DIR/ordering-app.env${NC}"

# Restaurant app config
cat > "$CONFIG_DIR/restaurant-app.env" << EOF
# DeliveryKick Restaurant App - Aurora Configuration
# Generated: $(date)
# Secret: $SECRET_RESTAURANT

# Database Configuration
DB_HOST_SERVER=$AURORA_ENDPOINT
DB_HOST_SERVER_READER=$READER_ENDPOINT
DB_PORT=5432
DB_NAME=$DB_RESTAURANT
DB_USER=$USER_RESTAURANT
DB_PASSWORD=$RESTAURANT_PASSWORD

# AWS Configuration
AWS_REGION=$AWS_REGION
RESTAURANT_AWS_SECRET_MANAGER_ARN=$SECRET_RESTAURANT

# Connection String
DATABASE_URL=postgresql://$USER_RESTAURANT:$RESTAURANT_PASSWORD@$AURORA_ENDPOINT:5432/$DB_RESTAURANT

# Django Settings
DATABASES_DEFAULT_ENGINE=django.db.backends.postgresql
DATABASES_DEFAULT_NAME=$DB_RESTAURANT
DATABASES_DEFAULT_USER=$USER_RESTAURANT
DATABASES_DEFAULT_HOST=$AURORA_ENDPOINT
DATABASES_DEFAULT_PORT=5432
DATABASES_DEFAULT_OPTIONS_SSLMODE=require
DATABASES_DEFAULT_CONN_MAX_AGE=600
EOF

echo -e "${GREEN}✓ Created: $CONFIG_DIR/restaurant-app.env${NC}"

# Connection details for other repo
cat > "$CONFIG_DIR/CONNECTION_DETAILS.md" << EOF
# DeliveryKick Aurora Connection Details

## Cluster Information

**Cluster ID**: $CLUSTER_IDENTIFIER
**Region**: $AWS_REGION
**Writer Endpoint**: $AURORA_ENDPOINT
**Reader Endpoint**: $READER_ENDPOINT
**Port**: 5432

## Databases Created

### 1. Ordering Database
- **Database**: $DB_ORDERING
- **User**: $USER_ORDERING
- **Password**: \`$ORDERING_PASSWORD\`
- **Connection Limit**: 50
- **Secret**: $SECRET_ORDERING

**Connection String:**
\`\`\`
postgresql://$USER_ORDERING:$ORDERING_PASSWORD@$AURORA_ENDPOINT:5432/$DB_ORDERING
\`\`\`

**Test Connection:**
\`\`\`bash
psql -h $AURORA_ENDPOINT -U $USER_ORDERING -d $DB_ORDERING
\`\`\`

### 2. Restaurant Database
- **Database**: $DB_RESTAURANT
- **User**: $USER_RESTAURANT
- **Password**: \`$RESTAURANT_PASSWORD\`
- **Connection Limit**: 50
- **Secret**: $SECRET_RESTAURANT

**Connection String:**
\`\`\`
postgresql://$USER_RESTAURANT:$RESTAURANT_PASSWORD@$AURORA_ENDPOINT:5432/$DB_RESTAURANT
\`\`\`

**Test Connection:**
\`\`\`bash
psql -h $AURORA_ENDPOINT -U $USER_RESTAURANT -d $DB_RESTAURANT
\`\`\`

## For Ordering Repo (This Repo)

Copy the configuration:
\`\`\`bash
cp aurora-config/ordering-app.env .env.aurora
cat .env.aurora >> .env
\`\`\`

Update \`core/settings/database.py\` to use these variables, then run:
\`\`\`bash
python manage.py migrate
\`\`\`

## For Restaurant Repo (Other Repo)

Share the \`aurora-config/restaurant-app.env\` file with the restaurant repo team.

In the restaurant repo:
\`\`\`bash
# Copy the env file
cp restaurant-app.env .env

# Update database settings to use Aurora endpoint
# Run migrations
python manage.py migrate
\`\`\`

## Getting Credentials from Secrets Manager

### Ordering App
\`\`\`bash
aws secretsmanager get-secret-value \\
    --secret-id $SECRET_ORDERING \\
    --region $AWS_REGION \\
    --query 'SecretString' --output text | jq
\`\`\`

### Restaurant App
\`\`\`bash
aws secretsmanager get-secret-value \\
    --secret-id $SECRET_RESTAURANT \\
    --region $AWS_REGION \\
    --query 'SecretString' --output text | jq
\`\`\`

## Monitoring

### View All Connections
\`\`\`sql
SELECT datname, usename, state, COUNT(*)
FROM pg_stat_activity
WHERE datname IN ('$DB_ORDERING', '$DB_RESTAURANT')
GROUP BY datname, usename, state;
\`\`\`

### Database Sizes
\`\`\`sql
SELECT datname, pg_size_pretty(pg_database_size(datname))
FROM pg_database
WHERE datname IN ('$DB_ORDERING', '$DB_RESTAURANT');
\`\`\`

## Security Notes

- Both databases are on the same cluster but fully isolated
- Each user can only access their own database
- Connection limit: 50 per database
- SSL/TLS required for all connections
- Credentials stored in AWS Secrets Manager

## Cost

Estimated cost: \$86-172/month for both applications (shared cluster)

## Support

- Cluster logs: \`/aws/rds/cluster/$CLUSTER_IDENTIFIER\`
- CloudWatch: Services → RDS → $CLUSTER_IDENTIFIER
- Secrets Manager: Services → Secrets Manager → deliverykick/prod/*

---
Generated: $(date)
EOF

echo -e "${GREEN}✓ Created: $CONFIG_DIR/CONNECTION_DETAILS.md${NC}"

# Create README for sharing
cat > "$CONFIG_DIR/README.md" << 'EOF'
# DeliveryKick Aurora Configuration

This directory contains configuration files for connecting to the DeliveryKick Aurora cluster.

## Files

- **ordering-app.env** - Configuration for ordering application
- **restaurant-app.env** - Configuration for restaurant application (share with other repo)
- **CONNECTION_DETAILS.md** - Complete connection details and instructions

## Quick Start

### For Ordering Repo (This Repo)
```bash
cp ordering-app.env .env.aurora
cat .env.aurora >> .env
python manage.py migrate
```

### For Restaurant Repo (Other Repo)
```bash
# Copy restaurant-app.env to the restaurant repo
# Then in that repo:
cp restaurant-app.env .env
python manage.py migrate
```

## Security

⚠️ **IMPORTANT**: These files contain passwords.
- Do NOT commit to git
- Share securely (encrypted channel, AWS Secrets Manager, etc.)
- Rotate passwords quarterly

## Questions?

See CONNECTION_DETAILS.md for complete setup instructions.
EOF

echo -e "${GREEN}✓ Created: $CONFIG_DIR/README.md${NC}"

#==============================================================================
# FINAL SUMMARY
#==============================================================================

echo ""
echo "========================================="
echo -e "${GREEN}✓ DeliveryKick Cluster Setup Complete!${NC}"
echo "========================================="
echo ""
echo -e "${BLUE}Cluster Information:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cluster ID: $CLUSTER_IDENTIFIER"
echo "Region: $AWS_REGION"
echo "Writer: $AURORA_ENDPOINT"
echo "Reader: $READER_ENDPOINT"
echo ""
echo -e "${BLUE}Databases Created:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. $DB_ORDERING (user: $USER_ORDERING)"
echo "2. $DB_RESTAURANT (user: $USER_RESTAURANT)"
echo ""
echo -e "${BLUE}Secrets Stored:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Master: $SECRET_MASTER"
echo "Ordering: $SECRET_ORDERING"
echo "Restaurant: $SECRET_RESTAURANT"
echo ""
echo -e "${BLUE}Configuration Files:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "All files saved in: $CONFIG_DIR/"
echo ""
ls -1 "$CONFIG_DIR/"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. For Ordering App (this repo):"
echo "   cp $CONFIG_DIR/ordering-app.env .env.aurora"
echo "   cat .env.aurora >> .env"
echo "   python manage.py migrate"
echo ""
echo "2. For Restaurant App (other repo):"
echo "   # Share $CONFIG_DIR/restaurant-app.env"
echo "   # Or share $CONFIG_DIR/CONNECTION_DETAILS.md"
echo "   # Restaurant team copies file and runs migrations"
echo ""
echo "3. View complete details:"
echo "   cat $CONFIG_DIR/CONNECTION_DETAILS.md"
echo ""
echo -e "${GREEN}Both applications can now stream data to Aurora! 🚀${NC}"
echo ""
