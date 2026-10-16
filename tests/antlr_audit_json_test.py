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
