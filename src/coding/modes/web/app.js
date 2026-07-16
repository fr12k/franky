// franky web UI — talks to the streamProxy listener (§4.7).
//
// Wire format: each SSE frame is `event: <kind>\ndata: <json>\n\n`,
// matching what the in-process agent loop emits. We reuse browser-
// native EventSource and just dispatch by event name.

// ─── Markdown renderer (v1.6.0) ──────────────────────────────────
//
// Hand-rolled subset — no external deps. Why hand-roll: the LLM
// output rarely needs the full CommonMark surface, and shipping a
// dependency would put the binary back into supply-chain territory
// the v1.5.0 zero-build-pipeline decision explicitly avoided.
//
// Supported:
//   - Headings:       # H1, ## H2, ### H3
//   - Code fences:    ```lang\ncode\n```  (lang optional)
//   - Inline code:    `code`
//   - Bold:           **text** or __text__
//   - Italic:         *text* or _text_
//   - Links:          [text](url) — http(s)/mailto/relative only
//   - Lists:          - item / * item / 1. item
//   - Tables:         GFM pipe tables (header row + separator row)
//   - Paragraphs:     anything else, joined by blank lines
//
// XSS posture: HTML-escape **before** any markdown pattern runs so
// `<script>` from the LLM never reaches the DOM. Code spans/fences
// keep escaped content verbatim. Link URLs are passed through
// `sanitizeUrl` which rejects `javascript:`, `data:`, etc.
const Markdown = (function () {
    function escapeHtml(s) {
        return s
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function escapeAttr(s) {
        return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
    }

    function sanitizeUrl(url) {
        const u = url.trim();
        if (/^https?:\/\//i.test(u)) return u;
        if (/^mailto:/i.test(u)) return u;
        if (/^[#/]/.test(u)) return u;          // anchors + relative paths
        return null;                            // reject javascript:, data:, file:, …
    }

    // Inline-level transforms applied to already-HTML-escaped text.
    function inline(text) {
        let r = escapeHtml(text);

        // Code spans first — their contents are protected from later
        // transforms by being wrapped in <code>.
        r = r.replace(/`([^`\n]+)`/g, function (_, code) {
            return '<code>' + code + '</code>';
        });

        // Bold (**…** and __…__) before italic so the asterisks/
        // underscores get consumed by the bold matcher.
        r = r.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
        r = r.replace(/__([^_\n]+)__/g, '<strong>$1</strong>');

        // Italic — match with a leading boundary so we don't mangle
        // identifiers like `snake_case_var`.
        r = r.replace(/(^|[^*\w])\*([^*\n]+)\*(?!\*)/g, '$1<em>$2</em>');
        r = r.replace(/(^|[^_\w])_([^_\n]+)_(?!_)/g, '$1<em>$2</em>');

        // Links — sanitize href before emit.
        r = r.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (_, label, url) {
            const safe = sanitizeUrl(url);
            if (!safe) return label;
            return '<a href="' + escapeAttr(safe) + '" target="_blank" rel="noopener noreferrer">' + label + '</a>';
        });

        return r;
    }

    function isHeading(line)   { return /^#{1,3}\s+/.test(line); }
    function isUlItem(line)    { return /^\s*[-*]\s+/.test(line); }
    function isOlItem(line)    { return /^\s*\d+\.\s+/.test(line); }
    function isFenceOpen(line) { return /^```/.test(line); }
    function isTableRow(line)  { return /^\s*\|/.test(line); }
    // A separator row contains only |, -, :, and spaces — e.g. |---|:---:|
    function isTableSep(line)  { return /^\s*\|[\s\-:|]+\|[\s\-:|]*$/.test(line); }
    function parseTableCells(line) {
        return line.trim().replace(/^\||\|$/g, '').split('|').map(function (c) { return c.trim(); });
    }

    function render(text) {
        if (!text) return '';
        const lines = text.split('\n');
        const out = [];
        let i = 0;

        while (i < lines.length) {
            const line = lines[i];

            // Code fence — consume until closing ``` (or EOF, mid-stream).
            if (isFenceOpen(line)) {
                const langRaw = line.slice(3).trim();
                const langClass = langRaw ? ' class="language-' + escapeAttr(langRaw) + '"' : '';
                const codeLines = [];
                i += 1;
                while (i < lines.length && !isFenceOpen(lines[i])) {
                    codeLines.push(lines[i]);
                    i += 1;
                }
                if (i < lines.length) i += 1; // skip the closing fence
                out.push('<pre' + langClass + '><code' + langClass + '>' + escapeHtml(codeLines.join('\n')) + '</code></pre>');
                continue;
            }

            // Heading.
            const h = line.match(/^(#{1,3})\s+(.*)$/);
            if (h) {
                const lvl = h[1].length;
                out.push('<h' + lvl + '>' + inline(h[2]) + '</h' + lvl + '>');
                i += 1;
                continue;
            }

            // Unordered list.
            if (isUlItem(line)) {
                const items = [];
                while (i < lines.length && isUlItem(lines[i])) {
                    items.push(lines[i].replace(/^\s*[-*]\s+/, ''));
                    i += 1;
                }
                out.push('<ul>' + items.map(function (it) {
                    return '<li>' + inline(it) + '</li>';
                }).join('') + '</ul>');
                continue;
            }

            // Ordered list.
            if (isOlItem(line)) {
                const items = [];
                while (i < lines.length && isOlItem(lines[i])) {
                    items.push(lines[i].replace(/^\s*\d+\.\s+/, ''));
                    i += 1;
                }
                out.push('<ol>' + items.map(function (it) {
                    return '<li>' + inline(it) + '</li>';
                }).join('') + '</ol>');
                continue;
            }

            // GFM table — header row followed by a separator row.
            if (isTableRow(line) && i + 1 < lines.length && isTableSep(lines[i + 1])) {
                const headers = parseTableCells(line);
                i += 2; // consume header + separator
                const rows = [];
                while (i < lines.length && isTableRow(lines[i]) && !isTableSep(lines[i])) {
                    rows.push(parseTableCells(lines[i]));
                    i += 1;
                }
                let tbl = '<table><thead><tr>';
                for (const h of headers) tbl += '<th>' + inline(h) + '</th>';
                tbl += '</tr></thead>';
                if (rows.length > 0) {
                    tbl += '<tbody>';
                    for (const row of rows) {
                        tbl += '<tr>';
                        for (const cell of row) tbl += '<td>' + inline(cell) + '</td>';
                        tbl += '</tr>';
                    }
                    tbl += '</tbody>';
                }
                tbl += '</table>';
                out.push(tbl);
                continue;
            }

            // Blank line — paragraph separator.
            if (line.trim() === '') {
                i += 1;
                continue;
            }

            // Paragraph — collect contiguous non-block lines.
            // Note: isTableRow lines are intentionally NOT excluded here.
            // A pipe-line that has no separator following it (e.g. a
            // streaming table header that hasn't received its `|---|` row
            // yet) would otherwise stall `i` forever: the table handler
            // skips it (no sep) and the paragraph inner loop also skips it
            // (!isTableRow), leaving para empty and i unmoved → busy-loop.
            const para = [];
            while (i < lines.length
                && lines[i].trim() !== ''
                && !isFenceOpen(lines[i])
                && !isHeading(lines[i])
                && !isUlItem(lines[i])
                && !isOlItem(lines[i])) {
                para.push(lines[i]);
                i += 1;
            }
            if (para.length > 0) {
                out.push('<p>' + inline(para.join('\n')).replace(/\n/g, '<br>') + '</p>');
            } else {
                i += 1; // safety: nothing matched — advance past the stuck line
            }
        }

        return out.join('');
    }

    return { render: render, sanitizeUrl: sanitizeUrl, escapeHtml: escapeHtml };
})();

// ─── Prism syntax highlighting (v1.30.0) ──────────────────────
//
// Runs Prism.highlightElement on every <code> block inside the
// given DOM container. Called after Markdown.render output is
// set as innerHTML so syntax colours apply over the plain
// monospace rendering.
//
// Prism is loaded from /prism.js before app.js runs, so the
// global Prism object is available here. The language class
// (e.g. `lang-python`) is set by the Markdown renderer from
// the code fence info string.
function highlightCodeBlocks(container) {
    if (typeof Prism === 'undefined') return;
    const codes = container.querySelectorAll('pre code[class^="language-"]');
    for (const el of codes) {
        Prism.highlightElement(el);
    }
}

(function () {
    'use strict';

    // Mirrors `agent.types.role_denied_code` — wire-format string
    // the runtime role gate emits as `tool_code` on a denied tool
    // call. Kept in sync by hand; if you rename one, rename both.
    const ROLE_DENIED = 'role_denied';
    const SUBAGENT_TOOL_NAME = 'subagent';
    const EDIT_TOOL_NAME = 'edit';

    const conversation = document.getElementById('conversation');
    const form = document.getElementById('composer');
    const input = document.getElementById('input');
    const sendBtn = document.getElementById('send');
    const statusEl = document.getElementById('status');
    // v1.7.0 — sidebar elements
    const sessionList = document.getElementById('session-list');
    const newSessionBtn = document.getElementById('new-session');
    const sidebarToggle = document.getElementById('sidebar-toggle');
    // v1.7.2 — header activity pill (out-of-flow streaming feedback)
    const activityEl = document.getElementById('activity');
    const activityLabel = activityEl ? activityEl.querySelector('.activity-label') : null;
    // v1.7.3 — slash command palette
    const cmdPaletteEl = document.getElementById('cmd-palette');
    // v1.7.7 — status line + help overlay
    const statusLineEl = document.getElementById('status-line');
    const helpOverlayEl = document.getElementById('help-overlay');
    const helpCloseBtn = document.getElementById('help-close');
    const helpToggleBtn = document.getElementById('help-toggle');
    const helpCmdsEl = document.getElementById('help-commands');
    // vN — Abort button in header. Always visible; just POSTs /interrupt.
    const abortBtn = document.getElementById('abort-btn');
    // v2.19 — design documents panel (right-side drawer)
    const designPanelEl    = document.getElementById('design-panel');
    const designPanelBtn   = document.getElementById('design-panel-btn');
    const designPanelClose = document.getElementById('design-panel-close');
    const designPanelBody  = document.getElementById('design-panel-body');
    // v2.7 — subagent panel (right-side drawer)
    const subagentPanelEl      = document.getElementById('subagent-panel');
    const subagentPanelBody    = document.getElementById('subagent-panel-body');
    const subagentPanelClose   = document.getElementById('sa-panel-close');
    const subagentPanelSubtitle = document.getElementById('sa-panel-subtitle');
    const subagentPanelBtn     = document.getElementById('sa-panel-btn');
    // v2.7 — overlay refs
    const saOverlayEl       = document.getElementById('sa-overlay');
    const saOverlayBackdrop = document.getElementById('sa-overlay-backdrop');
    const saOverlayClose    = document.getElementById('sa-overlay-close');
    const saOverlayBody     = document.getElementById('sa-overlay-body');
    const saOverlayBadge    = saOverlayEl.querySelector('.sa-overlay-badge');
    const saOverlayTitle    = saOverlayEl.querySelector('.sa-overlay-title');
    const saOverlayProfile   = saOverlayEl.querySelector('.sa-overlay-profile');

    /**
     * State for the in-progress assistant message.
     * `blocks[i]` holds the accumulated text for content block `i`,
     * keyed by block_index so concurrent text + thinking streams
     * stay separated. `el` is the message bubble element; null
     * between turns.
     */
    let active = {
        el: null,
        contentEl: null,
        blocks: new Map(),
        thinkingEl: null,
        thinkingBlocks: new Map(),
        // v1.6.2 — live tool-arg streaming. While the assistant
        // message is mid-stream, `toolcall_args` deltas arrive keyed
        // by block_index. We open a "pending" tool card per
        // block_index on first delta and append text into it as
        // more deltas arrive. When `message_end` fires, these cards
        // get moved into `pendingToolCards` (sorted by block_index)
        // for `tool_execution_start` to claim by binding a call_id.
        toolArgs: new Map(), // blockIndex → { el, argsText, argsEl }
    };

    /** call_id → tool-card element. Keeps tool start/end paired. */
    const toolCards = new Map();

    // v2.7 — per-subagent-call section state. callId → state object.
    // Survives across turns; cleared by clearConversation().
    const subagentSections = new Map();
    // v2.31 — buffer tool_execution_update events that arrive before
    // the parent's tool_execution_start (async race). Replayed once
    // the tool card is registered in toolCards.
    const pendingSubagentUpdates = new Map();
    let currentOverlayCallId = null; // null = overlay closed

    /**
     * v1.6.2 — tool cards that opened from streaming `toolcall_args`
     * but are still waiting for their `tool_execution_start` to
     * arrive (which carries the resolved `call_id` + tool `name`).
     * Drained in source order — the agent loop emits
     * `tool_execution_start` events in the same order as the
     * tool_call blocks in the assistant message, so popping the
     * front matches them by position.
     */
    const pendingToolCards = [];

    // vN — event anchors: monotonic counter for generating unique
    // anchor IDs for messages, errors, system messages, etc. Tool
    // calls use their caller-supplied callId directly.
    let nextAnchorId = 1;

    /**
     * Generate a unique anchor ID for a given element type.
     * Messages and system events get `msg-N`, tool calls get
     * `tool-call_{callId}`, errors get `error-N`.
     */
    function anchorIdFor(type, callId) {
        if (type === "tool-call" && callId) return "tool_" + callId;
        const n = nextAnchorId++;
        return type + "-" + n;
    }

    /**
     * vN — on page load and after every session switch, check if
     * the URL hash references an anchor in the conversation. If so,
     * scroll to it and flash a highlight.
     */
    function scrollToAnchor() {
        const hash = window.location.hash;
        if (!hash || hash.length < 2) return;
        const id = hash.slice(1);
        const target = document.getElementById(id);
        if (!target) return;
        requestAnimationFrame(() => {
            target.scrollIntoView({ behavior: "smooth", block: "center" });
            target.classList.add("anchor-highlight");
            setTimeout(() => target.classList.remove("anchor-highlight"), 2000);
        });
    }

    // Listen for hash changes (user navigates back/forward).
    window.addEventListener("hashchange", scrollToAnchor);

    /** Single "assistant is thinking..." indicator between turn_start and message_start. */
    let turnIndicator = null;

    /**
     * v1.7.1 — single source of truth for "a turn is in flight".
     * Set in `submitPrompt`, cleared on `turn_end` / `agent_error`.
     * The `sendBtn.disabled` flag only stops mouse clicks; the
     * Enter-key keydown bypasses it, so we need an explicit guard
     * to prevent double-submission.
     */
    let isStreaming = false;

    /**
     * v1.7.2 — watchdog state. `lastEventAt` is refreshed on every
     * SSE frame (including server-side keepalive `ping` frames in
     * v1.7.4). Tick runs every few seconds; once
     * `watchdogTimeoutMs` of silence has elapsed during a
     * streaming turn we surface an advisory banner — once per
     * turn — without resetting state. The user can choose to
     * keep waiting or click Stop.
     *
     * v1.7.4 — bumped to 5 minutes (was 60 s). The previous
     * threshold false-fired during long thinking phases on
     * slow models. Server keepalive `ping` events fire every
     * 15 s, so under healthy server conditions the watchdog
     * never trips even on multi-minute turns.
     */
    let lastEventAt = 0;
    const watchdogTimeoutMs = 300_000;
    let watchdogWarned = false;

    function setStatus(text, cls) {
        statusEl.textContent = text;
        statusEl.className = 'status ' + cls;
    }

    /**
     * v1.7.2 — update the header activity pill. `label` is a
     * short string ("thinking…", "responding…", "running:
     * read"); empty/null hides the pill (idle state).
     *
     * The pill lives in the header — outside the scrollable
     * conversation pane — so it's always visible regardless of
     * how far the user has scrolled. Animation cue (pulsing dot)
     * confirms the model is alive even when no new content is
     * landing on screen.
     */
    function setActivity(label) {
        if (!activityEl) return;
        if (!label) {
            activityEl.classList.remove('activity-active');
            return;
        }
        if (activityLabel) activityLabel.textContent = label;
        activityEl.classList.add('activity-active');
    }

    /**
     * v1.7.2 — track streaming state. The Abort button is always
     * visible after the first message (ui-driven, no state needed).
     * POSTs /interrupt for a graceful stop — the current turn
     * finishes, then the loop emits `agent_interrupted` and stops.
     */
    function setStreaming(streaming) {
        isStreaming = streaming;
        if (!streaming) {
            setActivity(null);
        }
    }

    /**
     * vN — POST /interrupt to request a graceful stop. Does NOT
     * reset UI state — the SSE handler for `agent_interrupted` or
     * `turn_end` handles that once the loop actually stops. This
     * prevents the race where the UI flips back to "Send" while
     * the agent is still producing output.
     */
    async function abortTurn() {
        try {
            await fetch('/interrupt', { method: 'POST' });
        } catch (_) { /* best-effort */ }
    }

    /**
     * v1.7.1 — smart auto-scroll. Only stick to the bottom if the
     * user is already pinned there (within `pinSlack` px tolerance).
     * If they've scrolled up to read earlier content (thinking
     * blocks, code, etc.) we leave their viewport alone and let the
     * conversation grow off-screen.
     *
     * Without this, every text delta yanked the page back to the
     * bottom, hiding any thinking content the assistant emitted
     * above its main answer (the bug Frank flagged in v1.7.0
     * feedback).
     */
    const pinSlack = 24;

    function isPinnedToBottom() {
        const el = conversation;
        return el.scrollHeight - el.scrollTop - el.clientHeight <= pinSlack;
    }

    function scrollToBottom(force) {
        const shouldScroll = force === true || isPinnedToBottom();
        if (!shouldScroll) return;
        requestAnimationFrame(() => {
            conversation.scrollTop = conversation.scrollHeight;
        });
    }

    function appendUserMessage(text) {
        const el = document.createElement('div');
        el.className = 'message message-user';
        const role = document.createElement('span');
        role.className = 'role';
        role.textContent = 'you';
        const content = document.createElement('span');
        content.className = 'content';
        content.textContent = text;
        el.appendChild(role);
        el.appendChild(content);
        el.id = anchorIdFor("msg");
        conversation.appendChild(el);
        // User just sent a message — force scroll so they see their
        // own bubble even if they were reading scrollback.
        scrollToBottom(true);
    }

    /**
     * v1.6.1 — render a finalized assistant message from the
     * transcript. Unlike the streaming path, this builds the bubble
     * in one shot from the persisted text/thinking blocks.
     */
    function appendFinalizedAssistantMessage(blocks, role) {
        // Skip empty messages (e.g. assistant turn that only emitted
        // a tool call and the call already rendered as a card).
        const hasRenderable = blocks.some(b => b.kind === 'text' || b.kind === 'thinking');
        if (!hasRenderable) return;

        const el = document.createElement('div');
        el.className = 'message message-assistant';
        const roleEl = document.createElement('span');
        roleEl.className = 'role';
        roleEl.textContent = role || 'assistant';
        el.appendChild(roleEl);

        // Thinking first (if any), then text — matches the live render.
        const thinkingText = blocks.filter(b => b.kind === 'thinking').map(b => b.text || '').join('');
        if (thinkingText.length > 0) {
            const t = document.createElement('div');
            t.className = 'thinking';
            t.textContent = thinkingText;
            el.appendChild(t);
        }
        const mainText = blocks.filter(b => b.kind === 'text').map(b => b.text || '').join('');
        if (mainText.length > 0) {
            const c = document.createElement('span');
            c.className = 'content';
            c.innerHTML = Markdown.render(mainText);
            highlightCodeBlocks(c);
            el.appendChild(c);
        }
        el.id = anchorIdFor("msg");
        conversation.appendChild(el);
    }

    const toolRenderers = new Map();

    function renderGenericTable(args, includeKeys) {
        const table = document.createElement('table');
        table.className = 'tool-args-table';
        const tbody = document.createElement('tbody');
        const keys = includeKeys || Object.keys(args);
        for (const key of keys) {
            if (!(key in args)) continue;
            const tr = document.createElement('tr');
            const th = document.createElement('th');
            th.textContent = key;
            const td = document.createElement('td');
            const val = args[key];
            if (typeof val === 'string') {
                if (key === 'path' || key === 'cwd') {
                    th.textContent = '📄';
                    td.appendChild(document.createTextNode(' ' + val));
                } else if (key === 'pattern') {
                    th.textContent = '🔍';
                    td.appendChild(document.createTextNode(' ' + val));
                } else {
                    td.textContent = val;
                }
            } else {
                const code = document.createElement('code');
                code.textContent = JSON.stringify(val);
                td.appendChild(code);
            }
            tr.appendChild(th);
            tr.appendChild(td);
            tbody.appendChild(tr);
        }
        table.appendChild(tbody);
        return table;
    }

    function appendSpan(parent, className, text) {
        const span = document.createElement('span');
        span.className = className;
        span.textContent = text;
        parent.appendChild(span);
    }

    function renderReadArgs(args) {
        const container = document.createElement('div');
        container.className = 'tool-args-render';
        const header = document.createElement('div');
        header.className = 'file-header';
        appendSpan(header, 'file-icon', '📄');
        appendSpan(header, 'file-path', args.path || '(unknown)');
        container.appendChild(header);
        if (args.limit != null || args.offset != null) {
            const meta = document.createElement('div');
            meta.className = 'file-meta';
            const offset = args.offset || 0;
            meta.textContent = args.limit != null
                ? 'Lines ' + (offset + 1) + '–' + (offset + args.limit)
                : 'From line ' + (offset + 1);
            container.appendChild(meta);
        }
        return container;
    }

    function renderBashArgs(args) {
        const container = document.createElement('div');
        container.className = 'tool-args-render';
        const term = document.createElement('div');
        term.className = 'bash-command';
        appendSpan(term, 'bash-prompt', '$');
        const code = document.createElement('code');
        code.textContent = args.command || '';
        term.appendChild(code);
        container.appendChild(term);
        if (args.description) {
            const desc = document.createElement('div');
            desc.className = 'bash-description';
            desc.textContent = args.description;
            container.appendChild(desc);
        }
        if (args.cwd) {
            const cwd = document.createElement('div');
            cwd.className = 'bash-cwd';
            appendSpan(cwd, 'cwd-label', 'cwd:');
            appendSpan(cwd, 'file-icon', '📄');
            container.appendChild(cwd);
        }
        return container;
    }

    toolRenderers.set('read', renderReadArgs);
    toolRenderers.set('bash', renderBashArgs);
    toolRenderers.set('grep', (args) => renderGenericTable(args, ['path', 'pattern']));
    toolRenderers.set('finish_task', (args) => renderGenericTable(args, ['commit_message']));
    function renderWriteArgs(args) {
        const container = document.createElement('div');
        const table = document.createElement('table');
        table.className = 'tool-args-table';
        const tbody = document.createElement('tbody');

        function addRow(key, val) {
            if (!(key in args)) return;
            const tr = document.createElement('tr');
            const th = document.createElement('th');
            th.textContent = key;
            const td = document.createElement('td');
            if (key === 'path' || key === 'cwd') {
                th.textContent = '📄';
                td.appendChild(document.createTextNode(' ' + val));
            } else if (typeof val === 'string') {
                td.textContent = val;
            } else {
                const code = document.createElement('code');
                code.textContent = JSON.stringify(val);
                td.appendChild(code);
            }
            tr.appendChild(th);
            tr.appendChild(td);
            tbody.appendChild(tr);
        }

        addRow('path', args.path);
        addRow('overwrite', args.overwrite);
        if ('content' in args && typeof args.content === 'string') {
            const tr = document.createElement('tr');
            const th = document.createElement('th');
            th.textContent = 'content';
            const td = document.createElement('td');
            const preview = document.createElement('span');
            preview.className = 'content-preview';
            const v = args.content;
            const isLong = v.length > 200;
            const short = isLong ? v.substring(0, 200) + '…' : v;
            preview.textContent = short;
            td.appendChild(preview);
            if (isLong) {
                const toggle = document.createElement('button');
                toggle.type = 'button';
                toggle.className = 'content-expand';
                toggle.textContent = '(' + v.length + ' chars)';
                toggle.addEventListener('click', function () {
                    const expanded = preview.getAttribute('data-expanded') === 'true';
                    if (expanded) {
                        preview.textContent = short;
                        toggle.textContent = '(' + v.length + ' chars)';
                        preview.setAttribute('data-expanded', 'false');
                    } else {
                        preview.textContent = v;
                        toggle.textContent = 'collapse';
                        preview.setAttribute('data-expanded', 'true');
                    }
                });
                td.appendChild(toggle);
            }
            tr.appendChild(th);
            tr.appendChild(td);
            tbody.appendChild(tr);
        }
        table.appendChild(tbody);
        container.appendChild(table);

        return container;
    }

    toolRenderers.set('write', renderWriteArgs);
    toolRenderers.set(EDIT_TOOL_NAME, (args) => renderGenericTable(args, ['path']));
    toolRenderers.set(SUBAGENT_TOOL_NAME, (args) => renderGenericTable(args, ['preset', 'profile']));

    function renderToolArgs(name, argsJson) {
        const args = parseData(argsJson);
        if (!args || typeof args !== 'object' || Array.isArray(args)) return null;
        const renderer = toolRenderers.get(name);
        return renderer ? renderer(args) : renderGenericTable(args);
    }

    function wrapRenderedArgs(rendered, argsJson) {
        const wrapper = document.createElement('div');
        wrapper.className = 'tool-args-wrapper';
        wrapper.appendChild(rendered);

        const rawDiv = document.createElement('div');
        rawDiv.className = 'tool-args-raw';
        rawDiv.hidden = true;
        const pre = document.createElement('pre');
        pre.textContent = argsJson || '';
        rawDiv.appendChild(pre);
        wrapper.appendChild(rawDiv);
        return wrapper;
    }

    function setRenderedArgs(argsEl, name, argsJson) {
        if (!argsEl) return;
        const raw = argsJson || '';
        const rendered = renderToolArgs(name, raw);
        argsEl.textContent = '';
        if (rendered) {
            argsEl.appendChild(wrapRenderedArgs(rendered, raw));
        } else {
            argsEl.textContent = raw;
        }
    }

    function addRawToggle(head, argsEl) {
        if (head.querySelector('.tool-args-raw-toggle')) return;
        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'tool-args-raw-toggle';
        toggle.setAttribute('aria-label', 'Toggle raw JSON');
        toggle.setAttribute('aria-pressed', 'false');
        toggle.textContent = '{ }';
        toggle.addEventListener('click', function () {
            const rawDiv = argsEl.querySelector('.tool-args-raw');
            if (!rawDiv) return;
            const showRaw = rawDiv.hidden;
            rawDiv.hidden = !showRaw;
            toggle.classList.toggle('is-active', showRaw);
            toggle.setAttribute('aria-pressed', String(showRaw));
        });
        head.appendChild(toggle);
    }

    function installToolArgs(head, argsEl, name, argsJson) {
        setRenderedArgs(argsEl, name, argsJson);
        addRawToggle(head, argsEl);
    }

    function appendFinalizedToolCard(callId, name, isError, argsJson, resultText, detailsJson) {
        const el = document.createElement('div');
        el.className = 'tool-card' + (isError ? ' is-error' : '');
        const head = document.createElement('div');
        head.className = 'tool-head';
        head.innerHTML =
            '<span class="tool-name"></span> <span class="tool-status"></span>';
        head.querySelector('.tool-name').textContent = name;
        head.querySelector('.tool-status').textContent = isError ? 'error' : 'done';
        el.appendChild(head);

        const args = document.createElement('div');
        args.className = 'tool-args';
        el.appendChild(args);
        installToolArgs(head, args, name, argsJson);

        if (name === SUBAGENT_TOOL_NAME) {
            attachSubagentPanel(el, callId, argsJson);
            const state = createSubagentSection(callId, argsJson || '');
            if (state) {
                state.done = true;
                state.isError = isError;
                if (state.badgeEl) {
                    state.badgeEl.className = 'sa-badge ' + (isError ? 'error' : 'done');
                    state.badgeEl.textContent = isError ? 'error' : 'done';
                }
                if (resultText) {
                    try {
                        const parsed = JSON.parse(resultText);
                        if (parsed && parsed.final_text) {
                            state.textBlocks.set(0, parsed.final_text);
                        }
                    } catch (_) { /* non-JSON body — keep state.textBlocks empty */ }
                }
            }
            const log = el.querySelector('.subagent-log');
            if (log && resultText) {
                const entry = document.createElement('div');
                entry.className = 'subagent-entry' + (isError ? ' sa-error' : '');
                entry.textContent = (isError ? '⚠ ' : '✓ ') + resultText;
                log.appendChild(entry);
            }
        } else {
            attachResultPanel(el);
            const panel = el.querySelector('.tool-result-log');
            const toggle = el.querySelector('.tool-result-toggle');
            const renderedDiff = !isError && tryRenderDiffPanel(el, panel, toggle, detailsJson);
            if (!renderedDiff && resultText) panel.textContent = resultText;
        }
        el.id = anchorIdFor("tool-call", callId)
        conversation.appendChild(el);
    }

    // Wire-format allowlist for the edit-tool diff view. The producer
    // is `computeUnifiedDiff` in `src/coding/tools/edit.zig`; the
    // parser is `parseUnifiedDiff` below. Bumping the format requires
    // a change on both sides — Zig tests pin the wire bytes.
    const SUPPORTED_DIFF_FORMATS = ['unified-diff-v1'];

    /// Attempt to render `detailsJson` as a unified diff into `panel`.
    /// Returns true on success — caller should skip the plain-text fallback.
    /// `detailsJson` may arrive as an already-parsed object (live SSE path,
    /// where the SSE handler JSON.parses the whole frame) or as a raw JSON
    /// string (rehydration path, if the transcript stores it verbatim).
    function tryRenderDiffPanel(el, panel, toggle, detailsJson) {
        if (!detailsJson) return false;
        const details = (typeof detailsJson === 'string') ? parseData(detailsJson) : detailsJson;
        if (!details || !details.diff) return false;
        // Reject unknown format versions loudly. Missing `format` is
        // tolerated so transcripts persisted before format versioning
        // was added still rehydrate (their diff strings are v1-shaped).
        if (details.format && !SUPPORTED_DIFF_FORMATS.includes(details.format)) {
            console.warn('[franky] unrecognized diff format', details.format,
                '— update SUPPORTED_DIFF_FORMATS in app.js to add support');
            return false;
        }
        renderEditDiffView(el, panel, toggle, details);
        return true;
    }

    function appendError(message) {
        const el = document.createElement('div');
        el.className = 'error-banner';
        el.textContent = message;
        el.id = anchorIdFor("error")
        conversation.appendChild(el);
        // Errors are worth showing — force scroll so the user sees
        // them even if they were reading earlier content.
        scrollToBottom(true);
    }

    // ─── v2.19 — design documents panel ──────────────────────────

    let dpPendingDoc = null;    // doc object waiting for toast Replace
    let dpPendingPrompt = null; // raw prompt string when no doc object is involved

    function dpPromptFor(doc) {
        const templates = {
            decided: `Please implement the design described in ${doc.path}.\nRead the document first, then follow the implementation plan closely.\nStart with the scope marked as v1 / first milestone.`,
            open:    `Let's work through the open design questions in ${doc.path}.\nPlease read the document, summarise the open questions, and help me decide each one.\nAfter every question has a decision mark it with "✓ decided:" and the chosen answer inline.`,
            draft:   `Let's discuss the design in ${doc.path}.\nPlease read the document, identify any open questions or missing decisions, and help me flesh them out.`,
        };
        return templates[doc.category] ?? templates.draft;
    }

    function dpAssessPrompt(doc) {
        return `Read ${doc.path} and check what has been implemented.\nCompare the implementation plan against the code in the files listed under **Affects:**.\nThen:\n- If fully implemented: update the **Status:** line to \`**Status:** implemented\`.\n- If partially implemented: list what is done and what remains, then update to \`**Status:** partially implemented\`.\n- If not started: confirm and leave the status unchanged.`;
    }

    function dpSplitPrompt(doc) {
        return `Read ${doc.path} — it is partially implemented.\nPlease:\n1. Move this file to docs/archive/design/ keeping only the sections that are fully implemented.\n2. Create a new design doc at docs/design/decided/ with only the remaining unimplemented sections, preserving the original decisions and **Affects:** list.\nUpdate the **Status:** line in both files accordingly.`;
    }

    function dpToggle() {
        if (!designPanelEl) return;
        const opening = designPanelEl.hidden;
        designPanelEl.hidden = !opening;
        if (designPanelBtn) designPanelBtn.classList.toggle('is-active', opening);
        if (opening) dpFetch();
    }

    async function dpFetch() {
        if (!designPanelBody) return;
        designPanelBody.innerHTML = '<div class="dp-empty">Loading…</div>';
        let docs;
        try {
            const r = await fetch('/design-docs');
            ({ docs } = await r.json());
        } catch (_) {
            designPanelBody.innerHTML = '<div class="dp-empty">Failed to load.</div>';
            return;
        }
        dpRender(docs || []);
    }

    // Status indicator: dot + tooltip for decided-category docs.
    const dpStatusMeta = {
        decided:     { dot: 'dp-dot-pending',     title: 'Not yet implemented' },
        implemented: { dot: 'dp-dot-implemented',  title: 'Implemented — ready to archive' },
        partial:     { dot: 'dp-dot-partial',      title: 'Partially implemented' },
        unknown:     { dot: 'dp-dot-unknown',      title: 'Implementation status unknown' },
    };

    function dpRender(docs) {
        if (!designPanelBody) return;
        if (docs.length === 0) {
            designPanelBody.innerHTML = '<div class="dp-empty">No design docs found.</div>';
            return;
        }
        const groups = { decided: [], open: [], draft: [] };
        for (const d of docs) {
            const g = groups[d.category] ?? groups.draft;
            g.push(d);
        }
        designPanelBody.innerHTML = '';
        for (const [cat, items] of [['decided', groups.decided], ['open', groups.open], ['draft', groups.draft]]) {
            if (items.length === 0) continue;
            const hdr = document.createElement('div');
            hdr.className = 'dp-group-header';
            hdr.innerHTML = `${cat} <span class="dp-group-count">${items.length}</span>`;
            designPanelBody.appendChild(hdr);
            for (const doc of items) {
                const row = document.createElement('div');
                row.className = 'dp-row';

                // Status dot — only for decided-category docs.
                if (cat === 'decided') {
                    const meta = dpStatusMeta[doc.status] ?? dpStatusMeta.unknown;
                    const dot = document.createElement('span');
                    dot.className = `dp-dot ${meta.dot}`;
                    dot.title = meta.title;
                    row.appendChild(dot);
                }

                const name = document.createElement('span');
                name.className = 'dp-row-name';
                name.textContent = doc.name;
                name.title = doc.path;
                row.appendChild(name);

                // Action buttons — decided-category only, shown on hover via CSS.
                if (cat === 'decided') {
                    const actions = document.createElement('span');
                    actions.className = 'dp-row-actions';

                    if (doc.status === 'implemented') {
                        const archBtn = document.createElement('button');
                        archBtn.className = 'dp-action-btn dp-action-archive';
                        archBtn.textContent = '📦';
                        archBtn.title = 'Archive (move to docs/archive/design/)';
                        archBtn.addEventListener('click', (e) => { e.stopPropagation(); dpArchiveDoc(doc); });
                        actions.appendChild(archBtn);
                    } else if (doc.status === 'partial') {
                        const splitBtn = document.createElement('button');
                        splitBtn.className = 'dp-action-btn dp-action-split';
                        splitBtn.textContent = '✂️';
                        splitBtn.title = 'Split into archive + remaining design doc';
                        splitBtn.addEventListener('click', (e) => { e.stopPropagation(); dpFillComposer(dpSplitPrompt(doc)); });
                        actions.appendChild(splitBtn);
                    } else {
                        const assessBtn = document.createElement('button');
                        assessBtn.className = 'dp-action-btn dp-action-assess';
                        assessBtn.textContent = '🔍';
                        assessBtn.title = 'Assess implementation status';
                        assessBtn.addEventListener('click', (e) => { e.stopPropagation(); dpFillComposer(dpAssessPrompt(doc)); });
                        actions.appendChild(assessBtn);
                    }
                    row.appendChild(actions);
                } else {
                    const badge = document.createElement('span');
                    badge.className = `dp-badge dp-badge-${cat}`;
                    badge.textContent = cat;
                    row.appendChild(badge);
                }

                row.addEventListener('click', () => dpSelectDoc(doc));
                designPanelBody.appendChild(row);
            }
        }
    }

    function dpClose() {
        if (designPanelEl) designPanelEl.hidden = true;
        if (designPanelBtn) designPanelBtn.classList.remove('is-active');
    }

    function dpFillComposer(prompt) {
        dpClose();
        if (!input.value.trim()) {
            input.value = prompt;
            input.focus();
            input.setSelectionRange(0, 0);
        } else {
            dpPendingPrompt = prompt;
            dpShowToast('action');
        }
    }

    async function dpArchiveDoc(doc) {
        dpClose();
        try {
            const r = await fetch('/design-docs/archive', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ path: doc.path }),
            });
            const data = await r.json();
            if (!data.ok) throw new Error('archive failed');
            appendSystemMessage('/design archive', `Archived **${doc.name}** → \`${data.archived}\``, false);
        } catch (err) {
            appendError('Archive failed: ' + (err.message || err));
        }
    }

    function dpSelectDoc(doc) {
        dpFillComposer(dpPromptFor(doc));
    }

    let dpToastNameEl = null;
    function dpShowToast(docName) {
        let toast = document.getElementById('dp-toast');
        if (!toast) {
            toast = document.createElement('div');
            toast.id = 'dp-toast';
            toast.innerHTML =
                '<span class="dp-toast-body"><strong id="dp-toast-name"></strong>Composer not empty — replace?</span>' +
                '<button class="dp-toast-replace">Replace</button>' +
                '<button class="dp-toast-close">×</button>';
            document.body.appendChild(toast);
            dpToastNameEl = toast.querySelector('#dp-toast-name');
            toast.querySelector('.dp-toast-replace').addEventListener('click', () => {
                const prompt = dpPendingPrompt ?? (dpPendingDoc ? dpPromptFor(dpPendingDoc) : '');
                dpPendingPrompt = null;
                dpPendingDoc = null;
                input.value = prompt;
                input.focus();
                input.setSelectionRange(0, 0);
                toast.hidden = true;
            });
            toast.querySelector('.dp-toast-close').addEventListener('click', () => {
                dpPendingPrompt = null;
                dpPendingDoc = null;
                toast.hidden = true;
            });
        }
        dpToastNameEl.textContent = docName + ' — ';
        toast.hidden = false;
    }

    if (designPanelBtn) designPanelBtn.addEventListener('click', dpToggle);
    if (designPanelClose) designPanelClose.addEventListener('click', dpClose);

    function showTurnIndicator() {
        if (turnIndicator) return;
        turnIndicator = document.createElement('div');
        turnIndicator.className = 'indicator';
        turnIndicator.textContent = 'thinking…';
        conversation.appendChild(turnIndicator);
        scrollToBottom();
    }

    function hideTurnIndicator() {
        if (!turnIndicator) return;
        turnIndicator.remove();
        turnIndicator = null;
    }

    function startAssistantMessage(role) {
        // v1.7.1 — defensive: a previous assistant message was
        // never closed (missed `message_end`, mid-stream
        // disconnect, server hiccup, …). Force-close it before
        // opening the new one. The pre-v1.7.1 code early-returned,
        // which silently merged the new message's deltas into the
        // previous bubble — causing the "answer above the question"
        // bug when a user submitted twice in quick succession.
        if (active.el) endAssistantMessage();
        const el = document.createElement('div');
        el.className = 'message message-assistant';
        const roleEl = document.createElement('span');
        roleEl.className = 'role';
        roleEl.textContent = role || 'assistant';
        const content = document.createElement('span');
        content.className = 'content';
        el.appendChild(roleEl);
        el.appendChild(content);
        el.id = anchorIdFor("msg");
        conversation.appendChild(el);
        active = {
            el,
            contentEl: content,
            blocks: new Map(),
            thinkingEl: null,
            thinkingBlocks: new Map(),
            toolArgs: new Map(),
        };
        textDirty = false;
        thinkingDirty = false;
        textHasFence = false;
        hideTurnIndicator();
        scrollToBottom();
    }

    function ensureActiveMessage() {
        if (!active.el) startAssistantMessage('assistant');
    }

    // Reasoning models emit 10K+ thinking_delta events in a single
    // turn; doing the full join+innerHTML+scroll dance per event
    // froze the browser tab. Defer DOM writes to one rAF per active
    // message and only re-render the panes that actually changed.
    let activeRenderScheduled = false;
    let textDirty = false;
    let thinkingDirty = false;
    let textHasFence = false;

    function flushActiveRender() {
        activeRenderScheduled = false;
        if (!active.el) return;
        const wrote = textDirty || thinkingDirty;
        if (textDirty && active.contentEl) {
            const ordered = joinOrderedBlocks(active.blocks);
            if (ordered.length > 0) {
                active.contentEl.innerHTML = Markdown.render(ordered);
                if (textHasFence) highlightCodeBlocks(active.contentEl);
            }
            textDirty = false;
        }
        if (thinkingDirty && active.thinkingEl) {
            active.thinkingEl.textContent = joinOrderedBlocks(active.thinkingBlocks);
            thinkingDirty = false;
        }
        if (wrote) scrollToBottom();
    }

    function scheduleActiveRender() {
        if (activeRenderScheduled) return;
        activeRenderScheduled = true;
        requestAnimationFrame(flushActiveRender);
    }

    function appendTextDelta(blockIndex, delta) {
        ensureActiveMessage();
        const prev = active.blocks.get(blockIndex) || '';
        active.blocks.set(blockIndex, prev + delta);
        textDirty = true;
        if (!textHasFence && delta.indexOf('`') !== -1) {
            // Cheap superset check; the actual fence detection happens
            // on render. Avoids re-scanning the full joined buffer.
            textHasFence = true;
        }
        scheduleActiveRender();
    }

    function appendThinkingDelta(blockIndex, delta) {
        ensureActiveMessage();
        if (!active.thinkingEl) {
            active.thinkingEl = document.createElement('div');
            active.thinkingEl.className = 'thinking';
            active.el.insertBefore(active.thinkingEl, active.contentEl);
        }
        const prev = active.thinkingBlocks.get(blockIndex) || '';
        active.thinkingBlocks.set(blockIndex, prev + delta);
        thinkingDirty = true;
        scheduleActiveRender();
    }

    function endAssistantMessage() {
        if (!active.el) return;
        // Force a synchronous flush of any deferred render so the
        // empty-bubble check below and the DOM hand-off see final state.
        flushActiveRender();
        // If the message ended up empty (tool-only turn), drop the bubble.
        if (active.contentEl.textContent.length === 0 && !active.thinkingEl) {
            active.el.remove();
        }
        // v1.6.2 — move any streaming tool-arg cards into the
        // pending queue, ordered by block_index ascending so the
        // first `tool_execution_start` gets the first card.
        // Defensive: a missing `toolArgs` Map (regression from a
        // bad reset elsewhere) used to throw out of the SSE
        // listener and wedge `setStreaming(false)`. Fall back to
        // an empty iteration instead of throwing.
        if (active.toolArgs) {
            const orderedKeys = [...active.toolArgs.keys()].sort(function (a, b) { return a - b; });
            for (const k of orderedKeys) {
                pendingToolCards.push(active.toolArgs.get(k));
            }
        }
        active = { el: null, contentEl: null, blocks: new Map(), thinkingEl: null, thinkingBlocks: new Map(), toolArgs: new Map() };
    }

    /**
     * v1.6.2 — append a `toolcall_args` delta. Opens a pending
     * tool card on first delta for this block_index; later deltas
     * accumulate into the same card. Arg text renders as plain
     * monospace (it's JSON; no markdown). Truncates to 4 KiB so
     * a runaway provider can't blow up the DOM.
     */
    function appendToolArgsDelta(blockIndex, delta) {
        if (!active.toolArgs) active.toolArgs = new Map();
        let entry = active.toolArgs.get(blockIndex);
        if (!entry) {
            const el = document.createElement('div');
            el.className = 'tool-card is-pending';
            const head = document.createElement('div');
            head.className = 'tool-head';
            head.innerHTML =
                '<span class="tool-name">…</span> <span class="tool-status">streaming args…</span>';
            const argsEl = document.createElement('div');
            argsEl.className = 'tool-args';
            el.appendChild(head);
            el.appendChild(argsEl);
            conversation.appendChild(el);
            entry = { el: el, argsText: '', argsEl: argsEl };
            active.toolArgs.set(blockIndex, entry);
        }
        entry.argsText += delta;
        if (entry.argsText.length > 4096) {
            entry.argsEl.textContent = entry.argsText.slice(0, 4096) + '… [truncated]';
        } else {
            entry.argsEl.textContent = entry.argsText;
        }
        scrollToBottom();
    }

    function startToolCall(callId, name, argsJson) {
        // Tools render between assistant messages, so close out any
        // active assistant bubble first — the next message_start will
        // open a new one. `endAssistantMessage` also drains streaming
        // `toolcall_args` cards into `pendingToolCards`.
        endAssistantMessage();

        // v1.6.2 — if we already opened a card from streaming args,
        // claim it now: bind the call_id, surface the tool name,
        // flip status from "streaming args…" to "running…".
        if (pendingToolCards.length > 0) {
            const card = pendingToolCards.shift();
            card.el.classList.remove('is-pending');
            const nameEl = card.el.querySelector('.tool-name');
            if (nameEl) nameEl.textContent = name;
            const status = card.el.querySelector('.tool-status');
            if (status) status.textContent = 'running…';
            const argsEl = card.el.querySelector('.tool-args');
            const headEl = card.el.querySelector('.tool-head');
            if (headEl && argsEl) installToolArgs(headEl, argsEl, name, argsJson);
            if (name === SUBAGENT_TOOL_NAME) {
                attachSubagentPanel(card.el, callId, argsJson);
                createSubagentSection(callId, argsJson || '');
                openSubagentPanel();
            } else {
                attachResultPanel(card.el);
            }
            if (name === EDIT_TOOL_NAME) card.el.classList.add('is-edit');
            card.el.id = anchorIdFor("tool-call", callId)
            toolCards.set(callId, card.el);
            scrollToBottom();
            return;
        }

        // No pending card (provider didn't stream toolcall_args, or
        // the args came outside an assistant message) — open a
        // fresh card. Matches the v1.5.0 behavior.
        const el = document.createElement('div');
        el.className = 'tool-card';
        if (name === EDIT_TOOL_NAME) el.classList.add('is-edit');
        const head = document.createElement('div');
        head.className = 'tool-head';
        head.innerHTML =
            '<span class="tool-name"></span> <span class="tool-status">running…</span>';
        head.querySelector('.tool-name').textContent = name;
        const args = document.createElement('div');
        args.className = 'tool-args';
        el.appendChild(head);
        el.appendChild(args);
        installToolArgs(head, args, name, argsJson);

        if (name === SUBAGENT_TOOL_NAME) {
            attachSubagentPanel(el, callId, argsJson);
            createSubagentSection(callId, argsJson || '');
            openSubagentPanel();
        } else {
            attachResultPanel(el);
        }
        el.id = anchorIdFor("tool-call", callId)
        conversation.appendChild(el);
        toolCards.set(callId, el);
        scrollToBottom();
    }

    function endToolCall(callId, isError, toolCode, resultText, detailsJson) {
        finalizeSubagentSection(callId, isError);
        const el = toolCards.get(callId);
        if (!el) return;
        toolCards.delete(callId);
        const denied = toolCode === ROLE_DENIED;
        const status = el.querySelector('.tool-status');
        if (status) status.textContent = denied ? 'denied (role)' : isError ? 'error' : 'done';
        if (isError) el.classList.add('is-error');
        if (denied) el.classList.add('is-role-denied');

        const toggle = el.querySelector('.tool-result-toggle');

        // For subagent cards: append result as a final entry in the
        // shared progress log so there is only one panel + one button.
        const saLog = el.querySelector('.subagent-log');
        if (saLog) {
            if (resultText) {
                const entry = document.createElement('div');
                entry.className = 'subagent-entry' + (isError ? ' sa-error' : '');
                entry.textContent = (isError ? '⚠ ' : '✓ ') + resultText;
                saLog.appendChild(entry);
            }
            if (isError) expandResultPanel(toggle, saLog);
            return;
        }

        const panel = el.querySelector('.tool-result-log');
        if (!isError && tryRenderDiffPanel(el, panel, toggle, detailsJson)) return;

        if (resultText) {
            panel.textContent = resultText;
            if (isError) expandResultPanel(toggle, panel);
        }
    }

    /// Render a visual diff into a tool card. Adds the `is-edit`
    /// class, auto-expands the result panel, and adds a unified ↔
    /// side-by-side toggle button. The diff string is parsed and
    /// rendered by `renderDiffHtml` (in-house, no CDN dependency).
    function renderEditDiffView(cardEl, panelEl, toggleEl, details) {
        cardEl.classList.add('is-edit');
        expandResultPanel(toggleEl, panelEl);

        // Memoize per-mode rendered HTML so toggling between
        // unified and side-by-side doesn't re-parse the diff.
        const cache = {};
        function show(mode) {
            if (!cache[mode]) cache[mode] = renderDiffHtml(details.diff, mode, details.path);
            panelEl.innerHTML = cache[mode];
        }

        let currentMode = 'line-by-line';
        const viewToggle = document.createElement('button');
        viewToggle.className = 'diff-view-toggle';
        viewToggle.textContent = 'Side-by-side';
        viewToggle.addEventListener('click', function () {
            currentMode = (currentMode === 'line-by-line') ? 'side-by-side' : 'line-by-line';
            viewToggle.textContent = (currentMode === 'line-by-line') ? 'Side-by-side' : 'Unified';
            show(currentMode);
        });
        const head = cardEl.querySelector('.tool-head');
        if (head) head.appendChild(viewToggle);

        show(currentMode);
    }

    /// Render a unified-diff string into HTML using our own
    /// renderer (no external dependency). Returns escaped text on
    /// any unexpected error so the caller still sees something.
    ///
    /// The diff format is:
    ///   --- a/<path>
    ///   +++ b/<path>
    ///   @@ -<oldStart>,<oldCount> +<newStart>,<newCount> @@
    ///    context
    ///   -removed
    ///   +added
    ///
    /// We emit either a unified (one column) or side-by-side (two
    /// stacked tables) rendering with our own classes — see
    /// `.franky-diff` rules in style.css.
    function renderDiffHtml(diffString, mode, _filePath) {
        try {
            const hunks = parseUnifiedDiff(diffString);
            if (mode === 'side-by-side') return renderDiffSideBySide(hunks);
            return renderDiffUnified(hunks);
        } catch (_) {
            return escHtml(diffString);
        }
    }

    /// Parse a unified-diff string produced by `computeUnifiedDiff`
    /// in `src/coding/tools/edit.zig`. The accepted grammar:
    ///   `--- a/<path>` and `+++ b/<path>` file headers (skipped).
    ///   `@@ -<old>(,<count>)? +<new>(,<count>)? @@` hunk headers.
    ///   Body lines starting with ' ' (context), '-' (remove), '+' (add).
    /// If you change this grammar, update `computeUnifiedDiff` AND the
    /// golden/structural tests in `edit.zig` (§v2.8 block) — and bump
    /// `SUPPORTED_DIFF_FORMATS` above.
    function parseUnifiedDiff(diffString) {
        const lines = diffString.split('\n');
        const hunks = [];
        let current = null;
        for (const line of lines) {
            if (line.startsWith('--- ') || line.startsWith('+++ ')) continue;
            if (line.startsWith('@@')) {
                const m = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(line);
                if (!m) continue;
                if (current) hunks.push(current);
                current = {
                    oldStart: parseInt(m[1], 10),
                    newStart: parseInt(m[3], 10),
                    header: line,
                    ops: [],
                };
                continue;
            }
            if (!current) continue;
            if (line.length === 0) continue;
            const prefix = line[0];
            const text = line.slice(1);
            if (prefix === ' ') current.ops.push({ kind: 'keep', text: text });
            else if (prefix === '-') current.ops.push({ kind: 'remove', text: text });
            else if (prefix === '+') current.ops.push({ kind: 'add', text: text });
        }
        if (current) hunks.push(current);
        return hunks;
    }

    function renderDiffUnified(hunks) {
        let html = '<div class="franky-diff franky-diff-unified"><table>'
            + '<colgroup><col style="width:44px"><col style="width:44px"><col></colgroup>'
            + '<tbody>';
        for (const hunk of hunks) {
            html += '<tr class="fd-info"><td colspan="3">' + escHtml(hunk.header) + '</td></tr>';
            let oldNum = hunk.oldStart;
            let newNum = hunk.newStart;
            for (const op of hunk.ops) {
                if (op.kind === 'keep') {
                    html += diffRowU('cntx', oldNum, newNum, ' ', op.text);
                    oldNum++; newNum++;
                } else if (op.kind === 'remove') {
                    html += diffRowU('del', oldNum, '', '−', op.text);
                    oldNum++;
                } else {
                    html += diffRowU('ins', '', newNum, '+', op.text);
                    newNum++;
                }
            }
        }
        html += '</tbody></table></div>';
        return html;
    }

    function diffRowU(kind, oldNum, newNum, glyph, text) {
        return '<tr class="fd-' + kind + '">'
            + '<td class="fd-num">' + oldNum + '</td>'
            + '<td class="fd-num">' + newNum + '</td>'
            + '<td class="fd-line">' + diffPrefix(glyph) + diffContent(text) + '</td></tr>';
    }

    function renderDiffSideBySide(hunks) {
        let left = '<table class="fd-side-table"><colgroup><col style="width:44px"><col></colgroup><tbody>';
        let right = '<table class="fd-side-table"><colgroup><col style="width:44px"><col></colgroup><tbody>';
        for (const hunk of hunks) {
            const info = '<tr class="fd-info"><td colspan="2">' + escHtml(hunk.header) + '</td></tr>';
            left += info;
            right += info;
            let oldNum = hunk.oldStart;
            let newNum = hunk.newStart;
            let i = 0;
            while (i < hunk.ops.length) {
                const op = hunk.ops[i];
                if (op.kind === 'keep') {
                    left += diffRowS('cntx', oldNum, ' ', op.text);
                    right += diffRowS('cntx', newNum, ' ', op.text);
                    oldNum++; newNum++; i++;
                } else {
                    const dels = [], adds = [];
                    while (i < hunk.ops.length && hunk.ops[i].kind !== 'keep') {
                        if (hunk.ops[i].kind === 'remove') dels.push(hunk.ops[i]);
                        else adds.push(hunk.ops[i]);
                        i++;
                    }
                    const len = Math.max(dels.length, adds.length);
                    for (let j = 0; j < len; j++) {
                        if (j < dels.length) {
                            left += diffRowS('del', oldNum, '−', dels[j].text);
                            oldNum++;
                        } else {
                            left += diffRowS('empty', '', '', '');
                        }
                        if (j < adds.length) {
                            right += diffRowS('ins', newNum, '+', adds[j].text);
                            newNum++;
                        } else {
                            right += diffRowS('empty', '', '', '');
                        }
                    }
                }
            }
        }
        left += '</tbody></table>';
        right += '</tbody></table>';
        return '<div class="franky-diff franky-diff-side"><div class="fd-side-pair">'
            + '<div class="fd-side-col">' + left + '</div>'
            + '<div class="fd-side-col">' + right + '</div>'
            + '</div></div>';
    }

    function diffRowS(kind, num, glyph, text) {
        return '<tr class="fd-' + kind + '">'
            + '<td class="fd-num">' + num + '</td>'
            + '<td class="fd-line">' + diffPrefix(glyph) + diffContent(text) + '</td></tr>';
    }

    /// Render the leading `<span class="fd-prefix">` cell. Empty
    /// or single-space glyph collapses to a non-breaking space so
    /// the gutter column always has a stable width.
    function diffPrefix(glyph) {
        if (!glyph || glyph === ' ') return '<span class="fd-prefix">&nbsp;</span>';
        return '<span class="fd-prefix">' + escHtml(glyph) + '</span>';
    }

    /// Render the `<span class="fd-ctn">` cell. Blank lines render
    /// as `&nbsp;` so the row keeps its line-height; the row tint
    /// (via the parent `<tr>` class) still signals the change.
    function diffContent(text) {
        return '<span class="fd-ctn">' + (text.length === 0 ? '&nbsp;' : escHtml(text)) + '</span>';
    }

    // v1.11.4 — permission-prompt modal. Renders an inline card
    // in the conversation pane (not a dialog overlay) so the
    // request stays in the transcript context. Buttons POST to
    // /permission/resolve and dismiss the card on success;
    // server-side resolve wakes the worker, the next tool event
    // appends below.
    function renderPermissionModal(req) {
        const el = document.createElement('div');
        el.className = 'permission-modal';
        el.dataset.callId = req.callId;

        const head = document.createElement('div');
        head.className = 'permission-head';
        head.textContent = '🔒 permission required: ' + req.toolName +
            ' (fingerprint: ' + req.fingerprint + ')';
        el.appendChild(head);

        const args = document.createElement('pre');
        args.className = 'permission-args';
        args.textContent = req.argsJson;
        el.appendChild(args);

        const buttons = document.createElement('div');
        buttons.className = 'permission-buttons';
        const choices = [
            { key: 'allow_once', label: 'Allow once', kind: 'allow' },
            { key: 'always_allow', label: 'Always allow', kind: 'allow' },
            { key: 'deny_once', label: 'Deny once', kind: 'deny' },
            { key: 'always_deny', label: 'Always deny', kind: 'deny' },
        ];
        let resolving = false;
        for (const c of choices) {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'permission-btn permission-btn-' + c.kind;
            btn.textContent = c.label;
            btn.addEventListener('click', async () => {
                if (resolving) return;
                resolving = true;
                for (const b of buttons.querySelectorAll('button')) b.disabled = true;
                try {
                    const r = await fetch('/permission/resolve', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ call_id: req.callId, resolution: c.key }),
                    });
                    if (r.ok) {
                        // Replace the modal with a compact result line.
                        const result = document.createElement('div');
                        result.className = 'permission-result permission-result-' + c.kind;
                        result.textContent = (c.kind === 'allow' ? '✓ allowed: ' : '✗ denied: ') +
                            req.toolName + ' (' + c.key + ')';
                        el.replaceWith(result);
                    } else {
                        head.textContent = '⚠ resolve failed (HTTP ' + r.status + ') — try again';
                        for (const b of buttons.querySelectorAll('button')) b.disabled = false;
                        resolving = false;
                    }
                } catch (_) {
                    head.textContent = '⚠ network error — try again';
                    for (const b of buttons.querySelectorAll('button')) b.disabled = false;
                    resolving = false;
                }
            });
            buttons.appendChild(btn);
        }
        el.appendChild(buttons);

        conversation.appendChild(el);
        scrollToBottom();
    }

    // ── v2.6 helpers ─────────────────────────────────────────────

    const ESC_HTML_MAP = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };
    function escHtml(s) {
        return String(s).replace(/[&<>"]/g, function (c) { return ESC_HTML_MAP[c]; });
    }

    function joinOrderedBlocks(m) {
        return [...m.entries()].sort((a, b) => a[0] - b[0]).map(([, t]) => t).join('');
    }

    function setBadge(el, label, extraClass) {
        el.className = 'sa-badge' + (extraClass ? ' ' + extraClass : '') + ' ' + label;
        el.textContent = label;
    }

    /// Wire up the collapsible result panel on every tool card.
    /// Populated and optionally expanded by endToolCall.
    function attachResultPanel(el) {
        const head = el.querySelector('.tool-head');

        const panel = document.createElement('div');
        panel.className = 'tool-result-log';
        panel.setAttribute('hidden', '');
        el.appendChild(panel);

        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'tool-result-toggle';
        toggle.setAttribute('aria-expanded', 'false');
        toggle.textContent = '▶';
        toggle.addEventListener('click', () => {
            const expanded = toggle.getAttribute('aria-expanded') === 'true';
            if (expanded) {
                toggle.setAttribute('aria-expanded', 'false');
                toggle.textContent = '▶';
                panel.setAttribute('hidden', '');
            } else {
                toggle.setAttribute('aria-expanded', 'true');
                toggle.textContent = '▼';
                panel.removeAttribute('hidden');
            }
        });
        if (head) head.appendChild(toggle);
    }

    function expandResultPanel(toggleEl, panelEl) {
        if (!toggleEl) return;
        toggleEl.setAttribute('aria-expanded', 'true');
        toggleEl.textContent = '▼';
        if (panelEl) panelEl.removeAttribute('hidden');
    }

    /// Wire up the collapsible sub-agent progress panel on a tool card.
    /// Called from startToolCall for both fresh cards and claimed
    /// pending cards (streaming providers open a pending card before
    /// tool_execution_start fires, so both paths must call this).
    function attachSubagentPanel(el, callId, argsJson) {
        el.classList.add('tool-card-subagent');

        // ↗ overlay-open button in the card corner
        const openBtn = document.createElement('button');
        openBtn.type = 'button';
        openBtn.className = 'sa-card-open';
        openBtn.textContent = '↗';
        openBtn.title = 'Open full sub-agent conversation';
        openBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            openSubagentOverlay(callId);
        });
        el.appendChild(openBtn);

        const head = el.querySelector('.tool-head');

        const log = document.createElement('div');
        log.className = 'subagent-log';
        log.setAttribute('hidden', '');
        el.appendChild(log);

        // Prompt field shown at the top of the expandable log
        if (argsJson) {
            try {
                const parsed = JSON.parse(argsJson);
                if (parsed && parsed.prompt) {
                    const promptRow = document.createElement('div');
                    promptRow.className = 'subagent-prompt';
                    const label = document.createElement('span');
                    label.className = 'subagent-prompt-label';
                    label.textContent = 'prompt: ';
                    const text = document.createElement('span');
                    text.className = 'subagent-prompt-text';
                    text.textContent = parsed.prompt;
                    promptRow.appendChild(label);
                    promptRow.appendChild(text);
                    log.appendChild(promptRow);
                }
            } catch (_) {}
        }

        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'tool-result-toggle';
        toggle.setAttribute('aria-expanded', 'false');
        toggle.textContent = '▶';
        toggle.addEventListener('click', () => {
            const expanded = toggle.getAttribute('aria-expanded') === 'true';
            if (expanded) {
                toggle.setAttribute('aria-expanded', 'false');
                toggle.textContent = '▶';
                log.setAttribute('hidden', '');
            } else {
                toggle.setAttribute('aria-expanded', 'true');
                toggle.textContent = '▼';
                log.removeAttribute('hidden');
            }
        });
        if (head) head.appendChild(toggle);

        el._saTools = new Map();
    }

    /// Append one sub-agent progress entry to the subagent log panel.
    function appendSubagentEntry(card, log, upd) {
        const kind = upd.kind;
        let el = null;

        if (kind === 'turn_start' || kind === 'turn_end') {
            return; // no-op — turn counter removed per UX feedback

        } else if (kind === 'tool_start') {
            el = document.createElement('div');
            el.className = 'subagent-entry';
            const argsHtml = upd.args
                ? ' <span class="sa-args">' + escHtml(upd.args) + '</span>'
                : '';
            el.innerHTML = '→ ' + escHtml(upd.name || '') + argsHtml +
                ' <span class="sa-status">running</span>';
            if (!card._saTools) card._saTools = new Map();
            card._saTools.set(upd.cid, el);

        } else if (kind === 'tool_end') {
            if (!card._saTools) return;
            const entry = card._saTools.get(upd.cid);
            if (entry) {
                const statusEl = entry.querySelector('.sa-status');
                if (statusEl) {
                    if (upd.ok === false) {
                        statusEl.textContent = 'error';
                        statusEl.classList.add('is-error');
                    } else {
                        statusEl.textContent = 'done';
                        statusEl.classList.add('done');
                    }
                }
            }
            return; // no new element to append

        } else if (kind === 'error') {
            el = document.createElement('div');
            el.className = 'subagent-entry sa-error';
            el.textContent = '⚠ ' + (upd.msg || 'error');
            // Auto-expand panel on error if currently collapsed.
            const toggle = card.querySelector('.tool-result-toggle');
            if (toggle && toggle.getAttribute('aria-expanded') !== 'true') {
                toggle.setAttribute('aria-expanded', 'true');
                toggle.textContent = '▼';
                log.removeAttribute('hidden');
            }

        }

        if (el) {
            log.appendChild(el);
            // Auto-scroll the log if already near the bottom.
            const atBottom = conversation.scrollHeight - conversation.scrollTop - conversation.clientHeight < 80;
            if (atBottom) scrollToBottom();
        }
    }

    // ── v2.7 — subagent panel helpers ────────────────────────────

    function openSubagentPanel() {
        if (!subagentPanelEl) return;
        subagentPanelEl.removeAttribute('hidden');
        if (subagentPanelBtn) subagentPanelBtn.removeAttribute('hidden');
        updateSubagentPanelSubtitle();
    }

    function closeSubagentPanel() {
        if (subagentPanelEl) subagentPanelEl.setAttribute('hidden', '');
    }

    function updateSubagentPanelSubtitle() {
        if (!subagentPanelSubtitle) return;
        const running = [...subagentSections.values()].filter(s => !s.done).length;
        subagentPanelSubtitle.textContent = running > 0 ? running + ' running' : '';
    }

    // ── v2.7 — overlay open/close ─────────────────────────────────

    function openSubagentOverlay(callId) {
        const state = subagentSections.get(callId);
        if (!state || !saOverlayEl) return;
        currentOverlayCallId = callId;

        setBadge(saOverlayBadge, state.done ? (state.isError ? 'error' : 'done') : 'running', 'sa-overlay-badge');
        saOverlayTitle.textContent = state.preset;
        if (saOverlayProfile) {
            saOverlayProfile.textContent = state.profile || '';
        }

        saOverlayBody.innerHTML = '';
        // Clear live-update overlay refs before re-rendering
        state._overlayTextEl = null;
        state._overlayThinkingEl = null;
        state._overlayThinkingArrow = null;
        state._overlayToolEls = null;
        renderSubagentOverlayContent(state);

        saOverlayEl.removeAttribute('hidden');
        document.body.style.overflow = 'hidden';
    }

    function closeSubagentOverlay() {
        if (!saOverlayEl) return;
        saOverlayEl.setAttribute('hidden', '');
        currentOverlayCallId = null;
        document.body.style.overflow = '';
    }

    // ── v2.7 — overlay content rendering ─────────────────────────

    function buildOverlayThinkingEl(text, done) {
        const wrapper = document.createElement('div');
        wrapper.className = 'sa-thinking';
        const label = document.createElement('div');
        label.className = 'sa-thinking-label';
        const arrow = document.createElement('span');
        arrow.textContent = done ? '▶' : '▼';
        label.append(arrow, document.createTextNode(' thinking'));
        const content = document.createElement('div');
        content.className = 'sa-thinking-content';
        content.textContent = text;
        if (done) content.setAttribute('hidden', '');
        label.addEventListener('click', () => {
            const open = !content.hasAttribute('hidden');
            if (open) { content.setAttribute('hidden', ''); arrow.textContent = '▶'; }
            else       { content.removeAttribute('hidden');  arrow.textContent = '▼'; }
        });
        wrapper.append(label, content);
        return wrapper;
    }

    function buildOverlayEventEl(ev) {
        if (ev.kind === 'tool_start') {
            const el = document.createElement('div');
            el.className = 'sa-tool-entry';
            el.innerHTML =
                '<span class="sa-tool-arrow">→</span>' +
                '<span class="sa-tool-name">' + escHtml(ev.name || '') + '</span>' +
                '<span class="sa-tool-args">'  + escHtml(ev.args || '') + '</span>' +
                '<span class="sa-tool-status running">running</span>';
            return el;
        }
        if (ev.kind === 'error') {
            const el = document.createElement('div');
            el.className = 'sa-text';
            el.style.color = 'var(--error-border)';
            el.textContent = '⚠ ' + (ev.msg || 'error');
            return el;
        }
        return null; // tool_end is a mutation, not a new element
    }

    function renderSubagentOverlayContent(state) {
        if (state.thinkingBlocks.size > 0) {
            const block = buildOverlayThinkingEl(joinOrderedBlocks(state.thinkingBlocks), state.done);
            saOverlayBody.appendChild(block);
            state._overlayThinkingEl    = block.querySelector('.sa-thinking-content');
            state._overlayThinkingArrow = block.querySelector('.sa-thinking-label span');
        }

        if (state.textBlocks.size > 0) {
            const el = document.createElement('div');
            el.className = 'sa-text';
            const ordered = joinOrderedBlocks(state.textBlocks);
            el.innerHTML = Markdown.render(ordered);
            if (ordered.includes('```')) highlightCodeBlocks(el);
            saOverlayBody.appendChild(el);
            state._overlayTextEl = el;
        }

        for (const ev of state.eventLog) {
            if (ev.kind === 'tool_end') {
                if (state._overlayToolEls) {
                    const startEl = state._overlayToolEls.get(ev.cid);
                    if (startEl) {
                        const s = startEl.querySelector('.sa-tool-status');
                        if (s) {
                            const ok = ev.ok !== false;
                            s.className = 'sa-tool-status ' + (ok ? 'done' : 'error');
                            s.textContent = ok ? 'done' : 'error';
                        }
                    }
                }
                continue;
            }
            const el = buildOverlayEventEl(ev);
            if (!el) continue;
            saOverlayBody.appendChild(el);
            if (ev.kind === 'tool_start') {
                if (!state._overlayToolEls) state._overlayToolEls = new Map();
                state._overlayToolEls.set(ev.cid, el);
            }
        }
    }

    // ── v2.7 — compact panel section (replaces expanded section) ──

    function createSubagentSection(callId, argsJson) {
        if (!subagentPanelEl) return null;

        let preset = 'subagent';
        let profile = '';
        try {
            const args = JSON.parse(argsJson || '{}');
            if (args.preset) preset = args.preset;
            if (args.profile) profile = args.profile;
        } catch (_) {}

        const rowEl = document.createElement('div');
        rowEl.className = 'sa-row';

        const titleEl = document.createElement('span');
        titleEl.className = 'sa-row-title';
        titleEl.textContent = preset;

        const openHint = document.createElement('span');
        openHint.className = 'sa-row-open';
        openHint.textContent = '↗';

        const badgeEl = document.createElement('span');
        badgeEl.className = 'sa-badge running';
        badgeEl.textContent = 'running';

        rowEl.append(titleEl, openHint, badgeEl);
        rowEl.addEventListener('click', () => openSubagentOverlay(callId));
        subagentPanelBody.appendChild(rowEl);

        const state = {
            preset,
            profile,
            rowEl, badgeEl,
            textBlocks: new Map(),
            thinkingBlocks: new Map(),
            eventLog: [],
            done: false,
            isError: false,
            // Overlay DOM refs — set when overlay is open for this callId
            _overlayTextEl: null,
            _overlayThinkingEl: null,
            _overlayThinkingArrow: null,
            _overlayToolEls: null,
        };
        subagentSections.set(callId, state);
        return state;
    }

    function appendSubagentPanelEvent(callId, upd) {
        const state = subagentSections.get(callId);
        if (!state) return;
        const kind = upd.kind;

        if (kind === 'text_delta') {
            const bi = upd.block ?? 0;
            state.textBlocks.set(bi, (state.textBlocks.get(bi) || '') + (upd.delta || ''));
            if (currentOverlayCallId === callId && saOverlayBody) {
                if (!state._overlayTextEl) {
                    state._overlayTextEl = document.createElement('div');
                    state._overlayTextEl.className = 'sa-text';
                    saOverlayBody.appendChild(state._overlayTextEl);
                }
                const ordered = joinOrderedBlocks(state.textBlocks);
                state._overlayTextEl.innerHTML = Markdown.render(ordered);
            }

        } else if (kind === 'thinking_delta') {
            const bi = upd.block ?? 0;
            state.thinkingBlocks.set(bi, (state.thinkingBlocks.get(bi) || '') + (upd.delta || ''));
            if (currentOverlayCallId === callId && saOverlayBody) {
                const ordered = joinOrderedBlocks(state.thinkingBlocks);
                if (!state._overlayThinkingEl) {
                    const block = buildOverlayThinkingEl(ordered, false);
                    saOverlayBody.insertBefore(block, saOverlayBody.firstChild);
                    state._overlayThinkingEl    = block.querySelector('.sa-thinking-content');
                    state._overlayThinkingArrow = block.querySelector('.sa-thinking-label span');
                } else {
                    state._overlayThinkingEl.textContent = ordered;
                    state._overlayThinkingEl.removeAttribute('hidden');
                    if (state._overlayThinkingArrow) state._overlayThinkingArrow.textContent = '▼';
                }
            }

        } else if (kind === 'tool_start') {
            const entry = { kind: 'tool_start', name: upd.name, cid: upd.cid, args: upd.args };
            state.eventLog.push(entry);
            if (currentOverlayCallId === callId && saOverlayBody) {
                const el = buildOverlayEventEl(entry);
                if (el) {
                    saOverlayBody.appendChild(el);
                    if (!state._overlayToolEls) state._overlayToolEls = new Map();
                    state._overlayToolEls.set(upd.cid, el);
                }
            }

        } else if (kind === 'tool_end') {
            state.eventLog.push({ kind: 'tool_end', cid: upd.cid, ok: upd.ok });
            if (currentOverlayCallId === callId && state._overlayToolEls) {
                const el = state._overlayToolEls.get(upd.cid);
                if (el) {
                    const s = el.querySelector('.sa-tool-status');
                    if (s) {
                        const ok = upd.ok !== false;
                        s.className = 'sa-tool-status ' + (ok ? 'done' : 'error');
                        s.textContent = ok ? 'done' : 'error';
                    }
                }
            }

        } else if (kind === 'error') {
            state.eventLog.push({ kind: 'error', msg: upd.msg });
            if (currentOverlayCallId === callId && saOverlayBody) {
                const el = buildOverlayEventEl({ kind: 'error', msg: upd.msg });
                if (el) saOverlayBody.appendChild(el);
            }
        }

        if (kind !== 'tool_end' && currentOverlayCallId === callId && saOverlayBody) {
            const atBottom = saOverlayBody.scrollHeight
                - saOverlayBody.scrollTop - saOverlayBody.clientHeight < 80;
            if (atBottom) saOverlayBody.scrollTop = saOverlayBody.scrollHeight;
        }
    }

    function finalizeSubagentSection(callId, isError) {
        const state = subagentSections.get(callId);
        if (!state) return;
        state.done = true;
        state.isError = isError;

        const label = isError ? 'error' : 'done';
        setBadge(state.badgeEl, label);
        if (currentOverlayCallId === callId)
            setBadge(saOverlayBadge, label, 'sa-overlay-badge');

        // Collapse thinking in overlay if open
        if (currentOverlayCallId === callId && state._overlayThinkingEl) {
            state._overlayThinkingEl.setAttribute('hidden', '');
            if (state._overlayThinkingArrow) state._overlayThinkingArrow.textContent = '▶';
        }

        updateSubagentPanelSubtitle();
    }

    // ── EventSource wiring ───────────────────────────────────────

    function connect() {
        setStatus('connecting…', 'status-idle');
        const es = new EventSource('/events');

        es.addEventListener('open', () => setStatus('live', 'status-live'));

        es.addEventListener('error', () => {
            setStatus('disconnected', 'status-error');
        });

        // v1.7.2 — refresh the watchdog timestamp on every SSE
        // frame. Each named handler below stamps `lastEventAt`
        // inline. The watchdog tick reads it to decide whether
        // a missed `turn_end` left us hanging.
        function noteEvent() { lastEventAt = Date.now(); }

        es.addEventListener('turn_start', () => {
            noteEvent();
            // v1.7.2 — header pill replaces the in-flow "thinking…"
            // indicator as the canonical activity cue. We keep the
            // in-flow indicator too for backwards compat but the
            // pill is what users see when they've scrolled away.
            setActivity('thinking…');
            if (!active.el && toolCards.size === 0) showTurnIndicator();
        });

        es.addEventListener('turn_end', () => {
            noteEvent();
            endAssistantMessage();
            hideTurnIndicator();
            setStreaming(false);            // v1.7.2 (replaces v1.7.1 plumbing)
            stopStatusLineTimer();          // v1.7.7
            refreshStatusLineUsage();
            input.focus();
        });

        es.addEventListener('message_start', (e) => {
            noteEvent();
            const data = parseData(e.data);
            startAssistantMessage(data && data.role);
            // v1.7.2 — assistant just started speaking; flip the
            // pill from "thinking…" to "responding…".
            if (data && data.role === 'assistant') setActivity('responding…');
        });

        es.addEventListener('message_update', (e) => {
            noteEvent();
            const data = parseData(e.data);
            if (!data) return;
            switch (data.deltaKind) {
                case 'text':
                    appendTextDelta(data.blockIndex || 0, data.delta || '');
                    setActivity('responding…');
                    break;
                case 'thinking':
                    appendThinkingDelta(data.blockIndex || 0, data.delta || '');
                    setActivity('thinking…');
                    break;
                case 'toolcall_args':
                    // v1.6.2 — open a pending tool card on first
                    // delta for this block_index, append further
                    // deltas into it. `tool_execution_start` claims
                    // the card later by binding a call_id.
                    appendToolArgsDelta(data.blockIndex || 0, data.delta || '');
                    break;
            }
        });

        es.addEventListener('message_end', () => {
            noteEvent();
            endAssistantMessage();
        });

        es.addEventListener('tool_execution_start', (e) => {
            noteEvent();
            const data = parseData(e.data);
            if (!data) return;
            startToolCall(data.callId, data.name || 'tool', data.argsJson || '');
            // v2.31 — replay any sub-agent progress events that arrived
            // before the tool card was created (timing race).
            if (data.name === SUBAGENT_TOOL_NAME) {
                const pending = pendingSubagentUpdates.get(data.callId);
                if (pending) {
                    pendingSubagentUpdates.delete(data.callId);
                    for (const upd of pending) {
                        const card = toolCards.get(data.callId);
                        if (!card || !card.classList.contains('tool-card-subagent')) continue;
                        const log = card.querySelector('.subagent-log');
                        if (!log) continue;
                        appendSubagentEntry(card, log, upd);
                        appendSubagentPanelEvent(data.callId, upd);
                    }
                }
            }
            setActivity('running: ' + (data.name || 'tool'));
        });

        es.addEventListener('tool_execution_end', (e) => {
            noteEvent();
            const data = parseData(e.data);
            if (!data) return;
            endToolCall(data.callId, !!data.isError, data.toolCode || null, data.resultText || '', data.detailsJson || null);
            // After a tool completes the loop usually starts the
            // next assistant turn — show "thinking…" until the
            // next message_start arrives.
            setActivity('thinking…');
        });

        // v2.6 — sub-agent progress updates. The server wraps each
        // sub-agent structural event in a `tool_execution_update`
        // event keyed by the parent subagent call's callId. The
        // payload's `update` field contains the sub-agent JSON blob.
        es.addEventListener('tool_execution_update', (e) => {
            noteEvent();
            const data = parseData(e.data);
            if (!data || !data.callId) return;
            let upd;
            try {
                upd = typeof data.update === 'string' ? JSON.parse(data.update) : data.update;
            } catch (_) { return; }
            if (!upd) return;

            const card = toolCards.get(data.callId);
            if (!card || !card.classList.contains('tool-card-subagent')) {
                // v2.31 — tool_execution_start hasn't arrived yet (async
                // race with sub-agent worker). Buffer the update and
                // replay it when the start event creates the tool card.
                let buf = pendingSubagentUpdates.get(data.callId);
                if (!buf) {
                    buf = [];
                    pendingSubagentUpdates.set(data.callId, buf);
                }
                buf.push(upd);
                return;
            }
            const log = card.querySelector('.subagent-log');
            if (!log) return;
            appendSubagentEntry(card, log, upd);
            appendSubagentPanelEvent(data.callId, upd);
        });

        // v1.11.4 — pause-and-prompt permission overlay. Server
        // suspends the worker on `ask`; we render a modal in the
        // conversation pane and POST the user's choice to
        // /permission/resolve to wake it.
        es.addEventListener('tool_permission_request', (e) => {
            noteEvent();
            const data = parseData(e.data);
            if (!data || !data.callId) return;
            renderPermissionModal({
                callId: data.callId,
                toolName: data.toolName || 'tool',
                argsJson: data.argsJson || '',
                fingerprint: data.fingerprint || data.toolName || '',
            });
        });

        es.addEventListener('agent_error', (e) => {
            noteEvent();
            const data = parseData(e.data);
            const msg = data ? `${data.code}: ${data.message}` : 'agent error';
            // Suppress the banner for aborted (user-driven stop) and for
            // non-fatal advisory errors (isFatal===false) — those already
            // appear in the guardrail tool card.
            if (!(data && (data.code === 'aborted' || data.isFatal === false))) {
                appendError(msg);
            }
            setStreaming(false);            // v1.7.2
            hideTurnIndicator();
            endAssistantMessage();
            stopStatusLineTimer();          // v1.7.7
            setStatusLine('');
        });

        // vN — graceful interrupt: the loop finished the current
        // turn cleanly then stopped (user clicked Stop). Transition
        // back to idle, same as turn_end but without queueing a
        // follow-up.
        es.addEventListener('agent_interrupted', (e) => {
            noteEvent();
            endAssistantMessage();
            hideTurnIndicator();
            setStreaming(false);
            stopStatusLineTimer();
            setStatusLine('');
            input.focus();
        });

        // v1.7.0 — server fires this when the active session
        // changes (via /session/activate or /session/new). Wipe
        // the conversation and rehydrate from the new transcript.
        es.addEventListener('session_switched', async (e) => {
            noteEvent();
            const data = parseData(e.data);
            if (!data || !data.id) return;
            await onSessionSwitched(data.id);
        });

        // v1.7.0 — refresh the sidebar after every turn ends so
        // the message-count + updated-at timestamps stay current.
        es.addEventListener('turn_end', () => loadSessions());

        // v1.7.2 — watchdog. Every 5s, if `isStreaming` is true
        // and no SSE event has arrived for `watchdogTimeoutMs`,
        // surface an advisory. v1.7.4 made this non-destructive:
        // we used to wipe the active assistant bubble and reset
        // streaming state, but that produced false positives on
        // long thinking phases AND fragmented mid-turn output
        // when events resumed. The current behavior leaves all
        // state untouched and just gives the user a one-time
        // heads-up — they can wait or click Stop.
        setInterval(function () {
            if (!isStreaming) return;
            if (lastEventAt === 0) return;
            if (Date.now() - lastEventAt < watchdogTimeoutMs) return;
            if (watchdogWarned) return;
            watchdogWarned = true;
            console.warn('franky watchdog: no SSE events for ' + watchdogTimeoutMs + 'ms while streaming — model is taking longer than usual.');
            appendSystemMessage('',
                '_Model is taking longer than usual to respond. Click **Stop** to cancel, or keep waiting._',
                false);
        }, 5_000);

        // v1.7.4 — server-side keepalive: refresh the watchdog
        // clock without doing anything user-visible. Server
        // broadcasts `event: ping` every 15s while a turn is
        // running.
        es.addEventListener('ping', () => { noteEvent(); });

        // v1.16.0 — the server fires `replay_gap` when a reconnecting
        // client's Last-Event-ID is older than the oldest ring entry
        // (ring overflow, typically from a large thinking-delta burst).
        // For completed turns: wipe the pane and rehydrate from the
        // persisted transcript so the user sees the full conversation.
        // For in-flight turns: warn that some streamed content was lost
        // and let the current stream continue from wherever it resumes.
        es.addEventListener('replay_gap', async () => {
            noteEvent();
            if (!isStreaming) {
                clearConversation();
                await rehydrate();
            } else {
                appendSystemMessage('',
                    '_Some streamed content was lost during reconnect. ' +
                    'The response will continue from where it reconnected._',
                    false);
            }
        });

        return es;
    }

    function parseData(raw) {
        try {
            return JSON.parse(raw);
        } catch (_) {
            return null;
        }
    }

    // ── Composer ────────────────────────────────────────────────

    async function submitPrompt(text) {
        if (isStreaming) return;       // v1.7.1 — single-flight guard

        // v1.7.7 — record the prompt in history (both LLM
        // prompts and slash commands; users want to recall both).
        pushHistory(text);
        historyReset();

        // v1.7.3 — leading "/" routes to the slash dispatcher
        // instead of the LLM. Slash commands run synchronously
        // server-side; no streaming, no agent-loop activity.
        if (text.length > 0 && text[0] === '/') {
            await dispatchSlash(text);
            return;
        }

        setStreaming(true);
        setActivity('sending…');       // v1.7.2 — show activity immediately
        lastEventAt = Date.now();      // v1.7.2 — start the watchdog clock
        watchdogWarned = false;        // v1.7.4 — fresh advisory budget per turn
        startStatusLineTimer();        // v1.7.7 — elapsed seconds counter
        appendUserMessage(text);
        try {
            const resp = await fetch('/prompt', {
                method: 'POST',
                headers: { 'Content-Type': 'text/plain' },
                body: text,
            });
            if (!resp.ok) {
                appendError(`prompt rejected: HTTP ${resp.status}`);
                setStreaming(false);
            }
        } catch (err) {
            appendError(`network error: ${err.message || err}`);
            setStreaming(false);
        }
    }

    // ─── v1.7.3 — slash command dispatch ─────────────────────────

    /**
     * Render a system bubble — a neutral card showing the command
     * the user entered + its rendered output. Distinct styling
     * from user/assistant bubbles so `/help` etc. don't read as a
     * conversational turn.
     */
    function appendSystemMessage(line, outputMd, isError) {
        const el = document.createElement('div');
        el.className = 'message message-system' + (isError ? ' is-error' : '');

        const head = document.createElement('span');
        head.className = 'role';
        head.textContent = '$ ' + line;
        el.appendChild(head);

        const content = document.createElement('span');
        content.className = 'content';
        content.innerHTML = Markdown.render(outputMd || '');
        highlightCodeBlocks(content);
        el.appendChild(content);
        el.id = anchorIdFor("msg")
        conversation.appendChild(el);
        scrollToBottom(true);
    }

    /**
     * POST a slash-command line to /command, render the result as
     * a system message, dispatch any side-effect.
     */
    async function dispatchSlash(line) {
        let data;
        try {
            const r = await fetch('/command', {
                method: 'POST',
                headers: { 'Content-Type': 'text/plain' },
                body: line,
            });
            data = await r.json();
        } catch (err) {
            appendError('command failed: ' + (err.message || err));
            return;
        }

        if (!data || data.ok !== true) {
            const msg = (data && data.error) ? data.error : 'unknown command error';
            appendSystemMessage(line, '**Error:** ' + msg, true);
            return;
        }

        appendSystemMessage(line, data.output || '', false);

        // Side-effect dispatch.
        switch (data.sideEffect) {
            case 'clear_transcript':
                // Server already wiped the transcript and persisted —
                // mirror locally so the conversation pane matches.
                clearConversation();
                // Re-append the system message for the /clear itself
                // so the user has a record of what happened.
                appendSystemMessage(line, data.output || '', false);
                loadSessions();
                break;
            case 'model_changed':
                if (data.data && data.data.model) {
                    setStatus('model: ' + data.data.model, 'status-live');
                    // Snap back to "live" after a short beat so the
                    // pill doesn't permanently show the model name.
                    setTimeout(() => setStatus('live', 'status-live'), 2_500);
                }
                break;
            case 'turn_restarted':
                // v1.7.8 — server trimmed the assistant chain
                // after the last user message; a worker is about
                // to re-run the loop. Wipe the old conversation
                // pane and rehydrate from the trimmed transcript;
                // the new turn's SSE events will then layer on
                // top. Server also broadcasts session_switched
                // for any other open tabs.
                clearConversation();
                rehydrate().then(() => {
                    appendSystemMessage(line, data.output || '', false);
                    loadSessions();
                });
                break;
            case 'fill_input':
                // v1.7.8 — server returned the previous user-
                // message text; drop it into the composer so the
                // user can edit + resubmit.
                if (data.data && typeof data.data.text === 'string') {
                    input.value = data.data.text;
                    const len = input.value.length;
                    input.setSelectionRange(len, len);
                    input.focus();
                }
                // Also clear the bubble that the trimmed user
                // message left in the conversation pane — the
                // server already removed it from the transcript.
                clearConversation();
                rehydrate().then(() => {
                    loadSessions();
                });
                break;
            case 'open_design_panel':
                dpToggle();
                break;
            case 'quit':
                // Browsers won't always allow window.close(); fall
                // back to a banner if blocked.
                try { window.close(); } catch (_) {}
                appendSystemMessage('', '_Tab closed by /quit. You can close this tab manually._', false);
                break;
            default:
                // null / thinking_changed / unknown — no client action.
                break;
        }
    }

    form.addEventListener('submit', (e) => {
        e.preventDefault();
        // v1.7.2 — while streaming, the Send button is the Stop
        // button; submitting via the form (Enter or click) routes
        // to abort instead of opening a second turn.
        if (isStreaming) {
            abortTurn();
            return;
        }
        const text = input.value.trim();
        if (!text) return;
        input.value = '';
        submitPrompt(text);
    });

    // vN — Abort button click handler. Always visible after first
    // message. Just POSTs /interrupt. Safe at any time — the
    // server-side handler is idempotent when no turn is in flight.
    abortBtn.addEventListener('click', (e) => {
        e.preventDefault();
        abortTurn();
    });

    input.addEventListener('keydown', (e) => {
        // v1.7.3 — palette navigation has priority over composer
        // shortcuts when it's open.
        if (paletteIsOpen()) {
            if (e.key === 'ArrowUp')   { e.preventDefault(); paletteSelect(-1); return; }
            if (e.key === 'ArrowDown') { e.preventDefault(); paletteSelect(+1); return; }
            if (e.key === 'Escape')    { e.preventDefault(); paletteHide(); return; }
            if (e.key === 'Tab')       { e.preventDefault(); paletteAcceptSelected(); return; }
        }

        // v1.7.7 — history nav. Up/down through prior prompts when
        // the input is empty (or already navigating). Esc resets.
        if (e.key === 'ArrowUp' && canNavigateHistory()) {
            e.preventDefault();
            historyStep(+1);
            return;
        }
        if (e.key === 'ArrowDown' && historyIndex >= 0) {
            e.preventDefault();
            historyStep(-1);
            return;
        }
        if (e.key === 'Escape' && historyIndex >= 0) {
            e.preventDefault();
            historyReset();
            return;
        }

        // Enter submits; Shift-Enter inserts a newline (browser default).
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            // While streaming, Enter triggers Stop (matches the
            // Send→Stop button swap). Pre-1.7.2 this was a hard
            // bail; v1.7.2 routes to abort so users can recover.
            if (isStreaming) {
                abortTurn();
                return;
            }
            form.dispatchEvent(new Event('submit', { cancelable: true }));
        }
    });

    // ─── v1.7.7 — prompt history (localStorage-backed ring) ──────

    /**
     * Bounded ring of recent user submissions, persisted to
     * localStorage. Newest at index 0. ↑ when input empty walks
     * backward in time (toward older); ↓ walks forward (toward
     * newer). At index -1 the user is "not navigating" and the
     * input reflects whatever they typed.
     */
    const historyKey = 'franky.history';
    const historyMax = 50;
    let inputHistory = [];
    let historyIndex = -1;
    let historyDraft = '';            // what the user had typed before navigating

    function loadHistory() {
        try {
            const raw = localStorage.getItem(historyKey);
            if (!raw) return;
            const parsed = JSON.parse(raw);
            if (Array.isArray(parsed)) {
                inputHistory = parsed.filter(s => typeof s === 'string').slice(0, historyMax);
            }
        } catch (_) { /* ignore */ }
    }

    function saveHistory() {
        try { localStorage.setItem(historyKey, JSON.stringify(inputHistory)); } catch (_) {}
    }

    function pushHistory(text) {
        if (!text || typeof text !== 'string') return;
        // Dedupe consecutive identical entries.
        if (inputHistory.length > 0 && inputHistory[0] === text) return;
        inputHistory.unshift(text);
        if (inputHistory.length > historyMax) inputHistory.length = historyMax;
        saveHistory();
    }

    function canNavigateHistory() {
        if (inputHistory.length === 0) return false;
        // Allow ↑ when input is empty OR we're already navigating.
        return historyIndex >= 0 || input.value.length === 0;
    }

    function historyStep(delta) {
        // Capture the user's draft on entry so ↓ back to -1 restores it.
        if (historyIndex < 0) historyDraft = input.value;
        const next = historyIndex + delta;
        if (next < 0) {
            historyIndex = -1;
            input.value = historyDraft;
        } else if (next >= inputHistory.length) {
            // Stay at the oldest.
            historyIndex = inputHistory.length - 1;
            input.value = inputHistory[historyIndex];
        } else {
            historyIndex = next;
            input.value = inputHistory[historyIndex];
        }
        // Move caret to end so the user can edit the recalled prompt.
        const len = input.value.length;
        input.setSelectionRange(len, len);
    }

    function historyReset() {
        historyIndex = -1;
        historyDraft = '';
    }

    // ─── v1.7.3 — slash command palette ──────────────────────────

    /** Static command list. Mirrors `buildProxySlashRegistry` in proxy.zig.
     *  Kept in lockstep manually — there are nine entries and they
     *  change rarely. If the registry grows we'll fetch it via
     *  GET /commands; for the v1.7.3 batch the static list is fine. */
    const slashCommands = [
        { name: 'help',     desc: 'Show this list', argHint: '' },
        { name: 'clear',    desc: 'Clear the active conversation', argHint: '' },
        { name: 'model',    desc: 'Hot-swap the model', argHint: '<id>' },
        { name: 'tools',    desc: 'List registered tools', argHint: '' },
        { name: 'tool',     desc: "Show a tool's schema", argHint: '<name>' },
        { name: 'thinking', desc: 'Set thinking level', argHint: '<level>' },
        { name: 'cost',     desc: 'Show token usage', argHint: '' },
        { name: 'export',   desc: 'Dump transcript', argHint: 'markdown|json' },
        // v1.7.8 — retry / edit
        { name: 'retry',    desc: 'Re-run the last turn', argHint: '' },
        { name: 'edit',     desc: 'Edit the last user message', argHint: '' },
        { name: 'compact',  desc: 'Compact older messages into a summary', argHint: '' },
        // v1.29.2 — diagnostic report (saved to ~/.franky/diagnostics/<sid>/<ts>.txt)
        { name: 'diagnostics', desc: 'Per-turn anomaly report (see docs/reference/diagnostics.md)', argHint: '' },
        { name: 'design',   desc: 'Open the Design Documents panel', argHint: '' },
        { name: 'quit',     desc: 'Close this browser tab', argHint: '' },
    ];

    let paletteSelected = 0;
    let palettePrefix = '';

    function paletteIsOpen() {
        return cmdPaletteEl && cmdPaletteEl.classList.contains('is-open');
    }

    function paletteHide() {
        if (cmdPaletteEl) cmdPaletteEl.classList.remove('is-open');
    }

    function paletteCandidates() {
        if (!palettePrefix) return slashCommands;
        return slashCommands.filter(c => c.name.startsWith(palettePrefix));
    }

    function paletteRender() {
        if (!cmdPaletteEl) return;
        const items = paletteCandidates();
        if (items.length === 0) {
            paletteHide();
            return;
        }
        if (paletteSelected >= items.length) paletteSelected = 0;
        cmdPaletteEl.innerHTML = '';
        for (let i = 0; i < items.length; i++) {
            const li = document.createElement('li');
            if (i === paletteSelected) li.classList.add('is-selected');
            const name = document.createElement('span');
            name.className = 'cmd-name';
            name.textContent = '/' + items[i].name + (items[i].argHint ? ' ' + items[i].argHint : '');
            const desc = document.createElement('span');
            desc.className = 'cmd-desc';
            desc.textContent = items[i].desc;
            li.appendChild(name);
            li.appendChild(desc);
            li.addEventListener('mousedown', (ev) => {
                // mousedown (not click) so the textarea doesn't lose
                // focus before we get to handle it.
                ev.preventDefault();
                paletteSelected = i;
                paletteAcceptSelected();
            });
            cmdPaletteEl.appendChild(li);
        }
        cmdPaletteEl.classList.add('is-open');
    }

    function paletteSelect(delta) {
        const items = paletteCandidates();
        if (items.length === 0) return;
        paletteSelected = (paletteSelected + delta + items.length) % items.length;
        paletteRender();
    }

    function paletteAcceptSelected() {
        const items = paletteCandidates();
        if (items.length === 0) return;
        const cmd = items[paletteSelected];
        // Replace input with the selected command, plus a trailing
        // space so the user can type args immediately.
        input.value = '/' + cmd.name + (cmd.argHint ? ' ' : ' ');
        paletteHide();
        // Keep focus on the textarea.
        input.focus();
        // Re-evaluate state — typing more `/` shouldn't reopen.
        paletteRefreshFromInput();
    }

    function paletteRefreshFromInput() {
        const v = input.value;
        // Open only when the line starts with '/' and has no
        // whitespace yet (i.e. the user is still typing the
        // command name).
        if (v.length === 0 || v[0] !== '/' || /\s/.test(v)) {
            paletteHide();
            return;
        }
        palettePrefix = v.slice(1);
        paletteSelected = 0;
        paletteRender();
    }

    if (cmdPaletteEl) {
        input.addEventListener('input', paletteRefreshFromInput);
        input.addEventListener('blur', () => {
            // Delay slightly so a click on a palette item still
            // fires before we hide.
            setTimeout(paletteHide, 80);
        });
    }

    // ─── v1.7.7 — live status line (elapsed + tokens) ───────────

    let statusTimer = null;
    let statusStartedAt = 0;
    // vN — cached usage data for the popover
    let cachedUsageData = null;
    let cachedTranscriptUsage = null;

    function setStatusLine(text) {
        if (statusLineEl) statusLineEl.textContent = text;
    }

    /** Format a token count: 1234 → "1234", 5200 → "5.2k", 1500000 → "1.5m" */
    function formatTokenCount(n) {
        if (n >= 1000000) return (n / 1000000).toFixed(1) + 'm';
        if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
        return String(n);
    }

    /** Sum tool counts into a total */
    function sumToolCounts(tools) {
        let total = 0;
        for (const name of Object.keys(tools)) total += tools[name];
        return total;
    }

    /** Render the popover body from cached data */
    function renderStatusPopover() {
        const body = document.getElementById('status-popover-body');
        if (!body) return;
        body.innerHTML = '';

        if (cachedUsageData) {
            const tools = cachedUsageData.tools;
            const toolTotal = tools ? sumToolCounts(tools) : 0;
            const guardrails = cachedUsageData.guardrails || 0;

            // Heading
            const head = document.createElement('span');
            head.className = 'st-popover-heading';
            head.textContent = 'Session usage';
            body.appendChild(head);

            // Tool calls
            if (toolTotal > 0 && tools) {
                const section = document.createElement('span');
                section.className = 'st-popover-section';

                const title = document.createElement('div');
                title.className = 'st-popover-row';
                title.innerHTML = '<span class="st-label">Tool calls</span><span class="st-value">' + toolTotal + '</span>';
                section.appendChild(title);

                // Sort tools by count descending, show top tools
                const sorted = Object.keys(tools).sort(function (a, b) { return tools[b] - tools[a]; });
                for (const name of sorted) {
                    if (tools[name] <= 0) continue;
                    const row = document.createElement('div');
                    row.className = 'st-popover-row';
                    row.innerHTML = '<span class="st-label">' + name + '</span><span class="st-value">' + tools[name] + '</span>';
                    section.appendChild(row);
                }
                body.appendChild(section);
            }

            // Guardrails
            if (guardrails > 0) {
                const row = document.createElement('div');
                row.className = 'st-popover-row';
                row.style.marginTop = '6px';
                row.innerHTML = '<span class="st-label">Guards</span><span class="st-value">' + guardrails + '</span>';
                body.appendChild(row);
            }

            // vN — cumulative token sums from /usage endpoint.
            const u = cachedUsageData;
            const cumIn = u.inputTokens || 0;
            const cumOut = u.outputTokens || 0;
            if (cumIn > 0 || cumOut > 0) {
                const sep = document.createElement('span');
                sep.className = 'st-popover-heading';
                sep.style.marginTop = '6px';
                sep.textContent = 'Tokens (cumulative)';
                body.appendChild(sep);

                const inRow = document.createElement('div');
                inRow.className = 'st-popover-row';
                inRow.innerHTML = '<span class="st-label">Input</span><span class="st-value">' + formatTokenCount(cumIn) + '</span>';
                body.appendChild(inRow);

                const outRow = document.createElement('div');
                outRow.className = 'st-popover-row';
                outRow.innerHTML = '<span class="st-label">Output</span><span class="st-value">' + formatTokenCount(cumOut) + '</span>';
                body.appendChild(outRow);
            }

            // v3.0 — compression stats from /usage endpoint.
            const comp = u.compression;
            if (comp && (comp.itemsCompressed > 0 || comp.saved > 0)) {
                const sep = document.createElement('span');
                sep.className = 'st-popover-heading';
                sep.style.marginTop = '6px';
                sep.textContent = 'Compression';
                body.appendChild(sep);

                const savedRow = document.createElement('div');
                savedRow.className = 'st-popover-row';
                const pct = Math.round(comp.ratio * 100);
                savedRow.innerHTML = '<span class="st-label">Saved</span><span class="st-value">' + formatTokenCount(comp.saved) + ' (' + pct + '%)</span>';
                body.appendChild(savedRow);

                const compressedRow = document.createElement('div');
                compressedRow.className = 'st-popover-row';
                compressedRow.innerHTML = '<span class="st-label">Compressed</span><span class="st-value">' + comp.itemsCompressed + ' blocks</span>';
                body.appendChild(compressedRow);

                if (comp.itemsPassthrough > 0) {
                    const passRow = document.createElement('div');
                    passRow.className = 'st-popover-row';
                    passRow.innerHTML = '<span class="st-label">Passthrough</span><span class="st-value">' + comp.itemsPassthrough + ' blocks</span>';
                    body.appendChild(passRow);
                }

                if (comp.itemsFailed > 0) {
                    const failRow = document.createElement('div');
                    failRow.className = 'st-popover-row';
                    failRow.innerHTML = '<span class="st-label">Failed</span><span class="st-value">' + comp.itemsFailed + ' blocks</span>';
                    body.appendChild(failRow);
                }
            }
        }

        if (!cachedUsageData && !cachedTranscriptUsage) {
            body.textContent = 'No usage data yet.';
        }
    }

    function startStatusLineTimer() {
        statusStartedAt = Date.now();
        const tick = () => {
            const elapsed = Math.floor((Date.now() - statusStartedAt) / 1000);
            setStatusLine(elapsed + 's');
        };
        tick();
        if (statusTimer) clearInterval(statusTimer);
        statusTimer = setInterval(tick, 1_000);
    }

    function stopStatusLineTimer() {
        if (statusTimer) {
            clearInterval(statusTimer);
            statusTimer = null;
        }
    }

    async function refreshStatusLineUsage() {
        const elapsed = Math.floor((Date.now() - statusStartedAt) / 1000);
        var parts = [elapsed + 's'];
        cachedUsageData = null;
        cachedTranscriptUsage = null;

        try {
            const ur = await fetch('/usage');
            if (ur.ok) {
                const udata = await ur.json();
                cachedUsageData = udata;
                if (udata) {
                    const tools = udata.tools;
                    if (tools) {
                        const total = sumToolCounts(tools);
                        if (total > 0) parts.push(total + ' tools');
                    }
                    if (udata.guardrails && udata.guardrails > 0) {
                        parts.push('guards: ' + udata.guardrails);
                    }
                    // vN — cumulative token sums from the server.
                    const cumIn = udata.inputTokens || 0;
                    const cumOut = udata.outputTokens || 0;
                    parts.push('in ' + formatTokenCount(cumIn) + ' / out ' + formatTokenCount(cumOut));

                    // v3.0 — compression savings from the server.
                    const comp = udata.compression;
                    if (comp && comp.saved > 0) {
                        const pct = Math.round(comp.ratio * 100);
                        parts.push('saved ' + formatTokenCount(comp.saved) + ' (' + pct + '%)');
                    }
                }
            }
        } catch (_) {}

        setStatusLine(parts.join(' · '));
        renderStatusPopover();
    }

    // ─── v1.7.7 — help overlay ──────────────────────────────────

    function showHelp() {
        if (!helpOverlayEl || !helpCmdsEl) return;
        // Re-render the slash command list each time so future
        // additions to `slashCommands` are reflected.
        helpCmdsEl.innerHTML = '';
        for (const c of slashCommands) {
            const li = document.createElement('li');
            const name = document.createElement('span');
            name.className = 'help-cmd-name';
            name.textContent = '/' + c.name + (c.argHint ? ' ' + c.argHint : '');
            const desc = document.createElement('span');
            desc.className = 'help-cmd-desc';
            desc.textContent = c.desc;
            li.appendChild(name);
            li.appendChild(desc);
            helpCmdsEl.appendChild(li);
        }
        helpOverlayEl.hidden = false;
    }

    function hideHelp() {
        if (helpOverlayEl) helpOverlayEl.hidden = true;
    }

    if (helpToggleBtn) helpToggleBtn.addEventListener('click', showHelp);
    if (helpCloseBtn)  helpCloseBtn.addEventListener('click', hideHelp);
    if (helpOverlayEl) {
        helpOverlayEl.addEventListener('click', (e) => {
            // Click on the dim backdrop (not the inner card) closes.
            if (e.target === helpOverlayEl) hideHelp();
        });
    }

    // Global ?-key opens help; Esc closes it. Skip when the user
    // is mid-typing in the textarea (so "?" inserts normally).
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && currentOverlayCallId !== null) {
            e.preventDefault();
            closeSubagentOverlay();
            return;
        }
        if (e.key === 'Escape' && helpOverlayEl && !helpOverlayEl.hidden) {
            e.preventDefault();
            hideHelp();
            return;
        }
        if (e.key === '?' && document.activeElement !== input) {
            e.preventDefault();
            showHelp();
        }
    });

    // ─── v1.7.0 — sidebar / session management ───────────────────

    /** Most-recent session list snapshot from /sessions. */
    let sessionsCache = [];
    let activeSessionId = null;
    let sessionsPersisted = true;

    function fmtRelativeTime(ms) {
        if (!ms) return '';
        const diff = Date.now() - ms;
        if (diff < 60_000) return 'just now';
        if (diff < 3_600_000) return Math.floor(diff / 60_000) + 'm ago';
        if (diff < 86_400_000) return Math.floor(diff / 3_600_000) + 'h ago';
        return Math.floor(diff / 86_400_000) + 'd ago';
    }

    function renderSessionList() {
        sessionList.innerHTML = '';
        if (!sessionsPersisted) {
            const li = document.createElement('li');
            li.className = 'session-empty';
            li.textContent = 'Sessions disabled (--no-session). Conversations stay in memory only.';
            sessionList.appendChild(li);
            return;
        }
        if (sessionsCache.length === 0) {
            const li = document.createElement('li');
            li.className = 'session-empty';
            li.textContent = 'No saved conversations yet — say something to start.';
            sessionList.appendChild(li);
            return;
        }
        for (const s of sessionsCache) {
            const li = document.createElement('li');
            li.dataset.id = s.id;
            if (s.id === activeSessionId) li.classList.add('is-active');
            const title = document.createElement('span');
            title.className = 'session-title';
            title.textContent = s.title || s.id;
            const meta = document.createElement('span');
            meta.className = 'session-meta';
            meta.textContent = `${s.messageCount} msg · ${fmtRelativeTime(s.updatedAtMs)}`;
            li.appendChild(title);
            li.appendChild(meta);
            li.addEventListener('click', function () {
                if (s.id !== activeSessionId) activateSession(s.id);
            });
            sessionList.appendChild(li);
        }
    }

    async function loadSessions() {
        try {
            const r = await fetch('/sessions');
            if (!r.ok) return;
            const data = await r.json();
            sessionsCache = Array.isArray(data.sessions) ? data.sessions : [];
            activeSessionId = data.active || activeSessionId;
            sessionsPersisted = data.persisted !== false;
            renderSessionList();
        } catch (_) {
            /* ignore — sidebar stays empty */
        }
    }

    /** Clear the conversation pane completely. Used on session swap. */
    function clearConversation() {
        conversation.innerHTML = '';
        active = { el: null, contentEl: null, blocks: new Map(), thinkingEl: null, thinkingBlocks: new Map(), toolArgs: new Map() };
        toolCards.clear();
        pendingToolCards.length = 0;
        closeSubagentOverlay();
        subagentSections.clear();
        pendingSubagentUpdates.clear();
        if (subagentPanelBody) subagentPanelBody.innerHTML = '';
        if (subagentPanelEl) subagentPanelEl.setAttribute('hidden', '');
        if (subagentPanelBtn) subagentPanelBtn.setAttribute('hidden', '');
        hideTurnIndicator();
        setStreaming(false);                // v1.7.2 (replaces v1.7.1 plumbing)
        stopStatusLineTimer();              // v1.7.7
        setStatusLine('');
    }

    async function activateSession(id) {
        try {
            const r = await fetch('/session/activate', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ id: id }),
            });
            if (!r.ok) return;
            // Activation succeeds → server broadcasts session_switched
            // to all subscribers, but the local handler's the same path.
            await onSessionSwitched(id);
        } catch (_) { /* ignore */ }
    }

    async function newSession() {
        try {
            const r = await fetch('/session/new', { method: 'POST' });
            if (!r.ok) return;
            const data = await r.json();
            await onSessionSwitched(data.id);
        } catch (_) { /* ignore */ }
    }

    async function onSessionSwitched(newId) {
        activeSessionId = newId;
        clearConversation();
        await rehydrate();
        await loadSessions();
    }

    if (newSessionBtn) newSessionBtn.addEventListener('click', newSession);
    if (sidebarToggle) {
        sidebarToggle.addEventListener('click', function () {
            document.body.classList.toggle('sidebar-collapsed');
        });
    }
    if (subagentPanelClose) subagentPanelClose.addEventListener('click', closeSubagentPanel);
    if (subagentPanelBtn)   subagentPanelBtn.addEventListener('click', openSubagentPanel);
    if (saOverlayClose) saOverlayClose.addEventListener('click', closeSubagentOverlay);
    if (saOverlayBackdrop) saOverlayBackdrop.addEventListener('click', (e) => {
        if (e.target === saOverlayBackdrop) closeSubagentOverlay();
    });

    /**
     * v1.6.1 — fetch /transcript and replay each persisted message
     * into the conversation pane. Runs once on page load before
     * the EventSource connects, so reload is non-destructive.
     *
     * Tool calls are rendered as a card sourced from the assistant
     * message's `tool_call` block; the matching tool_result message
     * just upgrades the card's status. We don't re-fire any events
     * — this is a pure DOM reconstruction from server-side state.
     */
    async function rehydrate() {
        let data;
        try {
            const resp = await fetch('/transcript', { headers: { 'Accept': 'application/json' } });
            if (!resp.ok) return;
            data = await resp.json();
        } catch (_) {
            return;
        }
        if (!data || !Array.isArray(data.messages)) return;

        // Pass 1: collect tool_result status + concatenated text body
        // keyed by toolCallId so pass 2 can paint each card's final
        // state — including the expandable result body and, for
        // subagent calls, the side-panel row + inline summary.
        const toolResults = new Map();
        for (const m of data.messages) {
            if (m.role === 'toolResult' && m.toolCallId) {
                const text = (m.blocks || [])
                    .filter(b => b.kind === 'text')
                    .map(b => b.text || '')
                    .join('');
                toolResults.set(m.toolCallId, { isError: !!m.isError, resultText: text });
            }
        }

        // Pass 2: render messages in order. user / assistant render
        // as bubbles; assistant tool_call blocks render as cards
        // inline with their resolved status; tool_result messages
        // are absorbed into the cards painted by pass 1's lookup
        // and intentionally skipped here.
        for (const m of data.messages) {
            if (m.role === 'user') {
                const text = (m.blocks || [])
                    .filter(b => b.kind === 'text')
                    .map(b => b.text || '')
                    .join('');
                if (text.length > 0) appendUserMessage(text);
            } else if (m.role === 'assistant') {
                appendFinalizedAssistantMessage(m.blocks || [], 'assistant');
                for (const b of m.blocks || []) {
                    if (b.kind === 'tool_call' && b.id) {
                        const r = toolResults.get(b.id) || { isError: false, resultText: '' };
                        appendFinalizedToolCard(b.id, b.name || 'tool', r.isError, b.args || '', r.resultText);
                    }
                }
            }
            // toolResult, custom — skipped
        }

        if (subagentSections.size > 0) openSubagentPanel();

        // Page just loaded / session just switched — land at the
        // bottom (newest message) regardless of saved scroll state.
        scrollToBottom(true);
        // vN — after rehydrating from saved transcript, check for URL anchor.
        scrollToAnchor();
    }

    // v1.7.7 — load prompt history before connecting; it's
    // localStorage-only so this is synchronous + instant.
    loadHistory();

    // One-shot fetch at boot — role is bound at session init
    // server-side and never changes for the proxy's lifetime.
    async function loadRole() {
        const el = document.getElementById('role-pill');
        const labelEl = document.getElementById('role-label');
        const mEl = document.getElementById('model-pill');
        if (!el) return;
        try {
            const r = await fetch('/role');
            if (!r.ok) {
                if (labelEl) labelEl.textContent = 'role: ?';
                if (mEl) mEl.textContent = 'model: ?';
                return;
            }
            const data = await r.json();
            const role = data.role || 'plan';
            const provider = data.provider || '?';
            const model = data.model || '?';
            if (labelEl) {
                labelEl.textContent = 'role: ' + role + (data.sandbox ? ' · sandboxed' : '');
            }

            // Populate the custom tooltip with description + allowed tools.
            const tipHeading = document.getElementById('role-tooltip-heading');
            const tipSandbox = document.getElementById('role-tooltip-sandbox');
            const tipTools   = document.getElementById('role-tooltip-tools');
            if (tipHeading) {
                tipHeading.textContent = data.description || (role + ' role');
            }
            if (tipSandbox) {
                tipSandbox.textContent = data.sandbox ? '✅ running in sandbox' : '';
                tipSandbox.style.display = data.sandbox ? 'block' : 'none';
            }
            if (tipTools) {
                const tools = data.allowed_tools || [];
                if (tools.length > 0) {
                    tipTools.textContent = '';
                    const prefix = document.createTextNode('Available tools: ');
                    tipTools.appendChild(prefix);
                    for (let i = 0; i < tools.length; i++) {
                        if (i > 0) tipTools.appendChild(document.createTextNode(', '));
                        const span = document.createElement('span');
                        span.className = 'rt-tool-name';
                        span.textContent = tools[i];
                        tipTools.appendChild(span);
                    }
                } else {
                    tipTools.textContent = 'No tools available.';
                }
            }

            el.classList.remove(
                'role-pill-read', 'role-pill-plan', 'role-pill-code', 'role-pill-full');
            el.classList.add('role-pill-' + role);
            if (mEl) {
                mEl.textContent = provider + ':' + model;
                mEl.title = 'provider: ' + provider + ' · model: ' + model;
            }
        } catch (_) {
            if (labelEl) labelEl.textContent = 'role: ?';
            if (mEl) mEl.textContent = 'model: ?';
        }
    }

    // `/session` resolves activeSessionId, which loadSessions +
    // rehydrate both depend on. loadRole is independent — fire
    // it in parallel with the dependent pair to overlap the
    // round-trips.
    (async function () {
        try {
            const r = await fetch('/session');
            if (r.ok) {
                const data = await r.json();
                if (data && data.id) activeSessionId = data.id;
                if (data && data.persisted === false) sessionsPersisted = false;
            }
        } catch (_) { /* ignore */ }
        await Promise.all([loadRole(), loadSessions(), rehydrate()]);
        connect();
    })();
})();
