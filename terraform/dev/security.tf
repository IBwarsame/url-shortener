# Security groups = firewalls. 
#
#   internet --80/443--> alb --8080--> api --6379--> redis
#                            --8081--> dashboard
#   api, dashboard, worker --5432--> rds
#   api, dashboard, worker --443---> endpoints (ECR, logs, SQS, secrets)

# ---------------------------------------------------------------------------
# The groups (empty shells; the rules are added below)
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "url-shortener-dev-alb"
  description = "Load balancer: open to the internet"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "url-shortener-dev-alb" }
}

resource "aws_security_group" "api" {
  name        = "url-shortener-dev-api"
  description = "API tasks"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "url-shortener-dev-api" }
}

resource "aws_security_group" "dashboard" {
  name        = "url-shortener-dev-dashboard"
  description = "Dashboard tasks"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "url-shortener-dev-dashboard" }
}

resource "aws_security_group" "worker" {
  name        = "url-shortener-dev-worker"
  description = "Worker tasks (nothing connects in)"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "url-shortener-dev-worker" }
}

resource "aws_security_group" "rds" {
  name        = "url-shortener-dev-rds"
  description = "Postgres database"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "url-shortener-dev-rds" }
}

resource "aws_security_group" "redis" {
  name        = "url-shortener-dev-redis"
  description = "Redis cache"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "url-shortener-dev-redis" }
}

resource "aws_security_group" "endpoints" {
  name        = "url-shortener-dev-endpoints"
  description = "VPC interface endpoints"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "url-shortener-dev-endpoints" }
}

# ALB: the only thing open to the internet
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# The ALB may only send traffic to the two apps, on their ports.
resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB to api"
  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "alb_to_dashboard" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB to dashboard"
  referenced_security_group_id = aws_security_group.dashboard.id
  ip_protocol                  = "tcp"
  from_port                    = 8081
  to_port                      = 8081
}

# Apps: only the ALB may connect in
resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  description                  = "api port from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "dashboard_from_alb" {
  security_group_id            = aws_security_group.dashboard.id
  description                  = "dashboard port from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8081
  to_port                      = 8081
}

# The worker has no inbound rules at all: nothing connects to it.
# "out" can only reach things inside the VPC:
# the database, Redis, and the endpoints.
locals {
  task_groups = {
    api       = aws_security_group.api.id
    dashboard = aws_security_group.dashboard.id
    worker    = aws_security_group.worker.id
  }
}

resource "aws_vpc_security_group_egress_rule" "tasks_out" {
  for_each = local.task_groups

  security_group_id = each.value
  description       = "${each.key} outbound inside the VPC"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Database: only the three apps, on the Postgres port
resource "aws_vpc_security_group_ingress_rule" "rds_from_tasks" {
  for_each = local.task_groups

  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres from ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# Redis: only the api (it is the only service that caches)
resource "aws_vpc_security_group_ingress_rule" "redis_from_api" {
  security_group_id            = aws_security_group.redis.id
  description                  = "Redis from api"
  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

# VPC endpoints: the tasks reach AWS services over HTTPS through these
resource "aws_vpc_security_group_ingress_rule" "endpoints_from_tasks" {
  for_each = local.task_groups

  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS from ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
