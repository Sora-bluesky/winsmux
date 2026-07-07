import assert from "node:assert/strict";
import {
  getSettingsPreferenceDescription,
  getSettingsPreferenceLabel,
  renderSettingsPreferenceOptions,
} from "../src/settingsPreferenceOptions.ts";
import {
  filterSettingsSections,
  getSettingsSectionScope,
  getSettingsTabScope,
  shouldDisableSettingsNavItem,
} from "../src/settingsNavigation.ts";

class FakeElement {
  constructor(tagName, ownerDocument) {
    this.tagName = tagName;
    this.ownerDocument = ownerDocument;
    this.children = [];
    this.attributes = new Map();
    this.listeners = new Map();
    this.className = "";
    this.textContent = "";
    this.type = "";
  }

  set innerHTML(_value) {
    this.children = [];
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  getAttribute(name) {
    return this.attributes.get(name) ?? null;
  }

  replaceChildren(...children) {
    this.children = children;
  }

  appendChild(child) {
    this.children.push(child);
  }

  addEventListener(type, listener) {
    this.listeners.set(type, listener);
  }

  click() {
    this.listeners.get("click")?.();
  }
}

class FakeDocument {
  createElement(tagName) {
    return new FakeElement(tagName, this);
  }
}

const options = [
  {
    value: "system",
    label: "System",
    labelJa: "システム",
    description: "Follow the operating system appearance.",
    descriptionJa: "OS の外観設定に合わせます。",
  },
  {
    value: "light",
    label: "Light",
    description: "Use a bright workspace.",
  },
];

assert.equal(getSettingsPreferenceLabel(options[0], true), "システム");
assert.equal(getSettingsPreferenceLabel(options[1], true), "Light", "Japanese labels should fall back to the English label");
assert.equal(getSettingsPreferenceDescription(options[0], true), "OS の外観設定に合わせます。");
assert.equal(
  getSettingsPreferenceDescription(options[1], true),
  "Use a bright workspace.",
  "Japanese descriptions should fall back to the English description",
);

const fakeDocument = new FakeDocument();
const root = fakeDocument.createElement("div");
const selectedValues = [];

const rendered = renderSettingsPreferenceOptions(root, options, "system", true, (value) => {
  selectedValues.push(value);
});

assert.equal(rendered, true);
assert.equal(root.children.length, 2, "all preference options should render");
assert.equal(root.children[0].className, "settings-option-chip is-active");
assert.equal(root.children[0].getAttribute("aria-pressed"), "true");
assert.equal(root.children[0].children[0].textContent, "システム");
assert.equal(root.children[0].children[1].textContent, "OS の外観設定に合わせます。");
assert.equal(root.children[1].className, "settings-option-chip ");
assert.equal(root.children[1].getAttribute("aria-pressed"), "false");
assert.equal(root.children[1].children[0].textContent, "Light");
root.children[1].click();
assert.deepEqual(selectedValues, ["light"], "clicking an option should report its value");

assert.equal(
  renderSettingsPreferenceOptions(null, options, "system", false, () => {}),
  false,
  "missing roots should be treated as a no-op",
);

assert.equal(getSettingsSectionScope("settings-section-workspace"), "workspace");
assert.equal(getSettingsSectionScope("settings-section-common"), "user");
assert.equal(getSettingsTabScope("settings-tab-workspace"), "workspace");
assert.equal(getSettingsTabScope("settings-tab-user"), "user");

const filtered = filterSettingsSections(
  [
    { id: "settings-section-common", text: "Theme Density" },
    { id: "settings-section-workspace", text: "Project directory" },
    { id: "settings-section-runtime", text: "Provider model" },
  ],
  "user",
  "model",
);

assert.equal(filtered.firstVisibleId, "settings-section-runtime");
assert.deepEqual(
  filtered.items.map((item) => [item.id, item.scope, item.visible]),
  [
    ["settings-section-common", "user", false],
    ["settings-section-workspace", "workspace", false],
    ["settings-section-runtime", "user", true],
  ],
);
assert.equal(shouldDisableSettingsNavItem("user", "user", "model", true), true);
assert.equal(shouldDisableSettingsNavItem("workspace", "user", "model", true), false);
assert.equal(shouldDisableSettingsNavItem("user", "user", "", true), false);

console.log("settings-preference-options-check passed");
