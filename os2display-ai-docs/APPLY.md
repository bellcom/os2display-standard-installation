# Applying these files to the repository

From the root of `bellcom/os2display-standard-installation`:

```bash
mkdir -p docs/architecture docs/runbooks docs/ai docs/decisions
```

Copy the files from this bundle into the matching paths, then optionally append the contents of `README_SNIPPET.md` to the repository `README.md`.

The old `v3.ai` can then be removed from Git because its useful content has been split into maintained project documentation.

Recommended Git sequence:

```bash
git rm v3.ai
git add AGENTS.md docs/ README.md
git status
git diff --cached
```

Then commit when the staged diff looks correct.

If you want to keep a local `v3.ai` scratch file after removing the tracked file, add this exact line to `.gitignore`:

```text
v3.ai
```
