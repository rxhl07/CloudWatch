output "rds_endpoint" {
  value       = aws_db_instance.postgres.endpoint
  description = "The connection endpoint for the PostgreSQL Database"
}

output "alb_dns_name" {
  value       = aws_lb.app_alb.dns_name
  description = "The public-facing URL of your Application Load Balancer to view your UI dashboard"
}
