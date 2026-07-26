# Safer ':=' (issue #360): ':=' declares a NEW variable, so reusing it
# on a name still visible as a local is almost always a bug (the writer
# meant '='). The redeclaration is an error instead of a silent shadow.
# expect_fail
# expect_stderr: ':=' redeclares 'x'; use '=' to assign, or a typed declaration to shadow
x := 1
x := 2
println(x)
