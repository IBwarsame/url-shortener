output "alb_dns_name" {
  description = "Open this in a browser or curl it"
  value       = aws_lb.main.dns_name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}
