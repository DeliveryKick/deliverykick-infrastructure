variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for ALB"
  type        = list(string)
}

variable "security_group_ids" {
  description = "List of security group IDs for ALB"
  type        = list(string)
}

variable "internal" {
  description = "Whether ALB is internal"
  type        = bool
  default     = false
}

variable "enable_deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
  default     = false
}

variable "enable_access_logs" {
  description = "Enable access logs"
  type        = bool
  default     = false
}

variable "access_logs_bucket" {
  description = "S3 bucket for access logs"
  type        = string
  default     = ""
}

variable "access_logs_prefix" {
  description = "S3 prefix for access logs"
  type        = string
  default     = "alb"
}

variable "certificate_arn" {
  description = "ARN of SSL certificate for HTTPS"
  type        = string
  default     = null
}

variable "ssl_policy" {
  description = "SSL policy for HTTPS listener"
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "enable_https_redirect" {
  description = "Redirect HTTP to HTTPS"
  type        = bool
  default     = false
}

variable "default_target_group" {
  description = "Default target group key"
  type        = string
}

variable "target_groups" {
  description = "Map of target groups to create"
  type = map(object({
    port                            = number
    health_check_path               = string
    health_check_interval           = number
    health_check_timeout            = number
    health_check_healthy_threshold  = number
    health_check_unhealthy_threshold = number
    health_check_matcher            = string
    enable_stickiness               = bool
  }))
}

variable "listener_rules" {
  description = "Map of listener rules for routing"
  type = map(object({
    priority      = number
    target_group  = string
    path_patterns = list(string)
    host_headers  = list(string)
  }))
  default = {}
}

variable "enable_cloudwatch_alarms" {
  description = "Enable CloudWatch alarms"
  type        = bool
  default     = true
}

variable "alarm_actions" {
  description = "List of ARNs for alarm actions"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
