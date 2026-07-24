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
- `start-ai-gateway-demo-wizard.ps1`
  - Starts a local click-through wizard for the live demo flow with one button per step.
  - Serves UI from `web/index.html` and executes steps via local API endpoints.

## Wizard UI (recommended for live talk)

```powershell
.\scripts\ai-gateway-demo\start-ai-gateway-demo-wizard.ps1
```

Default URL:

- http://localhost:5088

Optional flags:

```powershell
# Change port
.\scripts\ai-gateway-demo\start-ai-gateway-demo-wizard.ps1 -Port 5090

# Do not auto-open browser
.\scripts\ai-gateway-demo\start-ai-gateway-demo-wizard.ps1 -NoBrowser
```

The wizard is prefilled with these defaults and runs these actions in order:

- Subscription: `6bf68138-6ea4-4272-a3db-78e737e132a6`
- Resource Group: `integration`
- APIM: `intapim001`
- Workspace: `cw11`
- OpenAI Account: `bhs-development-public-foundry-r`
- Deployment: `gpt-4.1`

1. Create API + backend + RBAC
2. Apply AI gateway policies
3. Run baseline demo calls
4. Run enforcement demo (attempts to trigger 429)

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

### 3) Run demo calls (no APIM subscription key required)

```powershell
.\scripts\ai-gateway-demo\demo-ai-gateway.ps1 `
  -SubscriptionId $sub `
  -ResourceGroupName $rg `
  -ApimName $apim `
  -WorkspaceId $ws `
  -ApiPath "ai/chat"
```

Optional: if your APIM instance still enforces subscription keys, add `-SubscriptionKey <key>`.

### 4) Run one-command policy enforcement demo (limit exceeded)

```powershell
.\scripts\ai-gateway-demo\demo-ai-gateway-limit-exceeded.ps1 `
  -SubscriptionId $sub `
  -ResourceGroupName $rg `
  -ApimName $apim `
  -WorkspaceId $ws `
  -OpenAiAccountName $aoai `
  -OpenAiDeploymentName $deployment `
  -TokensPerMinute 120 `
  -RateLimitCalls 1 `
  -RateLimitRenewalPeriod 60
```

Optional: add `-SubscriptionKey <key>` if APIM requires subscriptions in your environment.

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
- This demo is workspace-scoped (all API and policy operations target `.../workspaces/<workspaceId>/...`).
