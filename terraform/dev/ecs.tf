data "aws_caller_identity" "current" {}

locals {
  registry   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com"
  db_secret  = aws_db_instance.main.master_user_secret[0].secret_arn
  queue_arn  = aws_sqs_queue.click_events.arn
  queue_url  = aws_sqs_queue.click_events.url
  redis_host = aws_elasticache_replication_group.main.primary_endpoint_address

  db_env = [
    { name = "DB_HOST", value = aws_db_instance.main.address },
    { name = "DB_PORT", value = "5432" },
    { name = "DB_NAME", value = "shortener" },
    { name = "DB_USER", value = "app" },
  ]
  db_secrets = [
    { name = "DB_PASSWORD", valueFrom = "${local.db_secret}:password::" },
  ]

  services = {
    api = {
      port   = 8080
      spot   = false
      group  = aws_lb_target_group.api.arn
      sg     = aws_security_group.api.id
      role   = aws_iam_role.api.arn
      secret = local.db_secrets
      env = concat(local.db_env, [
        { name = "PORT", value = "8080" },
        { name = "REDIS_URL", value = "rediss://${local.redis_host}:6379" },
        { name = "SQS_QUEUE_URL", value = local.queue_url },
      ])
    }
    worker = {
      port   = 8090
      spot   = true
      group  = null
      sg     = aws_security_group.worker.id
      role   = aws_iam_role.worker.arn
      secret = local.db_secrets
      env = concat(local.db_env, [
        { name = "HEALTH_PORT", value = "8090" },
        { name = "SQS_QUEUE_URL", value = local.queue_url },
      ])
    }
    dashboard = {
      port   = 8081
      spot   = true
      group  = aws_lb_target_group.dashboard.arn
      sg     = aws_security_group.dashboard.id
      role   = null
      secret = local.db_secrets
      env    = concat(local.db_env, [{ name = "PORT", value = "8081" }])
    }
  }
}

# The default AWS encryption is enough here; a customer-managed key costs about $1/month.
#tfsec:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "service" {
  for_each = local.services

  name              = "/ecs/url-shortener-dev/${each.key}"
  retention_in_days = 3
}

# Container Insights costs extra, so it is off in dev.
#tfsec:ignore:AVD-AWS-0034
resource "aws_ecs_cluster" "main" {
  name = "url-shortener-dev"
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

# ---- IAM ----

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by ECS itself to pull images, write logs, read the DB password
resource "aws_iam_role" "execution" {
  name               = "url-shortener-dev-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secret" {
  name = "read-db-secret"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = local.db_secret
    }]
  })
}

# Task roles: what the app code itself may do (dashboard has none)
resource "aws_iam_role" "api" {
  name               = "url-shortener-dev-api"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy" "api" {
  name = "send-click-events"
  role = aws_iam_role.api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = local.queue_arn
    }]
  })
}

resource "aws_iam_role" "worker" {
  name               = "url-shortener-dev-worker"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy" "worker" {
  name = "read-click-events"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      Resource = local.queue_arn
    }]
  })
}

# ---- Task definitions and services ----

resource "aws_ecs_task_definition" "service" {
  for_each = local.services

  family                   = "url-shortener-dev-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = each.value.role

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name         = each.key
    image        = "${local.registry}/url-shortener/${each.key}:${var.image_tag}"
    essential    = true
    portMappings = [{ containerPort = each.value.port }]
    environment  = each.value.env
    secrets      = each.value.secret

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service[each.key].name
        awslogs-region        = "us-east-1"
        awslogs-stream-prefix = each.key
      }
    }
  }])
}

resource "aws_ecs_service" "service" {
  for_each = local.services

  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service[each.key].arn
  desired_count   = 1

  # api on regular Fargate; worker and dashboard on cheaper Spot
  capacity_provider_strategy {
    capacity_provider = each.value.spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  # Zero downtime: start new tasks before stopping old ones
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # A deploy whose tasks never become healthy rolls back by itself
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = each.value.group == null ? null : 30

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [each.value.sg]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = each.value.group == null ? [] : [each.value.group]

    content {
      target_group_arn = load_balancer.value
      container_name   = each.key
      container_port   = each.value.port
    }
  }

  # The deploy pipeline owns the running image version, so Terraform must not revert it
  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener.http, aws_ecs_cluster_capacity_providers.main]
}
