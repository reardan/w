import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.antlr.v4.runtime.*;
import org.antlr.v4.runtime.tree.ParseTree;

/** Small stable wire format; symbolic names and UTF-8 byte offsets, not token IDs. */
public final class Oracle {
    private static final class Errors extends BaseErrorListener {
        int count;
        @Override public void syntaxError(Recognizer<?, ?> recognizer, Object symbol,
                int line, int column, String message, RecognitionException error) { count++; }
    }
    private static int byteOffset(String input, int codePoints) {
        int end = input.offsetByCodePoints(0, Math.min(codePoints, input.codePointCount(0, input.length())));
        return input.substring(0, end).getBytes(StandardCharsets.UTF_8).length;
    }
    private static String hex(String value) {
        StringBuilder result = new StringBuilder();
        for (byte item : value.getBytes(StandardCharsets.UTF_8)) result.append(String.format("%02x", item & 255));
        return result.toString();
    }
    private static void rules(ParseTree node, Parser parser, String input) {
        if (node instanceof ParserRuleContext) {
            ParserRuleContext context = (ParserRuleContext) node;
            int start = byteOffset(input, context.getStart().getStartIndex());
            int end = byteOffset(input, context.getStop().getStopIndex() + 1);
            System.out.printf("RULE\t%s\t%d\t%d%n", parser.getRuleNames()[context.getRuleIndex()], start, end - start);
        }
        for (int i = 0; i < node.getChildCount(); i++) rules(node.getChild(i), parser, input);
    }
    public static void main(String[] args) throws Exception {
        String input = Files.readString(Path.of(args[3]), StandardCharsets.UTF_8);
        Lexer lexer = (Lexer) Class.forName(args[0]).getConstructor(CharStream.class)
            .newInstance(CharStreams.fromString(input));
        Errors errors = new Errors();
        lexer.removeErrorListeners();
        lexer.addErrorListener(errors);
        CommonTokenStream tokens = new CommonTokenStream(lexer);
        tokens.fill();
        for (Token token : tokens.getTokens()) {
            boolean eof = token.getType() == Token.EOF;
            String name = eof ? "EOF" : lexer.getVocabulary().getSymbolicName(token.getType());
            if (name == null) name = lexer.getVocabulary().getLiteralName(token.getType());
            int start = byteOffset(input, token.getStartIndex());
            int end = eof ? start : byteOffset(input, token.getStopIndex() + 1);
            System.out.printf("TOKEN\t%s\t%d\t%d\t%d\t%s%n", name, token.getChannel(), start,
                end - start, end == start ? "" : hex(token.getText()));
        }
        tokens.seek(0);
        Parser parser = (Parser) Class.forName(args[1]).getConstructor(TokenStream.class).newInstance(tokens);
        parser.removeErrorListeners();
        parser.addErrorListener(errors);
        ParseTree root = (ParseTree) parser.getClass().getMethod(args[2]).invoke(parser);
        boolean accepted = errors.count == 0 && tokens.LA(1) == Token.EOF;
        System.out.println("ACCEPT\t" + (accepted ? "1" : "0"));
        if (accepted) rules(root, parser, input);
    }
}
