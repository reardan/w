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

## Typed chaining through method return values

Method chaining through a method return value works:

```
p.child().move(1, 2)
```

This section originally deferred chaining because generic call parsing
collapsed most non-float return values to the generic constant type.
That is no longer true: `parse_call_suffix` in `grammar/postfix_expr.w`
returns the callee's declared return type (as a value-marked type), so a
following postfix suffix has a precise type to dispatch against.

What chains today, on all targets:

- methods returning `Struct*` feed further method calls, field reads and
  field writes (`h.child().x = 42`);
- methods returning `Struct` by value park the return buffer on the
  stack and feed method receivers and field access the same way,
  including structs whose size is not a whole number of words;
- chains run to arbitrary depth (`p.set_x(1).set_y(2).sum()`) and work
  in statement, call-argument, condition and return position;
- free-function results chain the same way
  (`make_holder().child().sum()`);
- container-returning methods (e.g. `list[int]`) accept their built-in
  suffixes (`[i]`, `.length`).

Covered end to end by `tests/method_chaining_test.w` (with an x64 twin).

Chaining onto a call result that is not a struct — for example a second
`.sum()` on an int-returning method — is a compile error:

```
member 'sum' on non-struct type 'int'
```

The parser previously inherited cc500's silent-ignore for `.member` on
non-struct expressions, which compiled such chains into a call through a
garbage receiver that crashed at runtime. The message is asserted by
`tests/method_chain_error_fixture.w` (part of `type_system_error_test`).

