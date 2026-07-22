const state = {
  subscriptions: [],
  apimServices: [],
  workspaces: [],
  currentStep: 1,
};

const el = {
  tabWizardBtn: document.getElementById("tabWizardBtn"),
  tabWorkspacesBtn: document.getElementById("tabWorkspacesBtn"),
  wizardView: document.getElementById("wizardView"),
  workspacesView: document.getElementById("workspacesView"),

  stepBasics: document.getElementById("stepBasics"),
  stepGateway: document.getElementById("stepGateway"),
  stepReview: document.getElementById("stepReview"),
  basicsCard: document.getElementById("basicsCard"),
  gatewayCard: document.getElementById("gatewayCard"),
  runCard: document.getElementById("runCard"),
  toGatewayBtn: document.getElementById("toGatewayBtn"),
  backToBasicsBtn: document.getElementById("backToBasicsBtn"),
  toReviewBtn: document.getElementById("toReviewBtn"),
  backToGatewayBtn: document.getElementById("backToGatewayBtn"),
  ctxSubscription: document.getElementById("ctxSubscription"),
  ctxApim: document.getElementById("ctxApim"),
  ctxWorkspace: document.getElementById("ctxWorkspace"),
  ctxMode: document.getElementById("ctxMode"),

  subscriptionSelect: document.getElementById("subscriptionSelect"),
  apimSelect: document.getElementById("apimSelect"),
  loadSubscriptionsBtn: document.getElementById("loadSubscriptionsBtn"),
  loadApimBtn: document.getElementById("loadApimBtn"),
  resetSettingsBtn: document.getElementById("resetSettingsBtn"),
  basicsProgress: document.getElementById("basicsProgress"),
  basicsProgressText: document.getElementById("basicsProgressText"),

  mode: document.getElementById("mode"),
  workspaceId: document.getElementById("workspaceId"),
  displayName: document.getElementById("displayName"),
  description: document.getElementById("description"),

  dedicatedPanel: document.getElementById("dedicatedPanel"),
  verifyPanel: document.getElementById("verifyPanel"),
  runtimePanel: document.getElementById("runtimePanel"),

  networkResourceGroup: document.getElementById("networkResourceGroup"),
  location: document.getElementById("location"),
  networkMode: document.getElementById("networkMode"),
  skipWorkspaceCreate: document.getElementById("skipWorkspaceCreate"),

  strictVerify: document.getElementById("strictVerify"),

  apiPath: document.getElementById("apiPath"),
  probePath: document.getElementById("probePath"),
  expectedStatusCodes: document.getElementById("expectedStatusCodes"),
  gatewayUrl: document.getElementById("gatewayUrl"),
  collectDiagnostics: document.getElementById("collectDiagnostics"),
  diagnosticsOutputPath: document.getElementById("diagnosticsOutputPath"),

  whatIfOnly: document.getElementById("whatIfOnly"),
  deploySampleApi: document.getElementById("deploySampleApi"),
  createSampleProduct: document.getElementById("createSampleProduct"),
  sampleProfile: document.getElementById("sampleProfile"),
  sampleBackendUrl: document.getElementById("sampleBackendUrl"),
  autoVerifyRuntime: document.getElementById("autoVerifyRuntime"),
  autoApiPath: document.getElementById("autoApiPath"),
  autoProbePath: document.getElementById("autoProbePath"),
  autoExpectedStatusCodes: document.getElementById("autoExpectedStatusCodes"),
  autoRetryIntervalSeconds: document.getElementById("autoRetryIntervalSeconds"),
  autoTimeoutSeconds: document.getElementById("autoTimeoutSeconds"),

  runBtn: document.getElementById("runBtn"),
  clearOutputBtn: document.getElementById("clearOutputBtn"),
  loadWorkspacesBtn: document.getElementById("loadWorkspacesBtn"),
  refreshWorkspacesBtn: document.getElementById("refreshWorkspacesBtn"),
  workspaceProgress: document.getElementById("workspaceProgress"),
  workspaceProgressText: document.getElementById("workspaceProgressText"),
  workspacesTbody: document.getElementById("workspacesTbody"),
  wsCountChip: document.getElementById("wsCountChip"),
  wsAssocYesChip: document.getElementById("wsAssocYesChip"),
  wsAssocNoChip: document.getElementById("wsAssocNoChip"),
  wsAssocUnknownChip: document.getElementById("wsAssocUnknownChip"),

  output: document.getElementById("output"),
  status: document.getElementById("status"),
  validationStatus: document.getElementById("validationStatus"),
  validationBanner: document.getElementById("validationBanner"),
  apiResultPanel: document.getElementById("apiResultPanel"),
  apiResultTitle: document.getElementById("apiResultTitle"),
  apiResultJson: document.getElementById("apiResultJson"),
  copyApiResultBtn: document.getElementById("copyApiResultBtn"),
  progress: document.getElementById("progress"),
  urlActions: document.getElementById("urlActions"),
  workspacePortalUrlText: document.getElementById("workspacePortalUrlText"),
  workspaceUrlText: document.getElementById("workspaceUrlText"),
  gatewayUrlText: document.getElementById("gatewayUrlText"),
  runtimeUrlText: document.getElementById("runtimeUrlText"),
  copyWorkspacePortalUrlBtn: document.getElementById("copyWorkspacePortalUrlBtn"),
  copyWorkspaceUrlBtn: document.getElementById("copyWorkspaceUrlBtn"),
  copyGatewayUrlBtn: document.getElementById("copyGatewayUrlBtn"),
  copyRuntimeUrlBtn: document.getElementById("copyRuntimeUrlBtn"),

  profileCard: document.getElementById("profileCard"),
  profileBadge: document.getElementById("profileBadge"),
  profileHint: document.getElementById("profileHint"),
};

function appendOutput(text) {
  if (!text) return;
  const stamp = new Date().toLocaleTimeString();
  el.output.textContent += `[${stamp}] ${text}\n`;
  el.output.scrollTop = el.output.scrollHeight;
}

function setApiResult(title, payload) {
  if (!el.apiResultPanel || !el.apiResultJson || !el.apiResultTitle) return;

  if (!payload) {
    el.apiResultTitle.textContent = "Last API Response";
    el.apiResultJson.textContent = "";
    el.apiResultPanel.classList.add("hidden");
    if (el.copyApiResultBtn) el.copyApiResultBtn.disabled = true;
    return;
  }

  el.apiResultTitle.textContent = title || "Last API Response";
  try {
    el.apiResultJson.textContent = JSON.stringify(payload, null, 2);
  } catch {
    el.apiResultJson.textContent = String(payload);
  }
  el.apiResultPanel.classList.remove("hidden");
  if (el.copyApiResultBtn) el.copyApiResultBtn.disabled = false;
}

