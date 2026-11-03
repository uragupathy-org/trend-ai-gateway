# Two MCP upstreams, each a single script mounted from its own ConfigMap.
# Ports are fixed because they are registered in Vision One as MCP upstreams.
locals {
  servers = {
    mock-mcp = {
      port   = 8100
      script = "${path.module}/mock-mcp-server.py"
    }
    mock-mcp-restricted = {
      port   = 8200
      script = "${path.module}/mock-mcp-restricted-server.py"
    }
  }
}

data "kubernetes_namespace_v1" "gateway" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_config_map_v1" "server" {
  for_each = local.servers

  metadata {
    name      = "${each.key}-code"
    namespace = data.kubernetes_namespace_v1.gateway.metadata[0].name
    labels    = { app = each.key }
  }

  data = {
    "server.py" = file(each.value.script)
  }
}

resource "kubernetes_deployment_v1" "server" {
  for_each = local.servers

  metadata {
    name      = each.key
    namespace = data.kubernetes_namespace_v1.gateway.metadata[0].name
    labels    = { app = each.key }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = each.key }
    }

    template {
      metadata {
        labels = { app = each.key }
        annotations = {
          # Changing the script changes this hash, which rolls the pod.
          "checksum/script" = sha1(kubernetes_config_map_v1.server[each.key].data["server.py"])
        }
      }

      spec {
        container {
          name    = each.key
          image   = var.image
          command = ["python3", "/code/server.py", "--port", tostring(each.value.port)]

          port {
            name           = "http"
            container_port = each.value.port
          }

          volume_mount {
            name       = "code"
            mount_path = "/code"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "code"
          config_map {
            name = kubernetes_config_map_v1.server[each.key].metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "server" {
  for_each = local.servers

  metadata {
    name      = each.key
    namespace = data.kubernetes_namespace_v1.gateway.metadata[0].name
    labels    = { app = each.key }
  }

  spec {
    type     = "ClusterIP"
    selector = { app = each.key }

    port {
      name        = "http"
      port        = each.value.port
      target_port = each.value.port
      protocol    = "TCP"
    }
  }
}
