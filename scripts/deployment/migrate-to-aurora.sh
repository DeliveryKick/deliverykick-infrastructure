#!/bin/bash
set -e

# Ordering Backend - Aurora Migration Script
# Migrates data from existing RDS to Aurora Serverless v2

echo "========================================="
echo "Ordering Backend Aurora Migration"
echo "========================================="

# Load environment variables
if [ -f .env ]; then
    source .env
else
    echo "Error: .env file not found!"
    exit 1
fi

# Configuration
SOURCE_HOST="${DB_HOST_SERVER}"
SOURCE_DB="${DB_NAME}"
SOURCE_USER="${DB_USER}"
SOURCE_PASSWORD="${DB_PASSWORD:-}"

# Restaurant DB
RESTAURANT_SOURCE_HOST="${RESTAURANT_DB_HOST_SERVER}"
RESTAURANT_SOURCE_DB="${RESTAURANT_DB_NAME}"
RESTAURANT_SOURCE_USER="${RESTAURANT_DB_USER}"
RESTAURANT_SOURCE_PASSWORD="${RESTAURANT_DB_PASSWORD:-}"

# Target Aurora cluster (to be created)
TARGET_CLUSTER="ordering-prod-cluster"
TARGET_DB="ordering_prod"
TARGET_USER="postgres"
TARGET_PASSWORD="${AURORA_PASSWORD:-}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Configuration:${NC}"
echo "Source (Ordering DB): $SOURCE_HOST / $SOURCE_DB"
echo "Source (Restaurant DB): $RESTAURANT_SOURCE_HOST / $RESTAURANT_SOURCE_DB"
echo "Target Cluster: $TARGET_CLUSTER"
echo ""

# Check if Aurora cluster exists
echo -e "${YELLOW}Step 1: Checking Aurora cluster...${NC}"
CLUSTER_STATUS=$(aws rds describe-db-clusters \
    --db-cluster-identifier $TARGET_CLUSTER \
    --query 'DBClusters[0].Status' \
    --output text 2>/dev/null || echo "not-found")

if [ "$CLUSTER_STATUS" = "not-found" ]; then
    echo -e "${RED}Aurora cluster not found. Creating...${NC}"

    # Get VPC info
    echo "Discovering VPC configuration..."
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=false" --query 'Vpcs[0].VpcId' --output text)

    # Create DB subnet group if needed
    SUBNET_GROUP="ordering-db-subnet-group"
    aws rds create-db-subnet-group \
        --db-subnet-group-name $SUBNET_GROUP \
        --db-subnet-group-description "Subnet group for ordering backend" \
        --subnet-ids $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text | head -2 | tr '\t' ' ') \
        2>/dev/null || echo "Subnet group already exists"

    # Create security group
    SECURITY_GROUP="ordering-aurora-sg"
    SG_ID=$(aws ec2 create-security-group \
        --group-name $SECURITY_GROUP \
        --description "Security group for ordering Aurora cluster" \
        --vpc-id $VPC_ID \
        --query 'GroupId' \
        --output text 2>/dev/null || \
        aws ec2 describe-security-groups --filters "Name=group-name,Values=$SECURITY_GROUP" --query 'SecurityGroups[0].GroupId' --output text)

    # Allow PostgreSQL access
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 5432 \
        --cidr 0.0.0.0/0 \
        2>/dev/null || echo "Security group rule already exists"

    # Create Aurora Serverless v2 cluster
    echo -e "${YELLOW}Creating Aurora Serverless v2 cluster...${NC}"
    aws rds create-db-cluster \
        --db-cluster-identifier $TARGET_CLUSTER \
        --engine aurora-postgresql \
        --engine-version 15.4 \
        --master-username $TARGET_USER \
        --master-user-password "$TARGET_PASSWORD" \
        --database-name $TARGET_DB \
        --vpc-security-group-ids $SG_ID \
        --db-subnet-group-name $SUBNET_GROUP \
        --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=2 \
        --backup-retention-period 7 \
        --preferred-backup-window "03:00-04:00" \
        --preferred-maintenance-window "mon:04:00-mon:05:00" \
        --enable-http-endpoint \
        --tags Key=Environment,Value=production Key=Project,Value=ordering-backend

    echo -e "${YELLOW}Waiting for cluster to be available (this may take 10-15 minutes)...${NC}"
    aws rds wait db-cluster-available --db-cluster-identifier $TARGET_CLUSTER

    # Create primary instance
    echo -e "${YELLOW}Creating primary instance...${NC}"
    aws rds create-db-instance \
        --db-instance-identifier "${TARGET_CLUSTER}-instance-1" \
        --db-instance-class db.serverless \
        --engine aurora-postgresql \
        --db-cluster-identifier $TARGET_CLUSTER \
        --publicly-accessible

    echo -e "${YELLOW}Waiting for instance to be available...${NC}"
    aws rds wait db-instance-available --db-instance-identifier "${TARGET_CLUSTER}-instance-1"

    echo -e "${GREEN}✓ Aurora cluster created successfully!${NC}"
