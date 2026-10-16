# Iterative logical, comma, and conditional expressions

After numeric bitwise coercion, unchanged Preact reached Win's evaluator depth
limit during initial render. A scripted W debugger session measured depth 128
(the configured bound) with 992257 fuel remaining, and repeated left-operand
frames for a minified `&&` chain. Increasing the browser's limits was unnecessary.

`&&`, `||`, `??`, comma, and conditional (`?:`) AST trees now use an explicit bounded
work list. Left/right operands retain source order; logical chains return the
same original operand value and stop before evaluating unneeded operands.
Each AST node retains its own operator and branching; mixed logical/comma/conditional
nodes do not require evaluator recursion. Other operators retain normal nesting. Every visited logical/comma/conditional
node consumes its original fuel step, and leaf evaluation keeps all existing
call/depth/fuel checks. Work-list entries are capped by `max_properties`.

The work list owns only its container and borrows AST nodes from the existing
script/module lifetime. Await can suspend inside a leaf using the existing task
roots and stack ownership; rejection or cancellation unwinds the evaluator and
frees the work list. No source rewrites, raised fuel/depth limits, or synchronous
await shortcuts are involved.

Tests check original operand identity, exact order and short circuiting, mixed
and parenthesized chains, comma's unbound-call behavior, exceptions, async resume
and cancellation across GC, deep chains under a small evaluator depth bound,
unchanged recursive-call rejection, exact per-node fuel, and work-list limits.
Primary specification: [Binary Logical Operators](https://tc39.es/ecma262/#sec-binary-logical-operators)
and [Comma Operator](https://tc39.es/ecma262/#sec-comma-operator).

The first native form submission exposed conditional nesting during Preact’s
update render: depth 128 with 983265 fuel remaining. Including conditional nodes
in the same work list preserves test-before-branch evaluation and evaluates
only the selected branch. The unchanged workflow then reaches Ready, submits
a real POST, and redraws the successful response under the original limits.
Focused tests also cover selected-branch identity, skipped exceptions, nested
conditionals, exact fuel, and suspension while evaluating the condition. See
[Conditional Operator](https://tc39.es/ecma262/multipage/ecmascript-language-expressions.html#sec-conditional-operator-runtime-semantics-evaluation).
