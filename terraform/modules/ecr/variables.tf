variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "repositories" {
  description = "Map of ECR repositories to create"
  type = map(object({
    app_name = string
  }))
  default = {
    "deliverykick-ordering" = {
      app_name = "ordering"
    }
    "deliverykick-restaurant" = {
      app_name = "restaurant"
    }
  }
}

variable "image_tag_mutability" {
  description = "Image tag mutability (MUTABLE or IMMUTABLE)"
  type        = string
  default     = "MUTABLE"
}

variable "scan_on_push" {
  description = "Enable image scanning on push"
  type        = bool
  default     = true
}

variable "encryption_type" {
  description = "Encryption type (AES256 or KMS)"
  type        = string
  default     = "AES256"
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption (if using KMS)"
  type        = string
  default     = null
}

variable "image_retention_count" {
  description = "Number of images to retain"
  type        = number
  default     = 10
}

variable "untagged_image_retention_days" {
  description = "Days to retain untagged images"
  type        = number
  default     = 7
}

variable "enable_cross_account_access" {
  description = "Enable cross-account access to ECR repositories"
  type        = bool
  default     = false
}

variable "cross_account_ids" {
  description = "List of AWS account IDs for cross-account access"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
