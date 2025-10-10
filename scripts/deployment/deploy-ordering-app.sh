#!/bin/bash
set -e

# Manual deployment script for Ordering App
# Usage: ./deploy-ordering-app.sh [dev|prod] [image-tag]

ENVIRONMENT=${1:-prod}
IMAGE_TAG=${2:-latest}
AWS_REGION=${AWS_REGION:-us-east-1}

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Ordering App Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "Image Tag: ${YELLOW}${IMAGE_TAG}${NC}"
echo ""

# Set environment-specific variables
if [ "$ENVIRONMENT" = "prod" ]; then
    ECS_CLUSTER="deliverykick-prod-cluster"
    ECS_SERVICE="deliverykick-prod-ordering"
    ECR_REPOSITORY="deliverykick-ordering"
elif [ "$ENVIRONMENT" = "dev" ]; then
    ECS_CLUSTER="deliverykick-dev-cluster"
    ECS_SERVICE="deliverykick-dev-ordering"
    ECR_REPOSITORY="deliverykick-ordering-dev"
else
    echo -e "${RED}Invalid environment. Use 'dev' or 'prod'${NC}"
    exit 1
fi

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"

echo -e "${YELLOW}Step 1: Checking prerequisites...${NC}"

# Check if AWS CLI is configured
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}AWS CLI not configured. Run 'aws configure'${NC}"
    exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo -e "${RED}Docker is not running. Please start Docker.${NC}"
    exit 1
fi

# Check if ECR repository exists
if ! aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" --region "$AWS_REGION" &> /dev/null; then
    echo -e "${RED}ECR repository '$ECR_REPOSITORY' does not exist${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites check passed${NC}"
echo ""

# Ask for confirmation
echo -e "${YELLOW}Ready to deploy to ${ENVIRONMENT}?${NC}"
echo "Image: $IMAGE_URI"
echo "Cluster: $ECS_CLUSTER"
echo "Service: $ECS_SERVICE"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

echo -e "${YELLOW}Step 2: Building Docker image...${NC}"
cd "${APP_DIR:-.}"
docker build -t "$ECR_REPOSITORY:$IMAGE_TAG" .
echo -e "${GREEN}✓ Image built${NC}"
echo ""

echo -e "${YELLOW}Step 3: Logging in to ECR...${NC}"
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"
echo -e "${GREEN}✓ Logged in to ECR${NC}"
echo ""

echo -e "${YELLOW}Step 4: Tagging and pushing image...${NC}"
docker tag "$ECR_REPOSITORY:$IMAGE_TAG" "$IMAGE_URI"
docker push "$IMAGE_URI"

# Also push as 'latest' if not already
if [ "$IMAGE_TAG" != "latest" ]; then
    docker tag "$ECR_REPOSITORY:$IMAGE_TAG" "${ECR_REGISTRY}/${ECR_REPOSITORY}:latest"
    docker push "${ECR_REGISTRY}/${ECR_REPOSITORY}:latest"
fi

echo -e "${GREEN}✓ Image pushed to ECR${NC}"
echo ""

echo -e "${YELLOW}Step 5: Updating ECS service...${NC}"
aws ecs update-service \
    --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" \
    --force-new-deployment \
    --region "$AWS_REGION" \
    > /dev/null

echo -e "${GREEN}✓ ECS service update initiated${NC}"
echo ""

echo -e "${YELLOW}Step 6: Waiting for deployment to complete...${NC}"
echo "This may take 2-5 minutes..."

aws ecs wait services-stable \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --region "$AWS_REGION"

echo -e "${GREEN}✓ Deployment completed successfully!${NC}"
echo ""

# Show service status
echo -e "${BLUE}Service Status:${NC}"
aws ecs describe-services \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --region "$AWS_REGION" \
    --query 'services[0].[serviceName,status,runningCount,desiredCount,deployments[0].status]' \
    --output table

echo ""
echo -e "${GREEN}Deployment complete! 🚀${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. Check logs: aws logs tail /ecs/deliverykick-${ENVIRONMENT}/ordering --follow"
echo "2. Run migrations if needed: ./run-migrations.sh ${ENVIRONMENT} ordering"
echo "3. Test the API"
echo ""
