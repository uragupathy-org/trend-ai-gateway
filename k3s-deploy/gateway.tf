# ---------- Gateway chart, and an optional public entry point ----------
# The node comes from main.tf. When a domain is configured (local.public_enabled), the
# gateway Service is published through an ALB, certificate and Route 53 record.
# Without a domain, the ALB and DNS are skipped and the gateway is reached through
# kubectl port-forward (see README).

locals {
  gateway_namespace = "trendai-gateway"
  # Must match gateway.visionone.authToken.existingSecret in overrides.yaml.
  vision_one_secret = "vision-one-auth"
  # Bedrock Mantle key for the bedrock-mantle provider. The key name must match the
  # provider name in Vision One, so the gateway can find the mounted file.
  mantle_secret     = "bedrock-mantle-keys"
  mantle_key        = "bedrock-mantle"
  traefik_node_port = 30080
}

# Traefik NodePort pin and gateway Ingress. k3s applies files in its manifests
# directory on its own. The Ingress is applied after Helm, once its Namespace exists.

resource "null_resource" "k3s_manifests" {
  triggers = {
    ready        = null_resource.k3s_ready.id
    traefik_hash = filemd5("${path.root}/manifests/traefik-config.yaml")
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_eip.k3s.public_ip
    private_key = tls_private_key.k3s.private_key_openssh
    timeout     = "10m"
  }

  provisioner "file" {
    source      = "${path.root}/manifests/traefik-config.yaml"
    destination = "/tmp/traefik-config.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /tmp/traefik-config.yaml /var/lib/rancher/k3s/server/manifests/traefik-config.yaml",
    ]
  }
}

resource "local_file" "gateway_ingress" {
  count = local.public_enabled ? 1 : 0

  content = templatefile("${path.root}/manifests/gateway-ingress.yaml.tftpl", {
    gateway_hostname = var.gateway_hostname
  })
  filename = "${path.root}/generated/gateway-ingress.yaml"
}

# Installs the AI Gateway chart and the Ingress.
resource "null_resource" "gateway" {
  triggers = {
    kubeconfig = null_resource.kubeconfig.id
    overrides  = filemd5("${path.root}/overrides.yaml")
    ingress    = join("", local_file.gateway_ingress[*].content_md5)
    secrets    = nonsensitive(sha256(var.visionone_bootstrap_token))
    mantle     = nonsensitive(sha256("${local.mantle_key}:${var.aws_bearer_token_bedrock}"))
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG          = local.kubeconfig_path
      VISIONONE_BOOTSTRAP = var.visionone_bootstrap_token
      MANTLE_TOKEN        = var.aws_bearer_token_bedrock
    }
    command = <<-EOT
      set -euo pipefail
      kubectl create namespace ${local.gateway_namespace} --dry-run=client -o yaml | kubectl apply -f -
      kubectl -n ${local.gateway_namespace} create secret generic ${local.vision_one_secret} \
        --from-literal=token="$VISIONONE_BOOTSTRAP" --dry-run=client -o yaml | kubectl apply -f -
      kubectl -n ${local.gateway_namespace} create secret generic ${local.mantle_secret} \
        --from-literal=${local.mantle_key}="$MANTLE_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
      helm upgrade --install trendai-gateway oci://public.ecr.aws/trendmicro/ai-security/ai-gateway \
        -n ${local.gateway_namespace} \
        -f "${path.root}/overrides.yaml" \
        --wait --timeout 10m
      ${local.public_enabled ? "kubectl apply -f \"${local_file.gateway_ingress[0].filename}\"" : "echo 'No public domain configured: skipping Ingress.'"}
    EOT
  }

  depends_on = [
    null_resource.kubeconfig,
    null_resource.k3s_manifests,
    local_file.gateway_ingress,
  ]
}

module "alb" {
  source = "./modules/alb-ingress"
  count  = local.public_enabled ? 1 : 0

  name            = var.name
  vpc_id          = data.aws_vpc.selected.id
  subnet_ids      = sort(data.aws_subnets.selected.ids)
  domain_name     = var.domain_name
  hostnames       = [var.gateway_hostname]
  route53_zone_id = var.route53_zone_id
  allowed_cidrs   = var.public_access_cidrs
  target_port     = local.traefik_node_port
  alarm_actions   = var.alarm_actions

  # Traefik answers unmatched requests with 404, so any HTTP response proves the node and Traefik are up.
  health_check_path    = "/"
  health_check_matcher = "200-499"
}

resource "aws_lb_target_group_attachment" "node" {
  count = local.public_enabled ? 1 : 0

  target_group_arn = module.alb[0].target_group_arn
  target_id        = aws_instance.k3s.id
  port             = local.traefik_node_port

  depends_on = [null_resource.k3s_manifests]
}

# The node's security group accepts Traefik's NodePort from the ALB only.
resource "aws_vpc_security_group_ingress_rule" "alb_to_traefik" {
  count = local.public_enabled ? 1 : 0

  security_group_id            = aws_security_group.k3s.id
  from_port                    = local.traefik_node_port
  to_port                      = local.traefik_node_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.alb[0].security_group_id
  description                  = "Traefik HTTP from ALB"
}

# The ALB, DNS and Ingress used to be unindexed. These moves keep the existing
# resources in place instead of planning a destroy and recreate.
moved {
  from = module.alb
  to   = module.alb[0]
}

moved {
  from = aws_lb_target_group_attachment.node
  to   = aws_lb_target_group_attachment.node[0]
}

moved {
  from = aws_vpc_security_group_ingress_rule.alb_to_traefik
  to   = aws_vpc_security_group_ingress_rule.alb_to_traefik[0]
}

moved {
  from = local_file.gateway_ingress
  to   = local_file.gateway_ingress[0]
}
