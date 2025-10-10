# Development Environment Configuration
# Lower cost, simpler setup for development and testing

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "deliverykick-terraform-state-dev"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "deliverykick-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "development"
      Project     = "deliverykick"
      ManagedBy   = "terraform"
    }
  }
}

locals {
  project_name = "deliverykick"
  environment  = "dev"

  common_tags = {
    Environment = local.environment
    Project     = local.project_name
  }
}

# VPC and Networking (simplified for dev)
module "networking" {
  source = "../../modules/networking"

  project_name         = local.project_name
  environment          = local.environment
  aws_region           = var.aws_region
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  enable_nat_gateway   = false  # Cost saving: use public IPs
  enable_vpc_endpoints = false  # Cost saving

  tags = local.common_tags
}

# Secrets Manager
module "secrets" {
  source = "../../modules/secrets"

  project_name          = local.project_name
  environment           = local.environment
  use_existing_secrets  = true
  existing_secret_names = [
    "deliverykick/dev/master",
    "deliverykick/dev/ordering/admin",
    "deliverykick/dev/ordering/app",
    "deliverykick/dev/ordering/readonly",
    "deliverykick/dev/restaurant/admin",
    "deliverykick/dev/restaurant/app",
    "deliverykick/dev/restaurant/readonly"
  ]
  create_admin_policy = true

  tags = local.common_tags
}

# Aurora (or could use RDS Postgres for even lower cost in dev)
module "aurora" {
  source = "../../modules/aurora"

  project_name                 = local.project_name
  environment                  = local.environment
  cluster_identifier           = var.aurora_cluster_identifier
  engine_version               = "15.4"
  master_username              = var.aurora_master_username
  master_password              = var.aurora_master_password
  subnet_ids                   = module.networking.public_subnet_ids  # Public for dev
  security_group_ids           = [module.networking.aurora_security_group_id]
  min_capacity                 = 0.5
  max_capacity                 = 1
  instance_count               = 1
  publicly_accessible          = true  # For dev access
  backup_retention_period      = 1     # Minimal backups
  skip_final_snapshot          = true  # Don't need final snapshot in dev
  apply_immediately            = true  # Apply changes immediately
  performance_insights_enabled = false # Cost saving
  enable_cloudwatch_alarms     = false # No alarms in dev
  use_existing_secrets         = true
  master_secret_name           = "deliverykick/dev/master"

  tags = local.common_tags
}

# ECR Repositories (shared across environments)
module "ecr" {
  source = "../../modules/ecr"

  project_name = local.project_name
  environment  = local.environment

  repositories = {
    "deliverykick-ordering-dev" = {
      app_name = "ordering"
    }
    "deliverykick-restaurant-dev" = {
      app_name = "restaurant"
    }
  }

  scan_on_push                  = false  # Cost saving
  image_retention_count         = 5      # Keep fewer images
  untagged_image_retention_days = 3

  tags = local.common_tags
}

# Application Load Balancer
module "alb" {
  source = "../../modules/alb"

  project_name       = local.project_name
  environment        = local.environment
  vpc_id             = module.networking.vpc_id
  subnet_ids         = module.networking.public_subnet_ids
  security_group_ids = [module.networking.alb_security_group_id]

  internal                   = false
  enable_deletion_protection = false  # Allow easy deletion in dev
  enable_https_redirect      = false
  certificate_arn            = null   # HTTP only for dev
  default_target_group       = "ordering"

  target_groups = {
    ordering = {
      port                             = 8000
      health_check_path                = "/health/"
      health_check_interval            = 30
      health_check_timeout             = 5
      health_check_healthy_threshold   = 2
      health_check_unhealthy_threshold = 3
      health_check_matcher             = "200"
      enable_stickiness                = false
    }
    restaurant = {
      port                             = 8000
      health_check_path                = "/health/"
      health_check_interval            = 30
      health_check_timeout             = 5
      health_check_healthy_threshold   = 2
      health_check_unhealthy_threshold = 3
      health_check_matcher             = "200"
      enable_stickiness                = false
    }
  }

  listener_rules = {
    restaurant_api = {
      priority      = 100
      target_group  = "restaurant"
      path_patterns = ["/restaurant/*", "/api/restaurant/*"]
      host_headers  = null
    }
  }

  enable_cloudwatch_alarms = false  # No alarms in dev

  tags = local.common_tags
}

# ECS Cluster (minimal resources)
module "ecs" {
  source = "../../modules/ecs"

  project_name       = local.project_name
  environment        = local.environment
  aws_region         = var.aws_region
  subnet_ids         = module.networking.public_subnet_ids  # Public for dev
  security_group_ids = [module.networking.ecs_tasks_security_group_id]
  assign_public_ip   = true  # Required without NAT gateway

  applications = {
    ordering = {
      image          = "${module.ecr.repository_urls["deliverykick-ordering-dev"]}:latest"
      cpu            = 256  # Smaller for dev
      memory         = 512
      container_port = 8000
      desired_count  = 1    # Single instance
      min_capacity   = 1
      max_capacity   = 2
      cpu_target_value    = 80
      memory_target_value = 80
      target_group_arn    = module.alb.target_group_arns["ordering"]

      environment_variables = {
        ENVIRONMENT            = "development"
        DJANGO_SETTINGS_MODULE = "core.settings.development"
        ALLOWED_HOSTS          = "*"
        DEBUG                  = "True"
      }

      secret_arns = {
        DB_HOST     = "${module.secrets.ordering_app_secret_arn}:host::"
        DB_PORT     = "${module.secrets.ordering_app_secret_arn}:port::"
        DB_NAME     = "${module.secrets.ordering_app_secret_arn}:dbname::"
        DB_USER     = "${module.secrets.ordering_app_secret_arn}:username::"
        DB_PASSWORD = "${module.secrets.ordering_app_secret_arn}:password::"
      }

      health_check_command = ["CMD-SHELL", "curl -f http://localhost:8000/health/ || exit 1"]
    }

    restaurant = {
      image          = "${module.ecr.repository_urls["deliverykick-restaurant-dev"]}:latest"
      cpu            = 256
      memory         = 512
      container_port = 8000
      desired_count  = 1
      min_capacity   = 1
      max_capacity   = 2
      cpu_target_value    = 80
      memory_target_value = 80
      target_group_arn    = module.alb.target_group_arns["restaurant"]

      environment_variables = {
        ENVIRONMENT            = "development"
        DJANGO_SETTINGS_MODULE = "core.settings.development"
        ALLOWED_HOSTS          = "*"
        DEBUG                  = "True"
      }

      secret_arns = {
        DB_HOST     = "${module.secrets.restaurant_app_secret_arn}:host::"
        DB_PORT     = "${module.secrets.restaurant_app_secret_arn}:port::"
        DB_NAME     = "${module.secrets.restaurant_app_secret_arn}:dbname::"
        DB_USER     = "${module.secrets.restaurant_app_secret_arn}:username::"
        DB_PASSWORD = "${module.secrets.restaurant_app_secret_arn}:password::"
      }

      health_check_command = ["CMD-SHELL", "curl -f http://localhost:8000/health/ || exit 1"]
    }
  }

  secrets_policy_arn  = module.secrets.read_secrets_policy_arn
  ecr_pull_policy_arn = module.ecr.ecr_pull_policy_arn

  enable_container_insights = false  # Cost saving
  enable_autoscaling        = false  # No autoscaling in dev
  enable_execute_command    = true   # Enable for debugging
  log_retention_days        = 3      # Shorter retention

  tags = local.common_tags

  depends_on = [module.alb]
}
