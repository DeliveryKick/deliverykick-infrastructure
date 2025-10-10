output "repository_urls" {
  description = "Map of repository names to URLs"
  value = {
    for key, repo in aws_ecr_repository.app : key => repo.repository_url
  }
}

output "repository_arns" {
  description = "Map of repository names to ARNs"
  value = {
    for key, repo in aws_ecr_repository.app : key => repo.arn
  }
}

output "repository_ids" {
  description = "Map of repository names to IDs"
  value = {
    for key, repo in aws_ecr_repository.app : key => repo.registry_id
  }
}

output "ordering_repository_url" {
  description = "Ordering app repository URL"
  value       = lookup({ for k, v in aws_ecr_repository.app : k => v.repository_url }, "deliverykick-ordering", null)
}

output "restaurant_repository_url" {
  description = "Restaurant app repository URL"
  value       = lookup({ for k, v in aws_ecr_repository.app : k => v.repository_url }, "deliverykick-restaurant", null)
}

output "ecr_push_policy_arn" {
  description = "ARN of IAM policy for pushing to ECR"
  value       = aws_iam_policy.ecr_push.arn
}

output "ecr_pull_policy_arn" {
  description = "ARN of IAM policy for pulling from ECR"
  value       = aws_iam_policy.ecr_pull.arn
}
