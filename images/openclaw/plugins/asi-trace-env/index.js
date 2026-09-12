// Puts the active run's W3C traceparent into the environment of every command
// the agent runs.
//
// Why this exists: `main` dispatches a poem by curling the poet from the
// `bash` tool, not through openclaw's own A2A outbound client. That shell is
// where the request is built, and until now it had no way to know which trace
// it belonged to -- openclaw hands exec'd commands OPENCLAW_CONFIG_PATH,
// OPENCLAW_STATE_DIR and OPENCLAW_WORKSPACE_DIR and nothing else. So the
// dispatch could not name its own trace, `pick-poet-gateway` had nothing
// stable to key on, and the poet's run opened a trace unrelated to the run
// that caused it.
//
// `resolve_exec_env` is the sanctioned way in: a documented hook whose whole
// job is contributing plugin-owned environment variables to exec. Using it
// rather than patching the bash tool means this survives openclaw upgrades.
// TRACEPARENT is a plain name, so it passes the host key policy untouched --
// that filter drops PATH and the dangerous override families (LD_*, DYLD_*,
// NODE_OPTIONS, proxy and TLS variables), none of which this is.
//
// Pair with the A2A inbound patch in images/openclaw/patch-a2a-traceparent.mjs.
// This half puts the trace on the wire; that half makes the callee adopt it.
// Either alone leaves the two pods on separate traces.

import {
  createDiagnosticTraceContextFromActiveScope,
  formatDiagnosticTraceparent,
} from "openclaw/plugin-sdk/diagnostic-runtime";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

export default definePluginEntry({
  id: "asi-trace-env",
  name: "ASI trace env",
  description: "Exports the active run's W3C traceparent to the exec tool.",
  register(api) {
    api.on("resolve_exec_env", () => {
      // The scope helper always returns a context: a *child* of the active one
      // when a run is in flight, or a fresh root when nothing is. Only the
      // first case is worth exporting, and `parentSpanId` is how they are told
      // apart -- a root has none.
      //
      // The child's own spanId is deliberately not what goes on the wire. That
      // span is never exported, so naming it as the callee's parent would hang
      // the poet's spans off an id no backend ever receives. `parentSpanId` is
      // the active span, which *is* exported, so the poet's run attaches to a
      // real one.
      const active = createDiagnosticTraceContextFromActiveScope();
      if (!active?.parentSpanId) return {};

      const traceparent = formatDiagnosticTraceparent({
        traceId: active.traceId,
        spanId: active.parentSpanId,
        traceFlags: active.traceFlags,
      });

      // formatDiagnosticTraceparent returns undefined for a malformed or
      // all-zero context rather than throwing. Contributing nothing is the
      // right answer then: `pick-poet-gateway` falls back to minting its own.
      return traceparent ? { TRACEPARENT: traceparent } : {};
    });
  },
});
