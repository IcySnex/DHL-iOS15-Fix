// Fails if the given file still contains a class static block (parsed with acorn, so strings/comments don't count).
import * as acorn from "acorn";
import * as walk from "acorn-walk";
import fs from "node:fs";

const file = process.argv[2];
let left = 0;
walk.full(acorn.parse(fs.readFileSync(file, "utf8"), { ecmaVersion: "latest", sourceType: "script" }), (n) => {
  if (n.type === "StaticBlock") left++;
});
if (left) { console.error(`${file}: ${left} static block(s) left`); process.exit(1); }
