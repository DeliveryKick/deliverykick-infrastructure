# Aurora Serverless v2 PostgreSQL Module
# Integrates with existing Secrets Manager secrets created by setup script

# DB Subnet Group
resource "aws_db_subnet_group" "aurora" {
  name       = "${var.project_name}-${var.environment}-aurora-subnet-group"
  subnet_ids = var.subnet_ids

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-aurora-subnet-group"
    }
  )
}

# Aurora Cluster
resource "aws_rds_cluster" "aurora" {
  cluster_identifier              = var.cluster_identifier
  engine                          = "aurora-postgresql"
  engine_version                  = var.engine_version
  database_name                   = var.initial_database_name
  master_username                 = var.master_username
  master_password                 = var.master_password
  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = var.security_group_ids
  backup_retention_period         = var.backup_retention_period
  preferred_backup_window         = var.preferred_backup_window
  preferred_maintenance_window    = var.preferred_maintenance_window
  enabled_cloudwatch_logs_exports = ["postgresql"]
  skip_final_snapshot             = var.skip_final_snapshot
  final_snapshot_identifier       = var.skip_final_snapshot ? null : "${var.cluster_identifier}-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  apply_immediately               = var.apply_immediately
  storage_encrypted               = true
  kms_key_id                      = var.kms_key_id

  serverlessv2_scaling_configuration {
    min_capacity = var.min_capacity
    max_capacity = var.max_capacity
  }

  tags = merge(
    var.tags,
    {
      Name        = var.cluster_identifier
      Environment = var.environment
      Project     = var.project_name
    }
  )

  lifecycle {
    ignore_changes = [
      master_password, # Managed externally via Secrets Manager
    ]
  }
}

# Aurora Cluster Instance
resource "aws_rds_cluster_instance" "aurora" {
  count               = var.instance_count
  identifier          = "${var.cluster_identifier}-instance-${count.index + 1}"
  cluster_identifier  = aws_rds_cluster.aurora.id
  instance_class      = "db.serverless"
  engine              = aws_rds_cluster.aurora.engine
  engine_version      = aws_rds_cluster.aurora.engine_version
  publicly_accessible = var.publicly_accessible

  performance_insights_enabled    = var.performance_insights_enabled
  performance_insights_kms_key_id = var.performance_insights_enabled ? var.kms_key_id : null

  tags = merge(
    var.tags,
    {
      Name        = "${var.cluster_identifier}-instance-${count.index + 1}"
      Environment = var.environment
    }
  )
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "database_cpu" {
  count               = var.enable_cloudwatch_alarms ? 1 : 0
  alarm_name          = "${var.cluster_identifier}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors Aurora CPU utilization"
  alarm_actions       = var.alarm_actions

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.aurora.cluster_identifier
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "database_connections" {
  count               = var.enable_cloudwatch_alarms ? 1 : 0
  alarm_name          = "${var.cluster_identifier}-high-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors Aurora database connections"
  alarm_actions       = var.alarm_actions

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.aurora.cluster_identifier
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "serverless_capacity" {
  count               = var.enable_cloudwatch_alarms ? 1 : 0
  alarm_name          = "${var.cluster_identifier}-high-capacity"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "ServerlessDatabaseCapacity"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = var.max_capacity * 0.8
  alarm_description   = "This metric monitors Aurora Serverless capacity usage"
  alarm_actions       = var.alarm_actions

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.aurora.cluster_identifier
  }

  tags = var.tags
}

# CloudWatch Log Group (for enhanced monitoring)
resource "aws_cloudwatch_log_group" "aurora" {
  name              = "/aws/rds/cluster/${var.cluster_identifier}/postgresql"
  retention_in_days = var.log_retention_days

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_identifier}-logs"
    }
  )
}

# Data source to read secrets created by setup script
# These are created by scripts/deployment/setup-deliverykick-secure.sh
data "aws_secretsmanager_secret" "master" {
  count = var.use_existing_secrets ? 1 : 0
  name  = var.master_secret_name
}

data "aws_secretsmanager_secret_version" "master" {
  count     = var.use_existing_secrets ? 1 : 0
  secret_id = data.aws_secretsmanager_secret.master[0].id
}

# Output secret ARNs for ECS task definitions to use
data "aws_secretsmanager_secret" "ordering_admin" {
  count = var.use_existing_secrets ? 1 : 0
  name  = "deliverykick/${var.environment}/ordering/admin"
}

data "aws_secretsmanager_secret" "ordering_app" {
  count = var.use_existing_secrets ? 1 : 0
  name  = "deliverykick/${var.environment}/ordering/app"
}

data "aws_secretsmanager_secret" "ordering_readonly" {
  count = var.use_existing_secrets ? 1 : 0
  name  = "deliverykick/${var.environment}/ordering/readonly"
}

data "aws_secretsmanager_secret" "restaurant_admin" {
  count = var.use_existing_secrets ? 1 : 0
  name  = "deliverykick/${var.environment}/restaurant/admin"
}

data "aws_secretsmanager_secret" "restaurant_app" {
  count = var.use_existing_secrets ? 1 : 0
  name  = "deliverykick/${var.environment}/restaurant/app"
}

data "aws_secretsmanager_secret" "restaurant_readonly" {
  count = var.use_existing_secrets ? 1 : 0
  name  = "deliverykick/${var.environment}/restaurant/readonly"
}
