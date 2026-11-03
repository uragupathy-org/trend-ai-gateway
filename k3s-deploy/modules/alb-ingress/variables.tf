variable "name" {
  description = "Prefix for ALB, target group and security group names (max 32 characters in total for the ALB name)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets for the ALB. Must span at least two availability zones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "The ALB needs at least two subnets in different availability zones."
  }
}

variable "domain_name" {
  description = "Primary domain name for the ACM certificate, for example demo.example.com."
  type        = string
}

variable "hostnames" {
  description = "Fully qualified hostnames served by the ALB (added to the certificate and to Route 53)."
  type        = list(string)
}

variable "route53_zone_id" {
  description = "Public Route 53 hosted zone that contains domain_name and hostnames."
  type        = string
}

variable "allowed_cidrs" {
  description = "Client CIDRs allowed to reach the ALB on ports 80 and 443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "target_port" {
  description = "NodePort on the node where Traefik's HTTP entrypoint is exposed."
  type        = number
  default     = 30080
}

variable "health_check_path" {
  description = "Path that answers 200 on the target port. Traefik's ping endpoint is enabled for this."
  type        = string
  default     = "/ping"
}

variable "health_check_matcher" {
  description = "HTTP codes that count as a healthy target, for example 200 or 200-499."
  type        = string
  default     = "200"
}

variable "idle_timeout" {
  description = "ALB idle timeout in seconds. Raised above the 60 s default so streamed LLM and MCP responses are not cut off."
  type        = number
  default     = 600
}

variable "alarm_actions" {
  description = "SNS topic ARNs notified by the alarms. Empty means alarms only show in the console."
  type        = list(string)
  default     = []
}
