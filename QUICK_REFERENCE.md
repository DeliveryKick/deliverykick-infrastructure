# DeliveryKick Infrastructure Quick Reference

Fast reference for common tasks.

## Initial Setup

```bash
# 1. Create S3 bucket for Terraform state
aws s3 mb s3://deliverykick-terraform-state-prod

# 2. Create DynamoDB for state locking
aws dynamodb create-table --table-name deliverykick-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5

# 3. Run Aurora setup script
cd scripts/deployment
./setup-deliverykick-secure.sh

# 4. Deploy infrastructure
cd terraform/environments/prod
terraform init
export TF_VAR_aurora_master_password="your-password"
terraform apply

# 5. Get outputs
terraform output
```

## Daily Operations

### Deploy Applications

```bash
# Via GitHub Actions (automatic)
git push origin main

# Via manual script
cd deliverykick-infrastructure
APP_DIR=/path/to/app ./scripts/deployment/deploy-ordering-app.sh prod
APP_DIR=/path/to/app ./scripts/deployment/deploy-restaurant-app.sh prod
```

### Run Migrations

```bash
./scripts/deployment/run-migrations.sh prod ordering
./scripts/deployment/run-migrations.sh prod restaurant
```

### View Logs

```bash
# Real-time logs
aws logs tail /ecs/deliverykick-prod/ordering --follow
aws logs tail /ecs/deliverykick-prod/restaurant --follow

# Last 100 lines
aws logs tail /ecs/deliverykick-prod/ordering --since 10m
```

### Check Service Status

```bash
# ECS services
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering deliverykick-prod-restaurant \
  --query 'services[].[serviceName,status,runningCount,desiredCount]' \
  --output table

# Running tasks
aws ecs list-tasks \
  --cluster deliverykick-prod-cluster \
  --service-name deliverykick-prod-ordering
```

### Scale Services

```bash
# Manual scaling
aws ecs update-service \
  --cluster deliverykick-prod-cluster \
  --service deliverykick-prod-ordering \
  --desired-count 4

# Check auto-scaling
aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --resource-ids service/deliverykick-prod-cluster/deliverykick-prod-ordering
```

## Monitoring

### CloudWatch Metrics

```bash
# CPU utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions Name=ClusterName,Value=deliverykick-prod-cluster \
              Name=ServiceName,Value=deliverykick-prod-ordering \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average

# Memory utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ClusterName,Value=deliverykick-prod-cluster \
              Name=ServiceName,Value=deliverykick-prod-ordering \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average
```

### Database Metrics

```bash
# Aurora connections
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBClusterIdentifier,Value=deliverykick-prod-cluster \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average

# Aurora capacity (ACU)
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ServerlessDatabaseCapacity \
  --dimensions Name=DBClusterIdentifier,Value=deliverykick-prod-cluster \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average
```

### ALB Health

```bash
# Target health
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names deliverykick-prod-ordering-tg \
    --query 'TargetGroups[0].TargetGroupArn' --output text)

# Request count
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=app/deliverykick-prod-alb/... \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

## Troubleshooting

### Container Issues

```bash
# Get task details
TASK_ARN=$(aws ecs list-tasks \
  --cluster deliverykick-prod-cluster \
  --service-name deliverykick-prod-ordering \
  --query 'taskArns[0]' --output text)

aws ecs describe-tasks \
  --cluster deliverykick-prod-cluster \
  --tasks $TASK_ARN

# Exec into container
aws ecs execute-command \
  --cluster deliverykick-prod-cluster \
  --task $TASK_ARN \
  --container ordering \
  --interactive \
  --command "/bin/bash"
```

### Database Connection

```bash
# Test from ECS task
aws ecs execute-command \
  --cluster deliverykick-prod-cluster \
  --task $TASK_ARN \
  --container ordering \
  --interactive \
  --command "python manage.py dbshell"

# Check security groups
aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=deliverykick-prod-aurora-sg" \
  --query 'SecurityGroups[0].IpPermissions'
```

### Secrets

```bash
# List secrets
aws secretsmanager list-secrets \
  --filters Key=name,Values=deliverykick/prod

# Get secret value
aws secretsmanager get-secret-value \
  --secret-id deliverykick/prod/ordering/app \
  --query SecretString --output text | jq .

# Update secret
aws secretsmanager update-secret \
  --secret-id deliverykick/prod/ordering/app \
  --secret-string '{"username":"...","password":"...","host":"...","port":5432,"dbname":"..."}'
```

## Rollback

### Rollback via Git

```bash
# Revert last commit
git revert HEAD
git push

# GitHub Actions will automatically deploy
```

### Rollback to Specific Image

```bash
# List images
aws ecr describe-images \
  --repository-name deliverykick-ordering \
  --query 'sort_by(imageDetails,& imagePushedAt)[-10:].[imageTags[0],imagePushedAt]' \
  --output table

# Deploy specific image
APP_DIR=/path/to/app \
  ./scripts/deployment/deploy-ordering-app.sh prod <image-tag>
```

### Rollback Task Definition

```bash
# List task definitions
aws ecs list-task-definitions \
  --family-prefix deliverykick-prod-ordering \
  --sort DESC --max-items 5