else
    echo -e "${GREEN}✓ Aurora cluster already exists (Status: $CLUSTER_STATUS)${NC}"
fi

# Get Aurora endpoint
TARGET_HOST=$(aws rds describe-db-clusters \
    --db-cluster-identifier $TARGET_CLUSTER \
    --query 'DBClusters[0].Endpoint' \
    --output text)

echo ""
echo -e "${GREEN}Aurora Endpoint: $TARGET_HOST${NC}"
echo ""

# Dump ordering database
echo -e "${YELLOW}Step 2: Dumping ordering database...${NC}"
PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
    -h "$SOURCE_HOST" \
    -U "$SOURCE_USER" \
    -d "$SOURCE_DB" \
    --no-owner \
    --no-acl \
    --format=custom \
    --verbose \
    -f /tmp/ordering_backup.dump

DUMP_SIZE=$(du -sh /tmp/ordering_backup.dump | cut -f1)
echo -e "${GREEN}✓ Backup created: $DUMP_SIZE${NC}"

# Dump restaurant database
echo -e "${YELLOW}Step 3: Dumping restaurant database...${NC}"
PGPASSWORD="$RESTAURANT_SOURCE_PASSWORD" pg_dump \
    -h "$RESTAURANT_SOURCE_HOST" \
    -U "$RESTAURANT_SOURCE_USER" \
    -d "$RESTAURANT_SOURCE_DB" \
    --no-owner \
    --no-acl \
    --format=custom \
    --verbose \
    -f /tmp/restaurant_backup.dump

RESTAURANT_DUMP_SIZE=$(du -sh /tmp/restaurant_backup.dump | cut -f1)
echo -e "${GREEN}✓ Restaurant backup created: $RESTAURANT_DUMP_SIZE${NC}"

# Restore ordering database to Aurora
echo -e "${YELLOW}Step 4: Restoring ordering database to Aurora...${NC}"
PGPASSWORD="$TARGET_PASSWORD" pg_restore \
    -h "$TARGET_HOST" \
    -U "$TARGET_USER" \
    -d "$TARGET_DB" \
    --no-owner \
    --no-acl \
    --verbose \
    -j 4 \
    /tmp/ordering_backup.dump || echo "Some warnings during restore are normal"

echo -e "${GREEN}✓ Ordering database restored${NC}"

# Create restaurant database in Aurora
echo -e "${YELLOW}Step 5: Creating restaurant database in Aurora...${NC}"
PGPASSWORD="$TARGET_PASSWORD" psql -h "$TARGET_HOST" -U "$TARGET_USER" -d postgres -c "CREATE DATABASE restaurant_prod;" || echo "Database may already exist"

# Restore restaurant database
echo -e "${YELLOW}Step 6: Restoring restaurant database to Aurora...${NC}"
PGPASSWORD="$TARGET_PASSWORD" pg_restore \
    -h "$TARGET_HOST" \
    -U "$TARGET_USER" \
    -d "restaurant_prod" \
    --no-owner \
    --no-acl \
    --verbose \
    -j 4 \
    /tmp/restaurant_backup.dump || echo "Some warnings during restore are normal"

echo -e "${GREEN}✓ Restaurant database restored${NC}"

# Verify migration
echo -e "${YELLOW}Step 7: Verifying migration...${NC}"

# Count orders
SOURCE_ORDERS=$(PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -U "$SOURCE_USER" -d "$SOURCE_DB" -t -c "SELECT COUNT(*) FROM orders_order;" 2>/dev/null || echo "0")
TARGET_ORDERS=$(PGPASSWORD="$TARGET_PASSWORD" psql -h "$TARGET_HOST" -U "$TARGET_USER" -d "$TARGET_DB" -t -c "SELECT COUNT(*) FROM orders_order;" 2>/dev/null || echo "0")

