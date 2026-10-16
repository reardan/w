# wbuild: target=antlr_channels_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg tests/grammars/antlr_channels/ChannelsParser.g4 -o bin/antlr_channels.pg --parser-name channels --strict --matchers bin/antlr_channels_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_channels.pg -o bin/antlr_channels_parser.w"
# wbuild: step="bin/wv2 --strict tests/antlr_channels_test.w -o bin/antlr_channels_test"
# wbuild: step="bin/antlr_channels_test"
import lib.testing
import bin.antlr_channels_matchers
import bin.antlr_channels_parser

void test_custom_channels_preserve_tokens_without_error_channel():
	pg_parse_result* result = channels_parse_owned(c"#comment a!", 11, c"channels")
	pg_diagnostics_print(result.diagnostics)
	assert_equal(1, result.success)
	assert_equal(0, pg_diagnostics_count(result.diagnostics))
	assert_equal(2, result.stream.tokens.length)
	assert_equal(channels_channel_AT_CHANNEL_COMMENTS, result.stream.all_tokens[0].channel)
	assert_equal(3, result.stream.all_tokens[0].channel)
	assert_equal(channels_channel_AT_CHANNEL_EXTRA, result.stream.all_tokens[3].channel)
	assert_equal(4, result.stream.all_tokens[3].channel)
	char* source = pg_token_stream_source(result.stream)
	assert_strings_equal(c"#comment a!", source)
	free(source)
	pg_parse_result_free(result)
