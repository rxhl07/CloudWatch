terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ==========================================
# 1. NETWORKING LAYER (VPC & SUBNETS)
# ==========================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "OpsPulse-VPC"
  }
}

resource "aws_subnet" "public_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "OpsPulse-Public-Subnet-1" }
}

resource "aws_subnet" "public_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}b"
  tags              = { Name = "OpsPulse-Public-Subnet-2" }
}

resource "aws_subnet" "private_app_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "OpsPulse-Private-App-1" }
}

resource "aws_subnet" "private_app_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "${var.aws_region}b"
  tags              = { Name = "OpsPulse-Private-App-2" }
}

resource "aws_subnet" "private_db_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.20.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "OpsPulse-Private-DB-1" }
}

resource "aws_subnet" "private_db_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.21.0/24"
  availability_zone = "${var.aws_region}b"
  tags              = { Name = "OpsPulse-Private-DB-2" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "OpsPulse-IGW" }
}

# NAT Gateway Infrastructure for Private Tiers
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "OpsPulse-NAT-EIP" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_1.id
  tags          = { Name = "OpsPulse-NAT-Gateway" }
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "OpsPulse-Public-RT" }
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "OpsPulse-Private-App-RT" }
}

# Associations
resource "aws_route_table_association" "pub_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "pub_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app_1" {
  subnet_id      = aws_subnet.private_app_1.id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table_association" "app_2" {
  subnet_id      = aws_subnet.private_app_2.id
  route_table_id = aws_route_table.private_app.id
}

# ==========================================
# 2. FIREWALL & SECURITY GROUPS LAYER
# ==========================================

resource "aws_security_group" "alb" {
  name        = "opspulse-alb-sg"
  description = "Allow inbound public traffic to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app" {
  name        = "opspulse-app-sg"
  description = "Allow traffic ONLY from the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "opspulse-db-sg"
  description = "Allow traffic ONLY from App Tier on PostgreSQL port 5432"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# 3. DATA LAYER (AMAZON RDS POSTGRESQL)
# ==========================================

resource "aws_db_subnet_group" "db_group" {
  name       = "opspulse-db-subnet-group"
  subnet_ids = [aws_subnet.private_db_1.id, aws_subnet.private_db_2.id]
  tags       = { Name = "OpsPulse DB Subnet Group" }
}

resource "aws_db_instance" "postgres" {
  identifier             = "opspulse-postgres-db"
  allocated_storage      = 20
  max_allocated_storage  = 100
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = "db.t4g.micro"
  db_name                = "opspulse_db"
  username               = "opspulse_admin"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.db_group.name
  vpc_security_group_ids = [aws_security_group.db.id]
  skip_final_snapshot    = true

  tags = {
    Name = "OpsPulse-Backend-DB"
  }
}

# ==========================================
# 4. APP COMPUTE & LOAD BALANCING TIER
# ==========================================

resource "aws_lb" "app_alb" {
  name               = "opspulse-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]

  tags = { Name = "OpsPulse-ALB" }
}

resource "aws_lb_target_group" "app_tg" {
  name        = "opspulse-app-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/"
    port                = "8000"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# IAM Execution setup
resource "aws_iam_role" "ec2_role" {
  name = "opspulse-ec2-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cw_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "opspulse-ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# EC2 Launch Template
resource "aws_launch_template" "app_template" {
  name_prefix   = "opspulse-tpl-"
  image_id      = "ami-04b70fa74e45c3917" # Ensure this Ubuntu AMI exists in your target region
  instance_type = "t3.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  network_interfaces {
    associate_public_ip_address = false # Instances now safely leverage the NAT gateway routed configuration
    security_groups             = [aws_security_group.app.id]
  }

  user_data = base64encode(templatefile("${path.module}/../scripts/user_data.sh", {
    DB_HOST     = aws_db_instance.postgres.address
    DB_PASSWORD = var.db_password
    AWS_REGION  = var.aws_region
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "OpsPulse-App-Node"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ==========================================
# 5. AUTO SCALING GROUP & SCALING POLICIES
# ==========================================

resource "aws_autoscaling_group" "app_asg" {
  name_prefix         = "opspulse-asg-"
  vpc_zone_identifier = [aws_subnet.private_app_1.id, aws_subnet.private_app_2.id]
  target_group_arns   = [aws_lb_target_group.app_tg.arn]

  min_size         = 1
  max_size         = 3
  desired_capacity = 1

  force_delete              = true
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app_template.id
    version = aws_launch_template.app_template.latest_version # FIXED: Triggers rolling upgrade on template drift
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["tag"]
  }
}

resource "aws_autoscaling_policy" "cpu_scaling" {
  name                   = "opspulse-cpu-tracking-policy"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50.0
  }
}

# Attach Read-Only access so Boto3 can fetch data for the Streamlit graphs
resource "aws_iam_role_policy_attachment" "cw_readonly_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}
