data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

data "aws_vpc" "selected" {
  id      = var.vpc_id
  default = var.vpc_id == null ? true : null
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/${var.ubuntu_version}/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  admin_cidr = coalesce(var.admin_cidr, "${chomp(data.http.my_ip.response_body)}/32")
  subnet_id  = coalesce(var.subnet_id, sort(data.aws_subnets.selected.ids)[0])
  # Generated artifacts live under <working dir>/generated/ unless overridden.
  # Relative overrides are resolved against the working directory.
  private_key = var.private_key_path == null ? "${path.root}/generated/${var.name}.pem" : (
    startswith(var.private_key_path, "/") ? var.private_key_path : "${path.root}/${var.private_key_path}"
  )
  kubeconfig_path = var.kubeconfig_path == null ? "${path.root}/generated/${var.name}-kubeconfig.yaml" : (
    startswith(var.kubeconfig_path, "/") ? var.kubeconfig_path : "${path.root}/${var.kubeconfig_path}"
  )
}

# ---------- SSH key pair (generated, written locally with 0400) ----------

resource "tls_private_key" "k3s" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "k3s" {
  key_name   = "${var.name}-key"
  public_key = tls_private_key.k3s.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.k3s.private_key_openssh
  filename        = local.private_key
  file_permission = "0400"
}

# ---------- Network ----------

resource "aws_security_group" "k3s" {
  name        = "${var.name}-sg"
  description = "k3s demo node: SSH and Kubernetes API from admin CIDR only"
  vpc_id      = data.aws_vpc.selected.id
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.k3s.id
  cidr_ipv4         = local.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from admin"
}

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  security_group_id = aws_security_group.k3s.id
  cidr_ipv4         = local.admin_cidr
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  description       = "Kubernetes API from admin"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  count             = var.allow_http_https ? 1 : 0
  security_group_id = aws_security_group.k3s.id
  cidr_ipv4         = local.admin_cidr
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP from admin (optional)"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  count             = var.allow_http_https ? 1 : 0
  security_group_id = aws_security_group.k3s.id
  cidr_ipv4         = local.admin_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from admin (optional)"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.k3s.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All outbound (image pulls, k3s install)"
}

# Elastic IP is allocated independently of the instance so its address can be
# embedded in the k3s TLS certificate (--tls-san) without a dependency cycle.
resource "aws_eip" "k3s" {
  domain = "vpc"
  tags   = { Name = var.name }
}

# ---------- Compute ----------

resource "aws_instance" "k3s" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.k3s.key_name
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    eip       = aws_eip.k3s.public_ip
    node_name = var.name
  })
  user_data_replace_on_change = true

  tags = { Name = var.name }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip_association" "k3s" {
  instance_id   = aws_instance.k3s.id
  allocation_id = aws_eip.k3s.id
}

# ---------- Post-boot: wait for k3s, then fetch kubeconfig ----------

resource "null_resource" "k3s_ready" {
  triggers = {
    instance = aws_instance.k3s.id
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_eip.k3s.public_ip
    private_key = tls_private_key.k3s.private_key_openssh
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait || true",
      "until sudo test -f /etc/rancher/k3s/k3s.yaml; do sleep 5; done",
      "sudo k3s kubectl wait --for=condition=Ready node --all --timeout=300s",
    ]
  }
}

resource "null_resource" "kubeconfig" {
  triggers = {
    ready = null_resource.k3s_ready.id
    path  = local.kubeconfig_path
  }

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p "$(dirname "${local.kubeconfig_path}")"
      ssh -o StrictHostKeyChecking=accept-new -i "${local.private_key}" ubuntu@${aws_eip.k3s.public_ip} 'sudo cat /etc/rancher/k3s/k3s.yaml' \
        | sed -e 's/127.0.0.1/${aws_eip.k3s.public_ip}/' -e 's/name: default/name: ${var.name}/' -e 's/: default$/: ${var.name}/' \
        > "${local.kubeconfig_path}"
      chmod 600 "${local.kubeconfig_path}"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ${self.triggers.path}"
  }
}
