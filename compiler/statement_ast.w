# Production statement nodes own their expression arena. Resolved bindings
# remain valid for the statement's immediate semantic/emission phase.
const int statement_ast_return = 1
const int statement_ast_expression = 2
const int statement_ast_if_header = 3
const int statement_ast_while_header = 4

struct statement_ast:
	int kind
	int root
	int false_target
	expression_ast expressions

int ast_return_statements_emitted

int ast_return_statements_fallback

int ast_expression_statements_emitted
int ast_expression_statements_fallback

# Header counters include conditions and their false branches, not body trees.
int ast_if_headers_emitted
int ast_if_headers_fallback
int ast_while_headers_emitted
int ast_while_headers_fallback
