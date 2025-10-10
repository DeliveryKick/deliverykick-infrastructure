variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for ECS tasks"
  type        = list(string)
}

variable "security_group_ids" {
  description = "List of security group IDs for ECS tasks"
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Assign public IP to ECS tasks"
  type        = bool
  default     = false
}

variable "applications" {
  description = "Map of applications to deploy"
  type = map(object({
    image                    = string
    cpu                      = number
    memory                   = number
    container_port           = number
    desired_count            = number
    min_capacity             = number
    max_capacity             = number
    cpu_target_value         = number
    memory_target_value      = number
    target_group_arn         = string
    environment_variables    = map(string)
    secret_arns              = map(string)
    health_check_command     = list(string)
  }))
}

variable "secrets_policy_arn" {
  description = "ARN of IAM policy to read secrets"
  type        = string
}

variable "ecr_pull_policy_arn" {
  description = "ARN of IAM policy to pull ECR images"
  type        = string
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights"
  type        = bool
  default     = true
}

variable "enable_autoscaling" {
  description = "Enable auto-scaling for ECS services"
  type        = bool
  default     = true
}

variable "enable_execute_command" {
  description = "Enable ECS Exec for debugging"
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