function setBusy(message) {
  el.status.textContent = message;
  el.progress.classList.remove("hidden");
  for (const button of [
    el.loadSubscriptionsBtn,
    el.loadApimBtn,
    el.resetSettingsBtn,
    el.runBtn,
    el.loadWorkspacesBtn,
    el.refreshWorkspacesBtn,
  ]) {
    if (button) button.disabled = true;
  }
}

function setIdle(message = "Ready") {
  el.status.textContent = message;
  el.progress.classList.add("hidden");
  for (const button of [
    el.loadSubscriptionsBtn,
    el.loadApimBtn,
    el.resetSettingsBtn,
    el.runBtn,
    el.loadWorkspacesBtn,
    el.refreshWorkspacesBtn,
  ]) {
    if (button) button.disabled = false;
  }
}

function setWorkspaceProgress(active, message = "Loading workspace inventory...") {
  if (!el.workspaceProgress || !el.workspaceProgressText) return;
  el.workspaceProgressText.textContent = message;
  el.workspaceProgress.classList.toggle("hidden", !active);
}

function setBasicsProgress(active, message = "Loading context...") {
  if (!el.basicsProgress || !el.basicsProgressText) return;
  el.basicsProgressText.textContent = message;
  el.basicsProgress.classList.toggle("hidden", !active);
}

function setValidationStatus(state, message) {
  if (!el.validationStatus) return;

  el.validationStatus.classList.remove("idle", "running", "success", "failed");
  el.validationStatus.classList.add(state);
  el.validationStatus.textContent = `Validation: ${message}`;
}

function setValidationBanner(message, level = "warn") {
  if (!el.validationBanner) return;

  if (!message) {
    el.validationBanner.textContent = "";
    el.validationBanner.classList.add("hidden");
    el.validationBanner.classList.remove("warn", "ok");
    return;
  }

  el.validationBanner.textContent = message;
  el.validationBanner.classList.remove("hidden", "warn", "ok");
  el.validationBanner.classList.add(level === "ok" ? "ok" : "warn");
}

function extractValidationSummary(lines, expectedHint = "") {
  const source = Array.isArray(lines) ? lines.join("\n") : String(lines || "");
  if (!source) return null;

  const statusMatch = source.match(/"StatusCode"\s*:\s*(\d+)/i) || source.match(/got\s+'?(\d+)'?/i);
  const expectedMatch = source.match(/"ExpectedStatusCodes"\s*:\s*\[\s*([0-9,\s]+)/i);

  const statusCode = statusMatch ? statusMatch[1] : null;
  let expectedText = expectedHint || null;
  if (expectedMatch && expectedMatch[1]) {
    expectedText = expectedMatch[1].replace(/\s+/g, "").replace(/,+$/, "");
  }

  if (expectedText && statusCode) return `Expected ${expectedText}, got ${statusCode}`;
  if (statusCode) return `Validation returned status ${statusCode}`;
  return null;
}

function setActiveTab(tab) {
  const wizard = tab === "wizard";
  el.tabWizardBtn.classList.toggle("active", wizard);
  el.tabWorkspacesBtn.classList.toggle("active", !wizard);
  el.wizardView.classList.toggle("hidden", !wizard);
  el.workspacesView.classList.toggle("hidden", wizard);
}

async function copyTextToClipboard(text) {
  if (!text) return;
  try {
    await navigator.clipboard.writeText(text);
    appendOutput(`Copied: ${text}`);
  } catch {
    appendOutput("Copy failed: browser clipboard permission is unavailable.");
  }
}

function setUrlActions(urls) {
  const workspacePortal = urls?.WorkspacePortalUrl || "";
  const workspace = urls?.WorkspaceArmUrl || "";
  const gateway = urls?.GatewayUrl || "";
  const runtime = urls?.RuntimeUrl || urls?.GatewayUrl || "";

  el.workspacePortalUrlText.value = workspacePortal;
  el.workspaceUrlText.value = workspace;
  el.gatewayUrlText.value = gateway;
  el.runtimeUrlText.value = runtime;

  const hasAny = !!(workspacePortal || workspace || gateway || runtime);
  el.urlActions.classList.toggle("hidden", !hasAny);
  el.copyWorkspacePortalUrlBtn.disabled = !workspacePortal;
  el.copyWorkspaceUrlBtn.disabled = !workspace;
  el.copyGatewayUrlBtn.disabled = !gateway;
  el.copyRuntimeUrlBtn.disabled = !runtime;
}

function refreshContextSummary() {
  const sub = selectedSubscription();
  const apim = selectedApim();
  const workspace = (el.workspaceId?.value || "").trim();
  const mode = el.mode?.value || "create-default";

  if (el.ctxSubscription) el.ctxSubscription.textContent = sub?.id || "Not selected";
  if (el.ctxApim) el.ctxApim.textContent = apim?.name || "Not selected";
  if (el.ctxWorkspace) el.ctxWorkspace.textContent = workspace || "Not set";
  if (el.ctxMode) el.ctxMode.textContent = mode;
}

function updateModePanels() {
  const mode = el.mode.value;
  el.dedicatedPanel.classList.toggle("hidden", mode !== "create-dedicated");
  el.verifyPanel.classList.toggle("hidden", mode !== "verify");
  el.runtimePanel.classList.toggle("hidden", mode !== "verify-runtime");
  refreshContextSummary();
}

function setActiveStep(step) {
  state.currentStep = step;
  for (const [idx, node] of [el.stepBasics, el.stepGateway, el.stepReview].entries()) {
    node.classList.toggle("active", idx + 1 === step);
  }

  const panels = document.querySelectorAll("#wizardView .step-panel");
  panels.forEach((panel) => {
    const panelStep = Number(panel.dataset.step || "0");
    panel.classList.toggle("active", panelStep === step);
  });
}

function scrollToCard(card) {
  if (!card) return;
  card.scrollIntoView({ behavior: "smooth", block: "start" });
}

function updateSampleProfileUi() {
  const enabled = el.deploySampleApi.checked;
  const profile = el.sampleProfile.value;

  el.sampleProfile.disabled = !enabled;
  el.createSampleProduct.disabled = !enabled;
  el.sampleBackendUrl.disabled = !enabled;

  if (!enabled) {
    el.createSampleProduct.checked = false;
  }

  if (profile === "Echo API") {
    if (!el.sampleBackendUrl.value || el.sampleBackendUrl.value.includes("weather-api-cw001")) {
      el.sampleBackendUrl.value = "https://postman-echo.com";
    }
    el.profileBadge.textContent = "ECHO";
    el.profileBadge.style.background = "#0f766e";
    el.profileCard.style.background = "#dff6f3";
    el.profileHint.textContent = "Echo API forwards requests to postman-echo.com for request and response smoke tests.";
  } else {
    if (!el.sampleBackendUrl.value || el.sampleBackendUrl.value.includes("postman-echo.com")) {
      el.sampleBackendUrl.value = "https://weather-api-cw001.mangomeadow-171b7d7e.eastus2.azurecontainerapps.io";
    }
    el.profileBadge.textContent = "WEATHER";
    el.profileBadge.style.background = "#0078d4";
    el.profileCard.style.background = "#e8f3ff";
    el.profileHint.textContent = "Weather API uses the fake weather backend for quick APIM validation.";
  }

  if (!enabled) {
    el.profileCard.style.background = "#f2f5f9";
  }
}

function selectedSubscription() {
  const index = Number(el.subscriptionSelect.value);
  if (Number.isNaN(index) || index < 0 || index >= state.subscriptions.length) return null;
  return state.subscriptions[index];
}

function selectedApim() {
  const index = Number(el.apimSelect.value);
  if (Number.isNaN(index) || index < 0 || index >= state.apimServices.length) return null;
  return state.apimServices[index];
}

async function apiCall(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });

  let payload = null;
  const rawText = await response.text();
  if (rawText && rawText.trim()) {
    try {
      payload = JSON.parse(rawText);
    } catch {
      payload = {
        ok: false,
        error: `Unexpected response from ${path} (status ${response.status})`,
        raw: rawText.slice(0, 500),
      };
    }
  } else if (response.ok) {
    payload = { ok: true };
  } else {
    payload = { ok: false, error: `Request failed: ${response.status}` };
  }

  if (!response.ok || !payload.ok) {
    const err = new Error(payload.error || `Request failed: ${response.status}`);
    err.payload = payload;
    err.status = response.status;
    throw err;
  }

  return payload;
}

