variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "aurora_cluster_identifier" {
  description = "Aurora cluster identifier"
  type        = string
  default     = "deliverykick-prod-cluster"
}

variable "aurora_master_username" {
  description = "Aurora master username"
  type        = string
  default     = "postgres"
  sensitive   = true
}

variable "aurora_master_password" {
  description = "Aurora master password (store in AWS Secrets Manager or use TF_VAR)"
  type        = string
  sensitive   = true
}

variable "aurora_min_capacity" {
  description = "Aurora minimum capacity (ACU)"
  type        = number
  default     = 0.5
}

variable "aurora_max_capacity" {
  description = "Aurora maximum capacity (ACU)"
  type        = number
  default     = 2
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS"
  type        = string
  default     = null
}

variable "enable_https_redirect" {
  description = "Redirect HTTP to HTTPS"
  type        = bool
  default     = false
}

variable "allowed_hosts" {
  description = "Comma-separated list of allowed hosts for Django"
  type        = string
  default     = "*"
}
