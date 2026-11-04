# Trend AI Gateway: AWS deployment

This repository deploys a single-node k3s cluster on AWS and runs the Trend AI Gateway in it. The gateway can be published on a public domain you configure, or reached through port-forward without one. It also includes two in-cluster mocks for testing (an LLM and MCP servers) and a live connection to Amazon Bedrock through the Mantle endpoint.

## Prerequisites

Check each group before you run `terraform apply`. Everything below runs from your own machine, the one that applies Terraform.

### Local tools

| Tool | Version | Used for |
|---|---|---|
| Terraform | 1.5 or later (tested with 1.12) | Creates the node, ALB, Secrets, gateway install and mocks |
| AWS CLI v2 | Current | Authenticates Terraform to AWS through a named profile |
| kubectl | Same minor version as the cluster's k3s server | Port-forward, status checks, and the Terraform `local-exec` steps |
| Helm | 3.8 or later (OCI support) | Installs the gateway chart from `public.ecr.aws` |
| jq | Any recent | Used by `test-llm.sh` and the Secret checks |
| curl, python3 | Any recent | Test requests and the mock unit tests |
| ssh | Any | Optional access to the node |

Terraform's `local-exec` steps call `kubectl` and `helm` on the machine that applies, so both must be on `PATH` and must be able to reach the cluster's API on port 6443.

### AWS account

- **Profile:** a named AWS CLI profile with credentials. Check it with `aws sts get-caller-identity --profile <AWS_PROFILE>`.
- **Region:** `ap-southeast-2` by default. Set `region` for another region. The Bedrock Mantle endpoint must be in the same region as the model access you enable.
- **Permissions:** the profile needs to create and manage EC2 instances, key pairs, security groups, Elastic IPs and tags. It also needs ELB (ALB, listeners, target groups), ACM and Route 53 when you use a domain, and `ssm:GetParameter` on the Ubuntu AMI path under `/aws/service/canonical/`.
- **Quotas:** one free Elastic IP, and enough On-Demand vCPU quota for the instance type. `t3.medium` needs 2 vCPUs.
- **Network:** a VPC with at least two subnets in different availability zones. The default VPC normally works. Otherwise set `vpc_id` and `subnet_id`. An internet route is required, because the node downloads k3s and pulls images and the chart from the internet.
- **Optional, for a public domain:** a public Route 53 hosted zone for your domain, with its nameservers delegated to Route 53, and its zone ID. Without a domain, none of this is needed.

### Kubernetes

- Nothing needs to be installed on the cluster. Terraform installs single-node k3s on Ubuntu 24.04 on an EC2 instance. The node needs at least 2 vCPUs and 4 GiB of RAM. `t3.medium` meets that.
- The API port 6443 and SSH port 22 open only to `admin_cidr`. Leave `admin_cidr` null to use your current public IP.
- Terraform writes the kubeconfig to `k3s-deploy/generated/`. Its context is named after the `name` variable.
- The `trendai-gateway` namespace is created during the apply, so you don't need to create it.
- After the apply, check the server version against your local kubectl:

  ```bash
  kubectl --kubeconfig k3s-deploy/generated/<name>-kubeconfig.yaml version
  ```

### Vision One

- **Private Preview access (required).** AI Gateway is a Private Preview feature, and the console shows a "Pre-release" banner. Reach out to the AI Security PM to get Private Preview access before you start, and confirm that your account is enabled for AI Gateway in your region. Features in this build may change, and some (such as Discovered Tools) have known limitations.
- An account with AI Gateway access in your region, and permission to create a gateway.
- A one-time bootstrap token from the AI Gateway setup flow, which you can only generate once access is granted. Put it in `visionone_bootstrap_token`. Its API URL goes in `overrides.yaml` under `gateway.visionone.url`.

### Bedrock Mantle (for the live model connection)

- A Mantle bearer token. Put it in `aws_bearer_token_bedrock`.
- Model access enabled for the model you route to, in your region (the test alias uses `openai.gpt-oss-safeguard-20b`).
- Outbound HTTPS from the node to `bedrock-mantle.<region>.api.aws`. The node's security group allows all outbound traffic.