function appendApiErrorDetails(context, error) {
  if (!error) return;

  appendOutput(`ERROR [${context}]: ${error.message || "Request failed"}`);

  const payload = error.payload;
  if (!payload) return;

  if (payload.error) {
    appendOutput(`Server error: ${payload.error}`);
  }

  if (payload.requestContext) {
    appendOutput(
      `Request context: method=${payload.requestContext.method || "n/a"}, path=${payload.requestContext.path || "n/a"}`
    );
    if (payload.requestContext.workspaceId) {
      appendOutput(`Workspace context: ${payload.requestContext.workspaceId}`);
    }
  }

  if (payload.serverOutput?.length) {
    appendOutput("--- Server Output (error path) ---");
    payload.serverOutput.forEach(appendOutput);
  }

  if (payload.diagnose?.output?.length) {
    appendOutput("--- Diagnose Script Output (error path) ---");
    payload.diagnose.output.forEach(appendOutput);
  }

  if (payload.reportPath) {
    appendOutput(`Diagnosis report: ${payload.reportPath}`);
  }

  if (payload.raw) {
    appendOutput(`Raw response preview: ${payload.raw}`);
  }

  if (payload.exception) {
    appendOutput("--- Exception Detail ---");
    appendOutput(String(payload.exception));
  }
}

function appendRunSummary(payload) {
  appendOutput("--- Run Summary ---");
  appendOutput(`Mode: ${payload.mode}`);
  appendOutput(`WhatIfOnly: ${payload.whatIfOnly}`);
  appendOutput(`Subscription: ${payload.subscriptionId}`);
  appendOutput(`APIM: ${payload.apimName} (RG: ${payload.apimResourceGroup})`);
  appendOutput(`WorkspaceId: ${payload.workspaceId}`);

  if (payload.mode === "create-dedicated") {
    appendOutput(`NetworkResourceGroup: ${payload.networkResourceGroup}`);
    appendOutput(`Location: ${payload.location}`);
    appendOutput(`NetworkMode: ${payload.networkMode}`);
    appendOutput(`SkipWorkspaceCreate: ${payload.skipWorkspaceCreate}`);
  }

  if (payload.mode === "verify-runtime") {
    appendOutput(`ApiPath: ${payload.apiPath}`);
    appendOutput(`ProbePath: ${payload.probePath}`);
    appendOutput(`ExpectedStatusCodes: ${payload.expectedStatusCodes}`);
    appendOutput(`CollectDiagnostics: ${payload.collectDiagnostics}`);
    if (payload.gatewayUrl) appendOutput(`GatewayUrl override: ${payload.gatewayUrl}`);
    if (payload.diagnosticsOutputPath) appendOutput(`DiagnosticsOutputPath: ${payload.diagnosticsOutputPath}`);
  }

  appendOutput(`DeploySampleApi: ${payload.deploySampleApi}`);
  if (payload.deploySampleApi) {
    appendOutput(`SampleProfile: ${payload.sampleProfile}`);
    appendOutput(`CreateSampleProduct: ${payload.createSampleProduct}`);
    appendOutput(`SampleBackendUrl: ${payload.sampleBackendUrl}`);
  }

  appendOutput(`AutoVerifyRuntime: ${payload.autoVerifyRuntime}`);
  if (payload.autoVerifyRuntime) {
    appendOutput(`Auto ApiPath: ${payload.autoApiPath}`);
    appendOutput(`Auto ProbePath: ${payload.autoProbePath}`);
    appendOutput(`Auto ExpectedStatusCodes: ${payload.autoExpectedStatusCodes}`);
    appendOutput(`Auto RetryIntervalSeconds: ${payload.autoRetryIntervalSeconds}`);
    appendOutput(`Auto TimeoutSeconds: ${payload.autoTimeoutSeconds}`);
  }
}

function appendServerResult(result) {
  if (result?.serverOutput?.length) result.serverOutput.forEach(appendOutput);

  if (result?.workspace?.output?.length) {
    appendOutput("--- Workspace Script Output ---");
    result.workspace.output.forEach(appendOutput);
  }

  if (result?.autoVerify?.output?.length) {
    appendOutput("--- Auto Verify Runtime Output ---");
    result.autoVerify.output.forEach(appendOutput);
  }

  if (result?.sample?.output?.length) {
    appendOutput("--- Sample API Script Output ---");
    result.sample.output.forEach(appendOutput);
  }

  if (result?.urls) {
    appendOutput("--- Resolved URLs ---");
    if (result.urls.WorkspacePortalUrl) appendOutput(`Workspace Portal URL: ${result.urls.WorkspacePortalUrl}`);
    if (result.urls.WorkspaceArmUrl) appendOutput(`Workspace ARM URL: ${result.urls.WorkspaceArmUrl}`);
    if (result.urls.GatewayUrl) appendOutput(`Gateway URL: ${result.urls.GatewayUrl}`);
    if (result.urls.RuntimeUrl) appendOutput(`Runtime URL: ${result.urls.RuntimeUrl}`);
  }

  setUrlActions(result?.urls || null);
  if (typeof result?.durationSeconds === "number") appendOutput(`Duration: ${result.durationSeconds.toFixed(2)}s`);
}

