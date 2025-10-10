output "alb_id" {
  description = "ALB ID"
  value       = aws_lb.main.id
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "ALB zone ID for Route53"
  value       = aws_lb.main.zone_id
}

output "target_group_arns" {
  description = "Map of target group ARNs"
  value = {
    for key, tg in aws_lb_target_group.app : key => tg.arn
  }
}

output "target_group_ids" {
  description = "Map of target group IDs"
  value = {
    for key, tg in aws_lb_target_group.app : key => tg.id
  }
}

output "http_listener_arn" {
  description = "HTTP listener ARN"
  value       = aws_lb_listener.http.arn
}

output "https_listener_arn" {
  description = "HTTPS listener ARN"
  value       = var.certificate_arn != null ? aws_lb_listener.https[0].arn : null
}
