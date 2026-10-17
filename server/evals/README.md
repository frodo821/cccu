# evals

Scratch space for driving real sites and apps with the plugin at volume (harness scripts, JSONL run logs,
screenshots of unexpected pages). Everything in this directory is ignored by git by default; files worth
keeping are whitelisted one by one in `.gitignore` (`!server/evals/<file>`).

Run a harness from `server/`, for example:

```sh
bun run evals/<harness>.ts
```

Harnesses connect to `bin/cccu-server` as an MCP client, so they exercise the same tool layer Claude Code uses.