async function loadSubscriptions(preferredId = null) {
  setBusy("Loading subscriptions...");
  setBasicsProgress(true, "Loading subscriptions...");
  try {
    const payload = await apiCall("/api/subscriptions");
    state.subscriptions = Array.isArray(payload.subscriptions) ? payload.subscriptions : [];
    el.subscriptionSelect.innerHTML = "";

    state.subscriptions.forEach((sub, idx) => {
      const option = document.createElement("option");
      option.value = String(idx);
      option.textContent = `${sub.name} [${sub.id}]${sub.isDefault ? " (default)" : ""}`;
      el.subscriptionSelect.appendChild(option);
    });

    if (state.subscriptions.length > 0) {
      let selectedIndex = state.subscriptions.findIndex((sub) => sub.id === preferredId);
      if (selectedIndex < 0) selectedIndex = state.subscriptions.findIndex((sub) => !!sub.isDefault);
      if (selectedIndex < 0) selectedIndex = 0;
      el.subscriptionSelect.value = String(selectedIndex);
    }

    appendOutput(`Loaded ${state.subscriptions.length} subscription(s).`);
    refreshContextSummary();
  } catch (error) {
    appendOutput(`ERROR: ${error.message}`);
    alert(error.message);
  } finally {
    setBasicsProgress(false);
    setIdle();
  }
}

async function loadApim(preferredName = null) {
  const sub = selectedSubscription();
  if (!sub) {
    alert("Select a subscription first.");
    return;
  }

  setBusy("Loading APIM instances...");
  setBasicsProgress(true, "Loading APIM instances...");
  try {
    const payload = await apiCall("/api/apim", {
      method: "POST",
      body: JSON.stringify({ subscriptionId: sub.id }),
    });

    state.apimServices = Array.isArray(payload.services) ? payload.services : [];
    el.apimSelect.innerHTML = "";

    state.apimServices.forEach((svc, idx) => {
      const option = document.createElement("option");
      option.value = String(idx);
      option.textContent = `${svc.name} (RG: ${svc.resourceGroup}, SKU: ${svc.sku?.name || "n/a"}, Location: ${svc.location})`;
      el.apimSelect.appendChild(option);
    });

    if (state.apimServices.length > 0) {
      let selectedIndex = state.apimServices.findIndex((svc) => svc.name === preferredName);
      if (selectedIndex < 0) selectedIndex = 0;
      el.apimSelect.value = String(selectedIndex);
    }

    appendOutput(`Loaded ${state.apimServices.length} APIM instance(s).`);
    refreshContextSummary();
  } catch (error) {
    appendOutput(`ERROR: ${error.message}`);
    alert(error.message);
  } finally {
    setBasicsProgress(false);
    setIdle();
  }
}

function renderWorkspaces() {
  const summary = {
    total: state.workspaces.length,
    yes: 0,
    no: 0,
    unknown: 0,
  };

  for (const ws of state.workspaces) {
    const assoc = (ws.defaultGatewayAssociated || "unknown").toLowerCase();
    if (assoc === "yes") summary.yes += 1;
    else if (assoc === "no") summary.no += 1;
    else summary.unknown += 1;
  }

  if (el.wsCountChip) el.wsCountChip.textContent = String(summary.total);
  if (el.wsAssocYesChip) el.wsAssocYesChip.textContent = String(summary.yes);
  if (el.wsAssocNoChip) el.wsAssocNoChip.textContent = String(summary.no);
  if (el.wsAssocUnknownChip) el.wsAssocUnknownChip.textContent = String(summary.unknown);

  if (!state.workspaces.length) {
    el.workspacesTbody.innerHTML = '<tr><td colspan="9" class="muted">No workspaces found.</td></tr>';
    return;
  }

  el.workspacesTbody.innerHTML = "";
  state.workspaces.forEach((ws) => {
    const tr = document.createElement("tr");

    const id = document.createElement("td");
    id.textContent = ws.id || ws.name || "";
    tr.appendChild(id);

    const dn = document.createElement("td");
    dn.textContent = ws.displayName || "";
    tr.appendChild(dn);

    const assoc = document.createElement("td");
    const assocValue = ws.defaultGatewayAssociated || "unknown";
    const assocPill = document.createElement("span");
    assocPill.textContent = assocValue;
    assocPill.className = "cell-pill " + (assocValue === "yes" ? "ok" : assocValue === "no" ? "warn" : "muted");
    assoc.appendChild(assocPill);
    if (ws.defaultGatewayAssociationSource || ws.associationCheckError) {
      const titleParts = [];
      if (ws.defaultGatewayAssociationSource) {
        titleParts.push(`Source: ${ws.defaultGatewayAssociationSource}`);
      }
      if (ws.associationCheckError) {
        titleParts.push(`Check: ${ws.associationCheckError}`);
      }
      assoc.title = titleParts.join(" | ");
    }
    tr.appendChild(assoc);

    const st = document.createElement("td");
    const stateValue = ws.state || "unknown";
    const statePill = document.createElement("span");
    statePill.textContent = stateValue;
    const stateClass = stateValue.toLowerCase() === "succeeded" ? "ok" : stateValue.toLowerCase() === "failed" ? "warn" : "muted";
    statePill.className = `cell-pill ${stateClass}`;
    st.appendChild(statePill);
    if (ws.stateSource) {
      st.title = `Source: ${ws.stateSource}`;
    }
    tr.appendChild(st);

    const stSource = document.createElement("td");
    stSource.textContent = ws.stateSource || "-";
    tr.appendChild(stSource);

    const gw = document.createElement("td");
    gw.textContent = ws.associatedGateways || "not-returned";
    tr.appendChild(gw);

    const apiCount = document.createElement("td");
    apiCount.textContent = ws.apiCount === null || ws.apiCount === undefined ? "-" : String(ws.apiCount);
    if (Array.isArray(ws.apiNames) && ws.apiNames.length > 0) {
      apiCount.title = ws.apiNames.join(", ");
    }
    tr.appendChild(apiCount);

    const urlCell = document.createElement("td");
    if (ws.portalUrl || ws.armUrl) {
      const link = document.createElement("a");
      link.href = ws.portalUrl || ws.armUrl;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.textContent = "Open Portal";
      urlCell.appendChild(link);
    } else {
      urlCell.textContent = "-";
    }
    tr.appendChild(urlCell);

    const action = document.createElement("td");
    const actionWrap = document.createElement("div");
    actionWrap.className = "workspace-actions";
    const primaryActions = document.createElement("div");
    primaryActions.className = "workspace-actions-primary";
    const advancedActions = document.createElement("div");
    advancedActions.className = "workspace-actions-advanced hidden";

    const verify = document.createElement("button");
    verify.className = "btn subtle";
    verify.textContent = "Check Runtime";
    verify.addEventListener("click", () => verifyWorkspaceRuntime(ws.id || ws.name));
    primaryActions.appendChild(verify);

    const assocBtn = document.createElement("button");
    assocBtn.className = "btn subtle";
    assocBtn.textContent = "Assoc Default GW";
    assocBtn.addEventListener("click", () => associateDefaultGateway(ws.id || ws.name));
    primaryActions.appendChild(assocBtn);

    const moreBtn = document.createElement("button");
    moreBtn.className = "btn subtle";
    moreBtn.type = "button";
    moreBtn.textContent = "More";
    moreBtn.addEventListener("click", () => {
      const isHidden = advancedActions.classList.contains("hidden");
      advancedActions.classList.toggle("hidden", !isHidden);
      moreBtn.textContent = isHidden ? "Less" : "More";
    });
    primaryActions.appendChild(moreBtn);

    const checkAssocBtn = document.createElement("button");
    checkAssocBtn.className = "btn subtle";
    checkAssocBtn.textContent = "Check Assoc";
    checkAssocBtn.addEventListener("click", () => checkWorkspaceAssociation(ws.id || ws.name));
    advancedActions.appendChild(checkAssocBtn);

    const diagBtn = document.createElement("button");
    diagBtn.className = "btn subtle";
    diagBtn.textContent = "Diagnose GW";
    diagBtn.addEventListener("click", () => diagnoseWorkspaceGateway(ws.id || ws.name, false));
    advancedActions.appendChild(diagBtn);

    const diagFixBtn = document.createElement("button");
    diagFixBtn.className = "btn subtle";
    diagFixBtn.textContent = "Diagnose+Fix GW";
    diagFixBtn.addEventListener("click", () => diagnoseWorkspaceGateway(ws.id || ws.name, true));
    advancedActions.appendChild(diagFixBtn);

    const del = document.createElement("button");
    del.className = "btn subtle";
    del.textContent = "Delete";
    del.addEventListener("click", () => deleteWorkspace(ws.id || ws.name));
    advancedActions.appendChild(del);

    actionWrap.appendChild(primaryActions);
    actionWrap.appendChild(advancedActions);
    action.appendChild(actionWrap);
    tr.appendChild(action);

    el.workspacesTbody.appendChild(tr);
  });
}

