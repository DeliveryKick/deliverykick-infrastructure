output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "aurora_cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = module.aurora.cluster_endpoint
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.alb.alb_dns_name
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs.cluster_name
}

output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value       = module.ecr.repository_urls
}

output "dev_endpoints" {
  description = "Development environment endpoints"
  value = {
    ordering_api   = "http://${module.alb.alb_dns_name}"
    restaurant_api = "http://${module.alb.alb_dns_name}/restaurant"
    database       = module.aurora.cluster_endpoint
  }
}
