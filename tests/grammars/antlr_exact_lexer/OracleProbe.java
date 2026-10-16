// Optional live endpoint oracle. Runs a generated lexer rule in isolation,
// preserving its generated ATN and rule-call targets. Not used by W tests.
import java.lang.reflect.*;
import org.antlr.v4.runtime.*;
import org.antlr.v4.runtime.atn.*;
import org.antlr.v4.runtime.dfa.DFA;
public final class OracleProbe {
  public static void main(String[] args) throws Exception {
    Class<?> klass = Class.forName(args[0]);
    for (int pair = 1; pair < args.length; pair += 2) {
      Lexer lexer = (Lexer) klass.getConstructor(CharStream.class).newInstance(CharStreams.fromString(args[pair+1]));
      int rule = java.util.Arrays.asList(lexer.getRuleNames()).indexOf(args[pair]);
      if (rule < 0) throw new IllegalArgumentException("unknown rule: " + args[pair]);
      ATN atn = lexer.getATN();
      TokensStartState start = new TokensStartState();
      start.addTransition(new EpsilonTransition(atn.ruleToStartState[rule]));
      TokensStartState original = atn.modeToStartState.set(0, start);
      lexer.setInterpreter(new LexerATNSimulator(lexer, atn, new DFA[]{new DFA(start,0)}, new PredictionContextCache()));
      lexer.removeErrorListeners();
      final int[] errors = {0};
      lexer.addErrorListener(new BaseErrorListener() {
        public void syntaxError(Recognizer<?,?> r, Object o, int line, int col, String msg, RecognitionException ex) { errors[0]++; }
      });
      Token token = lexer.nextToken();
      int length = token.getType() == Token.EOF || errors[0] != 0 ? 0 : token.getText().getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
      System.out.println(args[pair] + "\t" + length);
      atn.modeToStartState.set(0, original);
    }
  }
}