async function loadWorkspaces() {
  const sub = selectedSubscription();
  const apim = selectedApim();
  if (!sub || !apim) {
    alert("Select subscription and APIM in Basics first.");
    return;
  }

  setBusy("Loading workspaces...");
  setWorkspaceProgress(true, "Loading workspace inventory...");
  try {
    const payload = await apiCall("/api/workspaces/list", {
      method: "POST",
      body: JSON.stringify({
        subscriptionId: sub.id,
        apimName: apim.name,
        resourceGroupName: apim.resourceGroup,
      }),
    });
    state.workspaces = Array.isArray(payload.workspaces) ? payload.workspaces : [];
    renderWorkspaces();
    appendOutput(`Loaded ${state.workspaces.length} workspace(s).`);
  } catch (error) {
    appendOutput(`ERROR: ${error.message}`);
    alert(error.message);
  } finally {
    setWorkspaceProgress(false);
    setIdle();
  }
}

async function associateDefaultGateway(workspaceId) {
  if (!workspaceId) return;
  const sub = selectedSubscription();
  const apim = selectedApim();
  if (!sub || !apim) {
    alert("Select subscription and APIM in Basics first.");
    return;
  }

  if (!confirm(`Associate workspace '${workspaceId}' with default gateway now?`)) return;

  setBusy(`Associating default gateway for ${workspaceId}...`);
  setWorkspaceProgress(true, `Associating default gateway for '${workspaceId}'...`);
  appendOutput(`Default gateway association requested for '${workspaceId}'.`);
  setApiResult(null, null);

  try {
    const payload = await apiCall("/api/workspaces/associate-default", {
      method: "POST",
      body: JSON.stringify({
        subscriptionId: sub.id,
        resourceGroupName: apim.resourceGroup,
        apimName: apim.name,
        workspaceId,
      }),
    });

    if (payload?.serverOutput?.length) {
      payload.serverOutput.forEach(appendOutput);
    }

    setApiResult(`Last API Response: /api/workspaces/associate-default (${workspaceId})`, payload);

    if (payload?.association) {
      const assoc = payload.association;
      const associated = assoc.defaultGatewayAssociated ?? assoc.DefaultGatewayAssociated ?? "unknown";
      const source = assoc.defaultGatewayAssociationSource ?? assoc.DefaultGatewayAssociationSource ?? "not-returned-by-arm";
      const gatewaysText = assoc.workspaceGatewaysText ?? assoc.WorkspaceGatewaysText;
      const apiCount = assoc.apiCount ?? assoc.ApiCount;
      const assocError = assoc.error ?? assoc.Error;

      appendOutput(`Association snapshot: defaultGatewayAssociated=${associated}; source=${source}`);
      if (gatewaysText) {
        appendOutput(`Workspace gateways: ${gatewaysText}`);
      }
      if (apiCount !== null && apiCount !== undefined) {
        appendOutput(`Workspace API count: ${apiCount}`);
      }
      if (assocError) {
        appendOutput(`Association check note: ${assocError}`);
      }
    }

    await loadWorkspaces();
  } catch (error) {
    if (error?.payload) {
      setApiResult(`Last API Error: /api/workspaces/associate-default (${workspaceId})`, error.payload);
    }
    appendOutput(`ERROR: ${error.message}`);
    alert(error.message);
    setWorkspaceProgress(false);
    setIdle("Ready");
  }
}

async function checkWorkspaceAssociation(workspaceId) {
  if (!workspaceId) return;
  const sub = selectedSubscription();
  const apim = selectedApim();
  if (!sub || !apim) {
    alert("Select subscription and APIM in Basics first.");
    return;
  }

  setBusy(`Checking association for ${workspaceId}...`);
  setWorkspaceProgress(true, `Checking association for '${workspaceId}'...`);
  appendOutput(`Association check requested for '${workspaceId}'.`);
  setApiResult(null, null);

  try {
    const payload = await apiCall("/api/workspaces/check-association", {
      method: "POST",
      body: JSON.stringify({
        subscriptionId: sub.id,
        resourceGroupName: apim.resourceGroup,
        apimName: apim.name,
        workspaceId,
      }),
    });

    if (payload?.serverOutput?.length) {
      payload.serverOutput.forEach(appendOutput);
    }

    setApiResult(`Last API Response: /api/workspaces/check-association (${workspaceId})`, payload);

    if (payload?.association) {
      const assoc = payload.association;
      const associated = assoc.defaultGatewayAssociated ?? assoc.DefaultGatewayAssociated ?? "unknown";
      const source = assoc.defaultGatewayAssociationSource ?? assoc.DefaultGatewayAssociationSource ?? "not-returned-by-arm";
      appendOutput(`Association snapshot: defaultGatewayAssociated=${associated}; source=${source}`);
    }
  } catch (error) {
    if (error?.payload) {
      setApiResult(`Last API Error: /api/workspaces/check-association (${workspaceId})`, error.payload);
    }
    appendOutput(`ERROR: ${error.message}`);
    alert(error.message);
  } finally {
    setWorkspaceProgress(false);
    setIdle("Ready");
  }
}

