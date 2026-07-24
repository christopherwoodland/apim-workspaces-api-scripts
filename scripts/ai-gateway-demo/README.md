# AI Gateway Demo for APIM Workspace

This folder contains a runnable demo flow to show Azure API Management (APIM) as an AI gateway in front of Azure OpenAI.

## What this demo creates

1. A workspace API (`ai-chat-api`) with one operation (`POST /`).
2. An APIM backend (`aoai-backend`) targeting your Azure OpenAI account.
3. Managed identity based backend auth in policy.
4. Governance policies for token/rate limiting and token metrics.
5. A simple test runner that invokes the API twice for before/after latency observation.

## Prerequisites

- Azure CLI (`az`) installed and signed in.
- APIM service and workspace already created.
- APIM managed identity enabled.
- Azure OpenAI account and deployment already created.
- Permissions to create role assignments and modify APIM workspace APIs/policies.

## Files

- `create-ai-gateway-api.ps1`
  - Creates backend, API, operation, and grants APIM managed identity `Cognitive Services User` on Azure OpenAI.
- `apply-ai-gateway-policies.ps1`
  - Applies operation policy including managed identity auth, token limit, rate limit, and token metric emit.
  - Writes policy XML to `policies/ai-gateway-operation-policy.xml`.
- `demo-ai-gateway.ps1`
  - Calls the API endpoint twice and prints status + latency to support live demo talk track.
- `demo-ai-gateway-limit-exceeded.ps1`
  - Applies restrictive policy values and runs repeated/large calls to force a visible policy enforcement response (typically HTTP 429).

## Run order

From repository root:

```powershell
Set-Location C:\Users\cwoodland\dev\apim

$sub = "<subscription-id>"
$rg = "<apim-resource-group>"
$apim = "<apim-name>"
$ws = "<workspace-id>"
$aoai = "<azure-openai-account-name>"
$deployment = "<azure-openai-deployment-name>"
```

### 1) Create API + backend + RBAC

```powershell
.\scripts\ai-gateway-demo\create-ai-gateway-api.ps1 `
  -SubscriptionId $sub `
  -ResourceGroupName $rg `
  -ApimName $apim `
  -WorkspaceId $ws `
  -OpenAiAccountName $aoai `
  -OpenAiDeploymentName $deployment
```

### 2) Apply AI gateway policies

```powershell
.\scripts\ai-gateway-demo\apply-ai-gateway-policies.ps1 `
  -SubscriptionId $sub `
  -ResourceGroupName $rg `
  -ApimName $apim `
  -WorkspaceId $ws `
  -OpenAiAccountName $aoai `
  -OpenAiDeploymentName $deployment `
  -TokensPerMinute 20000 `
  -RateLimitCalls 30 `
  -RateLimitRenewalPeriod 60
```

### 3) Get a subscription key and run demo calls

```powershell
# Example: list APIM subscriptions and retrieve keys
az apim subscription list --resource-group $rg --service-name $apim -o table
az apim subscription keys list --resource-group $rg --service-name $apim --sid <subscription-id-or-name>

$key = "<ocp-apim-subscription-key>"

.\scripts\ai-gateway-demo\demo-ai-gateway.ps1 `
  -SubscriptionId $sub `
  -ResourceGroupName $rg `
  -ApimName $apim `
  -WorkspaceId $ws `
  -ApiPath "ai/chat" `
  -SubscriptionKey $key
```

### 4) Run one-command policy enforcement demo (limit exceeded)

```powershell
.\scripts\ai-gateway-demo\demo-ai-gateway-limit-exceeded.ps1 `
  -SubscriptionId $sub `
  -ResourceGroupName $rg `
  -ApimName $apim `
  -WorkspaceId $ws `
  -OpenAiAccountName $aoai `
  -OpenAiDeploymentName $deployment `
  -SubscriptionKey $key `
  -TokensPerMinute 120 `
  -RateLimitCalls 1 `
  -RateLimitRenewalPeriod 60
```

If your environment does not return a `429` on the first run, reduce `-TokensPerMinute` further (for example `60`) and retry.

## Demo talk track suggestions

- Call 1: baseline response latency.
- Call 2: repeated prompt for potential cache/optimization story.
- Adjust `TokensPerMinute` low to intentionally trigger token-limit behavior.
- Use APIM trace/diagnostics to show policy-driven governance in the gateway.
- Use `demo-ai-gateway-limit-exceeded.ps1` to quickly produce a live policy-enforcement outcome for presentation.

## Notes

- `apply-ai-gateway-policies.ps1` includes commented placeholders for semantic cache and content safety policies. Enable these once your APIM SKU/feature set is confirmed in your environment.
- API management REST `api-version` is set to `2024-10-01-preview` for workspace policy/API operations.
