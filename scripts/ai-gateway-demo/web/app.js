const state = {
  currentStep: 1,
  completed: new Set(),
  running: false,
};

const el = {
  subscriptionId: document.getElementById("subscriptionId"),
  resourceGroupName: document.getElementById("resourceGroupName"),
  apimName: document.getElementById("apimName"),
  workspaceId: document.getElementById("workspaceId"),
  openAiAccountName: document.getElementById("openAiAccountName"),
  openAiDeploymentName: document.getElementById("openAiDeploymentName"),
  subscriptionKey: document.getElementById("subscriptionKey"),
  tokensPerMinute: document.getElementById("tokensPerMinute"),
  rateLimitCalls: document.getElementById("rateLimitCalls"),
  rateLimitRenewalPeriod: document.getElementById("rateLimitRenewalPeriod"),
  enforcementTokensPerMinute: document.getElementById("enforcementTokensPerMinute"),
  enforcementRateLimitCalls: document.getElementById("enforcementRateLimitCalls"),
  enforcementRateLimitRenewalPeriod: document.getElementById("enforcementRateLimitRenewalPeriod"),
  runStep1: document.getElementById("runStep1"),
  runStep2: document.getElementById("runStep2"),
  runStep3: document.getElementById("runStep3"),
  runStep4: document.getElementById("runStep4"),
  resetFlow: document.getElementById("resetFlow"),
  stepItem1: document.getElementById("stepItem1"),
  stepItem2: document.getElementById("stepItem2"),
  stepItem3: document.getElementById("stepItem3"),
  stepItem4: document.getElementById("stepItem4"),
  output: document.getElementById("output"),
  statusBadge: document.getElementById("statusBadge"),
};

function getPayload(step) {
  return {
    step: String(step),
    subscriptionId: el.subscriptionId.value.trim(),
    resourceGroupName: el.resourceGroupName.value.trim(),
    apimName: el.apimName.value.trim(),
    workspaceId: el.workspaceId.value.trim(),
    openAiAccountName: el.openAiAccountName.value.trim(),
    openAiDeploymentName: el.openAiDeploymentName.value.trim(),
    subscriptionKey: el.subscriptionKey.value.trim(),
    tokensPerMinute: Number(el.tokensPerMinute.value || 20000),
    rateLimitCalls: Number(el.rateLimitCalls.value || 30),
    rateLimitRenewalPeriod: Number(el.rateLimitRenewalPeriod.value || 60),
    enforcementTokensPerMinute: Number(el.enforcementTokensPerMinute.value || 120),
    enforcementRateLimitCalls: Number(el.enforcementRateLimitCalls.value || 1),
    enforcementRateLimitRenewalPeriod: Number(el.enforcementRateLimitRenewalPeriod.value || 60),
  };
}

function setStatus(kind, text) {
  el.statusBadge.className = `badge ${kind}`;
  el.statusBadge.textContent = text;
}

function appendOutput(text) {
  const stamp = new Date().toLocaleTimeString();
  el.output.textContent += `\n[${stamp}] ${text}\n`;
  el.output.scrollTop = el.output.scrollHeight;
}

function validateFields(step) {
  const missing = [];
  if (!el.subscriptionId.value.trim()) missing.push("Subscription ID");
  if (!el.resourceGroupName.value.trim()) missing.push("Resource Group");
  if (!el.apimName.value.trim()) missing.push("APIM Name");
  if (!el.workspaceId.value.trim()) missing.push("Workspace ID");
  if (!el.openAiAccountName.value.trim()) missing.push("Azure OpenAI Account");
  if (!el.openAiDeploymentName.value.trim()) missing.push("Azure OpenAI Deployment");

  if (missing.length > 0) {
    appendOutput(`Validation failed. Missing: ${missing.join(", ")}`);
    setStatus("error", "Missing Input");
    return false;
  }

  return true;
}

function setStepVisual(step, status) {
  const item = el[`stepItem${step}`];
  item.classList.remove("current", "done", "failed");
  if (status) {
    item.classList.add(status);
  }
}

function refreshButtons() {
  el.runStep1.disabled = state.running;
  el.runStep2.disabled = state.running || !state.completed.has(1);
  el.runStep3.disabled = state.running || !state.completed.has(2);
  el.runStep4.disabled = state.running || !state.completed.has(3);
}

async function runStep(step) {
  if (state.running) return;
  if (!validateFields(step)) return;

  state.running = true;
  refreshButtons();
  setStatus("running", `Running Step ${step}`);
  setStepVisual(step, "current");
  appendOutput(`Running Step ${step}...`);

  try {
    const payload = getPayload(step);
    const response = await fetch("/api/run-step", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    const result = await response.json();
    const lines = Array.isArray(result.output) ? result.output : [];

    if (lines.length > 0) {
      appendOutput(lines.join("\n"));
    }

    if (result.ok) {
      state.completed.add(step);
      setStepVisual(step, "done");
      setStatus("ok", `Step ${step} Succeeded`);
      appendOutput(`Step ${step} succeeded.`);
    } else {
      setStepVisual(step, "failed");
      setStatus("error", `Step ${step} Failed`);
      appendOutput(`Step ${step} failed.`);
    }
  } catch (error) {
    setStepVisual(step, "failed");
    setStatus("error", `Step ${step} Failed`);
    appendOutput(`Request failed: ${error.message}`);
  } finally {
    state.running = false;
    refreshButtons();
  }
}

function resetFlow() {
  state.currentStep = 1;
  state.completed.clear();
  setStepVisual(1, "current");
  setStepVisual(2, "");
  setStepVisual(3, "");
  setStepVisual(4, "");
  el.output.textContent = "Ready. Fill context and run Step 1.";
  setStatus("idle", "Idle");
  refreshButtons();
}

el.runStep1.addEventListener("click", () => runStep(1));
el.runStep2.addEventListener("click", () => runStep(2));
el.runStep3.addEventListener("click", () => runStep(3));
el.runStep4.addEventListener("click", () => runStep(4));
el.resetFlow.addEventListener("click", resetFlow);

resetFlow();