### Inputs

Create `k3s-deploy/terraform.tfvars` from `terraform.tfvars.example`, and keep it out of Git. At minimum, set:

- `aws_profile`, `name`, `region`
- `visionone_bootstrap_token`
- `aws_bearer_token_bedrock`
- `domain_name`, `route53_zone_id` and `gateway_hostname`, only if you want a public domain

Set the two token variables as `TF_VAR_...` environment variables instead, if you'd rather they aren't in a file.

### Preflight check

```bash
terraform version
aws sts get-caller-identity --profile <AWS_PROFILE>
kubectl version --client
helm version --short
jq --version
python3 --version
```

## Live endpoints

| Service | URL or address | Reachable from | Notes |
|---|---|---|---|
| AI Gateway (LLM proxy) | `https://<gateway_hostname>` when a domain is configured | Internet, through the ALB | Requires a virtual key. `401` without one. |
| AI Gateway, no domain | `http://localhost:8080` after port-forward | Your machine, through the Kubernetes API | `kubectl -n trendai-gateway port-forward svc/trendai-gateway-gateway 8080:8080 8081:8081` |
| Gateway MCP proxy | `svc/trendai-gateway-gateway:8081` | Inside the cluster, or a port-forward | Not on the public ALB. |
| Mock LLM | `http://mock-llm.trendai-gateway.svc.cluster.local:8001` | Inside the cluster | Test provider. |
| Mock MCP (safe) | `http://mock-mcp.trendai-gateway.svc.cluster.local:8100/` | Inside the cluster | Tools `add_numbers` and `get_server_time`. |
| Mock MCP (restricted) | `http://mock-mcp-restricted.trendai-gateway.svc.cluster.local:8200/` | Inside the cluster | Tool `delete_customer_record`, for Access Control tests. |
| Bedrock Mantle | `https://bedrock-mantle.ap-southeast-2.api.aws` | Outbound from the gateway | Provider `bedrock-mantle`. The base URL has no `/v1`. |

## Repository layout

```
trend-ai-gateway/
├── README.md                 This file
├── test-llm.sh               Control and guardrail prompt tests against the gateway
├── overrides.yaml            Helm values for the gateway (names of Secrets, no values)
├── overrides.example.yaml    Template for the Helm values
├── k3s-deploy/               EC2 node, k3s, ALB, Route 53, Secrets, gateway Helm install
├── mock-llm-service/         In-cluster mock LLM (JSON and streaming)
└── mock-mcp-service/         In-cluster mock MCP servers (safe and restricted)
```

Each component has its own README:

- [k3s-deploy/README.md](k3s-deploy/README.md): node, ALB, Route 53, certificate, alarms, Secrets and the gateway install
- [mock-llm-service/README.md](mock-llm-service/README.md): mock LLM, including streaming
- [mock-mcp-service/README.md](mock-mcp-service/README.md): mock MCP servers and Vision One registration

## Deployment order

Apply the components in this order. Each step depends on the one before it.

1. **`k3s-deploy/`** creates the EC2 node, the k3s cluster, the Secrets and the gateway chart. It also creates the ALB, certificate and Route 53 record when a domain is configured. Its state is local.
2. **`mock-llm-service/`** deploys the mock LLM into `trendai-gateway`. It reads the kubeconfig written by step 1.
3. **`mock-mcp-service/`** deploys both mock MCP servers. It reads the same kubeconfig.

```bash
cd k3s-deploy && terraform init && terraform plan -out=tfplan && terraform apply tfplan
cd ../mock-llm-service && terraform init && terraform plan -out=tfplan && terraform apply tfplan
cd ../mock-mcp-service && terraform init && terraform plan -out=tfplan && terraform apply tfplan
```

Review each plan before you apply it. `tfplan` files contain secret values in plain text, so delete them after use.

## Optional: public domain

A public domain is optional. Without one, no ALB, certificate or DNS record is created, and you reach the gateway with port-forward. Set `domain_name`, `route53_zone_id` and `gateway_hostname` together, or leave all three unset. For the Route 53 prerequisites, the hosted-zone lookup and the no-domain steps, see [k3s-deploy/README.md](k3s-deploy/README.md).

