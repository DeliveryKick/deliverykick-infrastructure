output "cluster_id" {
  description = "ECS cluster ID"
  value       = aws_ecs_cluster.main.id
}

output "cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.main.arn
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "task_execution_role_arn" {
  description = "ECS task execution role ARN"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "task_role_arns" {
  description = "Map of application task role ARNs"
  value = {
    for key, role in aws_iam_role.ecs_task : key => role.arn
  }
}

output "service_names" {
  description = "Map of application service names"
  value = {
    for key, service in aws_ecs_service.app : key => service.name
  }
}

output "service_arns" {
  description = "Map of application service ARNs"
  value = {
    for key, service in aws_ecs_service.app : key => service.id
  }
}

output "task_definition_arns" {
  description = "Map of application task definition ARNs"
  value = {
    for key, td in aws_ecs_task_definition.app : key => td.arn
  }
}

output "log_group_names" {
  description = "Map of CloudWatch log group names"
  value = {
    for key, lg in aws_cloudwatch_log_group.ecs_tasks : key => lg.name
  }
}
