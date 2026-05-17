# Hook Plugin Loader

Repository-local hook plugins live in this directory as `*.js` files. The loader runs from `.claude/hooks/sh-plugin-loader.js` and discovers only direct JavaScript files under this directory.

## Plugin Contract

Each plugin exports either a function or an object with a `run(input, context)` function.

```js
"use strict";

module.exports = {
  name: "example-policy",
  events: ["PreToolUse"],
  order: 100,
  failClosed: true,
  run(input, context) {
    return {
      additionalContext: `${context.pluginName} inspected ${context.eventName}`,
    };
  },
};
```

## Execution Rules

- Discovery is limited to direct `.js` files in `.claude/hooks/plugins`.
- Symlinks and files resolved outside the plugin directory are ignored.
- Plugins run by ascending `order`, then `name`, then file name.
- `events` accepts hook event names or `*`; missing `events` means `*`.
- `enabled: false` keeps a plugin installed but skipped.
- `failClosed` defaults to `true`; set it to `false` only for advisory plugins.

## Failure And Logging

- Plugin load failures are treated as blocking failures.
- Runtime failures block when `failClosed` is true and are recorded as evidence.
- Runtime failures continue when `failClosed` is false and are recorded as evidence.
- Plugin `console.log`, `console.warn`, and `console.error` output is captured and written to the evidence ledger instead of hook stdout or stderr.
- PreToolUse denials are emitted as structured `permissionDecision: "deny"` replies.
