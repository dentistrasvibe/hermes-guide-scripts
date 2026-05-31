# P1 — Live integration runbook (clean Ubuntu 24.04, `hermes-test`)

Run on a **freshly reimaged** box. The pure helper logic is covered by
`tests/test_helpers.bats`; this file is the live end-to-end verification that
only a real VPS can give. Fill in the `RESULT:` lines as you go.

---

## Task 1 — Verify the version-pin + update mechanism (do this FIRST)

`install_hermes_pinned()` in `install-hermes-unattended.sh` currently uses the
`--branch <tag>` path. Confirm which mechanism actually yields a pinned
`v0.14.0` before trusting the orchestrator.

### Step 1 — branch/tag pin
```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --branch v0.14.0
hermes --version
```
Expected: install succeeds, `hermes --version` → `0.14.0`.
RESULT:

### Step 2 — pip path (only if Step 1 did not pin)
```bash
pipx install hermes-agent==0.14.0 || pip install --user hermes-agent==0.14.0
hermes --version
```
Expected: `0.14.0`.
RESULT:

### Step 3 — `hermes update` behavior after a pinned install
```bash
hermes update
hermes --version
```
Observe: does `update` jump to latest `main`, or stay on the pinned tag?
RESULT:

### Step 4 — Record the winning mechanism
- Winning install command: ____________________
- `hermes update` un-pins? (yes/no): ____________________
- If branch-pin lost: edit `install_hermes_pinned()` to the pip path (see the
  header comment in `install-hermes-unattended.sh`).
- If `hermes update` un-pins: drop the `hermes update` step from `main()` (or
  re-pin after it).

---

## Task 10 — Full orchestrator run, all three provider paths

The orchestrator fetches scripts from
`https://raw.githubusercontent.com/dentistrasvibe/hermes-guide-scripts/main/`.
**Push the `p1-unattended-install` branch to `main` (or adjust `RAW_BASE`) before
running**, otherwise it will fetch the old `main` without these changes.

### Run A — openrouter path
```bash
export HERMES_VERSION=v0.14.0 PANEL_EMAIL=you@example.com \
       TELEGRAM_BOT_TOKEN=... TELEGRAM_ALLOWED_USERS=123456789 \
       PROVIDER=openrouter OPENROUTER_API_KEY=sk-or-... OPENROUTER_MODEL=anthropic/claude-opus-4.6
curl -fsSL https://raw.githubusercontent.com/dentistrasvibe/hermes-guide-scripts/main/install-hermes-unattended.sh | bash
```

Expected observable outcomes:
- [ ] script ends with `::done:: panel=https://<...>.sslip.io login=hermes password=<...>`
- [ ] `systemctl is-active hermes-dashboard` = active
- [ ] `systemctl is-active hermes-gateway` (confirm the exact unit name) = active
- [ ] `curl -s -o /dev/null -w '%{http_code}' https://<domain>/` = 401 (Basic Auth)
- [ ] log in to the panel with `hermes` / `<password>` over HTTPS works
- [ ] send the bot a Telegram message from the allowed user → agent replies
- [ ] `su - hermes -c 'hermes config get model.provider'` = `openrouter`
RESULT:

### Step 3 — `model.default` vs `model.model` (open research item)
```bash
su - hermes -c 'hermes config get model.default'
```
Expected: the model you set (`anthropic/claude-opus-4.6`).
If empty/error, try `model.model`. If `model.model` is the real key:
1. fix `provider_config_commands` in `lib/hermes-install-helpers.sh`,
2. update the Task 7 bats expectations,
3. re-run `bats tests/test_helpers.bats`,
4. note the correct key here.
RESULT (correct key): ____________________

### Run B — openai-codex path (OAuth, interactive)
```bash
export HERMES_VERSION=v0.14.0 PANEL_EMAIL=you@example.com \
       TELEGRAM_BOT_TOKEN=... TELEGRAM_ALLOWED_USERS=123456789 \
       PROVIDER=openai-codex
curl -fsSL .../install-hermes-unattended.sh | bash
```
When the script reaches `hermes auth add openai-codex`:
- [ ] it prints URL `https://auth.openai.com/codex/device` + a code `XXXX-XXXX-XXXX`
- [ ] completing the device-code login in a browser succeeds
- [ ] `su - hermes -c 'test -f ~/.hermes/auth.json && echo ok'` = ok
- [ ] agent answers a test prompt
RESULT:

### Run C — custom path
```bash
export HERMES_VERSION=v0.14.0 PANEL_EMAIL=you@example.com \
       TELEGRAM_BOT_TOKEN=... TELEGRAM_ALLOWED_USERS=123456789 \
       PROVIDER=custom CUSTOM_BASE_URL=https://.../v1 CUSTOM_API_KEY=... CUSTOM_MODEL=...
curl -fsSL .../install-hermes-unattended.sh | bash
```
- [ ] agent answers a test prompt against the custom endpoint
RESULT:

### Step 6 — Idempotency re-run
Re-run the **Run A** block on the already-installed box.
- [ ] completes without breaking the existing install
- [ ] panel password rotates (new password in the `::done::` line)
RESULT:

---

## Notes / surprises
(record anything that diverged from the plan — feeds back into the guide and P2)