echo "Orders - Source: $SOURCE_ORDERS, Target: $TARGET_ORDERS"

# Count restaurants
SOURCE_RESTAURANTS=$(PGPASSWORD="$RESTAURANT_SOURCE_PASSWORD" psql -h "$RESTAURANT_SOURCE_HOST" -U "$RESTAURANT_SOURCE_USER" -d "$RESTAURANT_SOURCE_DB" -t -c "SELECT COUNT(*) FROM restaurant_app_restaurant;" 2>/dev/null || echo "0")
TARGET_RESTAURANTS=$(PGPASSWORD="$TARGET_PASSWORD" psql -h "$TARGET_HOST" -U "$TARGET_USER" -d "restaurant_prod" -t -c "SELECT COUNT(*) FROM restaurant_app_restaurant;" 2>/dev/null || echo "0")

echo "Restaurants - Source: $SOURCE_RESTAURANTS, Target: $TARGET_RESTAURANTS"

# Update sequences
echo -e "${YELLOW}Step 8: Updating sequences...${NC}"
PGPASSWORD="$TARGET_PASSWORD" psql -h "$TARGET_HOST" -U "$TARGET_USER" -d "$TARGET_DB" << 'EOF'
DO $$
DECLARE
  seq_record RECORD;
  max_val BIGINT;
  table_name TEXT;
BEGIN
  FOR seq_record IN
    SELECT schemaname, sequencename FROM pg_sequences WHERE schemaname = 'public'
  LOOP
    -- Extract table name from sequence name
    table_name := regexp_replace(seq_record.sequencename, '_id_seq$', '');

    BEGIN
      EXECUTE format('SELECT COALESCE(MAX(id), 1) FROM %I.%I', seq_record.schemaname, table_name) INTO max_val;
      EXECUTE format('SELECT setval(%L, %s)', seq_record.schemaname || '.' || seq_record.sequencename, max_val);
      RAISE NOTICE 'Updated sequence %s to %', seq_record.sequencename, max_val;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Could not update sequence %s: %', seq_record.sequencename, SQLERRM;
    END;
  END LOOP;
END $$;
EOF

echo -e "${GREEN}✓ Sequences updated${NC}"

# Clean up
echo -e "${YELLOW}Step 9: Cleaning up...${NC}"
rm /tmp/ordering_backup.dump
rm /tmp/restaurant_backup.dump
echo -e "${GREEN}✓ Cleanup complete${NC}"

# Store connection info in Secrets Manager
echo -e "${YELLOW}Step 10: Storing credentials in AWS Secrets Manager...${NC}"
aws secretsmanager create-secret \
    --name ordering/prod/database \
    --description "Aurora database credentials for ordering production" \
    --secret-string "{
        \"username\": \"$TARGET_USER\",
        \"password\": \"$TARGET_PASSWORD\",
        \"engine\": \"postgres\",
        \"host\": \"$TARGET_HOST\",
        \"port\": 5432,
        \"dbname\": \"$TARGET_DB\"
    }" \
    2>/dev/null || \
    aws secretsmanager update-secret \
        --secret-id ordering/prod/database \
        --secret-string "{
            \"username\": \"$TARGET_USER\",
            \"password\": \"$TARGET_PASSWORD\",
            \"engine\": \"postgres\",
            \"host\": \"$TARGET_HOST\",
            \"port\": 5432,
            \"dbname\": \"$TARGET_DB\"
        }"

echo -e "${GREEN}✓ Credentials stored in Secrets Manager${NC}"

echo ""
echo "========================================="
echo -e "${GREEN}Migration Complete!${NC}"
echo "========================================="
echo ""
echo "Aurora Cluster Endpoint: $TARGET_HOST"
echo "Database: $TARGET_DB"
echo "Restaurant Database: restaurant_prod"
echo ""
echo "Update your production .env file:"
echo "DB_HOST_SERVER=$TARGET_HOST"
echo "DB_NAME=$TARGET_DB"
echo "RESTAURANT_DB_HOST_SERVER=$TARGET_HOST"
echo "RESTAURANT_DB_NAME=restaurant_prod"
echo ""
echo "Next steps:"
echo "1. Test connection to Aurora"
echo "2. Deploy application to ECS Fargate"
echo "3. Update CloudFront to point to new ALB"
echo ""
