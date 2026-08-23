// @ts-nocheck

import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import test from "node:test";

class FakeClassList {
  #values = new Set<string>();

  replaceFrom(value: string) {
    this.#values = new Set(value.split(/\s+/u).filter(Boolean));
  }

  contains(value: string) {
    return this.#values.has(value);
  }

  toggle(value: string, force?: boolean) {
    const enabled = force ?? !this.#values.has(value);
    if (enabled) {
      this.#values.add(value);
    } else {
      this.#values.delete(value);
    }
    return enabled;
  }

  toString() {
    return [...this.#values].join(" ");
  }
}

class FakeElement {
  readonly children: FakeElement[] = [];
  readonly classList = new FakeClassList();
  readonly dataset: Record<string, string> = {};
  readonly attributes = new Map<string, string>();
  readonly listeners = new Map<string, Array<(event: unknown) => unknown>>();
  disabled = false;
  hidden = false;
  id = "";
  offsetTop = 0;
  parentElement: FakeElement | null = null;
  scrollTop = 0;
  textContent = "";
  readonly tagName: string;
  type = "";
  value = "";

  constructor(tagName: string) {
    this.tagName = tagName;
  }

  get className() {
    return this.classList.toString();
  }

  set className(value: string) {
    this.classList.replaceFrom(value);
  }

  append(...elements: FakeElement[]) {
    for (const element of elements) {
      element.parentElement = this;
      this.children.push(element);
    }
  }

  appendChild(element: FakeElement) {
    this.append(element);
    return element;
  }

  addEventListener(type: string, listener: (event: unknown) => unknown) {
    const listeners = this.listeners.get(type) ?? [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  click() {
    this.dispatch("click");
  }

  dispatch(type: string) {
    for (const listener of this.listeners.get("click") ?? []) {
      if (type === "click") {
        listener({ currentTarget: this, target: this });
      }
    }
    if (type !== "click") {
      for (const listener of this.listeners.get(type) ?? []) {
        listener({ currentTarget: this, target: this });
      }
    }
  }

  setAttribute(name: string, value: string) {
    this.attributes.set(name, value);
    if (name === "id") {
      this.id = value;
    } else if (name === "class") {
      this.className = value;
    } else if (name === "lang") {
      this.attributes.set("lang", value);
    } else if (name.startsWith("data-")) {
      const key = name
        .slice(5)
        .replace(/-([a-z])/gu, (_match, letter: string) => letter.toUpperCase());
      this.dataset[key] = value;
    }
  }

  getAttribute(name: string) {
    return this.attributes.get(name) ?? null;
  }

  querySelectorAll(selector: string): FakeElement[] {
    const matches: FakeElement[] = [];
    const visit = (element: FakeElement) => {
      for (const child of element.children) {
        if (child.matches(selector)) {
          matches.push(child);
        }
        visit(child);
      }
    };
    visit(this);
    return matches;
  }

  querySelector(selector: string) {
    return this.querySelectorAll(selector)[0] ?? null;
  }

  matches(selector: string) {
    if (selector.startsWith("#")) {
      return this.id === selector.slice(1);
    }
    if (selector.startsWith(".")) {
      return this.classList.contains(selector.slice(1));
    }
    const dataPresence = selector.match(/^\[data-([a-z0-9-]+)\]$/u);
    if (dataPresence) {
      const key = dataPresence[1].replace(/-([a-z])/gu, (_match, letter: string) => letter.toUpperCase());
      return key in this.dataset;
    }
    return this.tagName.toLowerCase() === selector.toLowerCase();
  }

  scrollTo(options: { top?: number }) {
    this.scrollTop = options.top ?? 0;
  }
}

class FakeDocument {
  readonly documentElement = new FakeElement("html");

  createElement(tagName: string) {
    return new FakeElement(tagName);
  }

  getElementById(id: string) {
    if (this.documentElement.id === id) {
      return this.documentElement;
    }
    return this.documentElement.querySelector(`#${id}`);
  }

  querySelectorAll(selector: string) {
    const own = this.documentElement.matches(selector) ? [this.documentElement] : [];
    return own.concat(this.documentElement.querySelectorAll(selector));
  }
}

const document = new FakeDocument();
const body = document.createElement("body");
const settingsNav = document.createElement("nav");
const settingsContent = document.createElement("div");
settingsNav.id = "settings-nav";
settingsContent.id = "settings-content";
document.documentElement.setAttribute("lang", "en");
document.documentElement.append(body);
body.append(settingsNav, settingsContent);

Object.assign(globalThis, {
  document,
  HTMLElement: FakeElement,
  Node: FakeElement,
});

const invokeCalls: Array<{ command: string; payload: unknown }> = [];
let nextInvokeResponse = { ok: true, action: "inspect", hostState: "not_found" };
globalThis.__sshConnectReviewTestInvoke = async (command: string, payload: unknown) => {
  invokeCalls.push({ command, payload });
  return nextInvokeResponse;
};

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "@tauri-apps/api/core") {
      return { url: "ssh-connect-review-test:tauri", shortCircuit: true };
    }
    if (specifier.endsWith(".css")) {
      return { url: new URL(specifier, context.parentURL).href, shortCircuit: true };
    }
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url === "ssh-connect-review-test:tauri") {
      return {
        format: "module",
        source: "export const invoke = (command, payload) => globalThis.__sshConnectReviewTestInvoke(command, payload);",
        shortCircuit: true,
      };
    }
    if (url.endsWith(".css")) {
      return { format: "module", source: "", shortCircuit: true };
    }
    return nextLoad(url, context);
  },
});

