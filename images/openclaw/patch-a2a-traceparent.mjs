// Teaches openclaw's A2A inbound route to continue a caller's W3C trace.
//
// openclaw already makes exactly this move one layer up: the gateway control
// protocol parses `req.traceparent` and runs the dispatch inside
// `runWithDiagnosticTraceContext(createChildDiagnosticTraceContext(...))`.
// A2A is the one surface that terminates an HTTP request from another agent
// and it does not look at the header at all -- measured, not assumed: the
// whole `/app/extensions/a2a` tree contains no occurrence of "traceparent",
// and no diagnostic or span symbol either. Without this patch a dispatched
// poem produces two unrelated traces, one per pod, and nothing joins them.
//
// Why a codemod and not a source patch: the published image ships no core
// `src/`, and the TypeScript under /app/extensions/a2a is vestigial at
// runtime -- the live handler is bundled into a content-hashed dist chunk
// (`channel-<hash>.js`). That hash moves on every openclaw release, so the
// target is found by content and never by name. The chunk is bundled but not
// minified, which is the only reason this is reasonable to do at all.
//
// Every lookup asserts exactly one match and exits non-zero otherwise. An
// openclaw bump that moves this code MUST fail `make image` rather than
// produce an image that quietly traces nothing -- the same silent-nothing
// failure this chart refuses everywhere else.
//
//   node patch-a2a-traceparent.mjs [dist-dir]     # default /app/dist
//
// Idempotent: a second run over an already-patched tree is a no-op.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const DIST = process.argv[2] ?? "/app/dist";
const MARKER = "asi:a2a-traceparent";

// The guard that identifies the A2A HTTP handler's chunk. Chosen because it
// names both the method and the route, so it cannot collide with the agent
// card handler or with another channel's router.
const GUARD = 'pathname !== "/a2a/v1"';

// The handler itself. Anchored to the start of a line so the match is the
// declaration and not a reference to it.
const HANDLER = /^[\t ]*return async \(request, response\) => \{$/gm;

// Named exports this patch leans on. All four are unmangled on the plugin-sdk
// surface, which is the whole reason to import from there: inside the hashed
// chunks the same functions carry single-letter aliases that change per build.
const SDK_EXPORTS = [
  "parseDiagnosticTraceparent",
  "createChildDiagnosticTraceContext",
  "createDiagnosticTraceContextFromActiveScope",
  "freezeDiagnosticTraceContext",
];

function die(message) {
  console.error(`patch-a2a-traceparent: ${message}`);
  process.exit(1);
}

function* walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else if (entry.isFile() && full.endsWith(".js")) yield full;
  }
}

/**
 * Index of the `}` closing the block opened at `open`.
 *
 * Counts braces while skipping the places a brace does not nest: string and
 * template literals (including `${}` substitutions, which do nest) and both
 * comment forms. Regex literals are not tracked -- distinguishing `/` as
 * division from `/` as a literal needs real parsing -- so the caller checks
 * the shape of what came back rather than trusting the count.
 */
