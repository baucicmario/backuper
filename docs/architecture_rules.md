# Backuper Architecture Rules

This document serves as the canonical reference for architectural decisions and implementation rules established during the development of Backuper. It ensures consistency, prevents duplication, and guides future development.

## 1. Single Source of Truth
- **Shared Implementation:** Backup logic and restore logic must exist in one place. 
- **No Parallel Logic:** Avoid parallel implementations of identical functionality.
- **Frontend Thinness:** Frontends (WebUI, CLI) should invoke shared backend functionality whenever practical, acting primarily as orchestrators and presenters.

## 2. Ownership Rules
To prevent future duplication, the following architectural layers own specific responsibilities:
- **Backup execution:** Shared Bash Pipeline (`modules/backup/run.sh`)
- **Restore execution:** Shared Bash Pipeline (`modules/restore/run.sh`)
- **Archive creation:** Shared Bash Pipeline (`modules/backup/steps/`)
- **Archive extraction:** Shared Bash Pipeline (`modules/restore/steps/`)
- **Progress generation:** Shared Bash Pipeline (emits standardized tags like `[job-progress: X]`)
- **User interaction:** Specific UI layers (CLI uses `read`/`whiptail`, WebUI uses HTML modals)
- **Upload handling:** WebUI Backend (`modules/webui/backend/server.py`)
- **Download handling:** WebUI Backend (`modules/webui/backend/server.py`)

## 3. UI Rules
- **Display Diversity:** CLI and WebUI may present data differently to suit their respective mediums.
- **No Logic Duplication:** Business logic should not be duplicated merely to support different user interfaces.
- **Consume Shared Logic:** UI layers should consume shared functionality whenever possible (e.g., calling common discovery scripts rather than rewriting discovery in Python).

## 4. Refactoring Rules
- **Functionality First:** Functionality takes priority over architectural purity.
- **Preserve Stability:** Stable working behavior should not be rewritten unnecessarily.
- **Workflow Preservation:** Existing user workflows must remain intact unless explicitly approved by the maintainer.

## 5. Future Development Rules
All future backup and restore changes MUST adhere to the following guidelines:
1. **Check First:** Check for existing implementations before starting new features.
2. **Reuse Helpers:** Reuse existing helpers (e.g., from `lib/common.sh`) where possible.
3. **Avoid Duplicate Workflows:** Do not create duplicate workflows for similar tasks.
4. **Extend, Don't Duplicate:** Extend shared functionality rather than creating parallel implementations.
