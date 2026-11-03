variable "domain_name" {
  description = "Domain of the Route 53 hosted zone and the ACM certificate, for example trendailabs.click.\n\nOptional. Leave null to run without a public domain: no ALB, certificate or DNS record is created. See README (Access without a domain)."
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Public Route 53 hosted zone ID that contains domain_name.\n\nOptional. Leave null to run without a public domain: no ALB, certificate or DNS record is created. See README (Access without a domain)."
  type        = string
  default     = null
}

variable "gateway_hostname" {
  description = "Public hostname for the AI Gateway, for example aigateway.trendailabs.click. Routes to the gateway LLM proxy (port 8080).\n\nOptional. Leave null to run without a public domain: no ALB, certificate or DNS record is created. See README (Access without a domain)."
  type        = string
  default     = null
}

variable "public_access_cidrs" {
  description = "Client CIDRs allowed to reach the ALB on ports 80 and 443. The gateway's virtual keys are the authentication layer."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "alarm_actions" {
  description = "SNS topic ARNs notified by the ALB alarms. Empty means console-only."
  type        = list(string)
  default     = []
}

variable "visionone_bootstrap_token" {
  description = "Vision One bootstrap token for the AI Gateway. Written to a gitignored values file at apply time; never stored in overrides.yaml."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.visionone_bootstrap_token) > 0
    error_message = "visionone_bootstrap_token must not be empty."
  }
}

variable "aws_bearer_token_bedrock" {
  description = "Bedrock Mantle bearer token for the bedrock-mantle provider. Written to a Kubernetes Secret at apply time; never stored in overrides.yaml."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.aws_bearer_token_bedrock) > 0
    error_message = "aws_bearer_token_bedrock must not be empty."
  }
}

locals {
  # The public entry point (ALB, certificate, Route 53 record, Ingress) is created only
  # when all three domain inputs are set. Without them the gateway stays cluster-internal.
  public_enabled = var.domain_name != null && var.route53_zone_id != null && var.gateway_hostname != null
}

check "public_domain_inputs_all_or_none" {
  assert {
    condition = (
      (var.domain_name == null && var.route53_zone_id == null && var.gateway_hostname == null) ||
      (var.domain_name != null && var.route53_zone_id != null && var.gateway_hostname != null)
    )
    error_message = "Set domain_name, route53_zone_id and gateway_hostname together, or leave all three null."
  }
}
