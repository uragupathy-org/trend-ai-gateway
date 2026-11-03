# k3s-deploy: EC2 node, k3s, gateway install and optional public domain

Terraform for the Trend AI Gateway. One stack creates the k3s node on EC2, installs the gateway chart, and (optionally) publishes the gateway through an ALB with a Route 53 record.

Run every command below from this folder (`k3s-deploy/`).

## Layout

```
k3s-deploy/
├── main.tf                  Node: EC2, Elastic IP, security group, SSH key, k3s bootstrap, kubeconfig
├── gateway.tf               Secrets, gateway Helm install, Traefik pin, optional public entry point
├── gateway_variables.tf     Gateway, domain and secret inputs (domain inputs are optional)
├── outputs.tf               Single output set
├── variables.tf             Node inputs
├── overrides.yaml           Helm values: secret names only, no values (tracked in Git)
├── manifests/
│   ├── traefik-config.yaml          Pins Traefik to NodePort 30080 (k3s applies it on boot)
│   └── gateway-ingress.yaml.tftpl   Ingress for the public hostname (rendered only with a domain)
├── modules/
│   └── alb-ingress/         ALB, listeners, target group, certificate, Route 53 alias, alarms
└── generated/               Kubeconfig, SSH key and rendered files (git-ignored)
```

## Prerequisites