async function diagnoseWorkspaceGateway(workspaceId, applyFix) {
  if (!workspaceId) return;
  const sub = selectedSubscription();
  const apim = selectedApim();
  if (!sub || !apim) {
    alert("Select subscription and APIM in Basics first.");
    return;
  }

  if (applyFix) {
    const proceed = confirm(`Run full diagnosis and apply explicit default-gateway association PUT for '${workspaceId}'?`);
    if (!proceed) return;
  }

  setBusy(`${applyFix ? "Diagnosing + fixing" : "Diagnosing"} gateway state for ${workspaceId}...`);
  setWorkspaceProgress(true, `${applyFix ? "Diagnosing + fixing" : "Diagnosing"} gateway state for '${workspaceId}'...`);
  appendOutput(`${applyFix ? "Gateway diagnosis + remediation" : "Gateway diagnosis"} requested for '${workspaceId}'.`);
  setApiResult(null, null);

  try {
    const payload = await apiCall("/api/workspaces/diagnose-gateway", {
      method: "POST",
      body: JSON.stringify({
        subscriptionId: sub.id,
        resourceGroupName: apim.resourceGroup,
        apimName: apim.name,
        workspaceId,
        gatewayUrl: (el.gatewayUrl?.value || "").trim(),
        apiPath: (el.apiPath?.value || "").trim(),
        probePath: (el.probePath?.value || "").trim(),
        fixDefaultGatewayAssociation: !!applyFix,
      }),
    });

    if (payload?.serverOutput?.length) {
      payload.serverOutput.forEach(appendOutput);
    }

    if (payload?.diagnose?.output?.length) {
      appendOutput("--- Diagnose Script Output ---");
      payload.diagnose.output.forEach(appendOutput);
    }

    if (payload?.reportPath) {
      appendOutput(`Diagnosis report: ${payload.reportPath}`);
    }

    if (payload?.report?.Summary && Array.isArray(payload.report.Summary)) {
      appendOutput("--- Diagnosis Summary ---");
      payload.report.Summary.forEach((line) => appendOutput(`- ${line}`));
    }

    if (payload?.report?.Association) {
      const assoc = payload.report.Association;
      appendOutput(
        `Association: defaultGatewayAssociated=${assoc.DefaultGatewayAssociated || "unknown"}; source=${assoc.Source || "not-returned-by-arm"}`
      );
      if (assoc.Inference) {
        appendOutput(`Association inference: ${assoc.Inference}`);
      }
      if (assoc.GatewayListCheck?.Skipped) {
        appendOutput(`Workspace gateway check skipped: ${assoc.GatewayListCheck.Reason || "unsupported on current SKU"}`);
      }
      if (Array.isArray(assoc.WorkspaceGateways) && assoc.WorkspaceGateways.length > 0) {
        appendOutput(`Workspace gateways: ${assoc.WorkspaceGateways.join(", ")}`);
      }
    }

    if (payload?.report?.ApiGatewayAssignments?.ApiListError) {
      appendOutput(`API list error: ${payload.report.ApiGatewayAssignments.ApiListError}`);
    }

    if (Array.isArray(payload?.report?.ApiGatewayAssignments?.PerApi)) {
      payload.report.ApiGatewayAssignments.PerApi.forEach((entry) => {
        if (!entry) return;
        if (entry.Skipped) {
          appendOutput(`API gateway assignment check skipped for ${entry.ApiName}: ${entry.Error || "unsupported on current SKU"}`);
          return;
        }
        if (entry.Succeeded) {
          const gateways = Array.isArray(entry.Gateways) && entry.Gateways.length > 0 ? entry.Gateways.join(", ") : "none returned";
          appendOutput(`API gateway assignment: ${entry.ApiName} -> ${gateways}`);
          return;
        }

        appendOutput(`API gateway assignment check failed for ${entry.ApiName}: ${entry.Error || "unknown error"}`);
      });
    }

    setApiResult(
      `Last API Response: /api/workspaces/diagnose-gateway (${workspaceId}${applyFix ? " + fix" : ""})`,
      payload
    );

    if (payload?.urls) {
      setUrlActions(payload.urls);
    }

    await loadWorkspaces();
  } catch (error) {
    if (error?.payload) {
      setApiResult(
        `Last API Error: /api/workspaces/diagnose-gateway (${workspaceId}${applyFix ? " + fix" : ""})`,
        error.payload
      );
    }
    appendApiErrorDetails("diagnose-gateway", error);
    alert(error.message);
    setWorkspaceProgress(false);
    setIdle("Ready");
  }
}

async function deleteWorkspace(workspaceId) {
  if (!workspaceId) return;
  const sub = selectedSubscription();
  const apim = selectedApim();
  if (!sub || !apim) {
    alert("Select subscription and APIM in Basics first.");
    return;
  }

  if (!confirm(`Delete workspace '${workspaceId}' from APIM?`)) return;

  setBusy(`Deleting workspace ${workspaceId}...`);
  setWorkspaceProgress(true, `Deleting workspace '${workspaceId}'...`);
  try {
    await apiCall("/api/workspaces/delete", {
      method: "POST",
      body: JSON.stringify({
        subscriptionId: sub.id,
        apimName: apim.name,
        resourceGroupName: apim.resourceGroup,
        workspaceId,
      }),
    });
    appendOutput(`Delete requested for workspace '${workspaceId}'.`);
    await loadWorkspaces();
  } catch (error) {
    appendOutput(`ERROR: ${error.message}`);
    alert(error.message);
    setWorkspaceProgress(false);
    setIdle("Ready");
  }
}

