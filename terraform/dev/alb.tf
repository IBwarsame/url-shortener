resource "aws_lb" "main" {
  name               = "url-shortener-dev"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}

# ip target type is required for Fargate tasks
resource "aws_lb_target_group" "api" {
  name        = "url-shortener-dev-api"
  vpc_id      = aws_vpc.main.id
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"

  deregistration_delay = 30 # faster deploys

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "dashboard" {
  name        = "url-shortener-dev-dashboard"
  vpc_id      = aws_vpc.main.id
  port        = 8081
  protocol    = "HTTP"
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Anything not matched by a rule goes to the api
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# Dashboard paths go to the dashboard
resource "aws_lb_listener_rule" "dashboard" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dashboard.arn
  }

  condition {
    path_pattern {
      values = ["/dashboard*", "/summary", "/top", "/recent", "/url/*"]
    }
  }
}
