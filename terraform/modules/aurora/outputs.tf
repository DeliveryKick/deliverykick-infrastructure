output "cluster_id" {
  description = "Aurora cluster ID"
  value       = aws_rds_cluster.aurora.id
}

output "cluster_arn" {
  description = "Aurora cluster ARN"
  value       = aws_rds_cluster.aurora.arn
}

output "cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = aws_rds_cluster.aurora.endpoint
}

output "cluster_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "cluster_port" {
  description = "Aurora cluster port"
  value       = aws_rds_cluster.aurora.port
}

output "cluster_database_name" {
  description = "Aurora initial database name"
  value       = aws_rds_cluster.aurora.database_name
}

output "cluster_master_username" {
  description = "Aurora master username"
  value       = aws_rds_cluster.aurora.master_username
  sensitive   = true
}

output "instance_endpoints" {
  description = "Aurora instance endpoints"
  value       = aws_rds_cluster_instance.aurora[*].endpoint
}

# Secret ARNs for ECS task definitions
output "ordering_admin_secret_arn" {
  description = "ARN of ordering admin secret (for migrations)"
  value       = var.use_existing_secrets ? data.aws_secretsmanager_secret.ordering_admin[0].arn : null
}

output "ordering_app_secret_arn" {
  description = "ARN of ordering app secret (runtime)"
  value       = var.use_existing_secrets ? data.aws_secretsmanager_secret.ordering_app[0].arn : null
}

output "ordering_readonly_secret_arn" {
  description = "ARN of ordering readonly secret (analytics)"
  value       = var.use_existing_secrets ? data.aws_secretsmanager_secret.ordering_readonly[0].arn : null
}

output "restaurant_admin_secret_arn" {
  description = "ARN of restaurant admin secret (for migrations)"
  value       = var.use_existing_secrets ? data.aws_secretsmanager_secret.restaurant_admin[0].arn : null
}

output "restaurant_app_secret_arn" {
  description = "ARN of restaurant app secret (runtime)"
  value       = var.use_existing_secrets ? data.aws_secretsmanager_secret.restaurant_app[0].arn : null
}

output "restaurant_readonly_secret_arn" {
  description = "ARN of restaurant readonly secret (analytics)"
  value       = var.use_existing_secrets ? data.aws_secretsmanager_secret.restaurant_readonly[0].arn : null
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.aurora.name
}