async function verifyWorkspaceRuntime(workspaceId) {
  if (!workspaceId) return;
  const sub = selectedSubscription();
  const apim = selectedApim();
  if (!sub || !apim) {
    alert("Select subscription and APIM in Basics first.");
    return;
  }

  const apiPath = (el.apiPath?.value || "weather").trim() || "weather";
  const probePath = (el.probePath?.value || "/weather/seattle").trim() || "/weather/seattle";
  const expectedStatusCodes = (el.expectedStatusCodes?.value || "200").trim() || "200";
  const gatewayUrl = (el.gatewayUrl?.value || "").trim();

  setActiveTab("wizard");
  setActiveStep(3);
  scrollToCard(el.runCard);

  setBusy(`Checking runtime for ${workspaceId}...`);
  setWorkspaceProgress(true, `Checking runtime for '${workspaceId}'...`);
  setValidationStatus("running", "Running");
  setValidationBanner(null);
  appendOutput("--- Validation Lifecycle ---");
  appendOutput("Validation status: Running");
  appendOutput(`Workspace runtime check started for '${workspaceId}'.`);

  try {
    const response = await fetch("/api/workspaces/verify-runtime", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        subscriptionId: sub.id,
        resourceGroupName: apim.resourceGroup,
        apimName: apim.name,
        workspaceId,
        apiPath,
        probePath,
        expectedStatusCodes,
        gatewayUrl,
      }),
    });

    let result = null;
    const rawText = await response.text();
    if (rawText && rawText.trim()) {
      try {
        result = JSON.parse(rawText);
      } catch {
        result = { ok: false, error: `Unexpected response from /api/workspaces/verify-runtime (status ${response.status})` };
      }
    } else {
      result = { ok: response.ok };
    }

    if (result?.serverOutput?.length) result.serverOutput.forEach(appendOutput);
    if (result?.verify?.output?.length) {
      appendOutput("--- Verify Runtime Output ---");
      result.verify.output.forEach(appendOutput);
    }
    if (result?.urls) {
      appendOutput("--- Resolved URLs ---");
      if (result.urls.WorkspacePortalUrl) appendOutput(`Workspace Portal URL: ${result.urls.WorkspacePortalUrl}`);
      if (result.urls.WorkspaceArmUrl) appendOutput(`Workspace ARM URL: ${result.urls.WorkspaceArmUrl}`);
      if (result.urls.GatewayUrl) appendOutput(`Gateway URL: ${result.urls.GatewayUrl}`);
      if (result.urls.RuntimeUrl) appendOutput(`Runtime URL: ${result.urls.RuntimeUrl}`);
      setUrlActions(result.urls);
    }
    if (typeof result?.durationSeconds === "number") {
      appendOutput(`Duration: ${result.durationSeconds.toFixed(2)}s`);
    }
    const passed = !!(result?.ok && result?.verify?.Success);
    if (passed) {
      appendOutput("Validation status: Passed");
      setValidationBanner("Validation passed.", "ok");
      setValidationStatus("success", "Passed");
      setIdle("Completed");
    } else {
      if (result?.error) appendOutput(`Validation error detail: ${result.error}`);
      appendOutput("Validation status: Failed");
      const summary = extractValidationSummary(result?.verify?.output, expectedStatusCodes);
      if (summary) {
        setValidationBanner(summary, "warn");
      } else if (result?.error) {
        setValidationBanner(result.error, "warn");
      } else {
        setValidationBanner("Validation failed.", "warn");
      }
      setValidationStatus("failed", "Failed");
      setIdle("Failed");
    }
  } catch (error) {
    appendOutput(`ERROR: ${error.message}`);
    appendOutput("Validation status: Failed");
    setValidationBanner(error.message || "Validation failed.", "warn");
    setValidationStatus("failed", "Failed");
    setIdle("Failed");
  } finally {
    setWorkspaceProgress(false);
  }
}

function gatherRunPayload() {
  const sub = selectedSubscription();
  const apim = selectedApim();
  if (!sub) throw new Error("Subscription is required.");
  if (!apim) throw new Error("API Management instance is required.");
  if (!el.workspaceId.value.trim()) throw new Error("Workspace ID is required.");

  return {
    subscriptionId: sub.id,
    apimName: apim.name,
    apimResourceGroup: apim.resourceGroup,
    mode: el.mode.value,
    workspaceId: el.workspaceId.value.trim(),
    displayName: el.displayName.value.trim(),
    description: el.description.value.trim(),
    networkResourceGroup: el.networkResourceGroup.value.trim(),
    location: el.location.value.trim(),
    networkMode: el.networkMode.value,
    skipWorkspaceCreate: el.skipWorkspaceCreate.checked,
    strictVerify: el.strictVerify.checked,
    apiPath: el.apiPath.value.trim(),
    probePath: el.probePath.value.trim(),
    expectedStatusCodes: el.expectedStatusCodes.value.trim(),
    gatewayUrl: el.gatewayUrl.value.trim(),
    collectDiagnostics: el.collectDiagnostics.checked,
    diagnosticsOutputPath: el.diagnosticsOutputPath.value.trim(),
    whatIfOnly: el.whatIfOnly.checked,
    deploySampleApi: el.deploySampleApi.checked,
    sampleProfile: el.sampleProfile.value,
    createSampleProduct: el.createSampleProduct.checked,
    sampleBackendUrl: el.sampleBackendUrl.value.trim(),
    autoVerifyRuntime: el.autoVerifyRuntime.checked,
    autoApiPath: el.autoApiPath.value.trim(),
    autoProbePath: el.autoProbePath.value.trim(),
    autoExpectedStatusCodes: el.autoExpectedStatusCodes.value.trim(),
    autoRetryIntervalSeconds: Number(el.autoRetryIntervalSeconds.value || 20),
    autoTimeoutSeconds: Number(el.autoTimeoutSeconds.value || 900),
  };
}

async function runAction() {
  let payload;
  try {
    payload = gatherRunPayload();
  } catch (error) {
    alert(error.message);
    return;
  }

  setActiveStep(3);
  setBusy("Running workspace action...");
  setValidationStatus("running", "Running");
  setValidationBanner(null);
  appendOutput("--- Validation Lifecycle ---");
  appendOutput("Validation status: Running");
  appendOutput("Starting workspace action and verification sequence...");
  setUrlActions(null);
  appendRunSummary(payload);

  const startedAt = Date.now();
  const pulse = setInterval(() => {
    const elapsed = Math.floor((Date.now() - startedAt) / 1000);
    appendOutput(`...running (${elapsed}s elapsed)`);
  }, 5000);

  try {
    const result = await apiCall("/api/run", {
      method: "POST",
      body: JSON.stringify(payload),
    });
    clearInterval(pulse);
    appendServerResult(result);
    if (payload.mode === "create-default" || payload.mode === "create-dedicated") {
      appendOutput("Note: Workspace creation is control-plane success. 'Associated gateways' may remain empty unless a workspace gateway is explicitly associated or default gateway routing is configured for imported APIs.");
    }
    appendOutput("Completed successfully.");
    appendOutput("Validation status: Passed");
    setValidationBanner("Validation passed.", "ok");
    setValidationStatus("success", "Passed");
    setIdle("Completed");
  } catch (error) {
    clearInterval(pulse);
    if (error.payload) appendServerResult(error.payload);
    appendOutput(`ERROR: ${error.message}`);
    appendOutput("Validation status: Failed");
    const summary = extractValidationSummary(
      error?.payload?.verify?.output || error?.payload?.autoVerify?.output,
      payload?.expectedStatusCodes || payload?.autoExpectedStatusCodes || ""
    );
    if (summary) {
      setValidationBanner(summary, "warn");
    } else {
      setValidationBanner(error.message || "Validation failed.", "warn");
    }
    setValidationStatus("failed", "Failed");
    setIdle("Failed");
    alert(error.message);
  }
}

