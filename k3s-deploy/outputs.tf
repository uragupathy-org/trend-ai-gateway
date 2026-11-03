output "gateway_url" {
  description = "Public URL of the AI Gateway. Null when no domain is configured."
  value       = local.public_enabled ? "https://${var.gateway_hostname}" : null
}

output "alb_dns_name" {
  description = "DNS name of the ALB in front of the gateway. Null when no domain is configured."
  value       = one(module.alb[*].dns_name)
}

output "access_without_domain" {
  description = "Command that reaches the gateway without a public domain (run it from a machine with kubeconfig access)."
  value       = "kubectl -n trendai-gateway port-forward svc/trendai-gateway-gateway 8080:8080 8081:8081"
}

output "instance_id" {
  description = "EC2 instance ID of the k3s node."
  value       = aws_instance.k3s.id
}

output "public_ip" {
  description = "Elastic IP of the k3s node (stable across stop/start)."
  value       = aws_eip.k3s.public_ip
}

output "kubeconfig_path" {
  description = "Local kubeconfig for the cluster."
  value       = local.kubeconfig_path
}

output "ssh_command" {
  description = "SSH into the node."
  value       = "ssh -i ${local.private_key} ubuntu@${aws_eip.k3s.public_ip}"
}

output "private_key_path" {
  description = "Local path of the generated SSH private key."
  value       = local.private_key
}
