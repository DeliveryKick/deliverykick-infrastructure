# ECR (Elastic Container Registry) Module
# Creates Docker image repositories for each application

resource "aws_ecr_repository" "app" {
  for_each = var.repositories

  name                 = each.key
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = var.encryption_type
    kms_key         = var.kms_key_arn
  }

  tags = merge(
    var.tags,
    {
      Name        = each.key
      Environment = var.environment
      Application = each.value.app_name
    }
  )
}

# Lifecycle policy to clean up old images
resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = var.repositories
  repository = aws_ecr_repository.app[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last ${var.image_retention_count} images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = var.image_retention_count
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Remove untagged images after ${var.untagged_image_retention_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_retention_days
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# IAM policy for CI/CD to push images
resource "aws_iam_policy" "ecr_push" {
  name        = "${var.project_name}-${var.environment}-ecr-push"
  description = "Allow CI/CD to push Docker images to ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = [
          for repo in aws_ecr_repository.app : repo.arn
        ]
      }
    ]
  })

  tags = var.tags
}

# IAM policy for ECS to pull images
resource "aws_iam_policy" "ecr_pull" {
  name        = "${var.project_name}-${var.environment}-ecr-pull"
  description = "Allow ECS tasks to pull Docker images from ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = [
          for repo in aws_ecr_repository.app : repo.arn
        ]
      }
    ]
  })

  tags = var.tags
}

# Repository policy to allow specific AWS accounts (if needed for cross-account access)
resource "aws_ecr_repository_policy" "app" {
  for_each   = var.enable_cross_account_access ? var.repositories : {}
  repository = aws_ecr_repository.app[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCrossAccountPull"
        Effect = "Allow"
        Principal = {
          AWS = var.cross_account_ids
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
      }
    ]
  })
}
