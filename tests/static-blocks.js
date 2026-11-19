// Fixture for `make test`: the lowered copy must print exactly the same as this file.
// Covers the tokenizer edge cases: strings, comments, regex literals and template
// literals that contain `static{` or braces, nested classes, `this` and `super`.
const log = [];

const re = /static{[}]/g, tpl = `a${ { x: 1 }.x }static{b}`; // static { not a block }
/* static { also not a block } */

class A {
  static x = 1;
  static { this.y = this.x + 1; const s = "static{"; log.push("A1"); }
  static z() { return /}/.test("}") && `}` === "}"; }
  static {
    this.w = `${this.y}}`;
    this.inner = class { static { this.v = 42; } };
    log.push("A2");
  }
}

class B extends A {
  static { this.v = super.z() && this.y; }
  static
  {
    // block on its own line, with a comment
    var local = [1, 2, 3].map((n) => n * 2);
    this.list = local;
  }
}

const o = { static: 1, f() { return this.static; } };
const C = class { static #p = 5; static { this.p = this.#p ?? 0; } };

console.log(JSON.stringify([log, A.y, A.w, A.inner.v, B.v, B.list, re.source, tpl, o.f(), C.p]));