# Rollback to previous
aws ecs update-service \
  --cluster deliverykick-prod-cluster \
  --service deliverykick-prod-ordering \
  --task-definition deliverykick-prod-ordering:PREVIOUS_REVISION
```

## Backup & Recovery

### Database Backup

```bash
# Manual snapshot
aws rds create-db-cluster-snapshot \
  --db-cluster-identifier deliverykick-prod-cluster \
  --db-cluster-snapshot-identifier manual-backup-$(date +%Y%m%d-%H%M)

# List snapshots
aws rds describe-db-cluster-snapshots \
  --db-cluster-identifier deliverykick-prod-cluster \
  --query 'DBClusterSnapshots[].[DBClusterSnapshotIdentifier,SnapshotCreateTime,Status]' \
  --output table

# Restore from snapshot
aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier deliverykick-restored \
  --snapshot-identifier <snapshot-id> \
  --engine aurora-postgresql
```

### Export Database

```bash
# From ECS task
aws ecs execute-command \
  --cluster deliverykick-prod-cluster \
  --task $TASK_ARN \
  --container ordering \
  --interactive \
  --command "pg_dump -h \$DB_HOST -U \$DB_USER -d \$DB_NAME > /tmp/backup.sql"

# Copy from task (requires additional setup)
```

## Cost Optimization

### Check Current Costs

```bash
# ECS costs
aws ce get-cost-and-usage \
  --time-period Start=2024-01-01,End=2024-01-31 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --filter file://ecs-filter.json

# Aurora costs
aws ce get-cost-and-usage \
  --time-period Start=2024-01-01,End=2024-01-31 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=SERVICE \
  --filter '{"Services":["Amazon Relational Database Service"]}'
```

### Reduce Costs

```bash
# Scale down dev environment
aws ecs update-service \
  --cluster deliverykick-dev-cluster \
  --service deliverykick-dev-ordering \
  --desired-count 0

# Reduce Aurora capacity
# Edit terraform/environments/prod/variables.tf
# aurora_max_capacity = 1  # Down from 2

cd terraform/environments/prod
terraform apply
```

## Terraform Operations

### Update Infrastructure

```bash
cd terraform/environments/prod

# See what will change
terraform plan

# Apply changes
terraform apply

# Target specific resource
terraform apply -target=module.ecs
```

### Import Existing Resources

```bash
# Import Aurora cluster (if created by bash script)
terraform import module.aurora.aws_rds_cluster.aurora deliverykick-prod-cluster
```

### Destroy Environment

```bash
# Development (safer)
cd terraform/environments/dev
terraform destroy

# Production (be careful!)
cd terraform/environments/prod
terraform destroy  # Will prompt for confirmation
```

## Useful URLs

```bash
# Get ALB URL
terraform output -raw alb_dns_name

# Get Aurora endpoint
terraform output -raw aurora_cluster_endpoint

# AWS Console Links
echo "ECS: https://console.aws.amazon.com/ecs/home?region=us-east-1#/clusters/deliverykick-prod-cluster"
echo "RDS: https://console.aws.amazon.com/rds/home?region=us-east-1#database:id=deliverykick-prod-cluster"
echo "ECR: https://console.aws.amazon.com/ecr/repositories?region=us-east-1"
echo "Secrets: https://console.aws.amazon.com/secretsmanager/home?region=us-east-1"
```

## Emergency Procedures

### App Down - Immediate Response

```bash
# 1. Check service status
aws ecs describe-services \
  --cluster deliverykick-prod-cluster \
  --services deliverykick-prod-ordering \
  --query 'services[0].events[0:5]'

# 2. Check recent logs
aws logs tail /ecs/deliverykick-prod/ordering --since 10m

# 3. Check task health
aws ecs list-tasks \
  --cluster deliverykick-prod-cluster \
  --service-name deliverykick-prod-ordering

# 4. If needed, rollback immediately
git revert HEAD && git push
```

### Database Down

```bash
# 1. Check cluster status
aws rds describe-db-clusters \
  --db-cluster-identifier deliverykick-prod-cluster \
  --query 'DBClusters[0].Status'

# 2. Check recent events
aws rds describe-events \
  --source-identifier deliverykick-prod-cluster \
  --source-type db-cluster \
  --duration 60

# 3. Failover to reader (if available)
aws rds failover-db-cluster \
  --db-cluster-identifier deliverykick-prod-cluster
```

### Security Incident

```bash
# 1. Rotate all credentials immediately
aws secretsmanager rotate-secret --secret-id deliverykick/prod/ordering/app

# 2. Update security groups to lock down
aws ec2 revoke-security-group-ingress \
  --group-id sg-xxx \
  --ip-permissions ...

# 3. Review CloudTrail logs
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)
```

---

## Quick Links

- **Setup:** [GETTING_STARTED.md](GETTING_STARTED.md)
- **Deployment:** [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md)
- **CI/CD:** [docs/CI_CD_SETUP.md](docs/CI_CD_SETUP.md)
- **Terraform:** [terraform/README.md](terraform/README.md)
- **Security:** [docs/POSTGRES_USER_SECURITY.md](docs/POSTGRES_USER_SECURITY.md)
