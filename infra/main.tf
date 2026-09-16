######################################################################
# Provider
######################################################################

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "terraform-sk-krutarth-267673636159-us-east-2-an"
    key          = "cicd-project/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true   # Native S3 locking (Terraform >= 1.10) – no DynamoDB table needed
  }
}

provider "aws" {
  region = "us-east-2"
}

######################################################################
# Data – availability zones
######################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

######################################################################
# VPC
######################################################################

resource "aws_vpc" "cicd_project" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "CiCd-Project-VPC"
  }
}

######################################################################
# Internet Gateway
######################################################################

resource "aws_internet_gateway" "cicd_project" {
  vpc_id = aws_vpc.cicd_project.id

  tags = {
    Name = "CiCd-Project-IGW"
  }
}

######################################################################
# Public Subnets (2 AZs – required for ALB)
######################################################################

resource "aws_subnet" "cicd_project_public_a" {
  vpc_id                  = aws_vpc.cicd_project.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "CiCd-Project-Public-Subnet-A"
  }
}

resource "aws_subnet" "cicd_project_public_b" {
  vpc_id                  = aws_vpc.cicd_project.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "CiCd-Project-Public-Subnet-B"
  }
}

######################################################################
# Route Table
######################################################################

resource "aws_route_table" "cicd_project_public" {
  vpc_id = aws_vpc.cicd_project.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cicd_project.id
  }

  tags = {
    Name = "CiCd-Project-Public-RT"
  }
}

resource "aws_route_table_association" "cicd_project_public_a" {
  subnet_id      = aws_subnet.cicd_project_public_a.id
  route_table_id = aws_route_table.cicd_project_public.id
}

resource "aws_route_table_association" "cicd_project_public_b" {
  subnet_id      = aws_subnet.cicd_project_public_b.id
  route_table_id = aws_route_table.cicd_project_public.id
}

######################################################################
# Security Group – ALB (public HTTP)
######################################################################

resource "aws_security_group" "cicd_project_alb" {
  name        = "CiCd-Project-ALB-SG"
  description = "Allow HTTP inbound to ALB"
  vpc_id      = aws_vpc.cicd_project.id

  ingress {
    description = "HTTP from internet"
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

  tags = {
    Name = "CiCd-Project-ALB-SG"
  }
}

######################################################################
# Security Group – ECS Tasks (allow traffic only from ALB)
######################################################################

resource "aws_security_group" "cicd_project_ecs" {
  name        = "CiCd-Project-ECS-SG"
  description = "Allow traffic from ALB to ECS tasks"
  vpc_id      = aws_vpc.cicd_project.id

  ingress {
    description     = "Nginx port from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.cicd_project_alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "CiCd-Project-ECS-SG"
  }
}

######################################################################
# Application Load Balancer
######################################################################

resource "aws_lb" "cicd_project" {
  name               = "CiCd-Project-ALB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.cicd_project_alb.id]
  subnets            = [
    aws_subnet.cicd_project_public_a.id,
    aws_subnet.cicd_project_public_b.id,
  ]

  tags = {
    Name = "CiCd-Project-ALB"
  }
}

resource "aws_lb_target_group" "cicd_project" {
  name        = "CiCd-Project-TG"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.cicd_project.id
  target_type = "ip"   # Required for Fargate / awsvpc networking

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "CiCd-Project-TG"
  }
}

resource "aws_lb_listener" "cicd_project_http" {
  load_balancer_arn = aws_lb.cicd_project.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cicd_project.arn
  }
}

######################################################################
# IAM – ECS Task Execution Role
######################################################################

resource "aws_iam_role" "cicd_project_ecs_exec" {
  name = "CiCd-Project-ECS-ExecRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "CiCd-Project-ECS-ExecRole"
  }
}

resource "aws_iam_role_policy_attachment" "cicd_project_ecs_exec" {
  role       = aws_iam_role.cicd_project_ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

######################################################################
# IAM – Auto Scaling Role
######################################################################

resource "aws_iam_role" "cicd_project_autoscaling" {
  name = "CiCd-Project-AutoScaling-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "application-autoscaling.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "CiCd-Project-AutoScaling-Role"
  }
}

resource "aws_iam_role_policy_attachment" "cicd_project_autoscaling" {
  role       = aws_iam_role.cicd_project_autoscaling.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceAutoscaleRole"
}

######################################################################
# ECR Repository
######################################################################

resource "aws_ecr_repository" "cicd_project_nginx" {
  name                 = "cicd-project/nginx"
  image_tag_mutability = "MUTABLE"   # set to IMMUTABLE if you want tag protection

  image_scanning_configuration {
    scan_on_push = true   # auto vulnerability scan on every push
  }

  tags = {
    Name = "CiCd-Project-ECR-Nginx"
  }
}

resource "aws_ecr_lifecycle_policy" "cicd_project_nginx" {
  repository = aws_ecr_repository.cicd_project_nginx.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images, expire older ones"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

######################################################################
# CloudWatch Log Group
######################################################################

resource "aws_cloudwatch_log_group" "cicd_project" {
  name              = "/ecs/CiCd-Project-Nginx"
  retention_in_days = 7

  tags = {
    Name = "CiCd-Project-LogGroup"
  }
}

######################################################################
# ECS Cluster
######################################################################

resource "aws_ecs_cluster" "cicd_project" {
  name = "CiCd-Project-Cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "CiCd-Project-Cluster"
  }
}

