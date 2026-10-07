"""Measure public entrypoint captures without inferring tokens or successful work."""
import argparse
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
import unittest

for stream in (sys.stdin, sys.stdout, sys.stderr):
    if hasattr(stream, 'reconfigure'): stream.reconfigure(encoding='utf-8')

SURFACES = {'gui', 'cli', 'mcp'}
SCENARIOS = {'success', 'target_disappeared', 'unauthenticated', 'large_output', 'response_lost'}
CONDITIONS = {'os', 'cli', 'provider', 'model', 'effort', 'authentication', 'temperature', 'input_sha256', 'expected_artifact_sha256'}
REQUIRED_PHASES = {'project', 'pane', 'provider', 'work', 'state', 'artifact', 'terminal'}
PHASE_OPERATIONS = {'project': {'project.select'}, 'pane': {'pane.create'}, 'provider': {'agent.launch'},
    'work': {'input.write'}, 'state': {'run.get'}, 'artifact': {'artifact.read', 'artifact.diff'},
    'terminal': {'run.interrupt', 'run.get', 'pane.close'}}
OUTPUT_CASES = {'utf8_split', 'cursor_expired', 'ring_gap', 'large_output', 'cancel', 'gap', 'truncated'}


def require(value, message):
    if not value:
        raise ValueError(message)


def hash_bytes(raw):
    return hashlib.sha256(raw).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key')
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw.decode('utf-8', errors='strict'), object_pairs_hook=unique_object,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Non-finite JSON number')))


