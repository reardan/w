# wbuild: target=antlr_to_pg_dependencies_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 tests/antlr_to_pg_dependencies_test.w -o bin/antlr_to_pg_dependencies_test"
# wbuild: step="bin/antlr_to_pg_dependencies_test"
# wbuild: step="sh tests/grammars/antlr_dependencies/check.sh"
import lib.assert
import libs.extras.grammars.antlr_to_pg.dependencies
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.charsets
import libs.extras.grammars.antlr_to_pg.matchers_ascii
import libs.extras.grammars.antlr_to_pg.matchers_analyze
import libs.extras.grammars.antlr_to_pg.matchers_emit
import libs.extras.grammars.antlr_to_pg.audit


int main():
	list[char*] words = at_dependency_words(c"{ /* tokenVocab=Wrong; */ tokenVocab = Lex; superClass = 'tokenVocab=Other;'; // comment\n }")
	assert_equal(10, words.length)
	assert_strings_equal(c"tokenVocab", words[1])
	assert_strings_equal(c"Lex", words[3])
	assert_strings_equal(c"'tokenVocab=Other;'", words[7])
	assert_equal(1, at_dependency_identifier(c"_Grammar2"))
	assert_equal(0, at_dependency_identifier(c"../Grammar"))
	assert_equal(0, at_dependency_identifier(c"'Grammar'"))
	assert_equal(0, at_dependency_identifier(c""))
	println(c"antlr dependency tokenization tests passed")
	return 0
