#reads whoami 
data "aws_caller_identity" "current" {}

# 1. Terraform state bucket
# Access logging is skipped for this small state bucket; production would add it.
#tfsec:ignore:AVD-AWS-0089
resource "aws_s3_bucket" "tfstate" {
  bucket = "url-shortener-tfstate-${data.aws_caller_identity.current.account_id}"
}

#allows rolled back.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypts state at rest. State files can contain secrets (e.g. DB passwords).
# AES256 is enough here; a customer-managed key costs about $1/month.
#tfsec:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Hard stop on making the bucket public, even by mistake.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# 2. ECR: one private registry per service
# ---------------------------------------------------------------------------

# for_each makes one repo per name in var.services (api, worker, dashboard).
# each.key is the current name, e.g. "api".
# AES256 is enough here; a customer-managed key costs about $1/month.
#tfsec:ignore:AVD-AWS-0033
resource "aws_ecr_repository" "service" {
  for_each = var.services

  name = "url-shortener/${each.key}"

  # A tag like a git SHA can never be overwritten: what you tested is what you ship.
  image_tag_mutability = "IMMUTABLE"

  # Scans every pushed image for known vulnerabilities (a second check after Trivy in CI).
  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keeps only the last 5 images per repo, so storage cost stays near zero.
resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# 3. GitHub Actions -> AWS using OIDC (no long-lived access keys)
# ---------------------------------------------------------------------------

# Tells AWS to trust identity tokens issued by GitHub Actions.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# The trust policy: WHO may assume the role. Without the `sub` condition, any
# GitHub repo on earth could use it.
data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only this repo, and only runs on main or inside the "dev" environment.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_repo}:environment:dev",
      ]
    }
  }
}

# The role GitHub Actions assumes during a deploy.
resource "aws_iam_role" "github_deploy" {
  name               = "url-shortener-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

# The permissions policy: WHAT the role may do. Image push only for now;
# ECS deploy permissions are added in step 7 once the cluster exists.
data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this one action cannot be limited to a resource
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.service : r.arn]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

# What the deploy job needs: read and register task definitions, update the services.
data "aws_iam_policy_document" "ecs_deploy" {
  statement {
    sid = "TaskDefinitions"
    actions = [
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition", # these two do not support resource scoping
    ]
    resources = ["*"]
  }

  statement {
    sid       = "UpdateServices"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["arn:aws:ecs:us-east-1:${data.aws_caller_identity.current.account_id}:service/url-shortener-dev/*"]
  }

  # A new task definition names the execution and task roles, so the deployer
  # must be allowed to hand exactly those roles to ECS and nothing else.
  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/url-shortener-dev-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ecs_deploy" {
  name   = "ecs-deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.ecs_deploy.json
}
