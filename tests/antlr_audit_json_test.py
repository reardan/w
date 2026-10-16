"""CLI refusal must still publish actionable structured audit findings."""
import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(dir=ROOT / 'bin', prefix='audit-json-') as directory:
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
print('structured ANTLR audit: passed')
