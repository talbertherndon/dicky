# Intent

## Restatement
Fix the concrete OpenClicky review findings that can be safely addressed now: agent/bridge security defaults, secret persistence, honest service install reporting, and broken verification script.

## Constraints
- Do not run xcodebuild.
- Preserve existing repo naming and product identity.
- Keep changes scoped; do not refactor the entire app.
- Do not revert unrelated/user work.

## Assumptions
- It is acceptable to make bridge inference proxy disabled unless explicitly configured.
- Keychain migration can be best-effort: if Keychain writes fail, existing env/config fallbacks still work.
- Full app permission testing remains manual in Xcode.

## Unknowns
- Exact desired UX for showing stored secret values; this patch avoids exposing key material in settings fields.
