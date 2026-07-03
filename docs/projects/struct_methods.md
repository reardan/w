# Struct methods

W supports method-call syntax as sugar over the existing free-function
convention:

```
point p
p.move(1, 2)
```

lowers to:

```
point_move(&p, 1, 2)
```

For `point* p`, the receiver pointer is loaded and passed directly:

```
p.move(1, 2)  # point_move(p, 1, 2)
```

Field lookup has precedence over method lookup, so function-pointer fields keep
working:

```
runner.run()
```

calls the `run` field when the struct has one, not `runner_run`.

## Deferred: typed chaining through method return values

Method chaining through a method return value is intentionally not supported by
the initial implementation:

```
p.child().move(1, 2)
```

The blocker is not the method-call sugar itself. Normal call expressions still
collapse most non-float return values to the generic constant type after codegen,
so the following postfix `.` has no precise struct or pointer type to dispatch
against. Fixing this should update call-result typing in `grammar/postfix_expr.w`
so direct calls preserve the callee's declared return type when safe.

## GitHub issue draft

Title: Preserve direct call return types so method chaining can work

Body:

- Struct method calls currently work when the receiver expression already has a
  precise struct or struct-pointer type, for example `p.move(1, 2)`.
- Chaining through a method result, for example `p.child().move(1, 2)`, is still
  blocked because generic call parsing returns type `3` for most non-float
  calls.
- Implement direct-call result typing in `grammar/postfix_expr.w` so the parser
  returns the declared callee return type where available, then add tests for
  `Struct*` and struct-field method chaining.

