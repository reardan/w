import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import org.antlr.v4.runtime.*;
import org.antlr.v4.runtime.tree.*;

/** Canonical context/operand tree: retains grouping, context labels and token text. */
public final class TreeOracle {
    static final class Errors extends BaseErrorListener {
        int count;
        @Override public void syntaxError(Recognizer<?,?> r, Object s, int l, int c,
                String message, RecognitionException e) { count++; }
    }
    static String tree(ParseTree t, Parser p) {
        if (t instanceof TerminalNode) {
            Token token = ((TerminalNode)t).getSymbol();
            return "{\"token\":" + Inspect.quote(token.getText()) + "}";
        }
        ParserRuleContext c = (ParserRuleContext)t;
        StringBuilder out = new StringBuilder("{\"rule\":").append(Inspect.quote(p.getRuleNames()[c.getRuleIndex()]))
            .append(",\"context\":").append(Inspect.quote(c.getClass().getSimpleName())).append(",\"children\":[");
        for (int i=0; i<t.getChildCount(); i++) {
            if (i>0) out.append(',');
            out.append(tree(t.getChild(i), p));
        }
        return out.append("]}").toString();
    }
    public static void main(String[] args) throws Exception {
        Lexer lexer = (Lexer)Class.forName(args[0]+"Lexer").getConstructor(CharStream.class)
            .newInstance(CharStreams.fromPath(Path.of(args[2]), StandardCharsets.UTF_8));
        Errors errors = new Errors();
        lexer.removeErrorListeners(); lexer.addErrorListener(errors);
        CommonTokenStream tokens = new CommonTokenStream(lexer);
        tokens.fill(); tokens.seek(0);
        Parser p = (Parser)Class.forName(args[0]+"Parser").getConstructor(TokenStream.class).newInstance(tokens);
        p.removeErrorListeners(); p.addErrorListener(errors);
        ParseTree result = (ParseTree)p.getClass().getMethod(args[1]).invoke(p);
        boolean accepted = errors.count==0 && tokens.LA(1)==Token.EOF;
        System.out.println("{\"accepted\":"+accepted+",\"complete\":"+(tokens.LA(1)==Token.EOF)+",\"tree\":"+(accepted?tree(result,p):"null")+"}");
    }
}
