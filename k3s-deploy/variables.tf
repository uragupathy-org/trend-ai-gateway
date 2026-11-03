variable "aws_profile" {
  description = "AWS CLI profile to use. Leave null to use the default credential chain."
  type        = string
  default     = null
}

variable "region" {
  description = "AWS region for the k3s node."
  type        = string
  default     = "ap-southeast-2"
}

variable "name" {
  description = "Name prefix for all resources, also used as the Kubernetes node and kubectl context name."
  type        = string
  default     = "k3s-demo"
}

variable "instance_type" {
  description = "EC2 instance type. Must provide at least 2 vCPU and 4 GiB RAM (k3s server minimum is 2 cores / 2 GB; AI Gateway needs the extra headroom)."
  type        = string
  default     = "t3.medium"

  validation {
    condition     = contains(["t3.medium", "t3a.medium", "t3.large"], var.instance_type)
    error_message = "instance_type must be t3.medium, t3a.medium or t3.large. t3.small (2 GiB) is below the 4 GB requirement."
  }
}

variable "ubuntu_version" {
  description = "Ubuntu LTS version for the node (Canonical SSM parameter path)."
  type        = string
  default     = "24.04"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB (gp3, encrypted)."
  type        = number
  default     = 40
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH (22) and the Kubernetes API (6443). Null auto-detects your current public IP as /32."
  type        = string
  default     = null
}

variable "allow_http_https" {
  description = "Open ports 80 and 443 to admin_cidr for ingress testing. Keep false unless the demo needs it."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "VPC to deploy into. Null uses the account's default VPC."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet for the instance. Null picks the first subnet in the selected VPC."
  type        = string
  default     = null
}

variable "private_key_path" {
  description = "Path for the generated SSH private key. Null writes ./generated/<name>.pem. Relative paths resolve from the working directory."
  type        = string
  default     = null
}

variable "kubeconfig_path" {
  description = "Path for the generated kubeconfig. Null writes ./generated/<name>-kubeconfig.yaml. Relative paths resolve from the working directory."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to all taggable resources."
  type        = map(string)
  default = {
    Project = "AI-Gateway-Demo"
    Managed = "terraform"
  }
}
