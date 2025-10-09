#!/bin/bash
set -e

# Universal Aurora Cluster Setup for Multiple Applications
# This script creates a shared Aurora Serverless v2 cluster that can be used by multiple repos/applications
# Usage: ./setup-shared-aurora.sh

echo "========================================="
echo "Shared Aurora Cluster Setup"
echo "Multi-Application Database Infrastructure"
echo "========================================="

# Load environment variables if available
if [ -f .env ]; then
    source .env
fi

# Configuration
CLUSTER_IDENTIFIER="${AURORA_CLUSTER_ID:-ordering-prod-cluster}"
MASTER_USERNAME="${AURORA_MASTER_USER:-postgres}"
MASTER_PASSWORD="${AURORA_MASTER_PASSWORD}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MIN_CAPACITY="${AURORA_MIN_CAPACITY:-0.5}"
MAX_CAPACITY="${AURORA_MAX_CAPACITY:-2}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Validation
if [ -z "$MASTER_PASSWORD" ]; then
    echo -e "${RED}Error: Master password is required${NC}"
    echo "Set AURORA_MASTER_PASSWORD environment variable or provide it:"
    read -sp "Enter master password: " MASTER_PASSWORD
    echo
    if [ -z "$MASTER_PASSWORD" ]; then
        exit 1
    fi
fi

echo ""
echo -e "${YELLOW}Cluster Configuration:${NC}"
echo "Cluster ID: $CLUSTER_IDENTIFIER"
echo "Master User: $MASTER_USERNAME"
echo "Region: $AWS_REGION"
echo "Min Capacity: $MIN_CAPACITY ACU"
echo "Max Capacity: $MAX_CAPACITY ACU"
echo ""

# Check if cluster already exists
echo -e "${YELLOW}Step 1: Checking if Aurora cluster exists...${NC}"
CLUSTER_STATUS=$(aws rds describe-db-clusters \
    --db-cluster-identifier $CLUSTER_IDENTIFIER \
    --region $AWS_REGION \
    --query 'DBClusters[0].Status' \
    --output text 2>/dev/null || echo "not-found")

