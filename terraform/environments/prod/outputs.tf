output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "aurora_cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = module.aurora.cluster_endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = module.aurora.cluster_reader_endpoint
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "ALB Route53 zone ID"
  value       = module.alb.alb_zone_id
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs.cluster_name
}

output "ecs_service_names" {
  description = "ECS service names"
  value       = module.ecs.service_names
}

output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value       = module.ecr.repository_urls
}

output "ordering_repository_url" {
  description = "Ordering app ECR repository URL"
  value       = module.ecr.ordering_repository_url
}

output "restaurant_repository_url" {
  description = "Restaurant app ECR repository URL"
  value       = module.ecr.restaurant_repository_url
}

output "secret_arns" {
  description = "Secrets Manager secret ARNs"
  value       = module.secrets.secret_arns
  sensitive   = true
}
