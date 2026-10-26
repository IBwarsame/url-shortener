# VPC interface endpoints: private doors from the private subnets to AWS
# services.
# (The free S3 gateway endpoint is in network.tf.)

locals {
  interface_endpoints = {
    ecr_api        = "ecr.api"        # ECR: authentication and image lookup
    ecr_dkr        = "ecr.dkr"        # ECR: the Docker registry itself
    logs           = "logs"           # CloudWatch Logs: where task logs go
    sqs            = "sqs"            # the click-events queue
    secretsmanager = "secretsmanager" # the database password
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.${each.value}"
  vpc_endpoint_type = "Interface"

  # Dev: one endpoint network interface, in one AZ, to halve the cost.
  # Tasks in the other AZ still reach it. Production would use both subnets.
  subnet_ids         = [aws_subnet.private[0].id]
  security_group_ids = [aws_security_group.endpoints.id]

  # Makes the normal AWS name (e.g. sqs.us-east-1.amazonaws.com) resolve to
  # the private endpoint, so the app code needs no changes.
  private_dns_enabled = true

  tags = { Name = "url-shortener-dev-${each.value}" }
}