const {
  SSH_CONNECT_REVIEW_SECTION_ID,
  mountSshConnectReview,
} = await import("./sshConnectReview.ts");

test("mount shows all five review headings before any invoke", () => {
  mountSshConnectReview();

  const section = document.getElementById(SSH_CONNECT_REVIEW_SECTION_ID);
  assert.ok(section);
  const headings = section
    .querySelectorAll("[data-ssh-connect-review-heading]")
    .map((heading) => heading.textContent);

  assert.deepEqual(headings, ["Host", "Identity", "Runtime", "Scope", "Review"]);
  assert.equal(invokeCalls.length, 0);
});

test("mount is idempotent and exposes no one-button Connect shortcut", () => {
  mountSshConnectReview();

  const navItems = document
    .querySelectorAll(".settings-nav-item")
    .filter((item) => item.dataset.settingsTarget === SSH_CONNECT_REVIEW_SECTION_ID);
  const sections = document
    .querySelectorAll(".settings-section")
    .filter((item) => item.id === SSH_CONNECT_REVIEW_SECTION_ID);
  assert.equal(sections.length, 1);
  const buttonLabels = sections[0]
    .querySelectorAll("button")
    .map((button) => button.textContent.trim());

  assert.equal(navItems.length, 1);
  assert.equal(buttonLabels.some((label) => /^(connect|接続)$/iu.test(label)), false);
  assert.equal(buttonLabels.some((label) => /check.*register/iu.test(label)), true);
  assert.equal(invokeCalls.length, 0);
});

test("settings navigation exports the review id as user scope", async () => {
  const navigation = await import("./settingsNavigation.ts");

  assert.equal(navigation.SSH_CONNECT_REVIEW_SECTION_ID, SSH_CONNECT_REVIEW_SECTION_ID);
  assert.equal(navigation.getSettingsSectionScope(SSH_CONNECT_REVIEW_SECTION_ID), "user");
});

test("a later inspect cannot retain a fingerprint from another alias", async () => {
  const aliasInput = document.getElementById("ssh-connect-review-alias");
  const inspectButton = document.getElementById("ssh-connect-review-inspect");
  const confirmedValue = document.getElementById("ssh-connect-review-confirmed-value");
  assert.ok(aliasInput && inspectButton && confirmedValue);
  aliasInput.value = "first-alias";
  nextInvokeResponse = {
    ok: true,
    action: "inspect",
    hostState: "registered",
    confirmedFingerprint: "SHA256:firstalias",
  };
  inspectButton.click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(confirmedValue.textContent, "SHA256:firstalias");

  aliasInput.value = "second-alias";
  nextInvokeResponse = { ok: true, action: "inspect", hostState: "not_found" };
  inspectButton.click();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(confirmedValue.textContent, "Unavailable until a confirmed check returns it");
});

