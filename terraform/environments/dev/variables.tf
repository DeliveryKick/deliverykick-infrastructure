variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.1.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.1.10.0/24", "10.1.11.0/24"]
}

variable "aurora_cluster_identifier" {
  description = "Aurora cluster identifier"
  type        = string
  default     = "deliverykick-dev-cluster"
}

variable "aurora_master_username" {
  description = "Aurora master username"
  type        = string
  default     = "postgres"
  sensitive   = true
}

variable "aurora_master_password" {
  description = "Aurora master password"
  type        = string
  sensitive   = true
}
