"""CLI refusal must still publish actionable structured audit findings."""
import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(dir=ROOT / 'bin', prefix='audit_json_') as directory:
    directory = pathlib.Path(directory)
    source = directory / 'Proof.g4'
    output = directory / 'out.pg'
    audit = directory / 'audit.json'
    source.write_text("grammar Proof; root: A EOF; A: 'a' {host();};")
    output.write_text('sentinel')
    command = [str(ROOT / 'bin/antlr_to_pg'), str(source), '-o', str(output), '--strict', '--audit-json', str(audit)]
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode != 0, result.stderr
    assert output.read_text() == 'sentinel'
    document = json.loads(audit.read_text())
    assert document['schema_version'] == 1
    finding = next(f for f in document['findings'] if f['code'] == 'AT_HOST_SITE')
    assert finding['rule'] == 'A'
    assert finding['file'] == str(source)
    assert finding['line'] == 1 and finding['column'] > 0
    assert finding['classification'] == 'unsupported'
    source.write_text("grammar Proof; import Missing; root: 'a' EOF;")
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode != 0
    assert any(f['code'] == 'AT_DEPENDENCY' for f in json.loads(audit.read_text())['findings'])
    source.write_text("grammar Proof; root: 'a' EOF; WS: [ \\t\\r\\n]+ -> skip;")
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(audit.read_text())['findings'] == []
    source.write_text("grammar Proof; root: MISSING EOF; A: 'a';")
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode != 0
    codes = {f['code'] for f in json.loads(audit.read_text())['findings']}
    assert {'AT_INFERRED_TOKEN', 'AT_TOKEN_NO_LEXER'} <= codes
    permissive = [arg for arg in command if arg != '--strict']
    result = subprocess.run(permissive, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    generated = directory / 'generated.w'
    result = subprocess.run([str(ROOT / 'bin/parser_generator_grammars'), str(output), '-o', str(generated)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    driver = directory / 'driver.w'
    module = '.'.join(generated.relative_to(ROOT).with_suffix('').parts)
    driver.write_text(f'import {module}\nint main():\n\treturn 0\n')
    result = subprocess.run([str(ROOT / 'bin/wv2'), '--strict', str(driver), '-o', str(directory / 'driver')], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    source.write_text("grammar Proof; root: item EOF; item: other 'a' | 'b'; other: item;")
    output.write_text('sentinel')
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode != 0
    assert output.read_text() == 'sentinel'
    codes = {f['code'] for f in json.loads(audit.read_text())['findings']}
    assert 'AT_LEFT_RECURSION' in codes
    assert 'AT_PARSER_CONTINUATION' not in codes  # no decision proof on unsafe recursion
    # The first implementation wave adds evidence without admitting new shapes.
    # Guard failures and actual remaining call cycles are separate observations.
    exact = [*command, '--exact-lexer', '--prediction']
    report = directory / 'out.report'
    matchers = directory / 'out_matchers.w'
    exact += ['--report', str(report), '--matchers', str(matchers)]
    cases = [
        ("root: expr EOF; expr: expr expr | 'x';", 'expr',
         'operator_prefix_not_proven', ['expr', 'expr'], False),
        ("root: expr EOF; expr: expr ','? expr | 'x';", 'expr',
         'operator_prefix_not_proven', ['expr', 'expr'], False),
        ("root: expr EOF; expr: expr '+' expr | ;", 'expr',
         'empty_alternative', ['expr', 'expr'], False),
        ("root: item EOF; item: other 'a' | 'b'; other: item;", 'item',
         'primary_nullable_prefix_cycle', ['item', 'other', 'item'], True),
    ]
    for grammar, owner, guard_code, cycle, mutual in cases:
        source.write_text('grammar Proof; ' + grammar)
        for path in (output, report, matchers):
            path.write_text('sentinel')
        result = subprocess.run(exact, capture_output=True, text=True)
        assert result.returncode != 0, (grammar, result.stderr)
        assert all(path.read_text() == 'sentinel' for path in (output, report, matchers))
        findings = json.loads(audit.read_text())['findings']
        finding = next(f for f in findings if f['code'] == 'AT_LEFT_RECURSION' and f['rule'] == owner)
        details = finding['details']
        guard = next(g for g in details['normalization_guards'] if g['normalizer'] == 'prediction_expression')
        assert guard['reason_code'] == guard_code, (grammar, details)
        graph = details['remaining_graph']
        assert graph['complete'] and graph['cycles'], details
        assert any(c['path'] == cycle and c['mutual'] == mutual for c in graph['cycles']), details
        assert details['source']['plan']['complete'], details
        if not mutual:
            plan = details['source']['plan']
            binary = plan['alternatives'][0]
            assert binary['kind'] == 'binary', plan
            assert binary['precedence'] == 2, plan
            assert binary['occurrences'][-1]['binding'] == 3, plan
            assert not any(c['mutual'] for c in details['source']['graph']['cycles']), details
    lexer = directory / 'EmptyLexer.g4'
    parser = directory / 'EmptyParser.g4'
    parser.write_text("parser grammar EmptyParser; options {tokenVocab=EmptyLexer;} root: A EOF;")
    for commands in ("mode(DEFAULT_MODE), channel(HIDDEN)", "mode(NEXT)"):
        lexer.write_text("lexer grammar EmptyLexer; A: 'a'; EMPTY: -> " + commands + "; mode NEXT; B: 'b';")
        output.write_text('sentinel')
        result = subprocess.run([str(ROOT / 'bin/antlr_to_pg'), str(lexer), str(parser),
                                 '--strict', '--exact-lexer', '--prediction', '-o', str(output),
                                 '--audit-json', str(audit)], capture_output=True, text=True)
        assert result.returncode != 0, result.stderr
        assert output.read_text() == 'sentinel'
        assert any(f['code'] == 'AT_LEXER_EMPTY' for f in json.loads(audit.read_text())['findings'])
print('structured ANTLR audit: passed')
