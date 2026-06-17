# Hide .git folders in find tool results (Check if its already done)

```
tool: bash done
{"command":"find . -maxdepth 2 -type f | head -80","description":"List files in workspace to understand structure"}
[exit] code=0
[stdout]
./transcript.txt
./.containifyci/containifyci.go
./.containifyci/go.mod
./.containifyci/go.sum
./SANDBOX.md
./agent-guardrails.pdf
./.contextignore
./.goreleaser.yaml
./settings.json
./test/gitignore_test.zig
./test/agent_loop_test.zig
./test/agent_class_test.zig
./test/parallel_tools_test.zig
./test/replay_test.zig
./test/kitchen_sink_test.zig
./build.zig.zon
./.teller.yml
./build.zig
./.franky-workflow.yaml
./docs/README.md
./review-subagent-1.md
./README.md
./Dockerfile.sandbox
./review-subagent-2.md
./.gitignore
./skills/zig.md
./transcript2.txt
./AGENTS.md
./.git/ORIG_HEAD
./.git/config
./.git/HEAD
./.git/description
./.git/index
./.git/packed-refs
./.git/COMMIT_EDITMSG
```

# Prevent possible destructive bash commands

Prevent destructive bash commands like
```
git stash pop
```
May also define other commands as well


# Model Provider Feature Batch

THe mistral api have trhe batch feature https://docs.mistral.ai/studio-api/batch-processing
CHeck if this is a unified standard across other providers like opanai, ollama, openrouter.

Do a web research.

# List subagents/preset based on the available API KEYS. (Done)

Also if a subagent was started with profile gemini but gemini api key is not there return hint with please use one of the following or change the subagent model without telling the parent agent.

The list_preset tool should return the presets and also all the available profiles so
that the model can pick one.


# Deepseek multiple tool calls (Done)
```
<｜DSML｜tool_calls>
<｜DSML｜invoke name="bash">
<｜DSML｜parameter name="command" string="true">cd /Users/frankittermann/github/franky && git show HEAD:src/ai/registry.zig | head -160</｜DSML｜parameter>
<｜DSML｜parameter name="cwd" string="true">/Users/frankittermann/github/franky</｜DSML｜parameter>
</｜DSML｜invoke>
<｜DSML｜invoke name="bash">
<｜DSML｜parameter name="command" string="true">cd /Users/frankittermann/github/franky && git show HEAD:src/ai/providers/faux.zig | head -100</｜DSML｜parameter>
<｜DSML｜parameter name="cwd" string="true">/Users/frankittermann/github/franky</｜DSML｜parameter>
</｜DSML｜invoke>
<｜DSML｜invoke name="bash">
<｜DSML｜parameter name="command" string="true">cd /Users/frankittermann/github/franky && git show HEAD:src/ai/channel.zig | head -60</｜DSML｜parameter>
<｜DSML｜parameter name="cwd" string="true">/Users/frankittermann/github/franky</｜DSML｜parameter>
</｜DSML｜invoke>
<｜DSML｜invoke name="bash">
<｜DSML｜parameter name="command" string="true">cd /Users/frankittermann/github/franky && git show HEAD:src/agent/types.zig | head -80</｜DSML｜parameter>
<｜DSML｜parameter name="cwd" string="true">/Users/frankittermann/github/franky</｜DSML｜parameter>
</｜DSML｜invoke>
</｜DSML｜tool_calls>
```

# Edit Diff View (Web-UI)

Add the following header in the richt edit view.

This example is from the edit fallback view
```
applied 1 edit(s) to /Users/frankittermann/github/franky/src/coding/modes/print.zig
```

# Finish Task (Check for regression after nudging was implemented)

It could check if the worked on document was updated recently before the finish task was called and also take hash of it before the work and compare it after finish task to check changes as well. Or just send a final hint to the model please update the document you were working on if not already happended.

# Lets add the file icon to all path args in tool calls (failed)

Here is a failed example. The path value was deleted not the path field name the `<th>path</th>` is still there but the value is gone. We need to make sure to keep the value and just add the icon instead of the th print text.
```
<div class="tool-card"><div class="tool-head">tool: <span class="tool-name">ls</span> <span class="tool-status">done</span><button type="button" class="tool-args-raw-toggle" aria-label="Toggle raw JSON" aria-pressed="false">{ }</button><button type="button" class="tool-result-toggle" aria-expanded="false">▶</button></div><div class="tool-args"><div class="tool-args-wrapper"><table class="tool-args-table"><tbody><tr><th>path</th><td><span class="file-icon">📄</span></td></tr><tr><th>maxDepth</th><td><code>2</code></td></tr></tbody></table><div class="tool-args-raw" hidden=""><pre>{"path":"/Users/frank.ittermann@goflink.com/private/github/franky","maxDepth":2}</pre></div></div></div><div class="tool-result-log" hidden="">/Users/frank.ittermann@goflink.com/private/github/franky
.soteria/
</div></div>
```