function matchingBrace(source, open) {
  let depth = 0;
  const templates = [];
  for (let i = open; i < source.length; i += 1) {
    const c = source[i];
    const next = source[i + 1];
    if (c === "/" && next === "/") {
      i = source.indexOf("\n", i);
      if (i < 0) break;
      continue;
    }
    if (c === "/" && next === "*") {
      i = source.indexOf("*/", i + 2) + 1;
      if (i < 1) break;
      continue;
    }
    if (c === '"' || c === "'") {
      for (i += 1; i < source.length; i += 1) {
        if (source[i] === "\\") i += 1;
        else if (source[i] === c) break;
      }
      continue;
    }
    if (c === "`") {
      templates.push(depth);
      for (i += 1; i < source.length; i += 1) {
        if (source[i] === "\\") i += 1;
        else if (source[i] === "`") break;
        else if (source[i] === "$" && source[i + 1] === "{") {
          // Re-enter normal scanning for the substitution's expression.
          const end = matchingBrace(source, i + 1);
          if (end < 0) return -1;
          i = end;
        }
      }
      templates.pop();
      continue;
    }
    if (c === "{") depth += 1;
    else if (c === "}") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

const chunks = [...walk(DIST)].filter((file) => fs.readFileSync(file, "utf8").includes(GUARD));
if (chunks.length !== 1) {
  die(
    `expected exactly one dist chunk containing \`${GUARD}\`, found ${chunks.length}` +
      (chunks.length ? `: ${chunks.join(", ")}` : "") +
      " -- the A2A route has moved or changed shape",
  );
}
const target = chunks[0];
const source = fs.readFileSync(target, "utf8");

if (source.includes(MARKER)) {
  console.log(`patch-a2a-traceparent: ${target} already patched`);
  process.exit(0);
}

const sdk = path.join(DIST, "plugin-sdk", "diagnostic-runtime.js");
if (!fs.existsSync(sdk)) die(`${sdk} is missing -- the plugin-sdk layout has changed`);
const sdkSource = fs.readFileSync(sdk, "utf8");
for (const name of SDK_EXPORTS) {
  if (!new RegExp(`\\b${name}\\b`).test(sdkSource)) {
    die(`plugin-sdk/diagnostic-runtime.js no longer exports ${name}`);
  }
}
let specifier = path.relative(path.dirname(target), sdk).split(path.sep).join("/");
if (!specifier.startsWith(".")) specifier = `./${specifier}`;

const anchors = [...source.matchAll(HANDLER)];
if (anchors.length !== 1) {
  die(`expected exactly one A2A request handler in ${target}, found ${anchors.length}`);
}
const [anchor] = anchors;
const indent = anchor[0].match(/^[\t ]*/)[0];
const open = anchor.index + anchor[0].length - 1;
const close = matchingBrace(source, open);
if (close < 0) die("could not find the end of the A2A request handler");

const body = source.slice(open + 1, close);
// The handler answers every path it accepts with `return true`, so this is
// both a shape check on what the brace matcher extracted and a check that the
// route still has the contract the wrapper below assumes.
if (!/\breturn true;\s*$/.test(body)) {
  die("the A2A request handler no longer ends with `return true;` -- re-read the route before patching");
}

const prelude = `import { createChildDiagnosticTraceContext as __asiCreateChildTrace, createDiagnosticTraceContextFromActiveScope as __asiEnsureTraceScope, freezeDiagnosticTraceContext as __asiFreezeTrace, parseDiagnosticTraceparent as __asiParseTraceparent } from "${specifier}";
// ${MARKER}
// The trace scope itself is not on the plugin-sdk surface -- only the helpers
// that build and freeze a context are -- so reach the AsyncLocalStorage through
// the global symbol openclaw registers it under. Calling the active-scope
// helper first is what forces that state to exist: getDiagnosticTraceScopeState()
// defines the property lazily, on its first caller.
//
// Every failure here falls through to running un-traced. A missing or renamed
// scope must cost a trace, never the A2A route.
const __ASI_TRACE_SCOPE = Symbol.for("openclaw.diagnosticTraceScope.state.v1");
function __asiRunWithTrace(upstream, run) {
\ttry {
\t\t__asiEnsureTraceScope();
\t\tconst scope = globalThis[__ASI_TRACE_SCOPE];
\t\tif (typeof scope?.storage?.run !== "function") return run();
\t\treturn scope.storage.run(__asiFreezeTrace(__asiCreateChildTrace(upstream)), run);
\t} catch {
\t\treturn run();
\t}
}
`;

const wrapped = `${indent}return async (request, response) => {
${indent}\t// ${MARKER}: adopt the caller's trace, so a dispatch and the run it
${indent}\t// causes land on one trace instead of one per pod. Node lowercases
${indent}\t// inbound header names; a malformed or absent value parses to
${indent}\t// undefined and the request is handled exactly as before.
${indent}\tconst __asiUpstream = __asiParseTraceparent(request.headers?.traceparent);
${indent}\tconst __asiHandle = async () => {${body}};
${indent}\treturn __asiUpstream ? __asiRunWithTrace(__asiUpstream, __asiHandle) : __asiHandle();
${indent}}`;

const patched = prelude + source.slice(0, anchor.index) + wrapped + source.slice(close + 1);
fs.writeFileSync(target, patched);

try {
  execFileSync(process.execPath, ["--check", target], { stdio: "pipe" });
} catch (error) {
  fs.writeFileSync(target, source);
  die(`patched ${target} does not parse, reverted: ${error.stderr?.toString() ?? error}`);
}

console.log(`patch-a2a-traceparent: patched ${target} (plugin-sdk at ${specifier})`);
