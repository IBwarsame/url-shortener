output "tfstate_bucket" {
  description = "S3 bucket for Terraform state. Used as the backend bucket in other root modules."
  value       = aws_s3_bucket.tfstate.id
}

output "ecr_repository_urls" {
  description = "Image registry URL for each service."
  value       = { for name, repo in aws_ecr_repository.service : name => repo.repository_url }
}

output "github_deploy_role_arn" {
  description = "Role that GitHub Actions assumes. Used as role-to-assume in the workflows."
  value       = aws_iam_role.github_deploy.arn
}