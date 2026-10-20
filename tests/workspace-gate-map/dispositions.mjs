// Disposition data for build-map.mjs. Every weakening finding between the bases and the candidate is matched
// here by its tree-level identity (type, path, metric and base count, or test name) and given one disposition:
//   guarded      the candidate's own file carries the protection; selectors are verified at the candidate and at
//                least one pins an assertion line or a whole test body digest ({path, it|fn} anchors)
//   preserved    only an internal record was affected; its original bytes are pinned (pins) and the justification
//                is the preservation basis document pinned by sha256 below; not counted as protection
//   retired      the responsibility ended; basis lines at the candidate plus the assertion that now guards the
//                remainder (selectors), or an unguarded_reason
//   reclassified the finding is not a weakening; basis lines at the candidate
// deltas attribute a count change to commits for the reader; check-map verifies only their total per finding.
export const RULE = "Every gate at the candidate is listed with its Q-IDs, every CI entrypoint and every check it reaches is listed, and every deletion, count decrease, skip increase, missing test name and workflow change between each base tree and the candidate tree is guarded by a selector into the candidate's own files (an assertion line or a test body digest, never a title alone), preserved as original bytes outside the public tree (recorded as preservation, not as protection), retired with an in-tree basis and the assertion that guards the remainder, or reclassified with an in-tree basis. Mixed findings are split into components whose deltas must add up to the finding; the commits named in deltas are explanatory.";
export const DISPOSITIONS = {
  "guarded": "(a) the candidate's own file or entrypoint carries the protection; selectors are verified at the candidate and at least one is an assertion line or a body digest",
  "preserved": "(b) only an internal record was affected; its original bytes are pinned in git history and kept in the local preservation root whose basis document is pinned by sha256; not counted as protection",
  "retired": "(c) the responsibility ended; basis lines at the candidate and the assertion that guards the remainder are recorded, or an unguarded_reason when nothing guards it",
  "reclassified": "the finding is not a weakening; basis lines at the candidate are recorded"
};
export const BASES = {
  "rebuild_base": "9245269dcd3fc9973ca69abf55e6ef865d94d2ab",
  "prior_task882_inventory_baseline": "9158bf274ab7f0b141e7c6337b3acec1b08196fc",
  "pre_rebuild_plan_base": "d66fb785ff910e732a0581499c5bd2647ac82136"
};
export const LOCAL_RUNNERS = [
  { path: 'tests/workspace-update/run.ps1', invoked_by: 'local evidence runner outside the public tree; named in the preservation basis document' },
];
export const PRESERVATION_BASIS = { vault_path: 'preservation-basis.md', bytes: 2466, sha256: '384e1e0a5bba6052ef45b943298d9c1b20a4ec1d760a002a894a4685cfac8831' };
export const PINS = [
  {
    "path": "docs/project/THREAT_MODEL.md",
    "commit": "36a319d97d54030300623af6baa2f79e3d1434e6",
    "blob": "d06022166d64b2b857d5c60d16a59f05fc580ac7",
    "bytes": 8554,
    "sha256": "07ec05ce02cbcc3af1bf286d5d053c40b0a4d435b924057c853501870b1eb2e2",
    "vault_path": "preserved/docs/project/THREAT_MODEL.md"
  },
  {
    "path": "docs/project/THREAT_MODEL_AUDIT.md",
    "commit": "36a319d97d54030300623af6baa2f79e3d1434e6",
    "blob": "ea1187a3b5dda99e208a99f84c31a6127d1e5549",
    "bytes": 7756,
    "sha256": "c7f931e6213fed0941bbafd7651fc553b46dbe77cd78196dec85df9efb6ad0d1",
    "vault_path": "preserved/docs/project/THREAT_MODEL_AUDIT.md"
  },
  {
    "path": "docs/project/README.md",
    "commit": "36a319d97d54030300623af6baa2f79e3d1434e6",
    "blob": "b783aa72989d753e01a8c293f8500c8bb10c4948",
    "bytes": 1089,
    "sha256": "c97ba8fc774231c8a4e87f9b81a24d76efa8118e59765243e6db139f7f11f687",
    "vault_path": "preserved/docs/project/README.md"
  },
  {
    "path": "docs/project/review-latency-hardening.md",
    "commit": "36a319d97d54030300623af6baa2f79e3d1434e6",
    "blob": "2c145b544fab1ca74d5c68af51a9c17c191ed254",
    "bytes": 4217,
    "sha256": "c3640d3ed37c033648f34985c5d4701b504ed74666439c4620801640c366b8b7",
    "vault_path": "preserved/docs/project/review-latency-hardening.md"
  },
  {
    "path": "docs/project/DETAILED_DESIGN.md",
    "commit": "36a319d97d54030300623af6baa2f79e3d1434e6",
    "blob": "38e81df27bcdecba459332658493020069d3a37b",
    "bytes": 7803,
    "sha256": "8ef2f664220803f1d2e7e64e441c0a9aaa2a88f4827e51d8ba2c130ad2b8e1ae",
    "vault_path": "preserved/docs/project/DETAILED_DESIGN.md"
  },
  {
    "path": "docs/project/enterprise-strategy-roadmap-alignment.md",
    "commit": "36a319d97d54030300623af6baa2f79e3d1434e6",
    "blob": "e31e3076dc7ad5f26d422aae5f94f6a961a77710",
    "bytes": 3487,
    "sha256": "ec99a0df5b26c1d241c963cdf05c25b5ca767d69ac5f71094bb97256bc27b9ce",
    "vault_path": "preserved/docs/project/enterprise-strategy-roadmap-alignment.md"
  },
  {
    "path": "docs/project/design-freeze-gate.md",
    "commit": "36a319d97d54030300623af6baa2f79e3d1434e6",
    "blob": "6c081442b81a0d7d7b205103a08c40defffb453c",
    "bytes": 10683,
    "sha256": "46a28440f66188becd88d163bcfb94a9350d5207342ae00791d5036454c3f71b",
    "vault_path": "preserved/docs/project/design-freeze-gate.md"
  },
  {
    "path": "docs/project/v1-release-gate.md",
    "commit": "36a319d97d54030300623af6baa2f79e3d1434e6",
    "blob": "a79d6dfc27c77878798c0698edc6ef7f0e805d02",
    "bytes": 6835,
    "sha256": "c299f1593c68f86aec76abd7a35d2d3ae668bb7bfb81aa1c0decd77563809648",
    "vault_path": "preserved/docs/project/v1-release-gate.md"
  }
];
export const WORKFLOW_ROWS = {
  ".github/workflows/release-desktop.yml": {
    "disposition": "reclassified",
    "reason": "For v0.38.0 only, the build waits for the signed baseline and the direct release upload and public smoke are held back so publication goes through the integrated publication gate; other tags keep the old path. The stable Rust step became the pinned toolchain action.",
    "basis": [
      {
        "path": ".github/workflows/release-desktop.yml",
        "contains": "if: always() && (needs.signed_baseline.result == 'success' || (github.ref_name != 'v0.38.0' && inputs.release_tag != 'v0.38.0'))"
      },
      {
        "path": ".github/workflows/release-desktop.yml",
        "contains": "- name: Execute same-signed-byte finite NSIS and MSI journeys"
      },
      {
        "path": ".github/workflows/release-desktop.yml",
        "contains": "uses: ./.github/actions/setup-windows-distribution-toolchain"
      },
      {
        "path": ".github/workflows/release-core.yml",
        "contains": "- name: Require integrated publication gate"
      }
    ]
  },
  ".github/workflows/release-npm.yml": {
    "disposition": "reclassified",
    "reason": "For 0.38.0 only, npm publish is held back; the verify job prepares and verifies the integrated tarball for the integrated publication path. Other versions keep the old publish condition.",
    "basis": [
      {
        "path": ".github/workflows/release-npm.yml",
        "contains": "needs.verify.outputs.publish_ready == 'true' && needs.verify.outputs.version != '0.38.0' && needs.verify.outputs.release_tag != 'v0.38.0'"
      },
      {
        "path": ".github/workflows/release-npm.yml",
        "contains": "- name: Prepare and verify integrated npm tarball"
      }
    ]
  },
  ".github/workflows/test.yml": {
    "disposition": "guarded",
    "reason": "Renamed or moved, none dropped: the fresh install route now runs against the private candidate, the no-bundle build and V03630 process gate moved to desktop-release-process (required by Merge Gate), and desktop-nsis-lifecycle was replaced by the signed NSIS/MSI journeys and the native lifecycle job (74d66674). The gate-map job runs tests/workspace-gate-map/run.ps1 with the full history on push and pull_request and is required by Merge Gate.",
    "selectors": [
      {
        "path": ".github/workflows/test.yml",
        "contains": "- name: Run fresh install route against the private candidate"
      },
      {
        "path": ".github/workflows/test.yml",
        "contains": "  desktop-release-process:"
      },
      {
        "path": ".github/workflows/test.yml",
        "contains": "- name: Run V03630 desktop debug process gate"
      },
      {
        "path": ".github/workflows/test.yml",
        "contains": "      - desktop-release-process"
      },
      {
        "path": ".github/workflows/release-desktop.yml",
        "contains": "- name: Execute same-signed-byte finite NSIS and MSI journeys"
      },
      {
        "path": ".github/workflows/test.yml",
        "contains": "uses: ./.github/actions/setup-windows-distribution-toolchain"
      },
      {
        "path": ".github/workflows/test.yml",
        "contains": "  gate-map:"
      },
      {
        "path": ".github/workflows/test.yml",
        "contains": "run: pwsh -NoProfile -File tests/workspace-gate-map/run.ps1"
      },
      {
        "path": ".github/workflows/test.yml",
        "contains": "      - gate-map"
      }
    ]
  },
  ".github/workflows/build-desktop.yml": {
    "disposition": "guarded",
    "reason": "Steps renamed or moved, none dropped: the stable Rust step became the pinned distribution toolchain action, the sidecar stage became the licensed companion generation stage, and the Tauri backend test and the older-CLI preparation moved to test.yml desktop-build-test.",
    "selectors": [
      {
        "path": ".github/workflows/build-desktop.yml",
        "contains": "uses: ./.github/actions/setup-windows-distribution-toolchain"
      },
      {
        "path": ".github/workflows/build-desktop.yml",
        "contains": "- name: Stage complete licensed companion generation"
      },
      {
        "path": ".github/workflows/test.yml",
        "contains": "- name: Test Tauri backend"
      },
      {
        "path": ".github/workflows/test.yml",
        "contains": "run: cargo test --manifest-path winsmux-app/src-tauri/Cargo.toml"
      },
      {
        "path": ".github/workflows/test.yml",
        "contains": "- name: Prepare pinned older CLI for native version-pair proof"
      }
    ]
  },
  ".github/workflows/desktop-candidate-cdp-gate.yml": {
    "disposition": "guarded",
    "reason": "The gate became reusable (workflow_call, still dispatchable) and split into the CDP job and the desktop-native-lifecycle job selected by inputs.native_lifecycle; the Rust step became the pinned toolchain action.",
    "selectors": [
      {
        "path": ".github/workflows/desktop-candidate-cdp-gate.yml",
        "contains": "  workflow_call:"
      },
      {
        "path": ".github/workflows/desktop-candidate-cdp-gate.yml",
        "contains": "  workflow_dispatch:"
      },
      {
        "path": ".github/workflows/desktop-candidate-cdp-gate.yml",
        "contains": "  desktop-native-lifecycle:"
      },
      {
        "path": ".github/workflows/desktop-baseline-capture.yml",
        "contains": "uses: ./.github/workflows/desktop-candidate-cdp-gate.yml"
      }
    ]
  },
  ".github/workflows/public-smoke-recovery.yml": {
    "disposition": "reclassified",
    "reason": "Only the dispatch input defaults moved from v0.36.38 to v0.38.0; the inputs stay required and the job is unchanged in shape.",
    "basis": [
      {
        "path": ".github/workflows/public-smoke-recovery.yml",
        "contains": "default: v0.38.0"
      }
    ]
  },
  ".github/workflows/release-core.yml": {
    "disposition": "guarded",
    "reason": "The two helper steps merged into one package-and-test step, the stable Rust steps became the pinned toolchain action or rust 1.96.0, and the release job now requires the integrated publication gate.",
    "selectors": [
      {
        "path": ".github/workflows/release-core.yml",
        "contains": "- name: Package and test supported remote helper"
      },
      {
        "path": ".github/workflows/release-core.yml",
        "contains": "uses: ./.github/actions/setup-windows-distribution-toolchain"
      },
      {
        "path": ".github/workflows/release-core.yml",
        "contains": "- name: Require integrated publication gate"
      }
    ]
  }
};
// CliBakeoff.Tests.ps1 pester_should, shared by the two bases that count it (482 and 476 before).
const CB_COMPONENTS = [
  {
    "disposition": "guarded",
    "reason": "7c105672 dropped the four README desktop-first order assertions with the `## Main Commands` heading; 1e6c9793 restores them against `## CLI and MCP` / `## CLI・MCPで使う` and asserts both headings so the split cannot degrade to the whole file.",
    "selectors": [
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$readmeBeforeCommands = ($readme -split '(?m)^## CLI and MCP')[0]"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$readmeBeforeCommands | Should -Not -Match 'winsmux init'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$readmeBeforeCommands | Should -Not -Match 'winsmux launch'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$readmeJaBeforeCommands | Should -Not -Match 'winsmux init'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$readmeJaBeforeCommands | Should -Not -Match 'winsmux launch'"
      },
      {
        "path": "README.md",
        "contains": "## CLI and MCP"
      },
      {
        "path": "README.ja.md",
        "contains": "## CLI・MCPで使う"
      }
    ],
    "deltas": [
      {
        "commit": "7c105672d8bf5e78c208ca68edb0cefae19791a7",
        "delta": -4
      },
      {
        "commit": "1e6c9793",
        "delta": 6
      }
    ]
  },
  {
    "disposition": "guarded",
    "reason": "7c105672 dropped the two quickstart Not-Match assertions when the v0.38.0 quickstart began naming the older commands once in its CLI section. aa226344 restores them against the desktop steps only (the text before `## If you want the CLI path` / `## CLI で使いたい場合`), asserts both headings so the split cannot degrade to the whole file, and keeps the positive assertion that the desktop path needs no CLI initialization.",
    "selectors": [
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$quickstartDesktopSteps = ($quickstart -split '(?m)^## If you want the CLI path')[0]"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$quickstartJaDesktopSteps = ($quickstartJa -split '(?m)^## CLI で使いたい場合')[0]"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$quickstart | Should -Match '(?m)^## If you want the CLI path'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$quickstartDesktopSteps | Should -Not -Match 'npm install -g winsmux|winsmux init|winsmux launch|Create project settings'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$quickstartJa | Should -Match '(?m)^## CLI で使いたい場合'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$quickstartJaDesktopSteps | Should -Not -Match 'npm install -g winsmux|winsmux init|winsmux launch|プロジェクト設定を作る'"
      },
      {
        "path": "docs/quickstart.md",
        "contains": "## If you want the CLI path"
      },
      {
        "path": "docs/quickstart.ja.md",
        "contains": "## CLI で使いたい場合"
      }
    ],
    "deltas": [
      {
        "commit": "7c105672d8bf5e78c208ca68edb0cefae19791a7",
        "delta": -2
      },
      {
        "commit": "aa2263443a63f9aa404ebae74eff11a97c31cc11",
        "delta": 4
      }
    ]
  },
  {
    "disposition": "guarded",
    "reason": "7c105672 retired seven `releases/latest` link assertions with the README rewrite that tells the reader to choose the release matching the version they install. aa226344 turns the six rewritten documents into Not-Match assertions on `releases/latest` (a return to the latest link fails) and restores the positive link assertion for the npm package README, which still names it.",
    "selectors": [
      {
        "path": "README.md",
        "contains": "Choose the release for the version you intend to use from [Releases](https://github.com/Sora-bluesky/winsmux/releases)."
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$readme | Should -Not -Match 'releases/latest'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$readmeJa | Should -Not -Match 'releases/latest'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$quickstart | Should -Not -Match 'releases/latest'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$quickstartJa | Should -Not -Match 'releases/latest'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$installation | Should -Not -Match 'releases/latest'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$installationJa | Should -Not -Match 'releases/latest'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$packageReadme | Should -Match 'https://github\\.com/Sora-bluesky/winsmux/releases/latest'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$readme | Should -Match 'winsmux/releases'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$readmeJa | Should -Match 'winsmux/releases'"
      }
    ],
    "deltas": [
      {
        "commit": "7c105672d8bf5e78c208ca68edb0cefae19791a7",
        "delta": -5
      },
      {
        "commit": "aa2263443a63f9aa404ebae74eff11a97c31cc11",
        "delta": 7
      }
    ]
  },
  {
    "disposition": "guarded",
    "reason": "5d14e361 rewrote the installation and README text; 23 assertions on the old wording were replaced by 20 on the current wording (install steps, workspace closure before replacement, data preservation).",
    "selectors": [
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$installation | Should -Match 'Windows installer for your architecture'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$installationJa | Should -Match 'CPUに対応するWindowsインストーラー'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$readme | Should -Match 'Start with the desktop app'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$readmeJa | Should -Match 'デスクトップアプリから始める'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$installation | Should -Match 'Save work and normally close the workspace before replacing the app'"
      }
    ],
    "deltas": [
      {
        "commit": "7c105672d8bf5e78c208ca68edb0cefae19791a7",
        "delta": -3
      }
    ]
  },
  {
    "disposition": "retired",
    "reason": "The v0.36.23 benchmark routing It read docs/cli-comparison-bakeoff.md and the v0.36.17 bench report; c34d6d9b removed the version-routing paragraphs and the report as development records. The contract that remains public is that official evidence comes from visible desktop worker panes. aa226344 asserts that public rule from the v0.36.22 case, so weakening the document fails a Should.",
    "basis": [
      {
        "path": "docs/cli-comparison-bakeoff.md",
        "contains": "Official scoreable evidence must come from visible desktop worker panes with"
      },
      {
        "path": "docs/cli-comparison-bakeoff.md",
        "contains": "App-external batch results remain"
      }
    ],
    "selectors": [
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$contractDoc | Should -Match 'Official scoreable evidence must come from visible desktop worker panes'"
      },
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "contains": "$contractDoc | Should -Match 'App-external batch results remain'"
      }
    ],
    "retired_by": [
      "c34d6d9bfa1508718a30384460254fe525c744de"
    ],
    "deltas": [
      {
        "commit": "c34d6d9bfa1508718a30384460254fe525c744de",
        "delta": -4
      },
      {
        "commit": "aa2263443a63f9aa404ebae74eff11a97c31cc11",
        "delta": 2
      }
    ]
  },
  {
    "disposition": "guarded",
    "reason": "d3c059cb keeps the negative half of the retired It: the bakeoff contract must not route formal benchmark evidence to v0.36.22.",
    "selectors": [
      {
        "path": "tests/CliBakeoff.Tests.ps1",
        "it": "keeps the bakeoff contract from routing formal benchmark evidence to v0.36.22"
      }
    ],
    "deltas": [
      {
        "commit": "d3c059cb39c3b692bf17fcbf600d7930b5eecb5d",
        "delta": 1
      }
    ]
  },
  {
    "disposition": "preserved",
    "reason": "38 assertions read docs/project/v1-release-gate.md, which c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
    "basis": [
      {
        "path": "docs/repo-surface-policy.md",
        "contains": "- development history, internal plans, research screenshots, and original archives"
      },
      {
        "path": "docs/repo-surface-policy.md",
        "contains": "- development records must not be bundled as product documentation"
      },
      {
        "path": "docs/repo-surface-policy.md",
        "contains": "- never tracked"
      }
    ],
    "pins": [
      "docs/project/v1-release-gate.md"
    ],
    "deltas": [
      {
        "commit": "c34d6d9bfa1508718a30384460254fe525c744de",
        "delta": -38
      }
    ]
  }
];
const CB_READINESS_MOVED = {
  "disposition": "guarded",
  "reason": "3a49ac92 moved the bakeoff desktop readiness cases from the retired operator surface to the workspace surface and added six assertions.",
  "selectors": [
    {
      "path": "tests/CliBakeoff.Tests.ps1",
      "it": "refuses to rebuild while a repo or external desktop is running"
    },
    {
      "path": "tests/CliBakeoff.Tests.ps1",
      "it": "reads WebView workspace results without direct dynamic property assumptions"
    },
    {
      "path": "tests/CliBakeoff.Tests.ps1",
      "it": "requests normal closure only for the exact owned desktop when launch readiness fails"
    },
    {
      "path": "tests/CliBakeoff.Tests.ps1",
      "it": "requires the mounted main workspace before desktop launch readiness passes"
    },
    {
      "path": "tests/CliBakeoff.Tests.ps1",
      "it": "requires canonical read-only workspace API responses before launch readiness passes"
    }
  ],
  "deltas": [
    {
      "commit": "3a49ac92",
      "delta": 6
    }
  ]
};
export const ROWS = [
  {
    "match": {
      "type": "skip-increase",
      "path": "core/tests-rs/workspace_host_e2e.rs",
      "metric": "rust_ignore"
    },
    "body": {
      "disposition": "reclassified",
      "reason": "No existing test became ignored. bed23869 added a new ignored observation test; the three previously ignored tests are unchanged.",
      "basis": [
        {
          "path": "core/tests-rs/workspace_host_e2e.rs",
          "contains": "#[ignore = \"private one-call capability token observation\"]"
        },
        {
          "path": "core/tests-rs/workspace_host_e2e.rs",
          "contains": "fn server_capability_token_creation_snapshot()"
        }
      ]
    }
  },
  {
    "match": {
      "type": "metric-decrease",
      "path": "tests/CliBakeoff.Tests.ps1",
      "metric": "pester_should",
      "old": 482
    },
    "body": {
      "components": CB_COMPONENTS
    }
  },
  {
    "match": {
      "type": "metric-decrease",
      "path": "tests/EnterpriseStrategyAlignment.Tests.ps1",
      "metric": "pester_it",
      "old": 3
    },
    "body": {
      "disposition": "preserved",
      "reason": "Two Its read docs/project/enterprise-strategy-roadmap-alignment.md, which c34d6d9b removed from the public tree; the public-docs exclusion It stays. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        },
        {
          "path": "tests/EnterpriseStrategyAlignment.Tests.ps1",
          "it": "does not leak internal strategy positioning into public product docs"
        }
      ],
      "pins": [
        "docs/project/enterprise-strategy-roadmap-alignment.md",
        "docs/project/README.md"
      ]
    }
  },
  {
    "match": {
      "type": "metric-decrease",
      "path": "tests/EnterpriseStrategyAlignment.Tests.ps1",
      "metric": "pester_should",
      "old": 12
    },
    "body": {
      "disposition": "preserved",
      "reason": "All 10 assertions belong to the two Its that read the removed alignment note. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/enterprise-strategy-roadmap-alignment.md",
        "docs/project/README.md"
      ]
    }
  },
  {
    "match": {
      "type": "metric-decrease",
      "path": "tests/PublicSurfacePolicy.Tests.ps1",
      "metric": "pester_should",
      "old": 251
    },
    "body": {
      "components": [
        {
          "disposition": "guarded",
          "reason": "7c105672 moved the README authentication table to docs/authentication-support.md; the four table assertions became link and wording checks.",
          "selectors": [
            {
              "path": "tests/PublicSurfacePolicy.Tests.ps1",
              "contains": "$readme | Should -Match 'docs/authentication-support\\.md'"
            },
            {
              "path": "tests/PublicSurfacePolicy.Tests.ps1",
              "contains": "$authSupport = Get-Content (Join-Path $repoRoot 'docs/authentication-support.md') -Raw"
            }
          ],
          "deltas": [
            {
              "commit": "7c105672d8bf5e78c208ca68edb0cefae19791a7",
              "delta": -4
            }
          ]
        },
        {
          "disposition": "preserved",
          "reason": "The design-freeze It read docs/project/design-freeze-gate.md, which c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
          "basis": [
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- development history, internal plans, research screenshots, and original archives"
            },
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- development records must not be bundled as product documentation"
            },
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- never tracked"
            }
          ],
          "pins": [
            "docs/project/design-freeze-gate.md"
          ],
          "deltas": [
            {
              "commit": "c34d6d9bfa1508718a30384460254fe525c744de",
              "delta": -9
            }
          ]
        },
        {
          "disposition": "guarded",
          "reason": "e13999d0 added the native lifecycle boundary case.",
          "selectors": [
            {
              "path": "tests/PublicSurfacePolicy.Tests.ps1",
              "it": "keeps native lifecycle candidate identity and evidence publication within the declared boundary"
            }
          ],
          "deltas": [
            {
              "commit": "e13999d065788a85cde0a9ad857e600124d3b282",
              "delta": 5
            }
          ]
        },
        {
          "disposition": "guarded",
          "reason": "d3c059cb added the case that keeps the design-freeze record out of the tracked public surface.",
          "selectors": [
            {
              "path": "tests/PublicSurfacePolicy.Tests.ps1",
              "it": "keeps the v0.36.24 design-freeze gate record out of the tracked public surface"
            }
          ],
          "deltas": [
            {
              "commit": "d3c059cb39c3b692bf17fcbf600d7930b5eecb5d",
              "delta": 5
            }
          ]
        }
      ]
    }
  },
  {
    "match": {
      "type": "metric-decrease",
      "path": "tests/ReviewLatencyHardening.Tests.ps1",
      "metric": "pester_it",
      "old": 5
    },
    "body": {
      "disposition": "preserved",
      "reason": "Four Its read docs/project/review-latency-hardening.md and its links, which c34d6d9b removed from the public tree; the public-docs exclusion It stays. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        },
        {
          "path": "tests/ReviewLatencyHardening.Tests.ps1",
          "it": "keeps review latency details out of public product docs"
        }
      ],
      "pins": [
        "docs/project/review-latency-hardening.md",
        "docs/project/README.md",
        "docs/project/DETAILED_DESIGN.md"
      ]
    }
  },
  {
    "match": {
      "type": "metric-decrease",
      "path": "tests/ReviewLatencyHardening.Tests.ps1",
      "metric": "pester_should",
      "old": 22
    },
    "body": {
      "disposition": "preserved",
      "reason": "All 20 assertions belong to the four Its that read the removed review-latency record. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/review-latency-hardening.md",
        "docs/project/README.md",
        "docs/project/DETAILED_DESIGN.md"
      ]
    }
  },
  {
    "match": {
      "type": "metric-decrease",
      "path": "tests/ThreatModelContract.Tests.ps1",
      "metric": "pester_it",
      "old": 9
    },
    "body": {
      "components": [
        {
          "disposition": "preserved",
          "reason": "Five Its read THREAT_MODEL.md, THREAT_MODEL_AUDIT.md and docs/project/README.md, which c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
          "basis": [
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- development history, internal plans, research screenshots, and original archives"
            },
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- development records must not be bundled as product documentation"
            },
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- never tracked"
            }
          ],
          "pins": [
            "docs/project/THREAT_MODEL.md",
            "docs/project/THREAT_MODEL_AUDIT.md",
            "docs/project/README.md"
          ],
          "deltas": [
            {
              "commit": "c34d6d9bfa1508718a30384460254fe525c744de",
              "delta": -5
            }
          ]
        },
        {
          "disposition": "guarded",
          "reason": "The category-mapping It and the TM-005 wording It are guarded by d3c059cb's cases that run the real injection guard: every committed category loads and fires, a lone medium encoding token warns, the high combo is denied.",
          "selectors": [
            {
              "path": "tests/ThreatModelContract.Tests.ps1",
              "it": "loads every committed injection category into the guard and fires each pattern on a positive sample"
            },
            {
              "path": "tests/ThreatModelContract.Tests.ps1",
              "it": "warns on a lone medium encoding token and denies the high encoding co-occurrence"
            }
          ],
          "deltas": [
            {
              "commit": "c34d6d9bfa1508718a30384460254fe525c744de",
              "delta": -2
            },
            {
              "commit": "d3c059cb39c3b692bf17fcbf600d7930b5eecb5d",
              "delta": 2
            }
          ]
        }
      ]
    }
  },
  {
    "match": {
      "type": "metric-decrease",
      "path": "tests/ThreatModelContract.Tests.ps1",
      "metric": "pester_should",
      "old": 37
    },
    "body": {
      "components": [
        {
          "disposition": "preserved",
          "reason": "16 assertions belong to the five Its that read the removed threat model records. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
          "basis": [
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- development history, internal plans, research screenshots, and original archives"
            },
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- development records must not be bundled as product documentation"
            },
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- never tracked"
            }
          ],
          "pins": [
            "docs/project/THREAT_MODEL.md",
            "docs/project/THREAT_MODEL_AUDIT.md",
            "docs/project/README.md"
          ],
          "deltas": [
            {
              "commit": "c34d6d9bfa1508718a30384460254fe525c744de",
              "delta": -16
            }
          ]
        },
        {
          "disposition": "guarded",
          "reason": "6 assertions (category mapping, TM-005 wording) are guarded by d3c059cb's 12 assertions on the real guard output.",
          "selectors": [
            {
              "path": "tests/ThreatModelContract.Tests.ps1",
              "it": "loads every committed injection category into the guard and fires each pattern on a positive sample"
            },
            {
              "path": "tests/ThreatModelContract.Tests.ps1",
              "it": "warns on a lone medium encoding token and denies the high encoding co-occurrence"
            }
          ],
          "deltas": [
            {
              "commit": "c34d6d9bfa1508718a30384460254fe525c744de",
              "delta": -6
            },
            {
              "commit": "d3c059cb39c3b692bf17fcbf600d7930b5eecb5d",
              "delta": 12
            }
          ]
        }
      ]
    }
  },
  {
    "match": {
      "type": "metric-decrease",
      "path": "winsmux-app/src-tauri/src/desktop_companion_cli.rs",
      "metric": "rust_assert",
      "old": 36
    },
    "body": {
      "disposition": "guarded",
      "reason": "5d14e361 retired the PowerShell bridge for companion children; the 2 tests that pinned WINSMUX_CORE_SCRIPT were replaced by a test that the variable is removed even when the script is present.",
      "selectors": [
        {
          "path": "winsmux-app/src-tauri/src/desktop_companion_cli.rs",
          "fn": "companion_ledger_command_removes_bridge_even_when_script_is_present"
        },
        {
          "path": "winsmux-app/src-tauri/src/desktop_companion_cli.rs",
          "contains": "command.env_remove(WINSMUX_CORE_SCRIPT_ENV);"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "core/crates/winsmux-workspace/src/store/layout.rs",
      "name": "dos_device_target_prefix_discriminates_nt_and_volume_device_strings"
    },
    "body": {
      "disposition": "guarded",
      "reason": "c7ed8c9e moved SUBST detection into root_identity.rs; the successor test keeps the \\??\\ refusal and the \\Device\\ acceptance cases.",
      "selectors": [
        {
          "path": "core/crates/winsmux-workspace/src/store/root_identity.rs",
          "fn": "volume_admission_pure_raw_targets_preserve_all_dos_alias_refusals"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "winsmux-app/src-tauri/src/desktop_backend.rs",
      "name": "handle_desktop_json_rpc_contract_advertises_runtime_roles_apply"
    },
    "body": {
      "disposition": "guarded",
      "reason": "5d14e361 retired the bridge-backed JSON-RPC methods; the successor test asserts the method is refused.",
      "selectors": [
        {
          "path": "winsmux-app/src-tauri/src/desktop_backend.rs",
          "fn": "handle_desktop_json_rpc_contract_excludes_retired_bridge_methods"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "winsmux-app/src-tauri/src/desktop_backend.rs",
      "name": "handle_desktop_json_rpc_routes_workers_status"
    },
    "body": {
      "disposition": "guarded",
      "reason": "5d14e361 retired the bridge-backed JSON-RPC methods; the successor test asserts the method is refused.",
      "selectors": [
        {
          "path": "winsmux-app/src-tauri/src/desktop_backend.rs",
          "fn": "handle_desktop_json_rpc_refuses_retired_workers_status"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "winsmux-app/src-tauri/src/desktop_backend.rs",
      "name": "handle_desktop_json_rpc_routes_workers_start"
    },
    "body": {
      "disposition": "guarded",
      "reason": "5d14e361 retired the bridge-backed JSON-RPC methods; the successor test asserts the method is refused.",
      "selectors": [
        {
          "path": "winsmux-app/src-tauri/src/desktop_backend.rs",
          "fn": "handle_desktop_json_rpc_refuses_retired_workers_start"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "winsmux-app/src-tauri/src/desktop_backend.rs",
      "name": "handle_desktop_json_rpc_routes_runtime_roles_apply"
    },
    "body": {
      "disposition": "guarded",
      "reason": "5d14e361 retired the bridge-backed JSON-RPC methods; the successor test asserts the method is refused.",
      "selectors": [
        {
          "path": "winsmux-app/src-tauri/src/desktop_backend.rs",
          "fn": "handle_desktop_json_rpc_refuses_retired_runtime_roles_apply"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "winsmux-app/src-tauri/src/desktop_companion_cli.rs",
      "name": "companion_ledger_command_pins_sidecar_bridge_script_when_present"
    },
    "body": {
      "disposition": "guarded",
      "reason": "5d14e361 inverted the contract: companion children no longer receive the bridge script.",
      "selectors": [
        {
          "path": "winsmux-app/src-tauri/src/desktop_companion_cli.rs",
          "fn": "companion_ledger_command_removes_bridge_even_when_script_is_present"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "winsmux-app/src-tauri/src/desktop_companion_cli.rs",
      "name": "companion_bridge_script_path_finds_tauri_resource_layouts"
    },
    "body": {
      "disposition": "reclassified",
      "reason": "5d14e361 deleted the bridge-script resolver this test exercised; no code path resolves the script any more.",
      "basis": [
        {
          "path": "winsmux-app/src-tauri/src/desktop_companion_cli.rs",
          "contains": "// Desktop no longer supplies or inherits a PowerShell bridge."
        },
        {
          "path": "winsmux-app/src-tauri/src/desktop_companion_cli.rs",
          "contains": "command.env_remove(WINSMUX_CORE_SCRIPT_ENV);"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/CliBakeoff.Tests.ps1",
      "name": "routes the formal six-pane benchmark evidence to v0.36.23"
    },
    "body": {
      "components": [
        {
          "disposition": "retired",
          "reason": "The positive v0.36.23 routing requirement was retired with the version-routing paragraphs and the v0.36.17 bench report that c34d6d9b removed as development records. aa226344 asserts that public rule from the v0.36.22 case.",
          "basis": [
            {
              "path": "docs/cli-comparison-bakeoff.md",
              "contains": "Official scoreable evidence must come from visible desktop worker panes with"
            },
            {
              "path": "docs/cli-comparison-bakeoff.md",
              "contains": "App-external batch results remain"
            }
          ],
          "retired_by": [
            "c34d6d9bfa1508718a30384460254fe525c744de"
          ],
          "selectors": [
            {
              "path": "tests/CliBakeoff.Tests.ps1",
              "contains": "$contractDoc | Should -Match 'Official scoreable evidence must come from visible desktop worker panes'"
            },
            {
              "path": "tests/CliBakeoff.Tests.ps1",
              "contains": "$contractDoc | Should -Match 'App-external batch results remain'"
            }
          ]
        },
        {
          "disposition": "guarded",
          "reason": "The negative half, no routing of formal evidence to v0.36.22, is guarded by d3c059cb's It.",
          "selectors": [
            {
              "path": "tests/CliBakeoff.Tests.ps1",
              "it": "keeps the bakeoff contract from routing formal benchmark evidence to v0.36.22"
            }
          ]
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/EnterpriseStrategyAlignment.Tests.ps1",
      "name": "documents the stable roadmap placement for TASK-371"
    },
    "body": {
      "disposition": "preserved",
      "reason": "The It 'documents the stable roadmap placement for TASK-371' read docs/project/enterprise-strategy-roadmap-alignment.md, which c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/enterprise-strategy-roadmap-alignment.md",
        "docs/project/README.md"
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/EnterpriseStrategyAlignment.Tests.ps1",
      "name": "keeps the alignment note linked from the internal planning surface"
    },
    "body": {
      "disposition": "preserved",
      "reason": "The It 'keeps the alignment note linked from the internal planning surface' read docs/project/enterprise-strategy-roadmap-alignment.md, which c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/enterprise-strategy-roadmap-alignment.md",
        "docs/project/README.md"
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/NpmReleasePackage.Tests.ps1",
      "name": "re-executes the resolved target installer before a pinned install or update"
    },
    "body": {
      "disposition": "guarded",
      "reason": "5d14e361 removed the target-installer re-execution from install.ps1; the current case asserts the bootstrap is absent and the current consumer is persisted instead.",
      "selectors": [
        {
          "path": "tests/NpmReleasePackage.Tests.ps1",
          "it": "persists the complete current consumer for saved and piped release actions"
        },
        {
          "path": "tests/NpmReleasePackage.Tests.ps1",
          "contains": "Should -Not -Match 'Invoke-TargetInstallerBootstrap|Test-ShouldBootstrapTargetInstaller|WINSMUX_INTERNAL_TARGET_INSTALLER_BOOTSTRAPPED'"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/NpmReleasePackage.Tests.ps1",
      "name": "repairs installer-managed state without release assets when the installed binary already matches"
    },
    "body": {
      "disposition": "guarded",
      "reason": "5d14e361 made paired release assets mandatory; the current case refuses a repair without them instead of repairing silently.",
      "selectors": [
        {
          "path": "tests/NpmReleasePackage.Tests.ps1",
          "it": "refuses missing paired release assets even when the installed binary already matches"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/NpmReleasePackage.Tests.ps1",
      "name": "recovers an interrupted binary rotation and rolls back a failed replacement validation"
    },
    "body": {
      "disposition": "guarded",
      "reason": "5d14e361 replaced single-binary rotation with whole-generation replacement; rollback is asserted for the complete prior generation.",
      "selectors": [
        {
          "path": "tests/NpmReleasePackage.Tests.ps1",
          "it": "preserves legacy evidence and restores the complete prior generation after replacement failure"
        },
        {
          "path": "install.ps1",
          "contains": "function Restore-WinsmuxInstalledGeneration"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/NpmReleasePackage.Tests.ps1",
      "name": "skips staging only if the package source is explicitly gated"
    },
    "body": {
      "disposition": "guarded",
      "reason": "5d14e361 turned the gated-source skip into a refusal that also proves the source is preserved.",
      "selectors": [
        {
          "path": "tests/NpmReleasePackage.Tests.ps1",
          "it": "refuses staging when the package source is explicitly gated and preserves it"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/PublicSurfacePolicy.Tests.ps1",
      "name": "keeps the v0.36.24 design-freeze gate anchored to required surfaces"
    },
    "body": {
      "components": [
        {
          "disposition": "preserved",
          "reason": "The It read docs/project/design-freeze-gate.md, which c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
          "basis": [
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- development history, internal plans, research screenshots, and original archives"
            },
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- development records must not be bundled as product documentation"
            },
            {
              "path": "docs/repo-surface-policy.md",
              "contains": "- never tracked"
            }
          ],
          "pins": [
            "docs/project/design-freeze-gate.md"
          ]
        },
        {
          "disposition": "guarded",
          "reason": "d3c059cb's It keeps that record out of the tracked public surface.",
          "selectors": [
            {
              "path": "tests/PublicSurfacePolicy.Tests.ps1",
              "it": "keeps the v0.36.24 design-freeze gate record out of the tracked public surface"
            }
          ]
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/PublicSurfacePolicy.Tests.ps1",
      "name": "restores DNS and proves GitHub reachability before publishing NSIS evidence"
    },
    "body": {
      "disposition": "guarded",
      "reason": "The desktop-nsis-lifecycle job that cut and restored networking was removed (74d66674); the native lifecycle job asserts it never touches firewall or DNS.",
      "selectors": [
        {
          "path": "tests/PublicSurfacePolicy.Tests.ps1",
          "it": "keeps native lifecycle candidate identity and evidence publication within the declared boundary"
        },
        {
          "path": "tests/PublicSurfacePolicy.Tests.ps1",
          "contains": "$job.Value | Should -Not -Match 'New-NetFirewallRule|Set-DnsClientServerAddress|Clear-DnsClientCache'"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/ReviewLatencyHardening.Tests.ps1",
      "name": "documents the TASK-372 trigger and stop conditions"
    },
    "body": {
      "disposition": "preserved",
      "reason": "The It 'documents the TASK-372 trigger and stop conditions' read docs/project/review-latency-hardening.md, which c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/review-latency-hardening.md",
        "docs/project/README.md",
        "docs/project/DETAILED_DESIGN.md"
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/ReviewLatencyHardening.Tests.ps1",
      "name": "fixes the wait, background hold, and milestone review policy"
    },
    "body": {
      "disposition": "preserved",
      "reason": "The It 'fixes the wait, background hold, and milestone review policy' read docs/project/review-latency-hardening.md, which c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/review-latency-hardening.md",
        "docs/project/README.md",
        "docs/project/DETAILED_DESIGN.md"
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/ReviewLatencyHardening.Tests.ps1",
      "name": "makes delayed review results part of the merge gate"
    },
    "body": {
      "disposition": "preserved",
      "reason": "The It 'makes delayed review results part of the merge gate' read docs/project/review-latency-hardening.md, which c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/review-latency-hardening.md",
        "docs/project/README.md",
        "docs/project/DETAILED_DESIGN.md"
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/ReviewLatencyHardening.Tests.ps1",
      "name": "links the rule from internal project surfaces"
    },
    "body": {
      "disposition": "preserved",
      "reason": "The It 'links the rule from internal project surfaces' read docs/project/review-latency-hardening.md, which c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/review-latency-hardening.md",
        "docs/project/README.md",
        "docs/project/DETAILED_DESIGN.md"
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/ThreatModelContract.Tests.ps1",
      "name": "records exactly 23 unique threat IDs in the threat model"
    },
    "body": {
      "disposition": "preserved",
      "reason": "The It 'records exactly 23 unique threat IDs in the threat model' read the threat model records that c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/THREAT_MODEL.md",
        "docs/project/THREAT_MODEL_AUDIT.md",
        "docs/project/README.md"
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/ThreatModelContract.Tests.ps1",
      "name": "audits every threat ID from the threat model"
    },
    "body": {
      "disposition": "preserved",
      "reason": "The It 'audits every threat ID from the threat model' read the threat model records that c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/THREAT_MODEL.md",
        "docs/project/THREAT_MODEL_AUDIT.md",
        "docs/project/README.md"
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/ThreatModelContract.Tests.ps1",
      "name": "keeps injection pattern categories mapped in the threat model"
    },
    "body": {
      "disposition": "guarded",
      "reason": "The threat model table is no longer public; the category contract is guarded by d3c059cb's case that loads every committed injection category into the real guard and fires each pattern.",
      "selectors": [
        {
          "path": "tests/ThreatModelContract.Tests.ps1",
          "it": "loads every committed injection category into the guard and fires each pattern on a positive sample"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/ThreatModelContract.Tests.ps1",
      "name": "distinguishes medium single-token warnings from high co-occurrence denial in the audit"
    },
    "body": {
      "disposition": "guarded",
      "reason": "The audit wording is no longer public; the behavior is guarded by d3c059cb's case on the real guard output.",
      "selectors": [
        {
          "path": "tests/ThreatModelContract.Tests.ps1",
          "it": "warns on a lone medium encoding token and denies the high encoding co-occurrence"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/ThreatModelContract.Tests.ps1",
      "name": "keeps the audit narrative aligned with the 23-threat matrix and current checks"
    },
    "body": {
      "disposition": "preserved",
      "reason": "The It 'keeps the audit narrative aligned with the 23-threat matrix and current checks' read the threat model records that c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/THREAT_MODEL.md",
        "docs/project/THREAT_MODEL_AUDIT.md",
        "docs/project/README.md"
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/ThreatModelContract.Tests.ps1",
      "name": "keeps the audit from claiming unconditional safety"
    },
    "body": {
      "disposition": "preserved",
      "reason": "The It 'keeps the audit from claiming unconditional safety' read the threat model records that c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/THREAT_MODEL.md",
        "docs/project/THREAT_MODEL_AUDIT.md",
        "docs/project/README.md"
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/ThreatModelContract.Tests.ps1",
      "name": "links the threat model and audit from the project documentation index"
    },
    "body": {
      "disposition": "preserved",
      "reason": "The It 'links the threat model and audit from the project documentation index' read the threat model records that c34d6d9b removed from the public tree. Preservation of the original bytes outside the public tree. This is not a guard on the candidate and does not count as restored protection.",
      "basis": [
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development history, internal plans, research screenshots, and original archives"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- development records must not be bundled as product documentation"
        },
        {
          "path": "docs/repo-surface-policy.md",
          "contains": "- never tracked"
        }
      ],
      "pins": [
        "docs/project/THREAT_MODEL.md",
        "docs/project/THREAT_MODEL_AUDIT.md",
        "docs/project/README.md"
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/VersionSurface.Tests.ps1",
      "name": "T857-DESKTOP-ROUTER-COMPAT-01 requires router inventory only for candidates and releases at or after 0.36.38"
    },
    "body": {
      "disposition": "guarded",
      "reason": "6fb71f12 renamed the case with the same T857-DESKTOP-ROUTER-COMPAT-01 id after the current release gained the explicit workspace generation.",
      "selectors": [
        {
          "path": "tests/VersionSurface.Tests.ps1",
          "it": "T857-DESKTOP-ROUTER-COMPAT-01 preserves the known router release and requires the explicit workspace generation for the current release"
        }
      ]
    }
  },
  {
    "match": {
      "type": "metric-decrease",
      "path": "tests/CliBakeoff.Tests.ps1",
      "metric": "pester_should",
      "old": 476
    },
    "body": {
      "components": [CB_READINESS_MOVED, ...CB_COMPONENTS]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/CliBakeoff.Tests.ps1",
      "name": "stops an existing repo desktop before rebuilding the release desktop executable"
    },
    "body": {
      "disposition": "guarded",
      "reason": "3a49ac92 moved the bakeoff desktop readiness cases from the retired operator surface to the workspace surface.",
      "selectors": [
        {
          "path": "tests/CliBakeoff.Tests.ps1",
          "it": "refuses to rebuild while a repo or external desktop is running"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/CliBakeoff.Tests.ps1",
      "name": "reads WebView operator surface results without direct dynamic property assumptions"
    },
    "body": {
      "disposition": "guarded",
      "reason": "3a49ac92 moved the bakeoff desktop readiness cases from the retired operator surface to the workspace surface.",
      "selectors": [
        {
          "path": "tests/CliBakeoff.Tests.ps1",
          "it": "reads WebView workspace results without direct dynamic property assumptions"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/CliBakeoff.Tests.ps1",
      "name": "stops the repo desktop when launch readiness fails before the operator UI is usable"
    },
    "body": {
      "disposition": "guarded",
      "reason": "3a49ac92 moved the bakeoff desktop readiness cases from the retired operator surface to the workspace surface.",
      "selectors": [
        {
          "path": "tests/CliBakeoff.Tests.ps1",
          "it": "requests normal closure only for the exact owned desktop when launch readiness fails"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/CliBakeoff.Tests.ps1",
      "name": "requires a rendered operator surface before desktop launch readiness passes"
    },
    "body": {
      "disposition": "guarded",
      "reason": "3a49ac92 moved the bakeoff desktop readiness cases from the retired operator surface to the workspace surface.",
      "selectors": [
        {
          "path": "tests/CliBakeoff.Tests.ps1",
          "it": "requires the mounted main workspace before desktop launch readiness passes"
        }
      ]
    }
  },
  {
    "match": {
      "type": "name-absent",
      "path": "tests/CliBakeoff.Tests.ps1",
      "name": "requires desktop operator API reachability before desktop launch readiness passes"
    },
    "body": {
      "disposition": "guarded",
      "reason": "3a49ac92 moved the bakeoff desktop readiness cases from the retired operator surface to the workspace surface.",
      "selectors": [
        {
          "path": "tests/CliBakeoff.Tests.ps1",
          "it": "requires canonical read-only workspace API responses before launch readiness passes"
        }
      ]
    }
  },
  {
    "match": {
      "type": "metric-decrease",
      "path": "scripts/start-cli-bakeoff-desktop.ps1",
      "metric": "ps_throw",
      "old": 38
    },
    "body": {
      "disposition": "guarded",
      "reason": "3a49ac92 moved the bakeoff desktop launcher from the retired operator surface to the workspace surface: twelve operator-surface throws were replaced by eleven workspace-surface guards (busy desktop and debug port, owned PID identity, canonical read confirmation, window size) and the script now exits 1 on a failed result.",
      "selectors": [
        {
          "path": "scripts/start-cli-bakeoff-desktop.ps1",
          "contains": "if ($existing.Count -gt 0) { throw 'Existing repo desktop app is busy. Close it normally before building or launching.' }"
        },
        {
          "path": "scripts/start-cli-bakeoff-desktop.ps1",
          "contains": "throw 'Desktop debug port is busy. Existing process is preserved.'"
        },
        {
          "path": "scripts/start-cli-bakeoff-desktop.ps1",
          "contains": "throw 'Owned PID identity changed. Process preserved.'"
        },
        {
          "path": "scripts/start-cli-bakeoff-desktop.ps1",
          "contains": "throw new Error('canonical read unconfirmed')"
        },
        {
          "path": "scripts/start-cli-bakeoff-desktop.ps1",
          "contains": "throw 'Desktop window is smaller than required.'"
        },
        {
          "path": "scripts/start-cli-bakeoff-desktop.ps1",
          "contains": "if (-not $result.ok) { exit 1 }"
        }
      ],
      "deltas": [
        {
          "commit": "3a49ac92",
          "delta": -1
        }
      ]
    }
  }
];