test("editing the alias immediately invalidates the prior identity", async () => {
  const aliasInput = document.getElementById("ssh-connect-review-alias");
  const inspectButton = document.getElementById("ssh-connect-review-inspect");
  const confirmedValue = document.getElementById("ssh-connect-review-confirmed-value");
  assert.ok(aliasInput && inspectButton && confirmedValue);
  aliasInput.value = "registered-alias";
  nextInvokeResponse = {
    ok: true,
    action: "inspect",
    hostState: "registered",
    confirmedFingerprint: "SHA256:registeredalias",
  };
  inspectButton.click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(confirmedValue.textContent, "SHA256:registeredalias");

  aliasInput.value = "different-alias";
  aliasInput.dispatch("input");

  assert.equal(confirmedValue.textContent, "Unavailable until a confirmed check returns it");
});

test("scope proposals never enter the backend request", async () => {
  const aliasInput = document.getElementById("ssh-connect-review-alias");
  const workspaceInput = document.getElementById("ssh-connect-review-workspace");
  const permissionSelect = document.getElementById("ssh-connect-review-permission");
  const confirmButton = document.getElementById("ssh-connect-review-confirm");
  assert.ok(aliasInput && workspaceInput && permissionSelect && confirmButton);
  aliasInput.value = "registered-alias";
  workspaceInput.value = "private-workspace-proposal";
  permissionSelect.value = "read_write";
  nextInvokeResponse = {
    ok: true,
    action: "confirm",
    hostState: "registered",
    confirmedFingerprint: "sha256:" + "a".repeat(64),
  };

  confirmButton.click();
  await new Promise((resolve) => setImmediate(resolve));

  const call = invokeCalls.at(-1);
  assert.equal(call.command, "ssh_connect_review");
  assert.deepEqual(Object.keys(call.payload.request).sort(), ["action", "alias", "requestId"]);
  assert.equal(JSON.stringify(call.payload).includes("private-workspace-proposal"), false);
  assert.equal(JSON.stringify(call.payload).includes("read_write"), false);
});

test("review previews use the current alias and match the confirmation request", async () => {
  const aliasInput = document.getElementById("ssh-connect-review-alias");
  const checkPreview = document.getElementById("ssh-connect-review-check-preview");
  const registerPreview = document.getElementById("ssh-connect-review-register-preview");
  const confirmButton = document.getElementById("ssh-connect-review-confirm");
  assert.ok(aliasInput && checkPreview && registerPreview && confirmButton);

  aliasInput.value = "";
  aliasInput.dispatch("input");
  assert.equal(checkPreview.textContent, "Enter a configured OpenSSH alias.");
  assert.equal(registerPreview.textContent, "Enter a configured OpenSSH alias.");

  aliasInput.value = "prod-bastion";
  aliasInput.dispatch("input");
  assert.equal(checkPreview.textContent, '["host-profile", "check", "prod-bastion", "--json"]');
  assert.equal(
    registerPreview.textContent,
    '["host-profile", "register", "prod-bastion", "--json"] — only if check returns pending',
  );

  nextInvokeResponse = {
    ok: true,
    action: "confirm",
    hostState: "registered",
    confirmedFingerprint: "sha256:" + "c".repeat(64),
  };
  const callsBefore = invokeCalls.length;
  confirmButton.click();
  await new Promise((resolve) => setImmediate(resolve));

  const call = invokeCalls[callsBefore];
  assert.equal(call.payload.request.alias, "prod-bastion");
});

test("confirm stays locked and ignores another click while its request is in flight", async () => {
  const aliasInput = document.getElementById("ssh-connect-review-alias");
  const confirmButton = document.getElementById("ssh-connect-review-confirm");
  assert.ok(aliasInput && confirmButton);
  aliasInput.value = "prod-bastion";
  aliasInput.dispatch("input");

  let resolveConfirm: (value: unknown) => void = () => {};
  nextInvokeResponse = new Promise((resolve) => {
    resolveConfirm = resolve;
  });
  const callsBefore = invokeCalls.length;
  confirmButton.click();

  assert.equal(confirmButton.disabled, true);
  confirmButton.click();
  assert.equal(invokeCalls.length, callsBefore + 1);

  resolveConfirm({
    ok: true,
    action: "confirm",
    hostState: "registered",
    confirmedFingerprint: "sha256:" + "d".repeat(64),
  });
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(confirmButton.disabled, false);
});