# Web-UI Disconnect

For long session without activity the web-ui disconnects and the user needs to refresh the page to reconnect.
We need to add a reconnect logic to the web-ui to handle this case and also show a message to the user that the connection was lost and we are trying to reconnect.

# Abort Sub Agent (Done | Need Improvement)

Add the ability to abort a sub agent execution from the web-ui. This is useful in case the sub agent is going in a wrong direction or taking too long and we want to stop it and try a different approach.

# New Stack Mesage Feature

Make it possible to stack multiple tasks/messages that will send when the current session has called finished_task (successfully including non failing guardrails).

# Check for LLM Agent Standards

How PI and Hermes for example:
* handle AGENTS.md files ?
* what are the folders they check like .agents?
* how they load skills ? From .skills or .agent/skills ? How they check when to apply what skill ?
* how they handle tools and MCP ? Can tools be added ? WHen yes how ?

Create a design doc on how we can support the LLM standard.

# the tool call ids aren't unique (Not working)

To be able to link dediacted messages like tool calls we need a unique id.

# Review --mulitmodel (Done)

Here is an conversation snippet lets fix it the `/review --multimodel` command should work out of the box may we dont even need a skill the command just contain the prompt already or ? 
```
assistant
The multimodel review skill isn't found. Let me check the skills directory and the AGENTS.md to see what skills are loaded.
ls done
📄	 /Users/frankittermann/github/franky/skills
grep done
📄	 /Users/frankittermann/github/franky
🔍	 multimodel-review|multimodel_review
assistant
The multimodel-review design doc doesn't exist anymore, but the code references it. The `review_config_block` in the system prompt tells the model about the review profiles. The model uses the `subagent` tool with the `code-audit` and `diff-review` presets to run the review. Let me look at the system prompt to understand how it's wired in.

Let me now understand the full picture. The user's question is about fixing the tool_call_id suffix duplication in `renderTranscriptForUi`. We've already fixed it. Now they want me to run a multi-model code review with `--multimodel`. But actually, the `--multimodel` is not a CLI arg, it's triggered via the `/review` slash command which requires `--skill multimodel-review`.

Wait, the user said "Run a multi-model code review on: --multimodel". Let me re-read. They want a multi-model code review using the multimodel-review skill, specifically on the recent changes we made to proxy.zig.

Let me search for the skill file.

Since I'm not in interactive mode with the /review slash command available, I'll run the code review directly using sub-agents per the configured review profiles. Let me review the changes I just made to proxy.zig.
```

# Auto Continue (DONE)

When --autocontinue is enabled, after the model stops (any stop_reason except
error/aborted/refusal) without calling finish_task, inject a user message:
"Continue until you are done and then call finish task."

Implementation:
- `--autocontinue` CLI flag → `cfg.autocontinue`
- `Config.nudge_on_autocontinue` in loop config
- `maybeNudgeAutoContinue()` — broader than `maybeNudgeToFinishTask()`:
  fires after tool-call turns too, checks for `finish_task` tool_call
- Wired in print, interactive, proxy, and rpc modes
- Caps at 2 nudges per session


# Grep Tool multi pattern support (Done)

Now supports `"pattern": "foo"` (string) or `"pattern": ["foo", "bar"]` (array, OR semantics).

Changes:
- `parameters_json` uses `oneOf` to accept string or array of strings
- `extractPatterns()` helper (mirrors `find.zig`)
- `Matcher` now holds a slice of patterns (regex or literal) with OR matching
- `compileMultiRegex()` / `compileMultiLiteral()` helpers
- `deinit()` properly frees the slice and all regexes
- Test helpers updated for new `Matcher` struct layout

```
grep error
path	["/Users/frankittermann/github/franky/src/coding/modes/print.zig","/Users/frankittermann/github/franky/src/coding/modes/proxy.zig"]
pattern	["emitSessionSummary","fn slashHandler|POST /command|/command|slash_mod"]
[invalid_args] pattern must be a string
```
```
grep error
path	["/Users/frankittermann/github/franky/src/coding/modes/proxy.zig","/Users/frankittermann/github/franky/src/coding/slash.zig"]
pattern	["commandHandler|POST.*command|/command","pub fn|pub const"]
[invalid_args] pattern must be a string
```

# SubAgent Panel empty

The Subagent Panel is empty in the web ui but its working and the agent get's the result so
the subagent is working its just invisible.

To see the subagent conversation in the panel a full browser page reload is needed.
```
<div class="sa-overlay-body" id="sa-overlay-body"></div>
```