resource "aws_ecs_cluster_capacity_providers" "cicd_project" {
  cluster_name       = aws_ecs_cluster.cicd_project.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

######################################################################
# ECS Task Definition – Nginx
######################################################################

resource "aws_ecs_task_definition" "cicd_project_nginx" {
  family                   = "CiCd-Project-Nginx"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"   # 0.25 vCPU
  memory                   = "512"   # 512 MB
  execution_role_arn       = aws_iam_role.cicd_project_ecs_exec.arn

  container_definitions = jsonencode([
    {
      name      = "CiCd-Project-Nginx-Container"
      image     = "${aws_ecr_repository.cicd_project_nginx.repository_url}:latest"
      essential = true

      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.cicd_project.name
          "awslogs-region"        = "us-east-2"
          "awslogs-stream-prefix" = "nginx"
        }
      }
    }
  ])

  tags = {
    Name = "CiCd-Project-TaskDef"
  }
}

######################################################################
# ECS Service
######################################################################

resource "aws_ecs_service" "cicd_project_nginx" {
  name            = "CiCd-Project-Nginx-Service"
  cluster         = aws_ecs_cluster.cicd_project.id
  task_definition = aws_ecs_task_definition.cicd_project_nginx.arn
  desired_count   = 2    # Start with 2 containers
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [
      aws_subnet.cicd_project_public_a.id,
      aws_subnet.cicd_project_public_b.id,
    ]
    security_groups  = [aws_security_group.cicd_project_ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.cicd_project.arn
    container_name   = "CiCd-Project-Nginx-Container"
    container_port   = 80
  }

  depends_on = [
    aws_lb_listener.cicd_project_http,
    aws_iam_role_policy_attachment.cicd_project_ecs_exec,
  ]

  # Ignore desired_count changes so autoscaling can manage it
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = {
    Name = "CiCd-Project-Nginx-Service"
  }
}

######################################################################
# Auto Scaling – Scalable Target
######################################################################

resource "aws_appautoscaling_target" "cicd_project_ecs" {
  max_capacity       = 6
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.cicd_project.name}/${aws_ecs_service.cicd_project_nginx.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.cicd_project_nginx]
}

######################################################################
# Auto Scaling – Scale Out Policy (CPU high)
######################################################################

resource "aws_appautoscaling_policy" "cicd_project_scale_out" {
  name               = "CiCd-Project-ScaleOut"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.cicd_project_ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.cicd_project_ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.cicd_project_ecs.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 2
    }
  }
}

######################################################################
# Auto Scaling – Scale In Policy (CPU low)
######################################################################

resource "aws_appautoscaling_policy" "cicd_project_scale_in" {
  name               = "CiCd-Project-ScaleIn"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.cicd_project_ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.cicd_project_ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.cicd_project_ecs.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

######################################################################
# CloudWatch Alarm – CPU High → trigger scale out
######################################################################

resource "aws_cloudwatch_metric_alarm" "cicd_project_cpu_high" {
  alarm_name          = "CiCd-Project-CPU-High"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 70

  dimensions = {
    ClusterName = aws_ecs_cluster.cicd_project.name
    ServiceName = aws_ecs_service.cicd_project_nginx.name
  }

  alarm_actions = [aws_appautoscaling_policy.cicd_project_scale_out.arn]

  tags = {
    Name = "CiCd-Project-CPU-High-Alarm"
  }
}

######################################################################
# CloudWatch Alarm – CPU Low → trigger scale in
######################################################################

resource "aws_cloudwatch_metric_alarm" "cicd_project_cpu_low" {
  alarm_name          = "CiCd-Project-CPU-Low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 20

  dimensions = {
    ClusterName = aws_ecs_cluster.cicd_project.name
    ServiceName = aws_ecs_service.cicd_project_nginx.name
  }

  alarm_actions = [aws_appautoscaling_policy.cicd_project_scale_in.arn]

  tags = {
    Name = "CiCd-Project-CPU-Low-Alarm"
  }
}

######################################################################
# Outputs
######################################################################

output "alb_dns_name" {
  description = "ALB DNS name – use this to reach your Nginx containers"
  value       = aws_lb.cicd_project.dns_name
}

output "alb_url" {
  description = "Full HTTP URL of the ALB"
  value       = "http://${aws_lb.cicd_project.dns_name}"
}

output "ecs_cluster_name" {
  description = "ECS Cluster name"
  value       = aws_ecs_cluster.cicd_project.name
}

output "ecs_service_name" {
  description = "ECS Service name"
  value       = aws_ecs_service.cicd_project_nginx.name
}

output "ecr_repository_url" {
  description = "ECR repository URL – use this as your docker push/pull target"
  value       = aws_ecr_repository.cicd_project_nginx.repository_url
}

output "ecr_repository_name" {
  description = "ECR repository name"
  value       = aws_ecr_repository.cicd_project_nginx.name
}
