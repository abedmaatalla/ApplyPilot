# ApplyPilot — common commands
# Usage: make [target]   or   make help

.DEFAULT_GOAL := help

VENV          := .venv
PYTHON        := $(VENV)/bin/python
PIP           := $(VENV)/bin/pip
APPLYPILOT    := $(VENV)/bin/applypilot
RUFF          := $(VENV)/bin/ruff
PYTEST        := $(VENV)/bin/pytest
PLAYWRIGHT    := $(VENV)/bin/playwright

APPLYPILOT_DIR ?= $(HOME)/.applypilot

# Pipeline / apply defaults (override: make run WORKERS=4)
WORKERS        ?= 2
APPLY_WORKERS  ?= 3
MIN_SCORE      ?= 8
# Auto-apply uses Claude Code CLI (haiku, sonnet, opus) — not your Ollama LLM_MODEL
MODEL          ?= sonnet
VALIDATION     ?= normal

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_.-]+:.*##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

.PHONY: venv install install-dev install-jobspy install-playwright setup bootstrap-config clean

venv: ## Create Python virtual environment
	python3 -m venv $(VENV)
	$(PIP) install -U pip

install: venv ## Install ApplyPilot (editable) + runtime deps
	$(PIP) install -e .

install-dev: venv ## Install editable with dev deps (pytest, ruff)
	$(PIP) install -e ".[dev]"

install-jobspy: ## Install python-jobspy (separate; avoids numpy pin conflict)
	$(PIP) install --no-deps python-jobspy
	$(PIP) install pydantic tls-client requests markdownify regex

install-playwright: ## Download Chromium for Playwright
	$(PLAYWRIGHT) install chromium

setup: install-dev install-jobspy install-playwright bootstrap-config ## Full local dev setup
	@echo "Setup complete. Run: make doctor"

bootstrap-config: ## Copy example config to ~/.applypilot (won't overwrite existing files)
	@mkdir -p $(APPLYPILOT_DIR)
	@test -f $(APPLYPILOT_DIR)/.env || cp .env.example $(APPLYPILOT_DIR)/.env
	@test -f $(APPLYPILOT_DIR)/profile.json || cp profile.example.json $(APPLYPILOT_DIR)/profile.json
	@test -f $(APPLYPILOT_DIR)/searches.yaml || cp src/applypilot/config/searches.example.yaml $(APPLYPILOT_DIR)/searches.yaml
	@echo "Config bootstrapped in $(APPLYPILOT_DIR)"

clean: ## Remove virtual environment
	rm -rf $(VENV)

# ---------------------------------------------------------------------------
# CLI — setup & diagnostics
# ---------------------------------------------------------------------------

.PHONY: version init doctor status dashboard

version: ## Show ApplyPilot version
	$(APPLYPILOT) --version

init: ## Interactive first-time setup wizard
	$(APPLYPILOT) init

doctor: ## Verify setup (profile, LLM, Chrome, Claude Code, etc.)
	$(APPLYPILOT) doctor

status: ## Pipeline statistics from database
	$(APPLYPILOT) status

dashboard: ## Open HTML results dashboard in browser
	$(APPLYPILOT) dashboard

# ---------------------------------------------------------------------------
# Pipeline — full run
# ---------------------------------------------------------------------------

.PHONY: run run-parallel run-stream run-dry-run prepare

run: ## Full pipeline: discover → enrich → score → tailor → cover → pdf
	$(APPLYPILOT) run

run-parallel: ## Full pipeline with parallel discovery/enrichment
	$(APPLYPILOT) run -w $(WORKERS)

run-stream: ## Full pipeline in streaming (concurrent) mode
	$(APPLYPILOT) run --stream -w $(WORKERS)

run-dry-run: ## Preview pipeline without executing
	$(APPLYPILOT) run --dry-run

prepare: ## Score + tailor + cover + pdf (run after discover/enrich)
	$(APPLYPILOT) run score tailor cover pdf --min-score $(MIN_SCORE) --validation $(VALIDATION)

prepare-lenient: ## Same as prepare but relaxed validation (fewer tailor failures)
	$(APPLYPILOT) run score tailor cover pdf --min-score $(MIN_SCORE) --validation lenient

# ---------------------------------------------------------------------------
# Pipeline — individual stages
# ---------------------------------------------------------------------------

