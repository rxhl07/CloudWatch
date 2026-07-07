variable "aws_region" {
  type    = string
  default = "us-east-1" # Feel free to change this to your preferred region
}

variable "db_password" {
  type        = string
  description = "The master password for the PostgreSQL database"
  default     = "SuperSecurePassword123!" # In production, use secrets management, but keeping it simple for now
  sensitive   = true
}