if [ "$CLUSTER_STATUS" = "not-found" ]; then
    echo -e "${BLUE}Cluster not found. Creating new Aurora Serverless v2 cluster...${NC}"

    # Get VPC info
    echo "Discovering VPC configuration..."
    VPC_ID=$(aws ec2 describe-vpcs \
        --region $AWS_REGION \
        --filters "Name=isDefault,Values=false" \
        --query 'Vpcs[0].VpcId' \
        --output text)

    if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
        echo "No custom VPC found, using default VPC..."
        VPC_ID=$(aws ec2 describe-vpcs \
            --region $AWS_REGION \
            --filters "Name=isDefault,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text)
    fi

    echo "Using VPC: $VPC_ID"

    # Get subnets
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --region $AWS_REGION \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[*].SubnetId' \
        --output text)

    # Create DB subnet group
    SUBNET_GROUP="${CLUSTER_IDENTIFIER}-subnet-group"
    echo "Creating DB subnet group: $SUBNET_GROUP"

    aws rds create-db-subnet-group \
        --db-subnet-group-name $SUBNET_GROUP \
        --db-subnet-group-description "Subnet group for $CLUSTER_IDENTIFIER" \
        --subnet-ids $SUBNET_IDS \
        --region $AWS_REGION \
        2>/dev/null || echo "Subnet group already exists"

    # Create security group
    SECURITY_GROUP="${CLUSTER_IDENTIFIER}-sg"
    echo "Creating security group: $SECURITY_GROUP"

    SG_ID=$(aws ec2 create-security-group \
        --group-name $SECURITY_GROUP \
        --description "Security group for $CLUSTER_IDENTIFIER" \
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

    # Allow PostgreSQL access from within VPC
    echo "Configuring security group rules..."
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 5432 \
        --cidr 10.0.0.0/8 \
        --region $AWS_REGION \
        2>/dev/null || echo "VPC CIDR rule already exists"

    # Allow access from current IP (for management)
    CURRENT_IP=$(curl -s https://checkip.amazonaws.com)
    if [ ! -z "$CURRENT_IP" ]; then
        echo "Adding current IP to security group: $CURRENT_IP"
        aws ec2 authorize-security-group-ingress \
            --group-id $SG_ID \
            --protocol tcp \
            --port 5432 \
            --cidr "$CURRENT_IP/32" \
            --region $AWS_REGION \
            2>/dev/null || echo "Current IP rule already exists"
    fi

    # Create Aurora Serverless v2 cluster
    echo -e "${YELLOW}Creating Aurora Serverless v2 cluster (this takes 10-15 minutes)...${NC}"
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
        --tags Key=Environment,Value=production Key=Project,Value=shared-cluster

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

# Get Aurora endpoint
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
echo ""

# Store master credentials in Secrets Manager
echo -e "${YELLOW}Step 2: Storing master credentials in AWS Secrets Manager...${NC}"
SECRET_NAME="${CLUSTER_IDENTIFIER}/master"

aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "Master credentials for $CLUSTER_IDENTIFIER" \
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
        --secret-id "$SECRET_NAME" \
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

echo -e "${GREEN}✓ Master credentials stored in Secrets Manager${NC}"

# Create shared configuration file
echo ""
echo -e "${YELLOW}Step 3: Creating shared configuration file...${NC}"

SHARED_CONFIG_DIR="$HOME/.aurora-shared"
mkdir -p "$SHARED_CONFIG_DIR"

cat > "$SHARED_CONFIG_DIR/cluster-config.sh" << EOF
#!/bin/bash
# Shared Aurora Cluster Configuration
# Generated: $(date)
# This file can be sourced by any application that needs to connect to the shared cluster

# Cluster Information
export AURORA_CLUSTER_ID="$CLUSTER_IDENTIFIER"
export AURORA_REGION="$AWS_REGION"
export AURORA_ENDPOINT="$AURORA_ENDPOINT"
export AURORA_READER_ENDPOINT="$READER_ENDPOINT"
export AURORA_PORT="5432"
export AURORA_MASTER_USER="$MASTER_USERNAME"
export AURORA_SECRET_NAME="$SECRET_NAME"

# Helper function to get master password from Secrets Manager
get_aurora_master_password() {
    aws secretsmanager get-secret-value \
        --secret-id "\$AURORA_SECRET_NAME" \
        --region "\$AURORA_REGION" \
        --query 'SecretString' \
        --output text | jq -r '.password'
}

# Helper function to get full secret
get_aurora_credentials() {
    aws secretsmanager get-secret-value \
        --secret-id "\$AURORA_SECRET_NAME" \
        --region "\$AURORA_REGION" \
        --query 'SecretString' \
        --output text | jq
}

# Test connection
test_aurora_connection() {
    local password=\$(get_aurora_master_password)
    PGPASSWORD="\$password" psql -h "\$AURORA_ENDPOINT" -U "\$AURORA_MASTER_USER" -d postgres -c "SELECT version();"
}
EOF

chmod +x "$SHARED_CONFIG_DIR/cluster-config.sh"

echo -e "${GREEN}✓ Configuration saved to: $SHARED_CONFIG_DIR/cluster-config.sh${NC}"

# Test connection
echo ""
echo -e "${YELLOW}Step 4: Testing connection...${NC}"
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$MASTER_USERNAME" \
    -d postgres \
    -c "SELECT version();" > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Connection successful${NC}"
else
    echo -e "${RED}✗ Connection failed. Check security group and network settings.${NC}"
fi

# Create setup scripts directory
SETUP_SCRIPTS_DIR="$SHARED_CONFIG_DIR/setup-scripts"
mkdir -p "$SETUP_SCRIPTS_DIR"

# Generate per-application setup script template
cat > "$SETUP_SCRIPTS_DIR/add-application.sh" << 'EOFSCRIPT'
#!/bin/bash
set -e

# Script to add a new application to the shared Aurora cluster
# Usage: ./add-application.sh <app_name> <app_password>

# Load shared configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
source "$SCRIPT_DIR/cluster-config.sh"

APP_NAME="${1}"
APP_PASSWORD="${2}"

if [ -z "$APP_NAME" ] || [ -z "$APP_PASSWORD" ]; then
    echo "Usage: ./add-application.sh <app_name> <app_password>"
    echo "Example: ./add-application.sh myapp SecurePass123"
    exit 1
fi

echo "========================================="
echo "Adding Application to Shared Aurora"
echo "========================================="
echo "App Name: $APP_NAME"
echo "Cluster: $AURORA_CLUSTER_ID"
echo ""

# Database names
DB_MAIN="${APP_NAME}_prod"
DB_USER="${APP_NAME}_user"

# Get master password
MASTER_PASSWORD=$(get_aurora_master_password)

# Create database
echo "Creating database: $DB_MAIN"
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$AURORA_MASTER_USER" \
    -d postgres \
    -c "CREATE DATABASE $DB_MAIN;" \
    2>/dev/null || echo "Database already exists"

# Create user
echo "Creating user: $DB_USER"
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$AURORA_MASTER_USER" \
    -d postgres << EOF
CREATE USER $DB_USER WITH PASSWORD '$APP_PASSWORD';
GRANT ALL PRIVILEGES ON DATABASE $DB_MAIN TO $DB_USER;
ALTER USER $DB_USER CONNECTION LIMIT 50;
EOF

# Grant schema permissions
PGPASSWORD="$MASTER_PASSWORD" psql \
    -h "$AURORA_ENDPOINT" \
    -U "$AURORA_MASTER_USER" \
    -d "$DB_MAIN" << EOF
GRANT ALL ON SCHEMA public TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $DB_USER;
EOF

# Store credentials in Secrets Manager
SECRET_NAME="$AURORA_CLUSTER_ID/$APP_NAME"
echo "Storing credentials in Secrets Manager: $SECRET_NAME"

aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "Aurora credentials for $APP_NAME" \
    --region "$AURORA_REGION" \
    --secret-string "{
        \"username\": \"$DB_USER\",
        \"password\": \"$APP_PASSWORD\",
        \"engine\": \"postgres\",
        \"host\": \"$AURORA_ENDPOINT\",
        \"readerHost\": \"$AURORA_READER_ENDPOINT\",
        \"port\": 5432,
        \"dbname\": \"$DB_MAIN\",
        \"clusterIdentifier\": \"$AURORA_CLUSTER_ID\"
    }" \
    2>/dev/null || \
    aws secretsmanager update-secret \
        --secret-id "$SECRET_NAME" \
        --region "$AURORA_REGION" \
        --secret-string "{
            \"username\": \"$DB_USER\",
            \"password\": \"$APP_PASSWORD\",
            \"engine\": \"postgres\",
            \"host\": \"$AURORA_ENDPOINT\",
            \"readerHost\": \"$AURORA_READER_ENDPOINT\",
            \"port\": 5432,
            \"dbname\": \"$DB_MAIN\",
            \"clusterIdentifier\": \"$AURORA_CLUSTER_ID\"
        }"

# Create app-specific config file
APP_CONFIG_FILE="$SCRIPT_DIR/apps/$APP_NAME.env"
mkdir -p "$SCRIPT_DIR/apps"

cat > "$APP_CONFIG_FILE" << ENVEOF
# Aurora Database Configuration for $APP_NAME
# Generated: $(date)

DB_HOST_SERVER=$AURORA_ENDPOINT
DB_HOST_SERVER_READER=$AURORA_READER_ENDPOINT
DB_PORT=5432
DB_NAME=$DB_MAIN
DB_USER=$DB_USER
DB_PASSWORD=$APP_PASSWORD

# AWS Configuration
AWS_REGION=$AURORA_REGION
AWS_SECRET_MANAGER_ARN=$SECRET_NAME

# Connection String
DATABASE_URL=postgresql://$DB_USER:$APP_PASSWORD@$AURORA_ENDPOINT:5432/$DB_MAIN

# Django Configuration
DATABASES_DEFAULT_ENGINE=django.db.backends.postgresql
DATABASES_DEFAULT_NAME=$DB_MAIN
DATABASES_DEFAULT_USER=$DB_USER
DATABASES_DEFAULT_HOST=$AURORA_ENDPOINT
DATABASES_DEFAULT_PORT=5432
DATABASES_DEFAULT_SSLMODE=require
DATABASES_DEFAULT_CONN_MAX_AGE=600
ENVEOF

echo ""
echo "========================================="
echo "✓ Setup Complete!"
echo "========================================="
echo ""
echo "Database: $DB_MAIN"
echo "User: $DB_USER"
echo "Host: $AURORA_ENDPOINT"
echo "Secret: $SECRET_NAME"
echo ""
echo "Configuration saved to:"
echo "$APP_CONFIG_FILE"
echo ""
echo "Add to your application's .env:"
echo "source $APP_CONFIG_FILE"
echo ""
EOFSCRIPT

chmod +x "$SETUP_SCRIPTS_DIR/add-application.sh"

echo ""
echo "========================================="
echo -e "${GREEN}✓ Shared Aurora Cluster Setup Complete!${NC}"
echo "========================================="
echo ""
echo -e "${BLUE}Cluster Information:${NC}"
echo "Cluster ID: $CLUSTER_IDENTIFIER"
echo "Region: $AWS_REGION"
echo "Writer Endpoint: $AURORA_ENDPOINT"
echo "Reader Endpoint: $READER_ENDPOINT"
echo "Master User: $MASTER_USERNAME"
echo "Master Secret: $SECRET_NAME"
echo ""
echo -e "${BLUE}Configuration Files:${NC}"
echo "Shared Config: $SHARED_CONFIG_DIR/cluster-config.sh"
echo "Add App Script: $SETUP_SCRIPTS_DIR/add-application.sh"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo ""
echo "1. For each application/repo, run:"
echo "   $SETUP_SCRIPTS_DIR/add-application.sh <app_name> <password>"
echo ""
echo "   Example for App 1 (current repo):"
echo "   $SETUP_SCRIPTS_DIR/add-application.sh ordering SecurePass123"
echo ""
echo "   Example for App 2 (other repo):"
echo "   $SETUP_SCRIPTS_DIR/add-application.sh app2 AnotherSecurePass456"
echo ""
echo "2. Copy the generated .env file to each repo:"
echo "   cp $SHARED_CONFIG_DIR/apps/<app_name>.env /path/to/repo/.env"
echo ""
echo "3. In each repo, update database settings to use the Aurora endpoint"
echo ""
echo "4. Run migrations in each repo:"
echo "   python manage.py migrate"
echo ""
echo -e "${YELLOW}To use in other repositories:${NC}"
echo "1. Copy these files to the other repo:"
echo "   - $SHARED_CONFIG_DIR/cluster-config.sh"
echo "   - $SETUP_SCRIPTS_DIR/add-application.sh"
echo ""
echo "2. Or share the Aurora endpoint directly:"
echo "   Host: $AURORA_ENDPOINT"
echo "   Port: 5432"
echo ""
echo -e "${YELLOW}Access credentials:${NC}"
echo "aws secretsmanager get-secret-value --secret-id $SECRET_NAME --query 'SecretString' --output text | jq"
echo ""
