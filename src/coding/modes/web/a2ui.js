"use strict";
// ── A2UI surface renderer (main chat window integration) ─────────
// Mirrors the standalone /a2ui.html renderer, namespaced under
// window.A2UI so it can coexist with app.js. Consumes /a2ui/events
// (A2UI v1.0 envelopes over SSE), renders the catalog subset
// (Column, Row, Text, Button, TextField, CheckBox, Card) into
// #a2ui-surface, and POSTs Button actions to /a2ui/action. Data
// bindings are renderer-local per spec ({"@path": "/json/pointer"}
// against the surface data model, RFC 6901); state reaches the agent
// only via Button actions.
//
// Only loaded when the proxy was started with --a2ui; app.js calls
// A2UI.init({ onSurfaceUpdate }) once.

window.A2UI = (function () {
    const state = { components: [], dataModel: null, version: 0 };
    let surfaceEl = null;
    let onUpdate = null;

    // ── JSON Pointer (RFC 6901) ───────────────────────────────────
    function pointerGet(obj, path) {
        if (!path || path === "/") return obj;
        let cur = obj;
        for (const raw of path.split("/").slice(1)) {
            const seg = raw.replace(/~1/g, "/").replace(/~0/g, "~");
            if (cur == null || typeof cur !== "object") return undefined;
            cur = Array.isArray(cur) ? cur[Number(seg)] : cur[seg];
        }
        return cur;
    }
    function pointerSet(obj, path, value) {
        const segs = path.split("/").slice(1).map(s => s.replace(/~1/g, "/").replace(/~0/g, "~"));
        if (segs.length === 0) return value;
        let cur = obj;
        for (let i = 0; i < segs.length - 1; i++) {
            if (cur[segs[i]] == null || typeof cur[segs[i]] !== "object") cur[segs[i]] = {};
            cur = cur[segs[i]];
        }
        cur[segs[segs.length - 1]] = value;
        return obj;
    }

    function resolveDynamic(v) {
        if (v == null) return "";
        if (typeof v === "string") return v;
        if (typeof v === "object" && typeof v["@path"] === "string") {
            const r = pointerGet(state.dataModel, v["@path"]);
            if (r == null) return "";
            return typeof r === "object" ? JSON.stringify(r) : String(r);
        }
        return String(v);
    }
    // Resolve an action context: {"k": {"@path": "/..."}} → {"k": value}
    function resolveContext(ctx) {
        const out = {};
        for (const [k, v] of Object.entries(ctx || {})) {
            out[k] = (v && typeof v === "object" && typeof v["@path"] === "string")
                ? pointerGet(state.dataModel, v["@path"]) : v;
        }
        return out;
    }

    // ── component renderers ───────────────────────────────────────
    const renderers = {
        Column(def, render) {
            const el = document.createElement("div");
            el.className = "a2-column a2-card";
            for (const kid of def.children || []) render(kid, el);
            return el;
        },
        Row(def, render) {
            const el = document.createElement("div");
            el.className = "a2-row";
            for (const kid of def.children || []) render(kid, el);
            return el;
        },
        Text(def) {
            const el = document.createElement("p");
            el.className = "a2-text";
            el.textContent = resolveDynamic(def.text);
            return el;
        },
        Button(def) {
            const el = document.createElement("button");
            el.className = "a2-button";
            el.textContent = resolveDynamic(def.label);
            el.addEventListener("click", () => fireAction(def));
            return el;
        },
        TextField(def) {
            const wrap = document.createElement("div");
            wrap.className = "a2-field";
            const label = document.createElement("label");
            label.textContent = resolveDynamic(def.label);
            const input = document.createElement("input");
            input.type = "text";
            const binding = def.value && def.value["@path"];
            if (binding) {
                const cur = pointerGet(state.dataModel, binding);
                input.value = cur == null ? "" : String(cur);
                // Two-way binding, renderer-local per spec.
                input.addEventListener("input", () => {
                    if (state.dataModel == null || typeof state.dataModel !== "object") state.dataModel = {};
                    pointerSet(state.dataModel, binding, input.value);
                });
            }
            wrap.append(label, input);
            return wrap;
        },
        CheckBox(def) {
            const wrap = document.createElement("div");
            wrap.className = "a2-check";
            const input = document.createElement("input");
            input.type = "checkbox";
            input.id = "a2cb-" + def.id;
            const label = document.createElement("label");
            label.htmlFor = input.id;
            label.textContent = resolveDynamic(def.label);
            const binding = def.checked && typeof def.checked === "object" ? def.checked["@path"] : null;
            if (binding) {
                const cur = pointerGet(state.dataModel, binding);
                input.checked = cur === true;
                input.addEventListener("change", () => {
                    if (state.dataModel == null || typeof state.dataModel !== "object") state.dataModel = {};
                    pointerSet(state.dataModel, binding, input.checked);
                });
            } else {
                input.checked = def.checked === true;
            }
            wrap.append(input, label);
            return wrap;
        },
        Card(def, render) {
            const el = document.createElement("div");
            el.className = "a2-card-box";
            if (def.title != null) {
                const t = document.createElement("p");
                t.className = "a2-card-title";
                t.textContent = resolveDynamic(def.title);
                el.appendChild(t);
            }
            if (def.subtitle != null) {
                const s = document.createElement("p");
                s.className = "a2-card-sub";
                s.textContent = resolveDynamic(def.subtitle);
                el.appendChild(s);
            }
            for (const kid of def.children || []) render(kid, el);
            return el;
        },
        // Plan 4.7 franky catalog: tool invocation card.
        ToolCall(def) {
            const el = document.createElement("div");
            const status = typeof def.status === "string" ? def.status : "done";
            el.className = "a2-toolcall a2-toolcall-" + status;
            const head = document.createElement("div");
            head.className = "a2-toolcall-head";
            const badge = document.createElement("span");
            badge.className = "a2-toolcall-badge";
            badge.textContent = status === "running" ? "running" : status === "error" ? "error" : "done";
            const name = document.createElement("span");
            name.className = "a2-toolcall-name";
            name.textContent = resolveDynamic(def.name);
            head.append(badge, name);
            el.appendChild(head);
            if (def.args != null) {
                const args = document.createElement("pre");
                args.className = "a2-code a2-toolcall-args";
                args.textContent = resolveDynamic(def.args);
                el.appendChild(args);
            }
            if (def.result != null) {
                const result = document.createElement("pre");
                result.className = "a2-code a2-toolcall-result";
                result.textContent = resolveDynamic(def.result);
                el.appendChild(result);
            }
            return el;
        },
        // Plan 4.7 franky catalog: monospace code block.
        CodeBlock(def) {
            const el = document.createElement("pre");
            el.className = "a2-code";
            if (def.lang != null) el.dataset.lang = resolveDynamic(def.lang);
            el.textContent = resolveDynamic(def.code);
            return el;
        },
        // Plan 4.7 franky catalog: unified-diff view. Reuses the
        // franky-diff CSS classes from style.css (same look as the
        // chat tool-card diff view).
        Diff(def) {
            const wrap = document.createElement("div");
            wrap.className = "a2-diff";
            if (def.path != null) {
                const p = document.createElement("div");
                p.className = "a2-diff-path";
                p.textContent = resolveDynamic(def.path);
                wrap.appendChild(p);
            }
            const table = document.createElement("table");
            table.className = "a2-diff-table";
            const tbody = document.createElement("tbody");
            for (const line of resolveDynamic(def.diff).split("\n")) {
                if (line.startsWith("--- ") || line.startsWith("+++ ")) continue;
                const tr = document.createElement("tr");
                const td = document.createElement("td");
                if (line.startsWith("@@")) {
                    tr.className = "a2-diff-info";
                    td.textContent = line;
                } else if (line.startsWith("+")) {
                    tr.className = "a2-diff-ins";
                    td.textContent = line;
                } else if (line.startsWith("-")) {
                    tr.className = "a2-diff-del";
                    td.textContent = line;
                } else {
                    tr.className = "a2-diff-ctx";
                    td.textContent = line;
                }
                tr.appendChild(td);
                tbody.appendChild(tr);
            }
            table.appendChild(tbody);
            wrap.appendChild(table);
            return wrap;
        },
        // Plan 4.7 franky catalog: collapsible reasoning block.
        ThinkingBlock(def) {
            const det = document.createElement("details");
            det.className = "a2-thinking";
            det.open = def.collapsed === false;
            const sum = document.createElement("summary");
            sum.textContent = "Thinking";
            const body = document.createElement("div");
            body.className = "a2-thinking-body";
            body.textContent = resolveDynamic(def.text);
            det.append(sum, body);
            return det;
        },
    };

    function render() {
        if (!surfaceEl) return;
        surfaceEl.textContent = "";
        if (!state.components.length) {
            const d = document.createElement("div");
            d.className = "a2-empty";
            d.textContent = "No UI yet — ask the agent to render something (e.g. “show me a form”).";
            surfaceEl.appendChild(d);
            return;
        }
        const byId = new Map(state.components.map(c => [c.id, c]));
        const renderInto = (id, parent) => {
            const def = byId.get(id);
            if (!def) return; // dangling reference (id not in this surface)
            const r = renderers[def.component];
            if (!r) {
                const w = document.createElement("div");
                w.className = "a2-text";
                w.textContent = `[unsupported component: ${def.component}]`;
                parent.appendChild(w);
                return;
            }
            parent.appendChild(r(def, renderInto));
        };
        if (byId.has("root")) {
            // Model-driven tree rooted at "root"; unattached components
            // (e.g. host-injected permission cards) render after it.
            const attached = new Set();
            (function mark(id) {
                if (!id || attached.has(id)) return;
                attached.add(id);
                const def = byId.get(id);
                if (!def) return;
                for (const k of def.children || []) mark(k);
                if (def.child) mark(def.child);
            })("root");
            renderInto("root", surfaceEl);
            for (const c of state.components) {
                if (!attached.has(c.id)) renderInto(c.id, surfaceEl);
            }
        } else {
            // No "root" component (host-injected UI only) — render in list order.
            for (const c of state.components) renderInto(c.id, surfaceEl);
        }
    }

    // ── actions → agent ───────────────────────────────────────────
    async function fireAction(def) {
        const ev = (def.action && def.action.event) || {};
        const payload = {
            version: "1.0",
            action: {
                name: ev.name || "unknown",
                surfaceId: "main",
                sourceComponentId: def.id,
                timestamp: new Date().toISOString(),
                userMessage: resolveDynamic(ev.userMessage) || undefined,
                context: resolveContext(ev.context),
            },
        };
        try {
            await fetch("/a2ui/action", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify(payload),
            });
        } catch (e) {
            console.error("A2UI action POST failed", e);
        }
    }

    // ── envelopes ─────────────────────────────────────────────────
    function deepMerge(dst, src) {
        for (const [k, v] of Object.entries(src || {})) {
            if (v && typeof v === "object" && !Array.isArray(v) &&
                dst[k] && typeof dst[k] === "object" && !Array.isArray(dst[k])) {
                deepMerge(dst[k], v);
            } else {
                dst[k] = v;
            }
        }
        return dst;
    }

    function applyEnvelope(env) {
        if (env.createSurface) return; // surface is implicit
        if (env.updateComponents) {
            // Upsert semantics: components with a matching id are
            // replaced in place, new ids append; ids absent from the
            // batch are kept. Lets host-side projections (permission
            // cards) coexist with full-tree model renders.
            const batch = env.updateComponents.components || [];
            const byId = new Map(state.components.map((c, i) => [c.id, i]));
            for (const c of batch) {
                const idx = byId.get(c.id);
                if (idx === undefined) {
                    byId.set(c.id, state.components.length);
                    state.components.push(c);
                } else {
                    state.components[idx] = c;
                }
            }
            render();
            if (onUpdate) onUpdate();
            return;
        }
        if (env.updateDataModel) {
            if (state.dataModel == null || typeof state.dataModel !== "object") state.dataModel = {};
            deepMerge(state.dataModel, env.updateDataModel.data || {});
            render(); // re-resolve @path bindings
            return;
        }
        if (env.deleteSurface) {
            state.components = [];
            state.dataModel = null;
            render();
        }
    }

    function connect() {
        const es = new EventSource("/a2ui/events");
        es.addEventListener("a2ui_snapshot", (e) => {
            const snap = JSON.parse(e.data);
            state.components = snap.components || [];
            state.dataModel = snap.dataModel;
            state.version = snap.version || 0;
            render();
        });
        for (const kind of ["a2ui_updateComponents", "a2ui_updateDataModel", "a2ui_deleteSurface", "a2ui_createSurface"]) {
            es.addEventListener(kind, (e) => applyEnvelope(JSON.parse(e.data)));
        }
        // EventSource auto-reconnects and resends Last-Event-ID; the
        // server answers a stale id with a fresh snapshot.
    }

    function init(opts) {
        surfaceEl = document.getElementById("a2ui-surface");
        onUpdate = (opts && opts.onSurfaceUpdate) || null;
        render();
        connect();
    }

    return { init };
})();
