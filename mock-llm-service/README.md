# mock-llm-service

A small OpenAI-compatible mock of an upstream LLM. The gateway uses it as an
upstream provider when you want to test without a real model provider.

It is not public. It runs as a `ClusterIP` Service in the `trendai-gateway`
namespace, so only pods in the cluster can reach it.

## Contents

| File | What it is |
|---|---|
| `mock-llm-server.py` | Python HTTP server (standard library only). Serves the mock endpoints. |
| `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Terraform for the ConfigMap, Deployment and Service in the cluster. |

The Terraform does not create any AWS resources. It only manages Kubernetes objects.

## Endpoints

The mock listens on port `8001` by default. It serves these paths:

| Method | Path | Response |
|---|---|---|
| GET | `/health` | `{"status": "healthy"}`. Used by the readiness and liveness probes. |
| GET | `/v1/models` | One model, `mock-gpt-4o`. |
| POST | `/v1/chat/completions` | An OpenAI-style chat completion with fixed token usage. Add `"stream": true` for SSE (see Streaming). |
| POST | `/v1/completions` | An OpenAI-style text completion with fixed token usage. |

Any other path returns `404`. The server echoes the requested `model` back and falls back to `mock-gpt-4o` when none is given. Token usage is always `prompt_tokens: 15`, `completion_tokens: 25`, `total_tokens: 40`.

## Prerequisites

- Terraform >= 1.5
- `kubectl` access to the cluster. The kubeconfig comes from `k3s-deploy`, so apply the root stack in `k3s-deploy` first.
- The `trendai-gateway` namespace must already exist. It is created by the gateway Helm install in `k3s-deploy/README.md`.

## Deploy

```bash
cd trend-ai-gateway/mock-llm-service
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

The defaults come from `variables.tf`:

| Variable | Default | Notes |
|---|---|---|
| `kubeconfig_path` | `../k3s-deploy/generated/k3s-trend-ai-gateway-kubeconfig.yaml` | Kubeconfig written by the root stack in `k3s-deploy`. |
| `kube_context` | `k3s-trend-ai-gateway` | Context inside that kubeconfig. |
| `namespace` | `trendai-gateway` | Must already exist. |
| `port` | `8001` | Container and Service port. |
| `image` | `python:3.12-alpine` | Image that provides `python3`. |

To change any of them, create a `terraform.tfvars` in this folder. Real `*.tfvars` files are git-ignored.

## Outputs

| Output | Value |
|---|---|
| `service_name` | `mock-llm` |
| `in_cluster_url` | `http://mock-llm.trendai-gateway.svc.cluster.local:8001/v1` |

Use `in_cluster_url` as the upstream base URL when registering the mock as a provider in the gateway.

## Verify

Check the pod and Service:

```bash
export KUBECONFIG=../k3s-deploy/generated/k3s-trend-ai-gateway-kubeconfig.yaml
kubectl -n trendai-gateway get deploy,pods,svc -l app=mock-llm
```

Call the mock from your Mac with a port-forward:

```bash
kubectl -n trendai-gateway port-forward svc/mock-llm 8001:8001
```

In a second terminal:

```bash
curl -s http://localhost:8001/health
curl -s http://localhost:8001/v1/models
curl -s -X POST http://localhost:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "mock-gpt-4o", "messages": [{"role": "user", "content": "Hello"}]}'
```

To test from inside the cluster, run a throwaway pod:

```bash
kubectl -n trendai-gateway run curl-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s http://mock-llm.trendai-gateway.svc.cluster.local:8001/health
```


## Streaming

Send `"stream": true` to `/v1/chat/completions` to get OpenAI-style server-sent events. The reply is split into word chunks, followed by a final chunk with `finish_reason` and `usage`, then `data: [DONE]`.

| Env var | Default | Meaning |
|---|---|---|
| `MOCK_LLM_STREAM_DELAY_MS` | `50` | Pause between chunks. |
| `MOCK_LLM_STREAM_CHUNK_WORDS` | `3` | Words per chunk. |

Without `stream`, the endpoint returns a single JSON completion as before.

Test locally:

```bash
python3 -m unittest discover -s mock-llm-service/tests -v
```

## Updating the script

Edit `mock-llm-server.py`, then run `terraform apply`. The ConfigMap picks up the new file, and the `checksum/script` annotation changes. That rolls the Deployment onto the new code.

## Teardown

```bash
terraform destroy
```

This removes the ConfigMap, Deployment and Service. The namespace stays.

## Notes

- This is for testing only. The responses are fixed and do not come from a model.
- The mock is not exposed through the ALB or Route 53. See [../k3s-deploy/README.md](../k3s-deploy/README.md) for the public gateway endpoint.
- `mock-mcp-service/` is a placeholder and has no code yet.