## Secrets and where they live

| Secret | Set in | Kubernetes Secret | Referenced from |
|---|---|---|---|
| Vision One bootstrap token | `k3s-deploy/terraform.tfvars` (`visionone_bootstrap_token`) | `vision-one-auth`, key `token` | `overrides.yaml`: `gateway.visionone.authToken.existingSecret` |
| Bedrock Mantle bearer token | `k3s-deploy/terraform.tfvars` (`aws_bearer_token_bedrock`) | `bedrock-mantle-keys`, key `bedrock-mantle` | `overrides.yaml`: `gateway.secretsDir.existingSecret` |

Terraform writes both Secrets during the Helm step. The token is passed through an environment variable, so it never appears on a command line or in a file.

`overrides.yaml` holds only Secret names and never a value, which is why it is tracked in Git. `terraform.tfvars`, `generated/` and `tfplan` files are git-ignored.

Check a Secret's key names without printing values:

```bash
export KUBECONFIG=k3s-deploy/generated/k3s-aigateway-kubeconfig.yaml
kubectl -n trendai-gateway get secret bedrock-mantle-keys -o jsonpath='{.data}' | jq 'keys'
```

## Bedrock Mantle integration

The gateway calls Bedrock through its OpenAI-compatible Mantle endpoint. This is a live setup.

**Configuration**

- **Vision One provider:** name `bedrock-mantle`, base URL `https://bedrock-mantle.ap-southeast-2.api.aws`, with no `/v1`. The gateway adds `/v1/...` itself. Leave the provider's API-key field as a placeholder.
- **Model and alias:** the test alias points at `openai.gpt-oss-safeguard-20b`. This is a safety-classification model, so its replies read like policy reasoning. That's expected.
- **Key delivery:** the gateway reads the key from `/etc/secrets/gateway/bedrock-mantle`. `secretsDir` mounts that file from `bedrock-mantle-keys`. The file name must match the provider name exactly.

**Verified**

- `./test-llm.sh` passes against the Mantle-backed alias, both non-streaming and with `--stream`.
- Events from these requests appear in the Vision One console.

**If a request fails**

| Symptom | Cause | Fix |
|---|---|---|
| `api_key unresolvable, provider skipped` in the logs | The key file is missing, or its name doesn't match the provider | Check the Secret key is `bedrock-mantle`, then restart the gateway. A pod that started before the key existed doesn't retry its file watch. |
| `404` from Mantle, or a doubled `/v1` in the upstream path | `/v1` is in the provider base URL | Remove `/v1` from the base URL. |
| `401` or `403` from Mantle | Wrong or expired token, or no access to the model | Rotate the token, update `terraform.tfvars`, and re-apply `k3s-deploy`. |

Restart only the gateway with `kubectl -n trendai-gateway rollout restart deploy/trendai-gateway-gateway`. Leave Redis alone: the gateway can't reconnect to Redis if both restart at the same time.

## Adding an LLM provider

This section is generic. It applies to any OpenAI-compatible endpoint, such as Bedrock Mantle, a self-hosted model server or the mock LLM.

1. **Pick a provider name.** Use lowercase letters, digits and hyphens, for example `bedrock-mantle`. The name is also the key and file name for its credential, so it must match exactly.
2. **Check the upstream by hand.** Confirm the endpoint and token work before you involve the gateway:

   ```bash
   curl -sS "$BASE_URL/v1/models" -H "Authorization: Bearer $UPSTREAM_TOKEN"
   ```

   `$BASE_URL` is the root of the API, without `/v1`. The gateway adds `/v1/...` itself, so a `/v1` on the base URL produces a doubled path and a `404`.
3. **Store the credential as a Kubernetes Secret.**
   - Add a sensitive Terraform variable, for example `<provider>_api_key`, in `k3s-deploy/gateway_variables.tf`.
   - Add a line to the Secret step in `k3s-deploy/gateway.tf` that writes the value to a key named after the provider. Pass the value through an environment variable, as the existing secrets do.
   - Mount the Secret through `secretsDir` in `k3s-deploy/overrides.yaml`. Each provider key is one key in the shared Secret.
   - Apply `k3s-deploy`, then restart the gateway so it picks up the new file. A pod that started before the key existed does not retry its file watch:

     ```bash
     kubectl -n trendai-gateway rollout restart deploy/trendai-gateway-gateway
     ```

   Leave Redis alone while you restart.