def compact(raw):
    return json.dumps(raw, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')


def plain_file(path):
    path = Path(path)
    require(path.is_absolute() and path.is_file(), 'Absolute regular capture file required')
    for part in [path, *path.parents]:
        require(not part.is_symlink() and not part.is_junction(), 'Linked capture path refused')
    return path


def bound_file(root, descriptor):
    require(set(descriptor) == {'path', 'sha256'}, 'Exact capture file identity required')
    relative = PurePosixPath(descriptor['path'])
    require(not relative.is_absolute() and relative.parts
        and all(part not in ('.', '..') and ':' not in part and '\\' not in part for part in relative.parts),
        'Capture path escapes its root')
    path = plain_file(root.joinpath(*relative.parts))
    raw = path.read_bytes()
    require(hash_bytes(raw) == descriptor['sha256'], 'Capture bytes changed')
    return raw


def integer(value, name):
    require(type(value) is int and value >= 0, name + ' must be a measured nonnegative integer')
    return value


def exchange(root, surface, event):
    begin = integer(event['send_begin_ns'], 'send_begin_ns')
    sent = event['send_completed_ns']
    if sent is not None: sent = integer(sent, 'send_completed_ns')
    observed = integer(event.get('attempt_ended_ns', event.get('response_observed_ns')), 'attempt_ended_ns')
    require(begin <= observed and (sent is None or begin <= sent <= observed), 'Monotonic clock order differs')
    request_raw = bound_file(root, event['request_file'])
    request = decode(request_raw)
    response_descriptor = event.get('response_file')
    response_raw = bound_file(root, response_descriptor) if response_descriptor is not None else None
    logical_request = request['params']['arguments'] if surface == 'mcp' else request
    logical_sha = hash_bytes(json.dumps(logical_request, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))
    if sent is None or response_raw is None:
        require(response_raw is None, 'Failed send cannot contain an observed reply')
        require(event.get('failure_evidence'), 'Missing reply or failed send needs actual failure evidence')
        bound_file(root, event['failure_evidence'])
        operation_id = logical_request['operation_id'] if surface != 'gui' else event['operation_id']
        operation = logical_request['operation'] if surface != 'gui' else event['native_gui_operation']
        return {'operation_id': operation_id, 'operation': operation,
            'logical_request_sha256': logical_sha, 'request_sha256': hash_bytes(request_raw), 'request_bytes': len(request_raw),
            'response_sha256': None, 'response_bytes': None, 'returned_body_utf8_bytes': None,
            'projected_metadata_compact_json_utf8_bytes': None, 'round_trip_ns': None,
            'send_begin_ns': begin, 'response_observed_ns': observed,
            'send_completed': sent is not None, 'response_observed': False,
            'accepted': None, 'refusal_code': None, 'unchanged_wait': None}
    envelope = decode(response_raw)
    if surface == 'mcp':
        require(envelope.get('id') == request.get('id'), 'MCP response id differs')
        require(request.get('method') == 'tools/call', 'Public MCP tool call required')
        request = request['params']['arguments']
        result = envelope['result']
        response = decode(result['content'][0]['text'].encode('utf-8'))
        require(response == result['structuredContent'], 'MCP representations differ')
    elif surface == 'cli':
        response = envelope
    else:
        # GUI capture is public native Cua output, not a forged workspace reply.
        require(event.get('native_gui_operation') and envelope.get('structuredContent'), 'Native GUI capture required')
        require(not envelope.get('isError', False), 'Native GUI action was refused')
        response = None
    if response is not None:
        require(request['schema_version'] == response['schema_version'] == 1, 'Workspace schema differs')
        require(request['operation_id'] == response['operation_id'] and request['instance_id'] == response['instance_id'],
            'Workspace response identity differs')
        operation_id = request['operation_id']
        operation = request['operation']
        data = response.get('result')
        require(data is None or data.get('operation') == operation, 'Result operation differs from its request')
        text = data['data'].get('text') if isinstance(data, dict) and isinstance(data.get('data'), dict) else None
        require(text is None or isinstance(text, str), 'Returned output text is not text')
        body = (text or '').encode('utf-8', errors='strict')
        metadata = dict(response)
        if text is not None:
            metadata = decode(compact(response))
            del metadata['result']['data']['text']
        metadata_bytes = len(compact(metadata))
        accepted = response['accepted']
        require(type(accepted) is bool, 'Acceptance is not a boolean')
        refusal = response['error']['code'] if response.get('error') else None
        unchanged_wait = operation == 'events.wait' and isinstance(data, dict) and data.get('data', {}).get('events') == []
    else:
        operation_id, operation = event['operation_id'], event['native_gui_operation']
        body = bound_file(root, event['visible_body_file']) if event.get('visible_body_file') else None
        if body is not None: body.decode('utf-8', errors='strict')
        metadata_bytes = None
        accepted, refusal, unchanged_wait = None, None, None
    return {'operation_id': operation_id, 'operation': operation,
        'logical_request_sha256': logical_sha, 'send_completed': True, 'response_observed': True,
        'request_sha256': hash_bytes(request_raw), 'request_bytes': len(request_raw),
        'response_sha256': hash_bytes(response_raw), 'response_bytes': len(response_raw),
        'returned_body_utf8_bytes': len(body) if body is not None else None,
        'projected_metadata_compact_json_utf8_bytes': metadata_bytes,
        'round_trip_ns': observed - begin, 'send_begin_ns': begin, 'response_observed_ns': observed,
        'accepted': accepted, 'refusal_code': refusal, 'unchanged_wait': unchanged_wait}


def summarize(events):
    require(events, 'No observed exchanges')
    prior = {}
    retries = 0
    for event in events:
        key = event['operation_id']
        if key in prior:
            require(prior[key] == (event['operation'], event['logical_request_sha256']), 'Retry changed its logical operation or request')
            retries += 1
        prior[key] = (event['operation'], event['logical_request_sha256'])
    metadata = [row['projected_metadata_compact_json_utf8_bytes'] for row in events]
    return {'api_calls': len(events), 'retries': retries,
        'send_failures': sum(not row['send_completed'] for row in events),
        'missing_responses': sum(row['send_completed'] and not row['response_observed'] for row in events),
        'wait_calls': sum(row['operation'] == 'events.wait' for row in events),
        'unchanged_waits': sum(row['unchanged_wait'] is True for row in events),
        'refused_calls': sum(row['accepted'] is False for row in events),
        'request_wire_utf8_bytes': sum(row['request_bytes'] for row in events),
        'observed_response_wire_utf8_bytes': sum(row['response_bytes'] for row in events if row['response_bytes'] is not None),
        'response_wire_utf8_bytes': sum(row['response_bytes'] for row in events) if all(row['response_observed'] for row in events) else None,
        'returned_body_utf8_bytes': sum(row['returned_body_utf8_bytes'] for row in events)
            if all(row['returned_body_utf8_bytes'] is not None for row in events) else None,
        'projected_metadata_compact_json_utf8_bytes': sum(metadata) if all(value is not None for value in metadata) else None,
        'observation_span_ns': max(row['response_observed_ns'] for row in events) - min(row['send_begin_ns'] for row in events),
        'round_trip_ns': [row['round_trip_ns'] for row in events],
        'provider_tokens': None, 'cached_input_tokens': None, 'cost_usd': None,
        'limits': 'Observation span includes idle/operator intervals between exchanges and is not provider processing time. Metadata bytes are an explicit compact JSON projection, not wire partitioning. Missing GUI text, token/cache/cost and missing replies stay unknown. No worker stopping or hidden use is inferred.'}


def inspect_observer(root, batches):
    root = Path(root)
    rows = {'cli': [], 'mcp': []}
    for ordinal in batches:
        path = plain_file(root / f'batch-{ordinal:04d}-result.json')
        batch = decode(path.read_bytes())
        require(set(batch) == {'cli', 'mcp'}, 'Both actual clients required')
        for surface, event in batch.items():
            record = dict(event, request_file={'path': f'{surface}-{ordinal:04d}.request.raw.json', 'sha256': event['request_raw_sha256']},
                response_file={'path': f'{surface}-{ordinal:04d}.response.raw.json', 'sha256': event['response_raw_sha256']})
            checked = exchange(root, surface, record)
            rows[surface].append(checked)
    return {'schema': 'winsmux-efficiency-observation/v1', 'scope': 'Existing actual CLI/MCP capture instrumentation only; not the fixed three-entry journey or an improvement comparison',
        'surfaces': {surface: summarize(events) for surface, events in rows.items()},
        'task_complete': False, 'parent_adopted': False}


def load_group(path):
    path = plain_file(Path(path))
    group = decode(path.read_bytes())
    require(group.get('schema') == 'winsmux-efficiency-comparison-input/v1', 'Unknown comparison input')
    require(group.get('input_classification') == 'sanitized_native_captures', 'Sanitized native captures required')
    require(set(group['conditions']) == CONDITIONS, 'Exact matching conditions required')
    require(re.fullmatch('[a-f0-9]{40}', group.get('candidate_tree_sha', ''))
        and re.fullmatch('[a-f0-9]{64}', group.get('binary_sha256', '')), 'Candidate source and binary identity required')
    require(group.get('quality_evidence') and group['quality_evidence'].get('q_id') == 'Q-OUTPUT', 'Required output-boundary proof missing')
    quality = decode(bound_file(path.parent, group['quality_evidence']['file']))
    require(quality.get('passed') is True and quality.get('candidate_sha256') == group['binary_sha256'], 'Output proof is not successful for this candidate')
    require(set(quality.get('cases', {})) == OUTPUT_CASES and all(value == 'pass' for value in quality['cases'].values()),
        'Required output-boundary case evidence incomplete')
    samples = {}
    for sample in group['samples']:
        key = (sample['surface'], sample['scenario'], sample['trial_id'])
        require(key[0] in SURFACES and key[1] in SCENARIOS and key not in samples, 'Unknown or duplicate sample')
        events = [exchange(path.parent, key[0], event) for event in sample['events']]
        require({event.get('phase') for event in sample['events']} >= REQUIRED_PHASES, 'Incomplete protected journey')
        for capture_event, measured in zip(sample['events'], events):
            phase = capture_event.get('phase')
            require(phase in PHASE_OPERATIONS and measured['operation'] in PHASE_OPERATIONS[phase], 'Journey phase does not match its actual operation')
        require(sample['expected_outcome'] == sample['actual_outcome'] and sample['refusal_preserved'] is True, 'Wrong outcome or preservation not proved')
        samples[key] = summarize(events)
        if sample.get('runtime_usage'):
            usage = sample['runtime_usage']
            require(usage.get('source_kind') == 'public_runtime_json', 'Runtime usage source is not public runtime JSON')
            runtime = decode(bound_file(path.parent, usage['file']))
            require(set(usage['fields']) <= {'provider_tokens', 'cached_input_tokens', 'cost_usd'}, 'Unknown runtime usage metric')
            for name, pointer in usage['fields'].items():
                value = runtime
                for part in pointer: value = value[part]
                require(type(value) in (int, float) and value >= 0 and (type(value) is int or math.isfinite(value)),
                    'Runtime usage is not a measured finite nonnegative value')
                if name != 'cost_usd': require(type(value) is int, 'Runtime token count is not an integer')
                samples[key][name] = value
            samples[key]['runtime_usage_source_sha256'] = usage['file']['sha256']
    require({(surface, scenario) for surface, scenario, _ in samples} == {(surface, scenario) for surface in SURFACES for scenario in SCENARIOS},
        'Missing required entrypoint or scenario')
    return group, samples


def compare(baseline_path, candidate_path):
    baseline, before = load_group(baseline_path)
    candidate, after = load_group(candidate_path)
    require(baseline['conditions'] == candidate['conditions'], 'Input or environment comparison conditions differ')
    require(set(before) == set(after), 'Comparison trial inventory differs')
    return {'schema': 'winsmux-efficiency-comparison/v1', 'scope': 'Matched native capture measurement; independent journey and source evidence remains required',
        'conditions': baseline['conditions'], 'baseline_tree': baseline['candidate_tree_sha'], 'candidate_tree': candidate['candidate_tree_sha'],
        'samples': [{'surface': key[0], 'scenario': key[1], 'trial_id': key[2], 'baseline': before[key], 'candidate': after[key],
            'delta_api_calls': after[key]['api_calls'] - before[key]['api_calls'],
            'delta_response_wire_bytes': after[key]['response_wire_utf8_bytes'] - before[key]['response_wire_utf8_bytes']
                if after[key]['response_wire_utf8_bytes'] is not None and before[key]['response_wire_utf8_bytes'] is not None else None,
            'delta_observation_span_ns': after[key]['observation_span_ns'] - before[key]['observation_span_ns']} for key in sorted(before)],
        'threshold_applied': False, 'parent_adopted': False}


class MeasurementContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='winsmux-efficiency-selftest-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.request = {'schema_version': 1, 'instance_id': 'fixture-instance', 'operation_id': 'fixture-operation', 'operation': 'output.read', 'params': {}}
        self.response = {'schema_version': 1, 'instance_id': 'fixture-instance', 'operation_id': 'fixture-operation', 'accepted': True, 'error': None,
            'result': {'operation': 'output.read', 'data': {'text': '日本語😀', 'events': []}}}
    def row(self, surface='cli'):
        request, response = self.request, self.response
        if surface == 'mcp':
            request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'arguments': request}}
            response = {'jsonrpc': '2.0', 'id': 1, 'result': {'content': [{'text': compact(response).decode('utf-8')}], 'structuredContent': response}}
        raw_request, raw_response = compact(request) + b'\n', compact(response) + b'\n'
        (self.root / 'request.json').write_bytes(raw_request)
        (self.root / 'response.json').write_bytes(raw_response)
        return {'send_begin_ns': 10, 'send_completed_ns': 12, 'response_observed_ns': 30,
            'request_file': {'path': 'request.json', 'sha256': hash_bytes(raw_request)},
            'response_file': {'path': 'response.json', 'sha256': hash_bytes(raw_response)}}
    def test_actual_utf8_bytes(self):
        value = exchange(self.root, 'cli', self.row())
        self.assertEqual(value['returned_body_utf8_bytes'], 13)
        self.assertEqual(value['round_trip_ns'], 20)
        self.assertIsNone(summarize([value])['provider_tokens'])
        self.assertIsNone(summarize([value])['cost_usd'])
    def test_mcp_overhead_keeps_same_body(self):
        cli = exchange(self.root, 'cli', self.row())
        mcp = exchange(self.root, 'mcp', self.row('mcp'))
        self.assertEqual(cli['returned_body_utf8_bytes'], mcp['returned_body_utf8_bytes'])
        self.assertGreater(mcp['response_bytes'], cli['response_bytes'])
    def test_refusal_is_counted(self):
        self.response.update(accepted=False, error={'code': 'permission_denied'}, result=None)
        result = summarize([exchange(self.root, 'cli', self.row())])
        self.assertEqual(result['refused_calls'], 1)
        self.assertEqual(result['returned_body_utf8_bytes'], 0)
    def test_retries_are_not_discarded(self):
        row = exchange(self.root, 'cli', self.row())
        value = summarize([row, row])
        self.assertEqual((value['api_calls'], value['retries']), (2, 1))
        self.assertEqual(value['response_wire_utf8_bytes'], row['response_bytes'] * 2)
    def test_retry_payload_change_refused(self):
        row = exchange(self.root, 'cli', self.row())
        with self.assertRaises(ValueError): summarize([row, dict(row, logical_request_sha256='different')])
    def test_missing_reply_remains_missing(self):
        row = self.row(); row['response_file'] = None
        (self.root / 'failure.txt').write_bytes(b'observed EOF before reply')
        row['failure_evidence'] = {'path': 'failure.txt', 'sha256': hash_bytes((self.root / 'failure.txt').read_bytes())}
        result = summarize([exchange(self.root, 'cli', row)])
        self.assertEqual(result['missing_responses'], 1)
        self.assertIsNone(result['response_wire_utf8_bytes'])
        self.assertIsNone(result['returned_body_utf8_bytes'])
    def test_failed_send_is_counted(self):
        row = self.row(); row.update(send_completed_ns=None, response_file=None)
        (self.root / 'failure.txt').write_bytes(b'write failed before transmission')
        row['failure_evidence'] = {'path': 'failure.txt', 'sha256': hash_bytes((self.root / 'failure.txt').read_bytes())}
        result = summarize([exchange(self.root, 'cli', row)])
        self.assertEqual((result['api_calls'], result['send_failures'], result['missing_responses']), (1, 1, 0))
    def test_missing_reply_without_evidence_refused(self):
        row = self.row(); row['response_file'] = None
        with self.assertRaises(ValueError): exchange(self.root, 'cli', row)
    def test_mcp_transport_id_can_change_on_same_operation_retry(self):
        row = self.row('mcp'); first = exchange(self.root, 'mcp', row)
        request = decode((self.root / 'request.json').read_bytes()); request['id'] = 2
        response = decode((self.root / 'response.json').read_bytes()); response['id'] = 2
        for name, value in [('request', request), ('response', response)]:
            raw = compact(value); (self.root / (name + '.json')).write_bytes(raw)
            row[name + '_file']['sha256'] = hash_bytes(raw)
        second = exchange(self.root, 'mcp', row)
        self.assertEqual(summarize([first, second])['retries'], 1)
    def test_monotonic_order_refused(self):
        row = self.row(); row['send_completed_ns'] = 31
        with self.assertRaises(ValueError): exchange(self.root, 'cli', row)
    def test_boolean_clock_refused(self):
        row = self.row(); row['send_begin_ns'] = True
        with self.assertRaises(ValueError): exchange(self.root, 'cli', row)
    def test_modified_capture_refused(self):
        row = self.row(); (self.root / 'response.json').write_bytes(b'{}')
        with self.assertRaises(ValueError): exchange(self.root, 'cli', row)
    def test_path_escape_refused(self):
        row = self.row(); row['response_file']['path'] = '../response.json'
        with self.assertRaises(ValueError): exchange(self.root, 'cli', row)
    def test_duplicate_json_refused(self):
        with self.assertRaises(ValueError): decode(b'{"clock":1,"clock":2}')
    def test_response_identity_refused(self):
        self.response['operation_id'] = 'another-operation'
        with self.assertRaises(ValueError): exchange(self.root, 'cli', self.row())
    def test_mcp_representations_disagree_refused(self):
        row = self.row('mcp'); raw = decode((self.root / 'response.json').read_bytes()); raw['result']['structuredContent'] = {}
        data = compact(raw); (self.root / 'response.json').write_bytes(data); row['response_file']['sha256'] = hash_bytes(data)
        with self.assertRaises(ValueError): exchange(self.root, 'mcp', row)
    def test_metadata_probe_is_not_complete_journey(self):
        path = self.root / 'group.json'
        path.write_bytes(compact({'schema': 'winsmux-efficiency-comparison-input/v1', 'input_classification': 'sanitized_native_captures',
            'conditions': {name: 'fixture' for name in CONDITIONS}, 'candidate_tree_sha': 'fixture', 'binary_sha256': 'fixture', 'samples': []}))
        with self.assertRaises(ValueError): load_group(path)
    def fixture_group(self):
        quality = {'passed': True, 'candidate_sha256': '1' * 64, 'cases': {key: 'pass' for key in OUTPUT_CASES}}
        raw = compact(quality); (self.root / 'quality.json').write_bytes(raw)
        group = {'schema': 'winsmux-efficiency-comparison-input/v1', 'input_classification': 'sanitized_native_captures',
            'conditions': {name: 'synthetic-selftest' for name in CONDITIONS}, 'candidate_tree_sha': '2' * 40,
            'binary_sha256': '1' * 64, 'quality_evidence': {'q_id': 'Q-OUTPUT', 'file': {'path': 'quality.json', 'sha256': hash_bytes(raw)}}, 'samples': []}
        for surface in sorted(SURFACES):
            for scenario in sorted(SCENARIOS):
                events = []
                for index, phase in enumerate(sorted(REQUIRED_PHASES)):
                    operation = sorted(PHASE_OPERATIONS[phase])[0]
                    self.request.update(operation=operation, operation_id=f'synthetic-{phase}')
                    self.response.update(operation_id=f'synthetic-{phase}', result={'operation': operation, 'data': {'text': '日本語😀'}})
                    if surface == 'gui':
                        request_raw = compact({'tool': 'click', 'arguments': {'pid': 123}})
                        response_raw = compact({'structuredContent': {'pid': 123}, 'isError': False})
                    else:
                        row = self.row(surface)
                        request_raw = (self.root / 'request.json').read_bytes()
                        response_raw = (self.root / 'response.json').read_bytes()
                    stem = f'{surface}-{scenario}-{phase}'
                    (self.root / (stem + '-request.json')).write_bytes(request_raw)
                    (self.root / (stem + '-response.json')).write_bytes(response_raw)
                    events.append({'phase': phase, 'send_begin_ns': 10 + index * 100, 'send_completed_ns': 12 + index * 100,
                        'response_observed_ns': 30 + index * 100, 'native_gui_operation': operation, 'operation_id': f'synthetic-{phase}',
                        'request_file': {'path': stem + '-request.json', 'sha256': hash_bytes(request_raw)},
                        'response_file': {'path': stem + '-response.json', 'sha256': hash_bytes(response_raw)}})
                group['samples'].append({'surface': surface, 'scenario': scenario, 'trial_id': 'synthetic-selftest-1', 'events': events,
                    'expected_outcome': 'synthetic-expected', 'actual_outcome': 'synthetic-expected', 'refusal_preserved': True})
        return group
    def write_group(self, group, name='group.json'):
        path = self.root / name; path.write_bytes(compact(group)); return path
    def test_complete_fixture_matrix_can_compare_without_claiming_improvement(self):
        group = self.fixture_group()
        result = compare(self.write_group(group, 'before.json'), self.write_group(group, 'after.json'))
        self.assertEqual(len(result['samples']), 15)
        self.assertTrue(all(row['delta_api_calls'] == 0 for row in result['samples']))
        self.assertFalse(result['threshold_applied'])
        self.assertFalse(result['parent_adopted'])
    def test_different_environment_refused(self):
        group = self.fixture_group(); before = self.write_group(group, 'before.json')
        group['conditions']['model'] = 'another-model'
        with self.assertRaises(ValueError): compare(before, self.write_group(group, 'after.json'))
    def test_missing_surface_refused(self):
        group = self.fixture_group(); group['samples'] = [row for row in group['samples'] if row['surface'] != 'gui']
        with self.assertRaises(ValueError): load_group(self.write_group(group))
    def test_missing_phase_refused(self):
        group = self.fixture_group(); group['samples'][0]['events'].pop()
        with self.assertRaises(ValueError): load_group(self.write_group(group))
    def test_phase_cannot_be_a_metadata_probe(self):
        group = self.fixture_group(); event = group['samples'][0]['events'][0]
        raw = decode(bound_file(self.root, event['request_file'])); raw['operation'] = 'diagnostics.get'
        data = compact(raw); (self.root / event['request_file']['path']).write_bytes(data); event['request_file']['sha256'] = hash_bytes(data)
        with self.assertRaises(ValueError): load_group(self.write_group(group))
    def test_wrong_outcome_refused(self):
        group = self.fixture_group(); group['samples'][0]['actual_outcome'] = 'wrong-artifact'
        with self.assertRaises(ValueError): load_group(self.write_group(group))
    def test_preservation_missing_refused(self):
        group = self.fixture_group(); group['samples'][0]['refusal_preserved'] = False
        with self.assertRaises(ValueError): load_group(self.write_group(group))
    def test_missing_output_boundary_refused(self):
        group = self.fixture_group(); quality = decode((self.root / 'quality.json').read_bytes()); quality['cases'].pop('cancel')
        raw = compact(quality); (self.root / 'quality.json').write_bytes(raw); group['quality_evidence']['file']['sha256'] = hash_bytes(raw)
        with self.assertRaises(ValueError): load_group(self.write_group(group))
    def test_observed_runtime_usage_is_kept(self):
        group = self.fixture_group(); raw = compact({'usage': {'tokens': 120, 'cached': 100, 'usd': 0.002}})
        (self.root / 'usage.json').write_bytes(raw)
        group['samples'][0]['runtime_usage'] = {'source_kind': 'public_runtime_json', 'file': {'path': 'usage.json', 'sha256': hash_bytes(raw)},
            'fields': {'provider_tokens': ['usage', 'tokens'], 'cached_input_tokens': ['usage', 'cached'], 'cost_usd': ['usage', 'usd']}}
        _, samples = load_group(self.write_group(group))
        # The first fixture is sorted by surface and scenario, never a hidden aggregate.
        self.assertTrue(any(row['provider_tokens'] == 120 and row['cached_input_tokens'] == 100 and row['cost_usd'] == 0.002 for row in samples.values()))
    def test_unknown_gui_body_remains_unknown(self):
        group = self.fixture_group(); _, samples = load_group(self.write_group(group))
        self.assertTrue(all(row['returned_body_utf8_bytes'] is None for key, row in samples.items() if key[0] == 'gui'))
    def test_nonfinite_runtime_cost_refused(self):
        group = self.fixture_group(); raw = b'{"cost":1e999}'
        (self.root / 'usage.json').write_bytes(raw)
        group['samples'][0]['runtime_usage'] = {'source_kind': 'public_runtime_json', 'file': {'path': 'usage.json', 'sha256': hash_bytes(raw)},
            'fields': {'cost_usd': ['cost']}}
        with self.assertRaises(ValueError): load_group(self.write_group(group))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--observer-root', type=Path)
    parser.add_argument('--batches', type=int, nargs='+')
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--candidate', type=Path)
    args = parser.parse_args()
    if args.self_test:
        require(not any((args.observer_root, args.baseline, args.candidate, args.batches)), 'Self-test does not accept native captures')
        result = unittest.TextTestRunner(stream=sys.stderr).run(unittest.defaultTestLoader.loadTestsFromTestCase(MeasurementContract))
        print(json.dumps({'scope': 'measurement_contract_selftest', 'passed': result.wasSuccessful(), 'tests': result.testsRun, 'task_complete': False}))
        return 0 if result.wasSuccessful() else 1
    if args.observer_root:
        require(args.batches and not any((args.baseline, args.candidate)), 'Exact observer batch scope required')
        require(len(set(args.batches)) == len(args.batches) and all(value > 0 for value in args.batches), 'Duplicate or invalid batch selection')
        result = inspect_observer(args.observer_root, args.batches)
    else:
        require(args.baseline and args.candidate and args.batches is None, 'Both fixed comparison groups required')
        result = compare(args.baseline, args.candidate)
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as error:
        print(json.dumps({'scope': 'capture_validation', 'passed': False, 'error': str(error), 'task_complete': False}), file=sys.stderr)
        sys.exit(1)
