// Crawl an ES module graph from dhl.de and report syntax that Safari 15 (iOS 15) cannot parse.
// usage: node analyze.mjs <outdir> <entry-url> [entry-url...]
import * as acorn from "acorn";
import * as walk from "acorn-walk";
import fs from "node:fs";
import path from "node:path";

const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [DHL Paket iOS App/9.16.1 (1731)]";
const [outdir, ...entries] = process.argv.slice(2);
fs.mkdirSync(outdir, { recursive: true });

const seen = new Set();
const queue = [...entries];
const totals = {};

function report(url, kind, node, src) {
  totals[kind] = (totals[kind] || 0) + 1;
  if (totals[kind] <= 3) console.log(`  ${kind} @${node.start}: ${src.slice(node.start, node.start + 90).replace(/\s+/g, " ")}`);
}

while (queue.length) {
  const url = queue.shift();
  if (seen.has(url)) continue;
  seen.add(url);
  const res = await fetch(url, { headers: { "user-agent": UA } });
  const src = await res.text();
  fs.writeFileSync(path.join(outdir, path.basename(new URL(url).pathname)), src);
  console.log(`${res.status} ${src.length} ${url}`);

  let ast;
  try {
    ast = acorn.parse(src, { ecmaVersion: "latest", sourceType: "module", allowHashBang: true });
  } catch (e) {
    console.log("  acorn parse error:", e.message);
    continue;
  }

  const deps = [];
  walk.full(ast, (node) => {
    switch (node.type) {
      case "ImportDeclaration":
      case "ExportAllDeclaration":
      case "ExportNamedDeclaration":
        if (node.source) deps.push(node.source.value);
        break;
      case "ImportExpression":
        if (node.source.type === "Literal") deps.push(node.source.value);
        else report(url, "dynamic-import(non-literal)", node, src);
        break;
      case "StaticBlock":
        report(url, "class-static-block", node, src);
        break;
      case "Literal":
        if (node.regex) {
          const { pattern, flags } = node.regex;
          if (/\(\?<[=!]/.test(pattern)) report(url, "regex-lookbehind", node, src);
          if (flags.includes("v")) report(url, "regex-v-flag", node, src);
          if (/\(\?[ims]+[:-]/.test(pattern)) report(url, "regex-modifiers", node, src);
        }
        break;
      case "BinaryExpression":
        if (node.operator === "in" && node.left.type === "PrivateIdentifier") report(url, "private-in", node, src);
        break;
      case "ImportSpecifier":
      case "ExportSpecifier":
        if ((node.imported || node.local)?.type === "Literal" || node.exported?.type === "Literal") report(url, "string-module-names", node, src);
        break;
      case "ImportAttribute":
        report(url, "import-attributes", node, src);
        break;
    }
  });
  for (const d of deps) {
    if (d.startsWith(".") || d.startsWith("/")) queue.push(new URL(d, url).href);
  }
}

console.log("\nTOTALS", totals);