4. **Add the provider in Vision One.** Go to **AI Gateway → Resources → LLM → Add Provider**. Set the name to the same provider name, the type to `openai` for OpenAI-compatible endpoints, and the base URL to `$BASE_URL` without `/v1`. Leave the API-key field as a placeholder, because the gateway reads the mounted file.
5. **Add a model and an alias.** Add the upstream's model ID under the provider, then create an alias that points to it. Make sure the alias is enabled and "In catalog".
6. **Permit the calls.** Under **Controls → Access Control**, add a Permit rule for "Call LLM" that covers the provider's resources and the identities that should use it.
7. **Route the requests.** Under **Controls → Routing Rules**, route the requested model (or `*`) to the alias.
8. **Verify.** Wait about 30 seconds for the console change to reach the gateway, then:

   ```bash
   ALIAS=<alias> ./test-llm.sh
   ALIAS=<alias> ./test-llm.sh --stream
   kubectl -n trendai-gateway logs deploy/trendai-gateway-gateway --since=5m | grep -i 'unresolvable\|skipped\|upstream'
   ```

**Common failures**

| Symptom | Cause | Fix |
|---|---|---|
| `api_key unresolvable, provider skipped` | Secret key or file name doesn't match the provider | Rename the Secret key to the provider name, then restart the gateway. |
| `404` from the upstream, with `/v1/v1` in the path | `/v1` in the base URL | Remove `/v1` from the Vision One base URL. |
| `401` or `403` from the upstream | Wrong token, or no access to the model | Check the token by hand (step 2), then rotate it if needed. |
| `no upstreams configured` | Provider missing from the catalog, or no routing rule matches | Check steps 4 to 7. |

## Adding an MCP server (streamable HTTP)

This section is generic. It applies to any MCP server that speaks JSON-RPC over HTTP. `mock-mcp-service/` is a working example.

1. **Implement the server.** It must handle:
   - `initialize`: return `protocolVersion`, `capabilities.tools` and `serverInfo`
   - `notifications/*`: return `202` with an empty body. Notifications have no `id`.
   - `tools/list`: return the tools, each with `name`, `description` and `inputSchema`
   - `tools/call`: run the tool and return `content`, with `isError` on failure
   - Unknown methods: return a JSON-RPC `-32601` error in a `200` body. The gateway reads denials from the body, not from the status code.
   - `GET /health`: return `200`, for the probes

   Keep it standard library only if you deploy it from a ConfigMap, as `mock-mcp-service` does.
2. **Deploy it inside the cluster.** Add the server to the `local.servers` map in `mock-mcp-service/main.tf`, with its port and script. The Deployment, Service and ConfigMap come from the same `for_each`. Give the server a port that no other Service uses.

   Don't name environment variables after the Service. Kubernetes injects `<SERVICE>_PORT` into pods, so a Service called `mock-mcp` with an env var `MOCK_MCP_PORT` crashes at startup. Use a prefix that doesn't match a Service name.
3. **Store any upstream credential** the same way as for an LLM provider: a Secret key, mounted through `secretsDir`. For MCP upstreams, the chart's docs name the key `mcp-<name>`. Check the logs to confirm the name the gateway reads, then restart the gateway.
4. **Register it in Vision One.** Go to **AI Gateway → Resources → MCP → Add Server**. Set the URL to `http://<service>.trendai-gateway.svc.cluster.local:<port>/`, the transport to `http`, and a name. On the server's page, use **Add tool** for each tool, with the exact tool name and a description.

   Don't use "Discover tools" for cluster-local servers. Discovery runs from Vision One's cloud, which can't resolve cluster-local names.
