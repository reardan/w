# Golf ergonomics wave 5: words() is every whitespace-separated stdin
# token; join accepts string pieces (here from an f-string map).
# wbuild: x64
# wbuild: stdin="  pear fig\n\tapple  \n"
# wbuild: expect_stdout="3 words" expect_stdout="fig,pear,apple" expect_stdout="<pear>+<fig>+<apple>"
w := words()
println(f"{w.length} words")
println(join(w.sorted_by(len(it)), ","))
println(join(w.map(f"<{it}>"), "+"))