test("confirm locks Retry and preserves its audit from a late failed Retry", async () => {
  const aliasInput = document.getElementById("ssh-connect-review-alias");
  const inspectButton = document.getElementById("ssh-connect-review-inspect");
  const confirmButton = document.getElementById("ssh-connect-review-confirm");
  const retryButton = document.getElementById("ssh-connect-review-retry");
  const reviewStatus = document.getElementById("ssh-connect-review-review-status");
  const confirmedValue = document.getElementById("ssh-connect-review-confirmed-value");
  const presentedValue = document.getElementById("ssh-connect-review-presented-value");
  assert.ok(
    aliasInput && inspectButton && confirmButton && retryButton && reviewStatus && confirmedValue && presentedValue,
  );
  aliasInput.value = "prod-bastion";
  aliasInput.dispatch("input");

  let rejectRetry: (reason?: unknown) => void = () => {};
  nextInvokeResponse = new Promise((_resolve, reject) => {
    rejectRetry = reject;
  });
  const callsBefore = invokeCalls.length;
  retryButton.click();
  assert.equal(invokeCalls.length, callsBefore + 1);

  let resolveConfirm: (value: unknown) => void = () => {};
  nextInvokeResponse = new Promise((resolve) => {
    resolveConfirm = resolve;
  });
  confirmButton.click();
  assert.equal(confirmButton.disabled, true);
  assert.equal(inspectButton.disabled, true);
  assert.equal(retryButton.disabled, true);
  assert.equal(invokeCalls.length, callsBefore + 2);

  retryButton.click();
  assert.equal(invokeCalls.length, callsBefore + 2);

  resolveConfirm({
    ok: true,
    action: "confirm",
    hostState: "registered",
    confirmedFingerprint: "sha256:" + "e".repeat(64),
    presentedFingerprint: "sha256:" + "f".repeat(64),
  });
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(reviewStatus.textContent, "Review confirmation completed using the displayed argv sequence.");
  assert.equal(confirmedValue.textContent, "sha256:" + "e".repeat(64));
  assert.equal(presentedValue.textContent, "sha256:" + "f".repeat(64));
  assert.equal(inspectButton.disabled, false);
  assert.equal(retryButton.disabled, false);

  rejectRetry(new Error("late retry failure"));
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(reviewStatus.textContent, "Review confirmation completed using the displayed argv sequence.");
  assert.equal(confirmedValue.textContent, "sha256:" + "e".repeat(64));
  assert.equal(presentedValue.textContent, "sha256:" + "f".repeat(64));
});

test("safe stop tombstones its request while a later runtime uses a new request", async () => {
  const aliasInput = document.getElementById("ssh-connect-review-alias");
  const inspectButton = document.getElementById("ssh-connect-review-inspect");
  const safeStopButton = document.getElementById("ssh-connect-review-safe-stop");
  const runtimeButton = document.getElementById("ssh-connect-review-runtime");
  assert.ok(aliasInput && inspectButton && safeStopButton && runtimeButton);
  aliasInput.value = "prod-bastion";
  aliasInput.dispatch("input");

  nextInvokeResponse = { ok: true, action: "inspect", hostState: "registered" };
  inspectButton.click();
  await new Promise((resolve) => setImmediate(resolve));

  nextInvokeResponse = { ok: true, action: "stop", runtimeState: "stopped" };
  const callsBeforeStop = invokeCalls.length;
  safeStopButton.click();
  await new Promise((resolve) => setImmediate(resolve));
  const stopRequest = invokeCalls[callsBeforeStop].payload.request;

  nextInvokeResponse = {
    ok: true,
    action: "runtime",
    hostState: "registered",
    runtimeState: "handshake_confirmed",
  };
  runtimeButton.click();
  await new Promise((resolve) => setImmediate(resolve));
  const runtimeRequest = invokeCalls.at(-1).payload.request;

  assert.equal(stopRequest.action, "stop");
  assert.equal(runtimeRequest.action, "runtime");
  assert.notEqual(runtimeRequest.requestId, stopRequest.requestId);
});
