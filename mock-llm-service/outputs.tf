output "service_name" {
  description = "Kubernetes Service name."
  value       = kubernetes_service_v1.mock_llm.metadata[0].name
}

output "in_cluster_url" {
  description = "Base URL the gateway uses from inside the cluster."
  value       = "http://${kubernetes_service_v1.mock_llm.metadata[0].name}.${var.namespace}.svc.cluster.local:${var.port}/v1"
}
