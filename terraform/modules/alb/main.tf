# Application Load Balancer Module
# Creates ALB, target groups, and listeners for routing traffic to ECS services

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = var.internal
  load_balancer_type = "application"
  security_groups    = var.security_group_ids
  subnets            = var.subnet_ids

  enable_deletion_protection = var.enable_deletion_protection
  enable_http2               = true
  enable_cross_zone_load_balancing = true

  drop_invalid_header_fields = true

  access_logs {
    enabled = var.enable_access_logs
    bucket  = var.access_logs_bucket
    prefix  = var.access_logs_prefix
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.project_name}-${var.environment}-alb"
      Environment = var.environment
    }
  )
}

# Target Groups for each application
resource "aws_lb_target_group" "app" {
  for_each = var.target_groups

  name        = "${var.project_name}-${var.environment}-${each.key}-tg"
  port        = each.value.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # For Fargate

  health_check {
    enabled             = true
    healthy_threshold   = each.value.health_check_healthy_threshold
    unhealthy_threshold = each.value.health_check_unhealthy_threshold
    timeout             = each.value.health_check_timeout
    interval            = each.value.health_check_interval
    path                = each.value.health_check_path
    matcher             = each.value.health_check_matcher
  }

  deregistration_delay = 30

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = each.value.enable_stickiness
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.project_name}-${var.environment}-${each.key}-tg"
      Application = each.key
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# HTTP Listener (redirect to HTTPS if enabled)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = var.enable_https_redirect ? "redirect" : "forward"

    dynamic "redirect" {
      for_each = var.enable_https_redirect ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "forward" {
      for_each = var.enable_https_redirect ? [] : [1]
      content {
        target_group_arn = aws_lb_target_group.app[var.default_target_group].arn
      }
    }
  }

  tags = var.tags
}

# HTTPS Listener (if certificate is provided)
resource "aws_lb_listener" "https" {
  count = var.certificate_arn != null ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[var.default_target_group].arn
  }

  tags = var.tags
}

# Listener Rules for path-based routing
resource "aws_lb_listener_rule" "app" {
  for_each = var.listener_rules

  listener_arn = var.certificate_arn != null ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[each.value.target_group].arn
  }

  dynamic "condition" {
    for_each = each.value.path_patterns != null ? [1] : []
    content {
      path_pattern {
        values = each.value.path_patterns
      }
    }
  }

  dynamic "condition" {
    for_each = each.value.host_headers != null ? [1] : []
    content {
      host_header {
        values = each.value.host_headers
      }
    }
  }

  tags = merge(
    var.tags,
    {
      Rule = each.key
    }
  )
}

# CloudWatch Alarms for ALB
resource "aws_cloudwatch_metric_alarm" "alb_healthy_hosts" {
  for_each = var.enable_cloudwatch_alarms ? var.target_groups : {}

  alarm_name          = "${var.project_name}-${var.environment}-${each.key}-unhealthy-hosts"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Average"
  threshold           = "1"
  alarm_description   = "Alert when healthy host count is below 1"
  alarm_actions       = var.alarm_actions

  dimensions = {
    TargetGroup  = aws_lb_target_group.app[each.key].arn_suffix
    LoadBalancer = aws_lb.main.arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_target_response_time" {
  for_each = var.enable_cloudwatch_alarms ? var.target_groups : {}

  alarm_name          = "${var.project_name}-${var.environment}-${each.key}-high-response-time"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Average"
  threshold           = "1"
  alarm_description   = "Alert when response time is above 1 second"
  alarm_actions       = var.alarm_actions

  dimensions = {
    TargetGroup  = aws_lb_target_group.app[each.key].arn_suffix
    LoadBalancer = aws_lb.main.arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${var.project_name}-${var.environment}-alb-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Sum"
  threshold           = "10"
  alarm_description   = "Alert when 5XX errors exceed threshold"
  alarm_actions       = var.alarm_actions

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  tags = var.tags
}
