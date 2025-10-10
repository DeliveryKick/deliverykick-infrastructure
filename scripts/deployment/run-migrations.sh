#!/bin/bash
set -e

# Run database migrations in ECS
# Usage: ./run-migrations.sh [dev|prod] [ordering|restaurant]

ENVIRONMENT=${1:-prod}
APP=${2:-ordering}
AWS_REGION=${AWS_REGION:-us-east-1}

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Database Migration Runner${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "Application: ${YELLOW}${APP}${NC}"
echo ""

# Set environment-specific variables
if [ "$ENVIRONMENT" = "prod" ]; then
    ECS_CLUSTER="deliverykick-prod-cluster"
    ECS_SERVICE="deliverykick-prod-${APP}"
elif [ "$ENVIRONMENT" = "dev" ]; then
    ECS_CLUSTER="deliverykick-dev-cluster"
    ECS_SERVICE="deliverykick-dev-${APP}"
else
    echo -e "${RED}Invalid environment. Use 'dev' or 'prod'${NC}"
    exit 1
fi

if [ "$APP" != "ordering" ] && [ "$APP" != "restaurant" ]; then
    echo -e "${RED}Invalid app. Use 'ordering' or 'restaurant'${NC}"
    exit 1
fi

echo -e "${YELLOW}Step 1: Finding running task...${NC}"

# Get a running task ARN
TASK_ARN=$(aws ecs list-tasks \
    --cluster "$ECS_CLUSTER" \
    --service-name "$ECS_SERVICE" \
    --desired-status RUNNING \
    --region "$AWS_REGION" \
    --query 'taskArns[0]' \
    --output text)

if [ "$TASK_ARN" = "None" ] || [ -z "$TASK_ARN" ]; then
    echo -e "${RED}No running tasks found for service ${ECS_SERVICE}${NC}"
    echo "Make sure the service is running first."
    exit 1
fi

TASK_ID=$(echo "$TASK_ARN" | awk -F'/' '{print $NF}')
echo -e "${GREEN}✓ Found task: ${TASK_ID}${NC}"
echo ""

echo -e "${YELLOW}Step 2: Running migrations...${NC}"
echo "Command: python manage.py migrate --noinput"
echo ""

# Run migrations using ECS Exec
aws ecs execute-command \
    --cluster "$ECS_CLUSTER" \
    --task "$TASK_ARN" \
    --container "$APP" \
    --region "$AWS_REGION" \
    --interactive \
    --command "python manage.py migrate --noinput"

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Migrations completed successfully!${NC}"
else
    echo -e "${RED}✗ Migrations failed with exit code ${EXIT_CODE}${NC}"
    exit $EXIT_CODE
fi

echo ""
echo -e "${BLUE}Additional migration commands:${NC}"
echo ""
echo "Check migration status:"
echo "  aws ecs execute-command --cluster $ECS_CLUSTER --task $TASK_ARN --container $APP --interactive --command 'python manage.py showmigrations'"
echo ""
echo "Create a new migration:"
echo "  aws ecs execute-command --cluster $ECS_CLUSTER --task $TASK_ARN --container $APP --interactive --command 'python manage.py makemigrations'"
echo ""
echo "Roll back migrations:"
echo "  aws ecs execute-command --cluster $ECS_CLUSTER --task $TASK_ARN --container $APP --interactive --command 'python manage.py migrate <app_name> <migration_number>'"
echo ""
