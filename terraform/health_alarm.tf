# ─────────────────────────────────────────────────────────────────────
# External health-check alarm for https://<domain>/health
#
# A Route 53 health check probes the public endpoint from AWS's global
# checkers (tests DNS + TLS + Caddy + app together). Route 53 publishes
# its HealthCheckStatus metric ONLY in us-east-1, so the alarm + SNS
# topic live there — the rest of the stack stays in ap-south-1 (Mumbai).
# ─────────────────────────────────────────────────────────────────────

# us-east-1 provider, required for Route 53 health-check CloudWatch metrics.
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

variable "alarm_email" {
  description = "Email subscribed to the health-check SNS topic (confirm via the email link)."
  type        = string
  default     = "udathak@gmail.com"
}

# Route 53 health check — external HTTPS probe of /health.
resource "aws_route53_health_check" "health" {
  fqdn              = var.domain
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  request_interval  = 30 # seconds between probes
  failure_threshold = 3  # consecutive fails before the check flips unhealthy
  measure_latency   = true

  tags = {
    Name = "${var.project_name}-health"
  }
}

# SNS topic + email subscription (us-east-1, to match the alarm).
resource "aws_sns_topic" "health_alarms" {
  provider = aws.use1
  name     = "${var.project_name}-health-alarms"
}

resource "aws_sns_topic_subscription" "health_email" {
  provider  = aws.use1
  topic_arn = aws_sns_topic.health_alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# CloudWatch alarm on the Route 53 health-check status.
# HealthCheckStatus = 1 (healthy) / 0 (unhealthy); alarm when it drops below 1.
resource "aws_cloudwatch_metric_alarm" "health_check_failed" {
  provider            = aws.use1
  alarm_name          = "${var.project_name}-health-check-failed"
  alarm_description   = "Route 53 health check for https://${var.domain}/health is failing (endpoint down or unhealthy)."
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.health.id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.health_alarms.arn]
  ok_actions          = [aws_sns_topic.health_alarms.arn]
}

output "health_check_id" {
  description = "Route 53 health check id (metrics in us-east-1 AWS/Route53)."
  value       = aws_route53_health_check.health.id
}

output "health_alarm_sns_topic" {
  description = "SNS topic ARN for health-check notifications (confirm the email subscription)."
  value       = aws_sns_topic.health_alarms.arn
}