.PHONY: discover enrich score tailor cover pdf

discover: ## Stage 1: job discovery (JobSpy + Workday + sites)
	$(APPLYPILOT) run discover -w $(WORKERS)

enrich: ## Stage 2: fetch full job descriptions
	$(APPLYPILOT) run enrich -w $(WORKERS)

score: ## Stage 3: LLM fit scoring (1–10)
	$(APPLYPILOT) run score --min-score $(MIN_SCORE)

rescore: ## Re-score all jobs (including previously scored)
	$(APPLYPILOT) run score --rescore --min-score $(MIN_SCORE)

tailor: ## Stage 4: tailored resumes for high-fit jobs
	$(APPLYPILOT) run tailor --min-score $(MIN_SCORE) --validation $(VALIDATION)

cover: ## Stage 5: cover letter generation
	$(APPLYPILOT) run cover --min-score $(MIN_SCORE) --validation $(VALIDATION)

pdf: ## Stage 6: convert tailored resumes & letters to PDF
	$(APPLYPILOT) run pdf

# ---------------------------------------------------------------------------
# Auto-apply
# ---------------------------------------------------------------------------

.PHONY: apply apply-parallel apply-continuous apply-dry-run apply-headless

apply: ## Submit one application (default limit)
	$(APPLYPILOT) apply --min-score $(MIN_SCORE) --model $(MODEL)

apply-parallel: ## Auto-apply with parallel browser workers
	$(APPLYPILOT) apply -w $(APPLY_WORKERS) --min-score $(MIN_SCORE) --model $(MODEL)

apply-continuous: ## Run auto-apply forever (poll for new jobs)
	$(APPLYPILOT) apply -w $(APPLY_WORKERS) --continuous --min-score $(MIN_SCORE) --model $(MODEL)

apply-dry-run: ## Fill forms without submitting
	$(APPLYPILOT) apply -w $(APPLY_WORKERS) --dry-run --min-score $(MIN_SCORE) --model $(MODEL)

apply-headless: ## Auto-apply in headless browser mode
	$(APPLYPILOT) apply -w $(APPLY_WORKERS) --headless --min-score $(MIN_SCORE) --model $(MODEL)

# Apply utilities (set URL=... when invoking)
.PHONY: apply-gen mark-applied mark-failed reset-failed

apply-gen: ## Generate prompt file for manual debugging (requires URL=...)
	@test -n "$(URL)" || (echo "Usage: make apply-gen URL=https://..." && exit 1)
	$(APPLYPILOT) apply --gen --url "$(URL)" --min-score $(MIN_SCORE) --model $(MODEL)

mark-applied: ## Manually mark a job as applied (requires URL=...)
	@test -n "$(URL)" || (echo "Usage: make mark-applied URL=https://..." && exit 1)
	$(APPLYPILOT) apply --mark-applied "$(URL)"

mark-failed: ## Manually mark a job as failed (requires URL=..., optional REASON=...)
	@test -n "$(URL)" || (echo "Usage: make mark-failed URL=https://... [REASON=...]" && exit 1)
	$(APPLYPILOT) apply --mark-failed "$(URL)" $(if $(REASON),--fail-reason "$(REASON)",)

reset-failed: ## Reset all failed jobs for retry
	$(APPLYPILOT) apply --reset-failed

unlock-apply: ## Clear stale in_progress locks (crashed apply runs)
	$(PYTHON) -c "from applypilot.config import load_env, ensure_dirs; from applypilot.database import init_db; from applypilot.apply.launcher import reset_stale_apply_locks; load_env(); ensure_dirs(); init_db(); print(f'Unlocked {reset_stale_apply_locks()} job(s)')"

# ---------------------------------------------------------------------------
# Development
# ---------------------------------------------------------------------------

.PHONY: test test-cov lint lint-fix format

test: ## Run test suite
	$(PYTEST) tests/ -v

test-cov: ## Run tests with coverage report
	$(PYTEST) tests/ --cov=src/applypilot --cov-report=term-missing

lint: ## Ruff lint check
	$(RUFF) check src/

lint-fix: ## Ruff lint with auto-fix
	$(RUFF) check src/ --fix

format: ## Ruff format source
	$(RUFF) format src/


