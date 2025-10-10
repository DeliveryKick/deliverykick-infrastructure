# Production Environment Configuration
# This file orchestrates all modules for the production environment

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "deliverykick-terraform-state-prod"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "deliverykick-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "production"
      Project     = "deliverykick"
      ManagedBy   = "terraform"
    }
  }
}

# Local variables
locals {
  project_name = "deliverykick"
  environment  = "prod"

  common_tags = {
    Environment = local.environment
    Project     = local.project_name
  }
}

# VPC and Networking
module "networking" {
  source = "../../modules/networking"

  project_name       = local.project_name
  environment        = local.environment
  aws_region         = var.aws_region
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  public_subnet_cidrs = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  enable_nat_gateway  = true
  enable_vpc_endpoints = true

  tags = local.common_tags
}

# Secrets Manager (references existing secrets from setup script)
module "secrets" {
  source = "../../modules/secrets"

  project_name          = local.project_name
  environment           = local.environment
  use_existing_secrets  = true
  existing_secret_names = [
    "deliverykick/prod/master",
    "deliverykick/prod/ordering/admin",
    "deliverykick/prod/ordering/app",
    "deliverykick/prod/ordering/readonly",
    "deliverykick/prod/restaurant/admin",
    "deliverykick/prod/restaurant/app",
    "deliverykick/prod/restaurant/readonly"
  ]
  create_admin_policy = true

  tags = local.common_tags
}

# Aurora Serverless v2 PostgreSQL
module "aurora" {
  source = "../../modules/aurora"

  project_name           = local.project_name
  environment            = local.environment
  cluster_identifier     = var.aurora_cluster_identifier
  engine_version         = "15.4"
  master_username        = var.aurora_master_username
  master_password        = var.aurora_master_password
  subnet_ids             = module.networking.private_subnet_ids
  security_group_ids     = [module.networking.aurora_security_group_id]
  min_capacity           = var.aurora_min_capacity
  max_capacity           = var.aurora_max_capacity
  instance_count         = 1
  publicly_accessible    = false
  backup_retention_period = 7
  skip_final_snapshot    = false
  apply_immediately      = false
  performance_insights_enabled = true
  enable_cloudwatch_alarms = true
  use_existing_secrets   = true
  master_secret_name     = "deliverykick/prod/master"

  tags = local.common_tags
}

# ECR Repositories
module "ecr" {
  source = "../../modules/ecr"

  project_name = local.project_name
  environment  = local.environment

  repositories = {
    "deliverykick-ordering" = {
      app_name = "ordering"
    }
    "deliverykick-restaurant" = {
      app_name = "restaurant"
    }
  }

  scan_on_push              = true
  image_retention_count     = 10
  untagged_image_retention_days = 7

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
  enable_deletion_protection = true
  enable_https_redirect      = var.enable_https_redirect
  certificate_arn            = var.certificate_arn
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
      enable_stickiness                = true
    }
    restaurant = {
      port                             = 8000
      health_check_path                = "/health/"
      health_check_interval            = 30
      health_check_timeout             = 5
      health_check_healthy_threshold   = 2
      health_check_unhealthy_threshold = 3
      health_check_matcher             = "200"
      enable_stickiness                = true
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

  enable_cloudwatch_alarms = true

  tags = local.common_tags
}

# ECS Cluster and Services
module "ecs" {
  source = "../../modules/ecs"

  project_name       = local.project_name
  environment        = local.environment
  aws_region         = var.aws_region
  subnet_ids         = module.networking.private_subnet_ids
  security_group_ids = [module.networking.ecs_tasks_security_group_id]
  assign_public_ip   = false

  applications = {
    ordering = {
      image          = "${module.ecr.ordering_repository_url}:latest"
      cpu            = 512
      memory         = 1024
      container_port = 8000
      desired_count  = 2
      min_capacity   = 2
      max_capacity   = 10
      cpu_target_value    = 70
      memory_target_value = 80
      target_group_arn    = module.alb.target_group_arns["ordering"]

      environment_variables = {
        ENVIRONMENT     = "production"
        DJANGO_SETTINGS_MODULE = "core.settings.production"
        ALLOWED_HOSTS   = var.allowed_hosts
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
      image          = "${module.ecr.restaurant_repository_url}:latest"
      cpu            = 512
      memory         = 1024
      container_port = 8000
      desired_count  = 2
      min_capacity   = 2
      max_capacity   = 10
      cpu_target_value    = 70
      memory_target_value = 80
      target_group_arn    = module.alb.target_group_arns["restaurant"]

      environment_variables = {
        ENVIRONMENT     = "production"
        DJANGO_SETTINGS_MODULE = "core.settings.production"
        ALLOWED_HOSTS   = var.allowed_hosts
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

  enable_container_insights = true
  enable_autoscaling        = true
  enable_execute_command    = false
  log_retention_days        = 30

  tags = local.common_tags

  depends_on = [module.alb]
}
