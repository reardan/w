// Host support for the unmodified upstream Z grammar's InfixLeft/InfixRight
// predicate. grammars-v4's ZSupport answers from an operator table that its
// ZOperatorParser pre-pass fills; without that pre-pass the table is empty and
// every operator is left associative. W's permissive translation ignores the
// predicate, which is the same assumption, so the oracle states it explicitly.
import org.antlr.v4.runtime.TokenStream;

public class ZSupport {
	static boolean isLeftAssociative(TokenStream tokens) {
		return true;
	}
}
