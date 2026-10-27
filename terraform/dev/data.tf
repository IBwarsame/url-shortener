# The data layer: queue, database, cache.
#   api --click event--> SQS queue --> worker --> RDS <-- api, dashboard
#   api <--cache--> Redis (Valkey)

# SQS: click events go api -> queue -> worker

# Where messages go if the worker keeps failing on them (the "dead-letter
# queue"). Without it, a bad message would be retried forever.
resource "aws_sqs_queue" "click_events_dlq" {
  name                      = "url-shortener-dev-click-events-dlq"
  message_retention_seconds = 1209600 # 14 days, the maximum, so there is time to look
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "click_events" {
  name                       = "url-shortener-dev-click-events"
  visibility_timeout_seconds = 60 # time the worker has to finish a message before SQS offers it again
  sqs_managed_sse_enabled    = true

  # After 5 failed attempts, move the message to the dead-letter queue.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.click_events_dlq.arn
    maxReceiveCount     = 5
  })
}

# ---------------------------------------------------------------------------
# RDS Postgres: one database for the api, worker and dashboard
# ---------------------------------------------------------------------------

# Tells RDS which subnets it may live in: the private ones only.
resource "aws_db_subnet_group" "main" {
  name       = "url-shortener-dev"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "url-shortener-dev" }
}

# Ignored in dev on purpose: IAM auth (the password is in Secrets Manager), performance
# insights (extra cost) and deletion protection (off so destroy works; on when production = true).
#tfsec:ignore:AVD-AWS-0176
#tfsec:ignore:AVD-AWS-0133
resource "aws_db_instance" "main" {
  identifier     = "url-shortener-dev"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro" # smallest ARM instance, the cheapest sensible choice

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "shortener"
  username = "app"

  # AWS creates the master password and stores it in Secrets Manager.
  # It never appears in our code or in the Terraform state as plain text.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Dev: single AZ, no final snapshot, no deletion protection, so `terraform destroy` works.
  # production = true turns on Multi-AZ, a final snapshot, deletion protection and 14-day backups.
  multi_az                  = var.production
  backup_retention_period   = var.production ? 14 : 7
  skip_final_snapshot       = !var.production
  final_snapshot_identifier = var.production ? "url-shortener-final" : null
  #tfsec:ignore:AVD-AWS-0177
  deletion_protection = var.production
}

# ---------------------------------------------------------------------------
# ElastiCache: the cache for GET /{short_id}
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "main" {
  name       = "url-shortener-dev"
  subnet_ids = aws_subnet.private[*].id
}

# Valkey is the open-source Redis fork. It speaks the same protocol, so the
# api's redis client works unchanged, and it is cheaper than Redis on AWS.
#
# Valkey is only available through a "replication group". Dev runs one node
# with no failover; production = true runs two nodes with failover.
resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "url-shortener-dev"
  description                = "Cache for the url-shortener api"
  engine                     = "valkey"
  engine_version             = "8.0"
  node_type                  = "cache.t4g.micro"
  parameter_group_name       = "default.valkey8"
  port                       = 6379
  num_cache_clusters         = var.production ? 2 : 1
  automatic_failover_enabled = var.production
  multi_az_enabled           = var.production
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]
}
