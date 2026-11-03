output "in_cluster_urls" {
  description = "MCP upstream URLs to register in Vision One. Reachable only from inside the cluster (gateway pods)."
  value = {
    for name, s in local.servers :
    name => "http://${name}.${var.namespace}.svc.cluster.local:${s.port}/"
  }
}