The full list is in the [top-level README](../README.md#prerequisites). For this stack you need:

- Terraform 1.5 or later, AWS CLI v2 with a working profile, `kubectl` (matching the cluster version), Helm 3.8 or later, and `jq`
- AWS permissions for EC2, Elastic IPs, key pairs, security groups, and `ssm:GetParameter` on the Ubuntu AMI path. ELB, ACM and Route 53 are needed only with a domain
- At least one free Elastic IP and enough vCPU quota for `instance_type` (`t3.medium` needs 2)
- A VPC with two or more subnets in different availability zones, and an internet route
- A Vision One bootstrap token, and a Mantle bearer token with model access enabled

## Inputs

Set these in `terraform.tfvars`. Secrets are sensitive variables and must not appear in `overrides.yaml`.

| Variable | Required | Notes |
|---|---|---|
| `aws_profile` | Yes | AWS CLI profile. |
| `name` | Yes | Prefix for the node, key pair, ALB and kubeconfig names. |
| `instance_type` | No | Default `t3.medium`. Use `t3.large` for more headroom. |
| `admin_cidr` | No | Null detects your public IP as `/32`. It controls SSH and the Kubernetes API. |
| `visionone_bootstrap_token` | Yes | Sensitive. Written to the `vision-one-auth` Secret. |
| `aws_bearer_token_bedrock` | Yes | Sensitive. Bedrock Mantle token, written to the `bedrock-mantle-keys` Secret. |
| `domain_name`, `route53_zone_id`, `gateway_hostname` | No | Optional public domain. See the next section. Set all three or none. |
| `public_access_cidrs` | No | CIDRs allowed to reach the ALB. Default `0.0.0.0/0`. Only used with a domain. |
| `alarm_actions` | No | SNS topic ARNs for the ALB alarms. Empty means console only. |

Keep the sensitive values out of files where you can. Export them as `TF_VAR_visionone_bootstrap_token` and `TF_VAR_aws_bearer_token_bedrock` instead, if you prefer.

## Apply

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Review the plan before applying. `tfplan` contains secret values in plain text, so delete it after use.

The apply creates the node and waits for k3s to report `Ready`. It then writes the kubeconfig to `generated/`, creates the Secrets, installs the gateway chart with `overrides.yaml`, and, if a domain is configured, creates the public entry point.

## Optional: public domain (Route 53)

The public entry point is optional. Without a domain, no ALB, certificate or DNS record is created, and the gateway stays inside the cluster. Use the steps in [Access without a domain](#access-without-a-domain).

**Prerequisites**

1. A domain you control, and a **public Route 53 hosted zone** for it. If the zone is in another account or registrar, delegate the domain's nameservers to the zone's NS records before you apply.
2. The zone ID. Look it up with:

   ```bash
   aws route53 list-hosted-zones-by-name --dns-name example.com \
     --query 'HostedZones[0].Id' --output text --profile <AWS_PROFILE> | sed 's#/hostedzone/##'
   ```

3. Choose a hostname inside that zone, for example `aigateway.example.com`. Nothing is assumed: the hostname is whatever you set in `gateway_hostname`.

**Configure** (all three together, or none):

```hcl
domain_name      = "example.com"
route53_zone_id  = "Z0123456789ABCDEFGHIJ"
gateway_hostname = "aigateway.example.com"
```

**What gets created**

- An internet-facing ALB. HTTP 80 redirects to HTTPS 443.
- An ACM certificate for `domain_name` and `gateway_hostname`, validated through Route 53.
- A Route 53 A alias for `gateway_hostname` pointing to the ALB.
- A target group on the node's Traefik NodePort (`30080`), and an Ingress that routes `gateway_hostname` to the gateway's LLM proxy on port `8080`.
- Two CloudWatch alarms: unhealthy targets and ALB 5xx.

**Changing or removing the domain later**

- Changing `gateway_hostname` replaces the certificate and the Route 53 record.
- Clearing all three inputs destroys the ALB, certificate and DNS record. The gateway stays running and is reachable with port-forward only.

**Public endpoint**

| Service | URL |
|---|---|
| AI Gateway | `https://<gateway_hostname>` |

It returns `401` without a virtual key. The ALB has no WAF, so access control depends on the gateway's virtual keys.

## Access without a domain

Leave the three domain inputs unset. The gateway stays internal, and you reach it through the Kubernetes API, which is already open to `admin_cidr`.

1. **Get the kubeconfig** from the apply output:

   ```bash
   export KUBECONFIG="$(terraform output -raw kubeconfig_path)"
   kubectl -n trendai-gateway get pods
   ```

2. **Port-forward the gateway** in its own terminal. Leave it running:

   ```bash
   kubectl -n trendai-gateway port-forward svc/trendai-gateway-gateway 8080:8080 8081:8081
   ```

   Port `8080` is the LLM proxy and port `8081` is the MCP proxy.

3. **Call it at `http://localhost:8080`** from another terminal:

   ```bash
   curl -sS http://localhost:8080/v1/chat/completions \
     -H "Authorization: Bearer $AI_GATEWAY_KEY" \
     -H "Content-Type: application/json" \
     -d '{"model":"<alias>","messages":[{"role":"user","content":"hello"}]}'
   ```

Port-forward uses your existing Kubernetes access, so it needs no inbound rules and no public DNS. The `test-llm.sh` script works the same way with `GATEWAY_URL=http://localhost:8080`:

```bash
GATEWAY_URL=http://localhost:8080 ./test-llm.sh
```

Port-forward is for one operator at a time. It is not a shared endpoint.

## Outputs

| Output | Meaning |
|---|---|
| `gateway_url` | Public URL. Null without a domain. |
| `alb_dns_name` | ALB DNS name. Null without a domain. |
| `access_without_domain` | The port-forward command. |
| `instance_id`, `public_ip` | The node. The Elastic IP is stable across stop and start. |
| `kubeconfig_path` | Kubeconfig for the cluster. |
| `ssh_command`, `private_key_path` | SSH access to the node. |

## Verify on the node

```bash
ssh -i ./generated/<NODE_NAME>.pem ubuntu@<public_ip>
```

```bash
cloud-init status                  # expect: status: done
sudo systemctl is-active k3s       # expect: active
sudo k3s kubectl get nodes -o wide # expect: node Ready
sudo k3s kubectl get pods -A
```

Pods in `kube-system` should be `Running`, and the `helm-install-traefik*` jobs should be `Completed`. Allow 1 to 2 minutes after first boot.

## Verify from your Mac

```bash
export KUBECONFIG="$(terraform output -raw kubeconfig_path)"
kubectl get nodes -o wide
kubectl -n trendai-gateway get pods,svc
```

## Teardown

```bash
terraform destroy
```

Type `yes` when prompted. This removes the node, the Elastic IP, the security groups, the key pair, the Secrets, and (if they exist) the ALB, certificate and Route 53 record. Then remove `generated/` if you don't need the files.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ssh` times out | Your public IP changed. Update `admin_cidr`, then `terraform apply`. |
| `kubectl` connection refused or TLS error | Check `KUBECONFIG` points to `generated/…-kubeconfig.yaml`. The API is reachable only from `admin_cidr`. |
| `Invalid value … domain_name` on plan | Set `domain_name`, `route53_zone_id` and `gateway_hostname` together, or leave all three unset. |
| ALB targets unhealthy | Check the Traefik pod is `1/1` and `kubectl -n kube-system get helmchartconfig traefik` shows `nodePort: 30080`. |
| `api_key unresolvable` for a provider | The key Secret name or key does not match the provider name. See the top-level README, Bedrock section. |
| Pods stuck in `ContainerCreating` | Wait 2 minutes, then `sudo k3s kubectl describe pod -n kube-system <pod>` on the node. |
