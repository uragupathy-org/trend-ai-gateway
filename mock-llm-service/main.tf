data "kubernetes_namespace_v1" "gateway" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_config_map_v1" "mock_llm" {
  metadata {
    name      = "mock-llm-script"
    namespace = data.kubernetes_namespace_v1.gateway.metadata[0].name
    labels    = { app = "mock-llm" }
  }

  data = {
    "mock-llm-server.py" = file("${path.module}/mock-llm-server.py")
  }
}

resource "kubernetes_deployment_v1" "mock_llm" {
  metadata {
    name      = "mock-llm"
    namespace = data.kubernetes_namespace_v1.gateway.metadata[0].name
    labels    = { app = "mock-llm" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "mock-llm" }
    }

    template {
      metadata {
        labels = { app = "mock-llm" }
        annotations = {
          # Changing the script changes this hash, which rolls the pod.
          "checksum/script" = sha1(kubernetes_config_map_v1.mock_llm.data["mock-llm-server.py"])
        }
      }

      spec {
        container {
          name    = "mock-llm"
          image   = var.image
          command = ["python3", "/app/mock-llm-server.py", "--port", tostring(var.port)]

          port {
            name           = "http"
            container_port = var.port
          }

          volume_mount {
            name       = "script"
            mount_path = "/app"
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
          name = "script"
          config_map {
            name = kubernetes_config_map_v1.mock_llm.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "mock_llm" {
  metadata {
    name      = "mock-llm"
    namespace = data.kubernetes_namespace_v1.gateway.metadata[0].name
    labels    = { app = "mock-llm" }
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "mock-llm" }

    port {
      name        = "http"
      port        = var.port
      target_port = var.port
      protocol    = "TCP"
    }
  }
}
