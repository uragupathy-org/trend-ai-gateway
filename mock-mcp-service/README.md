# mock-mcp-service

Two mock MCP servers (Streamable HTTP, JSON-RPC) for AI Gateway demos. The gateway's MCP proxy calls them as upstreams.

They are not public. Each runs as a `ClusterIP` Service in the `trendai-gateway` namespace, so only gateway pods reach them.

## Contents

| File | What it is |
|---|---|
| `mock-mcp-server.py` | Port 8100. Tools: `add_numbers`, `get_server_time`. |
| `mock-mcp-restricted-server.py` | Port 8200. Tool: `delete_customer_record`. Used to demo an Access Control Forbid rule. |
| `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Terraform for the ConfigMaps, Deployments and Services. |
| `tests/test_mock_mcp.py` | Unit tests for both servers (stdlib `unittest`). |

Each server is standalone and stdlib-only, and is deployed as a single `server.py` from its own ConfigMap.

## Protocol

| Method | Behaviour |
|---|---|
| `initialize` | Returns `protocolVersion: 2025-06-18` and `capabilities.tools`. |
| `notifications/*` | `202 Accepted` with an empty body. |
| `tools/list` | Lists the server's tools. |
| `tools/call` | Runs the tool. |
| other methods | JSON-RPC error `-32601` in a `200` body. The gateway reads denials from the body, not the status. |

`GET /health` returns `200` and is used by the probes. Other `GET` paths return `405`.

## Deploy

```bash
cd trend-ai-gateway/mock-mcp-service
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Defaults point at the current cluster: kubeconfig `../k3s-deploy/generated/k3s-aigateway-kubeconfig.yaml`, context `k3s-aigateway`, namespace `trendai-gateway`.

## In-cluster URLs (register these in Vision One)

| Upstream | URL |
|---|---|
| Safe tools | `http://mock-mcp.trendai-gateway.svc.cluster.local:8100/` |
| Restricted tool | `http://mock-mcp-restricted.trendai-gateway.svc.cluster.local:8200/` |

Use "Add tool" on the server page rather than "Discover tools". Discovery runs from Vision One's cloud and cannot resolve cluster-local names.

## Test locally

```bash
python3 -m unittest discover -s mock-mcp-service/tests -v
```

Run the server by hand:

```bash
python3 mock-mcp-service/mock-mcp-server.py --port 8100
```

Then from another terminal:

```bash
curl -s -X POST http://localhost:8100/ -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Test through the gateway

The MCP proxy listens on port 8081 and is not on the public ALB. Port-forward it first:

```bash
export KUBECONFIG=../k3s-deploy/generated/k3s-aigateway-kubeconfig.yaml
kubectl -n trendai-gateway port-forward svc/trendai-gateway-gateway 8081:8081
```

Then send `initialize`, then `notifications/initialized`, then `tools/list` to `http://localhost:8081/`. Use the virtual key in `Authorization: Bearer <key>`. Capture the `Mcp-Session-Id` response header if the gateway returns one. A denied call returns HTTP 200 with a JSON-RPC `error` in the body.

## Teardown

```bash
terraform destroy
```

This removes the ConfigMaps, Deployments and Services. The namespace stays.
