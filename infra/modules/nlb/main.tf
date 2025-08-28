resource "aws_lb" "this" {
  name               = "${var.project_name}-nlb"
  internal           = var.internal
  load_balancer_type = "network"
  subnets            = var.subnet_ids

  tags = { Project = var.project_name }
}

resource "aws_lb_target_group" "this" {
  name_prefix = "tg-"
  port        = var.target_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = var.health_path
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }

  tags = { Project = var.project_name }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# Attach instance targets (handles unknown IDs at plan time)
resource "aws_lb_target_group_attachment" "targets" {
  count            = length(var.targets)
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = var.targets[count.index]
  port             = var.target_port
}

output "listener_arn" {
  value = aws_lb_listener.http.arn
}

output "nlb_dns_name" {
  value = aws_lb.this.dns_name
}