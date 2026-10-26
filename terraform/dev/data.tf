# The data layer: queue, database, cache.
#   api --click event--> SQS queue --> worker --> RDS <-- api, dashboard
#   api <--cache--> Redis (Valkey)

# ---------------------------------------------------------------------------
# SQS: click events go api -> queue -> worker
# ---------------------------------------------------------------------------

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

  # Dev settings: single AZ, no final snapshot, so `terraform destroy` works.
  # Production would use multi_az = true, a final snapshot and deletion protection.
  multi_az                = false
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
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
# Valkey is only available through a "replication group". We ask for exactly
# one node and no failover, so it costs the same as a single cache node.
resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "url-shortener-dev"
  description          = "Cache for the url-shortener api"
  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = "cache.t4g.micro"
  num_cache_clusters   = 1
  parameter_group_name = "default.valkey8"
  port                 = 6379

  automatic_failover_enabled = false # one node only, a dev setting
  at_rest_encryption_enabled = true

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]
}
