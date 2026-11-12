"""Run isolated synthetic contract checks using only the existing Python stdlib."""
from pathlib import Path
import ast
import hashlib
import json
import platform
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parent
DENIED_IMPORTS = {'socket', 'http', 'urllib', 'requests', 'subprocess', 'ctypes', 'os', 'boto3', 'azure', 'openai'}

class EvidenceResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.cases = []
        self.started = {}

    def startTest(self, test):
        self.started[test.id()] = time.perf_counter()
        super().startTest(test)

    def record(self, test, status, detail=None):
        row = {'test_id': test.id(), 'status': status,
               'seconds': round(time.perf_counter()-self.started.get(test.id(), time.perf_counter()), 6)}
        if detail:
            row['detail'] = detail
        self.cases.append(row)

    def addSuccess(self, test):
        super().addSuccess(test)
        self.record(test, 'passed')

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.record(test, 'failed', self._exc_info_to_string(err, test))

    def addError(self, test, err):
        super().addError(test, err)
        self.record(test, 'error', self._exc_info_to_string(err, test))

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.record(test, 'skipped', reason)

def main():
    for name in ('reference_model.py', 'test_contracts.py', 'fixtures.json'):
        if not (ROOT/name).is_file():
            raise RuntimeError(f'Not ready: missing {name}')
    imported = set()
    for name in ('reference_model.py', 'test_contracts.py'):
        tree = ast.parse((ROOT/name).read_text(encoding='utf-8-sig'))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(item.name.split('.')[0] for item in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported.add(node.module.split('.')[0])
    forbidden = sorted(imported & DENIED_IMPORTS)
    if forbidden:
        raise RuntimeError(f'Local scope import review needed: {forbidden}')
    # This guard is a source check, not a system firewall or a security certification.
    json.loads((ROOT/'fixtures.json').read_text(encoding='utf-8-sig'))
    schema = json.loads((ROOT/'contract_schema.json').read_text(encoding='utf-8-sig'))
    expected_contracts = [f'C{i:02}' for i in range(1, 8)]
    if schema.get('properties', {}).get('contract_id', {}).get('enum') != expected_contracts:
        raise RuntimeError('Schema catalogue must identify C01-C07')
    references = []
    def review_refs(part):
        if isinstance(part, dict):
            if '$ref' in part:
                ref = part['$ref']
                if not ref.startswith('#/$defs/') or ref[8:] not in schema.get('$defs', {}):
                    raise RuntimeError('Unresolved/nonlocal schema reference')
                references.append(ref)
            for value in part.values():
                review_refs(value)
        elif isinstance(part, list):
            for value in part:
                review_refs(value)
    review_refs(schema)
    sys.path.insert(0, str(ROOT))
    suite = unittest.defaultTestLoader.discover(str(ROOT), pattern='test_contracts.py')
    started = time.perf_counter()
    result = unittest.TextTestRunner(verbosity=2, resultclass=EvidenceResult).run(suite)
    report = {
        'verification_id': 'V-LOCAL-01', 'evidence_version': 1,
        'execution_date_client_timezone': '2026-11-12',
        'python': platform.python_version(), 'platform': platform.system(),
        'scope': 'isolated local synthetic reference-model checks',
        'production_app': False, 'real_postgresql': False, 'real_speech_service': False,
        'real_device_validation': False, 'paid_service_calls': False,
        'source_import_guard': {'forbidden_found': forbidden, 'not_a_firewall': True},
        'schema_catalogue': {'contracts': expected_contracts, 'local_refs_resolved': len(references),
                             'full_json_schema_validator_executed': False},
        'tests_run': result.testsRun,
        'passed_cases': sum(row['status']=='passed' for row in result.cases),
        'failures': len(result.failures), 'errors': len(result.errors),
        'skipped': len(result.skipped), 'successful': result.wasSuccessful(),
        'duration_seconds': round(time.perf_counter()-started, 6),
        'source_sha256': {name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
                          for name in ('reference_model.py', 'test_contracts.py', 'fixtures.json', 'contract_schema.json')},
        'cases': result.cases,
        'limits': ['In-memory reference behavior is not production implementation.',
                   'Does not prove PostgreSQL concurrency, durability or restore behavior.',
                   'Does not prove real pronunciation quality, Flutter media, performance or cloud charges.']
    }
    results_dir = ROOT/'results'
    results_dir.mkdir(exist_ok=True)
    report_path = results_dir/'latest.json'
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({key: report[key] for key in ('verification_id', 'tests_run', 'passed_cases', 'failures', 'errors', 'skipped', 'successful')}, ensure_ascii=True))
    return 0 if result.wasSuccessful() and result.testsRun > 0 else 1

if __name__ == '__main__':
    raise SystemExit(main())
