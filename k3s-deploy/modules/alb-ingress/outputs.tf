output "dns_name" {
  description = "ALB DNS name (the hostnames are aliases to it)."
  value       = aws_lb.this.dns_name
}

output "security_group_id" {
  description = "ALB security group. Node security groups allow the Traefik NodePort from this group only."
  value       = aws_security_group.alb.id
}

output "target_group_arn" {
  value = aws_lb_target_group.this.arn
}

output "hostnames" {
  value = var.hostnames
}
