# Production statement nodes own their expression arena. Resolved bindings
# remain valid for the statement's immediate semantic/emission phase.
const int statement_ast_return = 1
const int statement_ast_expression = 2

struct statement_ast:
	int kind
	int root
	expression_ast expressions

int ast_return_statements_emitted

int ast_return_statements_fallback

int ast_expression_statements_emitted
int ast_expression_statements_fallback
