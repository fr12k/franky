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

# Abort Sub Agent

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

# The session id should be a path parameter (Done)

This make it possible to jump between session but consider there is only one active session but still how we can support at least jumping between sessions and view them while still keep the active session
MAke a design doc

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

# Improve Edit tool Error Handling (Done)

With some changes we can save some turns and tokens when we handle error cases with better response.
Auto-read on first edit_no_match

Server-side: when edit_no_match occurs, instead of just returning an error, return the actual file content in the error message so the model can retry immediately without an extra read call:

return common.toolError(allocator, "edit_no_match",
    "old not found. Here are the actual file contents:\n---\n{s}\n---\n" ++
    "Copy-paste the exact bytes you want to replace from above.",
    .{original}
);

This eliminates the "waste a turn re-reading" excuse — the model gets the correct bytes in the error and can immediately retry with matching old.

Validate old against file before attempting edits

Run a pre-check: if old appears nowhere in the file (not even partially), short-circuit to the auto-read error immediately without going through the full edit pipeline. Saves the allocation/atomic-write setup cost on what is guaranteed to fail.

# Add ast-grep (Removed)

The grep is good for text search but its missing programming language syntax there is tool 
https://github.com/ast-grep/ast-grep that does. How could we intgrate it so that the Model use ast-grep instread of grep or we offer normal grep and run ast-grep in the background or
merge the result from grep and ast-grep in the tool result what would be the prefred way ?

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

# Fix segafult (Done)

Segmentation fault at address 0x13fc13300
/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/compiler_rt/memcpy.zig:170:17: 0x100f9f92c in copyFixedLength (compiler_rt)
        d[i] = s[i];
                ^
/Users/frankittermann/github/franky/src/coding/modes/proxy.zig:2473:11: 0x100b92e3f in writeMessageForUi (franky)
    for (m.content) |cb| {
          ^
/Users/frankittermann/github/franky/src/coding/modes/proxy.zig:2424:30: 0x100b93c77 in renderTranscriptForUi (franky)
        try writeMessageForUi(&buf, allocator, m, &tool_call_seq, &tool_result_seq);
                             ^
/Users/frankittermann/github/franky/src/coding/modes/proxy.zig:2376:39: 0x100bb6fc3 in respondTranscript (franky)
    const body = renderTranscriptForUi(allocator, &session.transcript) catch {
                                      ^
/Users/frankittermann/github/franky/src/coding/modes/proxy.zig:1808:26: 0x100b76e3b in handleConnection (franky)
        respondTranscript(arg.session, &stream, arg.io, arg.allocator);
                         ^
/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/Thread.zig:422:13: 0x100b76373 in callFn__anon_70414 (franky)
            @call(.auto, f, args);
            ^
/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/Thread.zig:752:30: 0x100b761eb in entryFn (franky)
                return callFn(f, args_ptr.*);
                             ^
???:?:?: 0x186f7bc57 in __pthread_cond_wait (/usr/lib/system/libsystem_pthread.dylib)
???:?:?: 0x186f76c1b in _pthread_cond_broadcast (/usr/lib/system/libsystem_pthread.dylib)

# Tool Result offload missing path (Done)

The tool offload results missing the path for the model to read the result again that leads to multiple new full reads because context was missing.
```
    {
      "role": "assistant",
      "content": null,
      "tool_calls": [
        {
          "id": "call_h9xz6ave",
          "type": "function",
          "function": {
            "name": "bash",
            "arguments": "{\"command\":\"cd /Users/frankittermann/github/zettler \\u0026\\u0026 zig run src/main.zig -- 2\\u003e\\u00261 | head -5\",\"description\":\"Check how to build and run the project\",\"timeoutMs\":30000}"
          }
        }
      ]
    },
    {
      "role": "tool",
      "tool_call_id": "call_h9xz6ave",
      "content": "[tool result: call_h9xz6ave — 257B (offloaded)]"
    }
```

# lets support find tools with multiple patterns as args (Done)

```
find error
pattern	["**/FlagManager.zig","**/types.zig","**/enums.zig","**/SerfState.zig","**/FlagState.zig","**/BuildingState.zig"]

{"pattern":["**/FlagManager.zig","**/types.zig","**/enums.zig","**/SerfState.zig","**/FlagState.zig","**/BuildingState.zig"]}

[invalid_args] pattern must be a string
```

# Lets support multiple query args in the web_search tool (Done)
```
web_search error
max_results	10
query	["öffentlicher Dienst IT Stellenangebote Berlin 2025 Senior DevOps SRE","Bund Berlin IT Stellenausschreibung Platform Engineer 2025","German government IT jobs Berlin 2025 DevOps Platform Engineer Bundesamt"]

{"max_results":10,"query":["öffentlicher Dienst IT Stellenangebote Berlin 2025 Senior DevOps SRE","Bund Berlin IT Stellenausschreibung Platform Engineer 2025","German government IT jobs Berlin 2025 DevOps Platform Engineer Bundesamt"]}

[invalid_args] query must be a string
```

# Disconnected Web UI (Done)

```
<span id="status" class="status status-idle">disconnected</span>
```

The command `curl -v http://127.0.0.1:8788/transcript` hangs while the llm loop is working
what happened earlier the messages where displayed correctly.

# Grep Tool multi pattern support (In Progress)

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