5. **Control access.** Access Control scopes MCP rules to whole servers, not to single tools. To allow some tools and block others, put them on separate servers, then add a Permit rule for the safe server and a Forbid rule for the restricted one.
6. **Test the stream.** Port-forward the MCP proxy, then run the handshake:

   ```bash
   kubectl -n trendai-gateway port-forward svc/trendai-gateway-gateway 8081:8081
   ```

   Send `initialize`, then `notifications/initialized` (expect `202`), then `tools/list` and `tools/call` to `http://localhost:8081/`. Tools appear as `<server-name>__<tool-name>`. Send `Accept: application/json, text/event-stream`, and the `Mcp-Session-Id` header returned by `initialize`, if the gateway returns one.

   The gateway may send responses as server-sent events. If so, read the `data:` lines, for example with `sed -n 's/^data: //p'`.
7. **Verify.** A denied call returns HTTP `200` with a JSON-RPC `error` in the body. A successful call returns a `result`. Both appear in **AI Gateway → Events**.

**Common failures**

| Symptom | Cause | Fix |
|---|---|---|
| Pod crash-loops with `invalid literal for int()` | An env var name matches a Service's injected variable | Rename the env var (see step 2). |
| "Discover tools" fails with `no such host` | Discovery runs in Vision One's cloud | Use Add tool instead. |
| Forbid rule has no effect | The tool isn't listed on its server | Add the tool on that server's page. |
| `unknown upstream` on `tools/call` | Server not registered, or its name differs | Check the server name under Resources → MCP. |

## Testing

**LLM controls and guardrails**

```bash
export AI_GATEWAY_KEY='<virtual key>'
export ALIAS='openai.gpt-oss-safeguard-20b'
./test-llm.sh            # non-streaming
./test-llm.sh --stream   # streaming
./test-llm.sh --verbose  # show prompts and bodies
```

The script reports PASS or FAIL for each case and exits 1 on any mismatch.

**MCP handshake and access checks** (port-forward first, see Prerequisites):

```bash
./test-mcp.sh            # defaults to http://localhost:8081/
```

The script runs initialize, notifications, tools/list, a safe tool call, and a restricted tool call that the Forbid rule should deny.

**Test scenarios and console configuration:** see [TEST-SCENARIOS.md](TEST-SCENARIOS.md) for the routing, access control and guardrail scenarios, the configuration as observed in the console, and the findings to review before a demo.

**Mock MCP:** port-forward the gateway's MCP proxy, then run the handshake from the mock MCP README.

```bash
export KUBECONFIG=k3s-deploy/generated/k3s-aigateway-kubeconfig.yaml
kubectl -n trendai-gateway port-forward svc/trendai-gateway-gateway 8081:8081
```

**Unit tests for the mocks** (no cluster needed):

```bash
python3 -m unittest discover -s mock-llm-service/tests -v
python3 -m unittest discover -s mock-mcp-service/tests -v
```

## Operations

- **Status:** `kubectl -n trendai-gateway get pods,svc,ingress`
- **Gateway logs:** `kubectl -n trendai-gateway logs deploy/trendai-gateway-gateway --since=10m`
- **Helm release:** `helm -n trendai-gateway status trendai-gateway`
- **Scale back replicas** if Vision One pushes an autoscaling policy: `kubectl -n trendai-gateway scale deploy/trendai-gateway-gateway --replicas=2`
- **Access control and guardrails** are configured in the Vision One console, not in this repository. The field guide in `docs/` covers them.

## Security

- Never commit `terraform.tfvars`, `*.tfstate`, `*.pem`, `generated/`, `tfplan` files, or any file that contains a token.
- Rotate the Bedrock Mantle token and the Vision One bootstrap token. Both values have appeared in files and in terminal output during setup.
- The ALB is public, so access control depends on the gateway's virtual keys.
- Provider keys are never stored in Git. They are mounted from Kubernetes Secrets.

## Teardown

Destroy in reverse order, so dependent resources go first:

```bash
cd mock-mcp-service && terraform destroy
cd ../mock-llm-service && terraform destroy
cd ../k3s-deploy && terraform destroy
```

`terraform destroy` in `k3s-deploy` removes the node, the ALB, the certificate, the Route 53 record and the Secrets it created. Vision One drops inactive gateway instances after about seven days, or you can delete the entry from **AI Gateway → Management**.
