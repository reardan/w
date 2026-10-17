// Independent ANTLR 4.13.2 API probe. No W parser or classification is consulted.
import java.util.*;
import org.antlr.v4.Tool;
import org.antlr.v4.tool.*;
import org.antlr.v4.tool.ast.*;
import org.antlr.v4.analysis.*;
import org.antlr.v4.parse.ANTLRParser;

public class Inspect extends Tool {
    static String quote(String s) {
        if (s == null) return "null";
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            if (c == '"' || c == '\\') b.append('\\').append(c);
            else if (c < 32) b.append(String.format("\\u%04x", (int)c));
            else b.append(c);
        }
        return b.append('"').toString();
    }
    static class Classify extends LeftRecursiveRuleAnalyzer {
        Map<Integer,String> classes = new TreeMap<>();
        Classify(GrammarAST tree, Tool tool, String name) {
            super(tree, tool, name, "Java");
        }
        public void binaryAlt(AltAST a, int n) { classes.put(n,"binary"); super.binaryAlt(a,n); }
        public void prefixAlt(AltAST a, int n) { classes.put(n,"prefix"); super.prefixAlt(a,n); }
        public void suffixAlt(AltAST a, int n) { classes.put(n,"suffix"); super.suffixAlt(a,n); }
        public void otherAlt(AltAST a, int n) { classes.put(n,"other"); super.otherAlt(a,n); }
    }
    static String references(GrammarAST node, String owner, String rewritten, String path) {
        List<String> values = new ArrayList<>();
        collect(node, owner, rewritten, path, values);
        return "[" + String.join(",", values) + "]";
    }
    static void collect(GrammarAST node, String owner, String rewritten, String path, List<String> values) {
        if (node.getType() == ANTLRParser.RULE_REF && node.getText().equals(owner)) {
            int index = node.getToken().getTokenIndex();
            java.util.regex.Matcher m = java.util.regex.Pattern.compile("tokenIndex=" + index + "(?:,p=(\\d+))?>").matcher(rewritten);
            boolean kept = m.find();
            String binding = kept ? (m.group(1) == null ? "0" : m.group(1)) : "null";
            values.add("{\"token_index\":"+index+",\"ast_path\":"+quote(path)+",\"line\":"+node.getLine()+",\"column\":"+(node.getCharPositionInLine()+1)+",\"binding\":"+binding+",\"removed_left_operand\":"+!kept+"}");
        }
        for (int i=0; i<node.getChildCount(); i++) collect((GrammarAST)node.getChild(i), owner, rewritten, path+"/"+i, values);
    }
    Set<String> wanted;
    Inspect(String[] args, Set<String> wanted) { super(args); this.wanted = wanted; }
    @Override public void process(Grammar g, boolean generate) {
        super.process(g, generate);
        if (g.isLexer() || getNumErrors() > 0) return;
        for (Rule r : g.rules.values()) {
            if (!wanted.contains(r.name)) continue;
            if (!(r instanceof LeftRecursiveRule)) throw new IllegalStateException("not transformed: " + r.name);
            LeftRecursiveRule lr = (LeftRecursiveRule)r;
            Classify c = new Classify(lr.originalAST.dupTree(), this, r.name);
            try { c.rec_rule(); } catch (Exception e) { throw new RuntimeException(e); }
            List<LeftRecursiveRuleAltInfo> infos = new ArrayList<>(lr.recPrimaryAlts);
            infos.addAll(lr.recOpAlts.values());
            System.out.print("{\"rule\":"+quote(r.name)+",\"file\":"+quote(new java.io.File(g.fileName).getName())+",\"line\":"+lr.originalAST.getLine()+",\"alternatives\":[");
            String comma = "";
            for (LeftRecursiveRuleAltInfo a : infos) {
                GrammarAST original = a.originalAltAST;
                System.out.print(comma+"{\"source_alt\":"+a.altNum+",\"line\":"+original.getLine()+",\"column\":"+(original.getCharPositionInLine()+1)+",\"class\":"+quote(c.classes.get(a.altNum))+",\"precedence\":"+c.precedence(a.altNum)+",\"next_precedence\":"+a.nextPrec+",\"assoc\":"+quote(c.altAssociativity.containsKey(a.altNum) ? c.altAssociativity.get(a.altNum).toString() : null)+",\"label\":"+quote(a.altLabel)+",\"source\":"+quote(g.tokenStream.toString(original.getTokenStartIndex(), original.getTokenStopIndex()))+",\"rewritten\":"+quote(a.altText)+",\"owner_references\":"+references(original, r.name, a.altText, "alt")+"}");
                comma = ",";
            }
            System.out.println("]}");
        }
    }
    public static void main(String[] args) {
        Set<String> names = new HashSet<>(Arrays.asList(args[0].split(",")));
        Inspect tool = new Inspect(Arrays.copyOfRange(args,1,args.length), names);
        tool.processGrammarsOnCommandLine();
        if (tool.getNumErrors() > 0) System.exit(1);
    }
}