function applySettings(settings) {
  if (!settings) return;

  const setValue = (node, value) => {
    if (!node || value === undefined || value === null) return;
    node.value = String(value);
  };

  setValue(el.mode, settings.Mode);
  setValue(el.workspaceId, settings.WorkspaceId);
  setValue(el.displayName, settings.DisplayName);
  setValue(el.description, settings.Description);
  setValue(el.networkResourceGroup, settings.NetworkResourceGroup);
  setValue(el.location, settings.Location);
  setValue(el.networkMode, settings.NetworkMode || "integration");
  setValue(el.apiPath, settings.ApiPath || "weather");
  setValue(el.probePath, settings.ProbePath || "/weather/seattle");
  setValue(el.expectedStatusCodes, settings.ExpectedStatusCodes || "200");
  setValue(el.gatewayUrl, settings.GatewayUrl);
  setValue(el.diagnosticsOutputPath, settings.DiagnosticsOutputPath);
  setValue(el.sampleProfile, settings.SampleProfile || "Weather API");
  setValue(el.sampleBackendUrl, settings.SampleBackendUrl || "https://weather-api-cw001.mangomeadow-171b7d7e.eastus2.azurecontainerapps.io");

  setValue(el.autoApiPath, settings.AutoApiPath || "weather");
  setValue(el.autoProbePath, settings.AutoProbePath || "/weather/seattle");
  setValue(el.autoExpectedStatusCodes, settings.AutoExpectedStatusCodes || "200");
  setValue(el.autoRetryIntervalSeconds, settings.AutoRetryIntervalSeconds || 20);
  setValue(el.autoTimeoutSeconds, settings.AutoTimeoutSeconds || 900);

  el.skipWorkspaceCreate.checked = !!settings.SkipWorkspaceCreate;
  el.strictVerify.checked = !!settings.StrictVerify;
  el.collectDiagnostics.checked = settings.CollectDiagnostics !== false;
  el.whatIfOnly.checked = !!settings.WhatIfOnly;
  el.deploySampleApi.checked = !!settings.DeploySampleApi;
  el.createSampleProduct.checked = !!settings.CreateSampleProduct;
  el.autoVerifyRuntime.checked = !!settings.AutoVerifyRuntime;

  updateModePanels();
  updateSampleProfileUi();
  refreshContextSummary();
}

async function initialize() {
  try {
    await apiCall("/api/health");
    const settingsPayload = await apiCall("/api/settings");
    const settings = settingsPayload.settings;
    applySettings(settings);

    await loadSubscriptions(settings?.SubscriptionId || null);
    if (state.subscriptions.length > 0) {
      await loadApim(settings?.ApimName || null);
    }
  } catch (error) {
    appendOutput(`ERROR: ${error.message}`);
    alert(error.message);
  }
}

el.mode.addEventListener("change", updateModePanels);
el.workspaceId.addEventListener("input", refreshContextSummary);
el.subscriptionSelect.addEventListener("change", refreshContextSummary);
el.apimSelect.addEventListener("change", refreshContextSummary);
el.sampleProfile.addEventListener("change", updateSampleProfileUi);
el.deploySampleApi.addEventListener("change", updateSampleProfileUi);

el.loadSubscriptionsBtn.addEventListener("click", () => loadSubscriptions());
el.loadApimBtn.addEventListener("click", () => loadApim());
el.clearOutputBtn.addEventListener("click", () => {
  el.output.textContent = "";
  setValidationBanner(null);
  setApiResult(null, null);
});

el.copyApiResultBtn.addEventListener("click", () => copyTextToClipboard(el.apiResultJson.textContent));

el.resetSettingsBtn.addEventListener("click", async () => {
  if (!confirm("Delete saved web wizard settings?")) return;
  setBusy("Resetting saved settings...");
  try {
    await apiCall("/api/reset-settings", { method: "POST" });
    appendOutput("Saved settings reset.");
    location.reload();
  } catch (error) {
    appendOutput(`ERROR: ${error.message}`);
    alert(error.message);
    setIdle("Ready");
  }
});

el.runBtn.addEventListener("click", runAction);
el.copyWorkspacePortalUrlBtn.addEventListener("click", () => copyTextToClipboard(el.workspacePortalUrlText.value));
el.copyWorkspaceUrlBtn.addEventListener("click", () => copyTextToClipboard(el.workspaceUrlText.value));
el.copyGatewayUrlBtn.addEventListener("click", () => copyTextToClipboard(el.gatewayUrlText.value));
el.copyRuntimeUrlBtn.addEventListener("click", () => copyTextToClipboard(el.runtimeUrlText.value));

el.tabWizardBtn.addEventListener("click", () => setActiveTab("wizard"));
el.tabWorkspacesBtn.addEventListener("click", () => setActiveTab("workspaces"));
el.loadWorkspacesBtn.addEventListener("click", loadWorkspaces);
el.refreshWorkspacesBtn.addEventListener("click", loadWorkspaces);

el.stepBasics.addEventListener("click", () => {
  setActiveStep(1);
  scrollToCard(el.basicsCard);
});

el.stepGateway.addEventListener("click", () => {
  setActiveStep(2);
  scrollToCard(el.gatewayCard);
});

el.stepReview.addEventListener("click", () => {
  setActiveStep(3);
  scrollToCard(el.runCard);
});

el.toGatewayBtn?.addEventListener("click", () => {
  setActiveStep(2);
  scrollToCard(el.gatewayCard);
});

el.backToBasicsBtn?.addEventListener("click", () => {
  setActiveStep(1);
  scrollToCard(el.basicsCard);
});

el.toReviewBtn?.addEventListener("click", () => {
  setActiveStep(3);
  scrollToCard(el.runCard);
});

el.backToGatewayBtn?.addEventListener("click", () => {
  setActiveStep(2);
  scrollToCard(el.gatewayCard);
});

updateModePanels();
updateSampleProfileUi();
setActiveTab("wizard");
setActiveStep(1);
setValidationStatus("idle", "Not started");
setUrlActions(null);
refreshContextSummary();
initialize();

setApiResult(null, null);
