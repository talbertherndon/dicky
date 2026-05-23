# Plan

| ID | Goal | Outputs | Acceptance criteria | Dependencies |
|---|---|---|---|---|
| T1 | Move API-key lookup/storage toward Keychain. | AppBundleConfiguration / CompanionManager / settings edits. | Secret reads prefer Keychain; setter writes Keychain and removes plaintext UserDefaults; existing plaintext defaults are migrated on read. | none |
| T2 | Protect bridge inference proxy. | OpenClickyExternalControlBridge + config helpers. | Proxy disabled by default; when enabled, request must present configured token; health does not advertise proxy endpoints unless enabled. | T1 |
| T3 | Safer Claude SDK bridge defaults. | bridge.mjs. | No unconditional full SDK stderr dump; dangerous permission bypass only enabled by explicit env flag. | none |
| T4 | Honest launch-agent install status. | OpenClickyAgentManager. | Non-zero launchctl exits throw and do not mark service running. | none |
| T5 | Repair lightweight verification. | scripts/test-external-control-bridge.sh. | Script no longer fails before live tests because package modules are absent from raw swiftc module path. | none |
