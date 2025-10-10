variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "cluster_identifier" {
  description = "Aurora cluster identifier"
  type        = string
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "15.4"
}

variable "initial_database_name" {
  description = "Initial database name (typically postgres)"
  type        = string
  default     = "postgres"
}

variable "master_username" {
  description = "Master username for Aurora"
  type        = string
  default     = "postgres"
  sensitive   = true
}

variable "master_password" {
  description = "Master password for Aurora (use AWS Secrets Manager in production)"
  type        = string
  sensitive   = true
}

variable "subnet_ids" {
  description = "List of subnet IDs for Aurora"
  type        = list(string)
}

variable "security_group_ids" {
  description = "List of security group IDs for Aurora"
  type        = list(string)
}

variable "min_capacity" {
  description = "Minimum Aurora Serverless capacity (ACU)"
  type        = number
  default     = 0.5
}

variable "max_capacity" {
  description = "Maximum Aurora Serverless capacity (ACU)"
  type        = number
  default     = 2
}

variable "instance_count" {
  description = "Number of Aurora instances"
  type        = number
  default     = 1
}

variable "publicly_accessible" {
  description = "Whether Aurora is publicly accessible"
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Backup retention period in days"
  type        = number
  default     = 7
}

variable "preferred_backup_window" {
  description = "Preferred backup window"
  type        = string
  default     = "03:00-04:00"
}

variable "preferred_maintenance_window" {
  description = "Preferred maintenance window"
  type        = string
  default     = "sun:04:00-sun:05:00"
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot when destroying"
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Apply changes immediately"
  type        = bool
  default     = false
}

variable "kms_key_id" {
  description = "KMS key ID for encryption"
  type        = string
  default     = null
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights"
  type        = bool
  default     = true
}

variable "enable_cloudwatch_alarms" {
  description = "Enable CloudWatch alarms"
  type        = bool
  default     = true
}

variable "alarm_actions" {
  description = "List of ARNs for alarm actions (SNS topics)"
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7
}

variable "use_existing_secrets" {
  description = "Use existing secrets from Secrets Manager (created by setup script)"
  type        = bool
  default     = true
}

variable "master_secret_name" {
  description = "Name of master secret in Secrets Manager"
  type        = string
  default     = "deliverykick/prod/master"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
