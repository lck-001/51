"""Synthetic, in-memory contract reference model. Not an app/backend or PG proof.

Only Python stdlib; no network, credentials, devices, environment or disk access.
Principal represents an ALREADY authenticated server context, not JWT validation.
Monetary values are integer synthetic units, never actual vendor prices or billing.
"""
from copy import deepcopy
from dataclasses import dataclass, field
from functools import wraps
from hashlib import sha256
import json
from threading import RLock

SCOPES = frozenset({
    'material:write', 'material:read', 'receive:create', 'receipt:read_own',
    'progress:write', 'processing:approve', 'processing:submit', 'processing:manage',
    'coach:plan', 'coach:approve', 'coach:execute', 'coach:manage', 'learning:write',
    'assessment:read', 'feedback:create', 'feedback:read', 'feedback:append',
    'feedback:manage', 'inbox:read',
})
COACH_TOOLS = frozenset({'read_selected', 'save_plan_draft', 'create_practice_draft', 'list_due'})
ASSISTANCE = frozenset({'question_text', 'chinese', 'slow', 'keywords', 'demo', 'option_audio'})
# Fixed SYNTHETIC validation policies, not approved product/service defaults.
MAX_COACH_STEPS = 8
MAX_RUN_TOOL_CALLS = 8
MAX_RUN_SECONDS = 300
MAX_PLAN_REVISIONS = 3


class ContractError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class Principal:
    owner_id: str
    integration_id: str = 'app'
    scopes: frozenset = field(default_factory=frozenset)
    material_scope: frozenset | None = None
    roles: frozenset = field(default_factory=frozenset)
    expires_at: int | None = None
    grant_id: str = 'default'


def guarded(fn):
    @wraps(fn)
    def invoke(self, principal, *args, **kwargs):
        with self._lock:
            self._auth(principal)
            return deepcopy(fn(self, principal, *args, **kwargs))
    return invoke


def digest(value):
    return sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


class LocalPlatform:
    def __init__(self, now=1000):
        self.now = now
        self._lock = RLock()
        self._serial = 0
        self._revoked = set()
        self._materials, self._receipts, self._deliveries, self._sources = {}, {}, {}, {}
        self._source_versions = {}
        self._progress, self._approvals, self._operations, self._ledger = {}, {}, {}, []
        self._runs, self._tool_steps, self._questions, self._attempts = {}, {}, {}, {}
        self._feedbacks, self._feedback_ops, self._attachments = {}, {}, {}
        self._outbox, self._inbox, self._notice_keys = {}, {}, {}

    def _id(self, prefix):
        self._serial += 1
        return f'{prefix}-{self._serial:05d}'

    def _auth(self, p):
        if not isinstance(p, Principal) or not p.owner_id:
            raise ContractError('AUTH_REQUIRED')
        if (p.owner_id, p.integration_id, p.grant_id) in self._revoked:
            raise ContractError('SCOPE_DENIED')
        if p.expires_at is not None and self.now >= p.expires_at:
            raise ContractError('GRANT_EXPIRED')

    def _require(self, p, capability, material_id=None):
        if capability not in p.scopes and '*' not in p.scopes:
            raise ContractError('SCOPE_DENIED')
        if material_id is not None and p.material_scope is not None and material_id not in p.material_scope:
            raise ContractError('SCOPE_DENIED')

    def _get(self, collection, resource_id, p):
        row = collection.get(resource_id)
        if row is None or row['owner_id'] != p.owner_id:
            raise ContractError('ACCESS_DENIED')
        return row

    def _manager(self, p, actor='human'):
        self._require(p, 'feedback:manage')
        if not (set(p.roles) & {'support', 'admin'}):
            raise ContractError('ACCESS_DENIED')
        if p.integration_id != 'app' or actor != 'human':
            raise ContractError('ACTOR_NOT_ALLOWED')

    @staticmethod
    def _amount(value):
        if type(value) is not int or value < 0:
            raise ContractError('INVALID_AMOUNT')

    @guarded
    def revoke(self, p):
        self._revoked.add((p.owner_id, p.integration_id, p.grant_id))
        return {'state': 'revoked'}

    @guarded
    def add_material(self, p, material_id, learning_revision, sentences):
        self._require(p, 'material:write', material_id)
        if not material_id or not learning_revision or not sentences or not all(isinstance(x, str) and x for x in sentences):
            raise ContractError('INVALID_INPUT')
        row = self._materials.get(material_id)
        if row is not None and row['owner_id'] != p.owner_id:
            raise ContractError('ACCESS_DENIED')
        if row is None:
            row = {'material_id': material_id, 'owner_id': p.owner_id, 'versions': {}, 'source_versions': []}
            self._materials[material_id] = row
        previous = row['versions'].get(learning_revision)
        if previous is not None and previous != list(sentences):
            raise ContractError('REVISION_CONFLICT')
        row['versions'][learning_revision] = list(sentences)
        return row

    @guarded
    def get_material(self, p, material_id):
        self._require(p, 'material:read', material_id)
        return self._get(self._materials, material_id, p)

    @guarded
    def receive(self, p, delivery_id, payload):
        self._require(p, 'receive:create')
        required = ('material_id', 'source_ref', 'source_revision', 'body')
        if not delivery_id or not isinstance(payload, dict) or any(not isinstance(payload.get(k), str) or not payload[k] for k in required):
            raise ContractError('INVALID_INPUT')
        material_id = payload['material_id']
        self._require(p, 'receive:create', material_id)
        canonical = {k: payload[k] for k in required}  # Never trust payload.owner_id.
        key = (p.owner_id, p.integration_id, delivery_id)
        fingerprint = digest(canonical)
        if key in self._deliveries:
            old = self._receipts[self._deliveries[key]]
            if old['fingerprint'] != fingerprint:
                raise ContractError('OPERATION_CONFLICT')
            return {**old, 'state': 'duplicate'}
        material = self._materials.get(material_id)
        if material is not None and material['owner_id'] != p.owner_id:
            raise ContractError('ACCESS_DENIED')
        source_key = (p.owner_id, p.integration_id, payload['source_ref'])
        previous = self._sources.get(source_key)
        if previous is not None and previous['material_id'] != material_id:
            raise ContractError('SOURCE_CONFLICT')
        version_key = source_key + (payload['source_revision'],)
        same_version = self._source_versions.get(version_key)
        if same_version:
            if same_version['fingerprint'] != fingerprint:
                raise ContractError('REVISION_CONFLICT')
            self._deliveries[key] = same_version['receipt_id']
            return {**self._receipts[same_version['receipt_id']], 'state': 'duplicate'}
        if material is None:
            material = {'material_id': material_id, 'owner_id': p.owner_id, 'versions': {}, 'source_versions': []}
            self._materials[material_id] = material
        source = {**canonical, 'fingerprint': fingerprint}
        material['source_versions'].append(source)
        self._sources[source_key] = source
        receipt_id = self._id('receipt')
        row = {'receipt_id': receipt_id, 'owner_id': p.owner_id, 'integration_id': p.integration_id,
               'material_id': material_id, 'source_revision': payload['source_revision'],
               'state': 'update_pending' if previous else 'accepted', 'generated': False, 'fingerprint': fingerprint}
        self._receipts[receipt_id] = row
        self._deliveries[key] = receipt_id
        self._source_versions[version_key] = {'fingerprint': fingerprint, 'receipt_id': receipt_id}
        return row

    @guarded
    def receipt(self, p, receipt_id):
        self._require(p, 'receipt:read_own')
        row = self._get(self._receipts, receipt_id, p)
        if row['integration_id'] != p.integration_id:
            raise ContractError('ACCESS_DENIED')
        return row

    @guarded
    def save_progress(self, p, material_id, learning_revision, sentence_id, expected_revision=0):
        self._require(p, 'progress:write', material_id)
        material = self._get(self._materials, material_id, p)
        if learning_revision not in material['versions'] or sentence_id not in material['versions'][learning_revision]:
            raise ContractError('REFERENCE_UNAVAILABLE')
        key = (p.owner_id, material_id)
        previous = self._progress.get(key)
        if previous and previous['learning_revision'] != learning_revision:
            raise ContractError('REVISION_CONFLICT')
        actual = previous['revision'] if previous else 0
        if type(expected_revision) is not int or expected_revision != actual:
            raise ContractError('REVISION_CONFLICT')
        row = {'material_id': material_id, 'learning_revision': learning_revision,
               'sentence_id': sentence_id, 'revision': actual + 1}
        self._progress[key] = row
        return row

    @guarded
    def approve_processing(self, p, plan_hash, limit, confirmed=False):
        self._require(p, 'processing:approve')
        self._amount(limit)
        if p.integration_id != 'app':
            raise ContractError('ACTOR_NOT_ALLOWED')
        if confirmed is not True or not plan_hash:
            raise ContractError('CONSENT_REQUIRED')
        used = sum(o['actual_cost'] if o['state'] in {'succeeded', 'failed', 'cancelled'} else o['cost']
                   for (owner, _), o in self._operations.items() if owner == p.owner_id and o['plan_hash'] == plan_hash)
        if limit < used:
            raise ContractError('BUDGET_EXCEEDED')
        self._approvals[(p.owner_id, plan_hash)] = limit
        return {'plan_hash': plan_hash, 'limit': limit, 'confirmed': True}

    @guarded
    def submit_processing(self, p, operation_id, plan_hash, cost):
        self._require(p, 'processing:submit')
        self._amount(cost)
        key = (p.owner_id, operation_id)
        if key in self._operations:
            old = self._operations[key]
            if old['plan_hash'] != plan_hash or old['cost'] != cost:
                raise ContractError('OPERATION_CONFLICT')
            return old
        limit = self._approvals.get((p.owner_id, plan_hash))
        if limit is None:
            raise ContractError('BUDGET_NOT_CONFIRMED')
        used = sum(o['actual_cost'] if o['state'] in {'succeeded', 'failed', 'cancelled'} else o['cost']
                   for (owner, _), o in self._operations.items() if owner == p.owner_id and o['plan_hash'] == plan_hash)
        if used + cost > limit:
            raise ContractError('BUDGET_EXCEEDED')
        row = {'operation_id': operation_id, 'owner_id': p.owner_id, 'plan_hash': plan_hash,
               'cost': cost, 'actual_cost': 0, 'state': 'running', 'reconcile_required': False, 'cancel_requested': False}
        self._operations[key] = row
        self._ledger.append({'owner_id': p.owner_id, 'operation_id': operation_id, 'kind': 'reserve', 'amount': cost})
        return row

    def _operation(self, p, operation_id):
        self._require(p, 'processing:manage')
        return self._get(self._operations, (p.owner_id, operation_id), p)

    @guarded
    def mark_unknown(self, p, operation_id):
        row = self._operation(p, operation_id)
        if row['state'] in {'succeeded', 'failed', 'cancelled'}:
            raise ContractError('OPERATION_FINALIZED')
        row.update(state='outcome_unknown', reconcile_required=True)
        return row

    @guarded
    def cancel_processing(self, p, operation_id):
        row = self._operation(p, operation_id)
        if row['state'] not in {'succeeded', 'failed', 'cancelled'}:
            row.update(state='cancel_requested', cancel_requested=True, reconcile_required=True)
        return row

    @guarded
    def reconcile(self, p, operation_id, outcome, actual_cost=0):
        row = self._operation(p, operation_id)
        self._amount(actual_cost)
        if outcome not in {'succeeded', 'failed', 'cancelled'}:
            raise ContractError('INVALID_OUTCOME')
        if row['state'] in {'succeeded', 'failed', 'cancelled'}:
            if (row['state'], row['actual_cost']) != (outcome, actual_cost):
                raise ContractError('OPERATION_CONFLICT')
            return row
        if actual_cost > row['cost']:
            raise ContractError('USAGE_REQUIRES_REVIEW')
        row.update(state=outcome, actual_cost=actual_cost, reconcile_required=False)
        self._ledger.extend([
            {'owner_id': p.owner_id, 'operation_id': operation_id, 'kind': 'settle', 'amount': actual_cost},
            {'owner_id': p.owner_id, 'operation_id': operation_id, 'kind': 'release', 'amount': row['cost'] - actual_cost},
        ])
        return row

    @guarded
    def budget(self, p):
        self._require(p, 'processing:manage')
        rows = [o for (owner, _), o in self._operations.items() if owner == p.owner_id]
        return {'reserved': sum(o['cost'] for o in rows if o['state'] not in {'succeeded', 'failed', 'cancelled'}),
                'spent': sum(o['actual_cost'] for o in rows),
                'ledger_entries': [e for e in self._ledger if e['owner_id'] == p.owner_id]}

    def _run(self, p, run_id, cap):
        self._require(p, cap)
        row = self._get(self._runs, (p.owner_id, run_id), p)
        self._require(p, cap, row['material_id'])
        self._get(self._materials, row['material_id'], p)
        return row

    @staticmethod
    def _tools(steps):
        if not steps or any(tool not in COACH_TOOLS for tool in steps):
            raise ContractError('TOOL_NOT_ALLOWED')
        if len(steps) > MAX_COACH_STEPS:
            raise ContractError('LIMIT_REACHED')

    @guarded
    def coach_plan(self, p, run_id, material_id, steps, planning_operation_id=None):
        self._require(p, 'coach:plan', material_id)
        self._get(self._materials, material_id, p)
        self._tools(steps)
        operation = self._operations.get((p.owner_id, planning_operation_id))
        if operation is None or operation['plan_hash'] != 'planning:' + run_id or operation['state'] != 'succeeded':
            raise ContractError('BUDGET_NOT_CONFIRMED')
        key = (p.owner_id, run_id)
        if key in self._runs:
            old = self._runs[key]
            if (old['material_id'], old['steps']) != (material_id, list(steps)):
                raise ContractError('OPERATION_CONFLICT')
            return old
        deadline_at = self.now + MAX_RUN_SECONDS
        row = {'owner_id': p.owner_id, 'run_id': run_id, 'material_id': material_id, 'steps': list(steps),
               'revision': 1, 'plan_hash': digest([material_id, steps, 1, MAX_RUN_TOOL_CALLS, deadline_at]), 'approved_hash': None,
               'stopped': False, 'state': 'awaiting_approval', 'linked_operations': [],
               'max_tool_calls': MAX_RUN_TOOL_CALLS, 'tool_calls': 0,
               'deadline_at': deadline_at}
        self._runs[key] = row
        return row

    @guarded
    def approve_coach(self, p, run_id, confirmed=False):
        row = self._run(p, run_id, 'coach:approve')
        if p.integration_id != 'app':
            raise ContractError('ACTOR_NOT_ALLOWED')
        if confirmed is not True:
            raise ContractError('CONSENT_REQUIRED')
        if row['stopped']:
            raise ContractError('RUN_STOPPED')
        if row['revision'] > MAX_PLAN_REVISIONS or self.now >= row['deadline_at']:
            raise ContractError('LIMIT_REACHED')
        row.update(approved_hash=row['plan_hash'], state='ready')
        return row

    @guarded
    def edit_coach(self, p, run_id, steps):
        row = self._run(p, run_id, 'coach:plan')
        self._tools(steps)
        if row['stopped']:
            raise ContractError('RUN_STOPPED')
        if row['revision'] >= MAX_PLAN_REVISIONS or self.now >= row['deadline_at']:
            raise ContractError('LIMIT_REACHED')
        row['revision'] += 1
        row.update(steps=list(steps), approved_hash=None,
                   plan_hash=digest([row['material_id'], steps, row['revision'], row['max_tool_calls'], row['deadline_at']]), state='awaiting_approval')
        return row

    @guarded
    def coach_step(self, p, run_id, step_id, tool, operation_id):
        row = self._run(p, run_id, 'coach:execute')
        if tool not in COACH_TOOLS or tool not in row['steps']:
            raise ContractError('TOOL_NOT_ALLOWED')
        key = (p.owner_id, run_id, row['revision'], step_id)
        if key in self._tool_steps:
            previous = self._tool_steps[key]
            if (previous['tool'], previous['operation_id']) != (tool, operation_id):
                raise ContractError('OPERATION_CONFLICT')
            return previous
        if row['stopped']:
            raise ContractError('RUN_STOPPED')
        if row['approved_hash'] != row['plan_hash']:
            raise ContractError('PLAN_STALE')
        if self.now >= row['deadline_at'] or row['tool_calls'] >= row['max_tool_calls']:
            raise ContractError('LIMIT_REACHED')
        # Each approved occurrence may execute once. Inventing a new step_id must
        # not create additional allowance for the same approved tool.
        used = sum(v['tool'] == tool for k, v in self._tool_steps.items()
                   if k[:3] == (p.owner_id, run_id, row['revision']))
        if used >= row['steps'].count(tool):
            raise ContractError('LIMIT_REACHED')
        operation = self._operations.get((p.owner_id, operation_id))
        pending = operation and operation['state'] not in {'succeeded', 'failed', 'cancelled'}
        if operation and operation_id not in row['linked_operations']:
            row['linked_operations'].append(operation_id)
        result = {'run_id': run_id, 'step_id': step_id, 'tool': tool, 'operation_id': operation_id,
                  'state': 'awaiting_reconciliation' if pending else 'completed', 'mock': True}
        self._tool_steps[key] = result
        row['tool_calls'] += 1
        return result

    @guarded
    def stop_coach(self, p, run_id):
        row = self._run(p, run_id, 'coach:manage')
        row['stopped'] = True
        pending = [op for op in row['linked_operations'] if self._operations[(p.owner_id, op)]['state'] not in {'succeeded', 'failed', 'cancelled'}]
        row['state'] = 'awaiting_reconciliation' if pending else 'stopped'
        return {**row, 'pending_operations': pending, 'new_steps_stopped': True}

    @guarded
    def add_question(self, p, question_id, accepted_answers):
        self._require(p, 'learning:write')
        if not accepted_answers or not all(isinstance(x, str) for x in accepted_answers):
            raise ContractError('INVALID_INPUT')
        key = (p.owner_id, question_id)
        if key in self._questions:
            raise ContractError('REVISION_CONFLICT')
        self._questions[key] = set(accepted_answers)
        return {'question_id': question_id}

    @guarded
    def start_attempt(self, p, attempt_id, question_id):
        self._require(p, 'learning:write')
        if (p.owner_id, question_id) not in self._questions:
            raise ContractError('REFERENCE_UNAVAILABLE')
        key = (p.owner_id, attempt_id)
        if key in self._attempts:
            if self._attempts[key]['question_id'] != question_id:
                raise ContractError('OPERATION_CONFLICT')
            return self._attempts[key]
        row = {'owner_id': p.owner_id, 'attempt_id': attempt_id, 'question_id': question_id, 'assistance': [], 'state': 'presented'}
        self._attempts[key] = row
        return row

    @guarded
    def assist(self, p, attempt_id, kind):
        self._require(p, 'learning:write')
        row = self._get(self._attempts, (p.owner_id, attempt_id), p)
        if row['state'] != 'presented':
            raise ContractError('ATTEMPT_FINALIZED')
        if kind not in ASSISTANCE:
            raise ContractError('INVALID_INPUT')
        row['assistance'].append({'kind': kind, 'order': len(row['assistance']) + 1})
        return row

    @guarded
    def submit_answer(self, p, attempt_id, answer):
        self._require(p, 'learning:write')
        row = self._get(self._attempts, (p.owner_id, attempt_id), p)
        if row['state'] == 'evaluated':
            if row['answer'] != answer:
                raise ContractError('OPERATION_CONFLICT')
            return row
        row.update(state='evaluated', answer=answer,
                   accepted=answer in self._questions[(p.owner_id, row['question_id'])],
                   independent=not any(a['kind'] != 'option_audio' for a in row['assistance']), mastered=False)
        return row

    @guarded
    def assess(self, p, recording_id, quality='valid', provider_available=True, task_type='scripted'):
        self._require(p, 'assessment:read')
        if task_type not in {'scripted', 'keywords', 'unscripted'}:
            raise ContractError('TASK_UNSUPPORTED')
        state = 'quality_insufficient' if quality != 'valid' else 'not_evaluated'
        return {'recording_id': recording_id, 'task_type': task_type, 'state': state, 'score': None,
                'mock': True, 'reason': 'quality_gate' if quality != 'valid' else ('provider_unavailable' if not provider_available else 'no_real_assessment')}

    @guarded
    def add_attachment(self, p, attachment_id):
        self._require(p, 'feedback:create')
        if attachment_id in self._attachments and self._attachments[attachment_id] != p.owner_id:
            raise ContractError('ATTACHMENT_DENIED')
        self._attachments[attachment_id] = p.owner_id
        return {'attachment_id': attachment_id}

    @guarded
    def submit_feedback(self, p, operation_id, body, attachments=None, context=None):
        self._require(p, 'feedback:create')
        if not isinstance(body, str) or not body.strip() or not operation_id:
            raise ContractError('INVALID_INPUT')
        attachments, context = list(attachments or []), dict(context or {})
        if any(self._attachments.get(a) != p.owner_id for a in attachments):
            raise ContractError('ATTACHMENT_DENIED')
        if 'material_id' in context:
            self._get(self._materials, context['material_id'], p)
            if p.material_scope is not None and context['material_id'] not in p.material_scope:
                raise ContractError('SCOPE_DENIED')
        fingerprint = digest([body, attachments, context])
        key = (p.owner_id, operation_id)
        if key in self._feedback_ops:
            previous = self._feedbacks[self._feedback_ops[key]]
            if previous['fingerprint'] != fingerprint:
                raise ContractError('OPERATION_CONFLICT')
            return previous
        fid = self._id('feedback')
        row = {'feedback_id': fid, 'owner_id': p.owner_id, 'body': body, 'attachments': attachments,
               'context': context, 'info': [], 'status': 'received', 'outcome': None,
               'release': None, 'evidence': None, 'fingerprint': fingerprint, 'revision': 1,
               'history': [{'status': 'received', 'actor': p.owner_id, 'at': self.now}]}
        self._feedbacks[fid] = row
        self._feedback_ops[key] = fid
        self._outbox[fid] = {'event_id': 'created:' + fid, 'delivered': set()}
        return row

    def _feedback(self, p, feedback_id):
        row = self._feedbacks.get(feedback_id)
        if row is None:
            raise ContractError('ACCESS_DENIED')
        if row['owner_id'] != p.owner_id:
            self._manager(p)
        return row

    @guarded
    def feedback(self, p, feedback_id):
        self._require(p, 'feedback:read')
        return self._feedback(p, feedback_id)

    @guarded
    def append_feedback(self, p, feedback_id, body):
        self._require(p, 'feedback:append')
        row = self._feedback(p, feedback_id)
        if not isinstance(body, str) or not body.strip():
            raise ContractError('INVALID_INPUT')
        row['info'].append(body)
        row['revision'] += 1
        return row

    @guarded
    def dispatch_feedback(self, p, feedback_id, recipient, fail=False):
        self._manager(p)
        row = self._feedback(p, feedback_id)
        if recipient not in {p.owner_id, row['owner_id']}:
            raise ContractError('ACCESS_DENIED')
        event = self._outbox[feedback_id]
        key = (event['event_id'], recipient)
        if key in self._notice_keys:
            return self._inbox[self._notice_keys[key]]
        if fail:
            return {'state': 'delivery_failed', 'feedback_id': feedback_id, 'feedback_preserved': True}
        nid = self._id('notice')
        notice = {'notification_id': nid, 'owner_id': recipient, 'feedback_id': feedback_id,
                  'event_id': event['event_id'], 'cursor': self._serial, 'read_at': None, 'state': 'inbox_written'}
        self._inbox[nid] = notice
        self._notice_keys[key] = nid
        event['delivered'].add(recipient)
        return notice

    @guarded
    def inbox(self, p, after=0):
        self._require(p, 'inbox:read')
        accessible = []
        for row in self._inbox.values():
            if row['owner_id'] != p.owner_id:
                continue
            try:
                self._feedback(p, row['feedback_id'])
            except ContractError:
                continue  # Role revocation also invalidates historical operator notices.
            if row['cursor'] > after:
                accessible.append(row)
        accessible.sort(key=lambda row: row['cursor'])
        return {'items': accessible, 'cursor': max([after] + [row['cursor'] for row in accessible])}

    @guarded
    def mark_read(self, p, notification_id):
        self._require(p, 'inbox:read')
        row = self._get(self._inbox, notification_id, p)
        self._feedback(p, row['feedback_id'])
        if row['read_at'] is None:
            row['read_at'] = self.now
        return row

    @guarded
    def change_feedback(self, p, feedback_id, status, release=None, evidence=None, actor='human'):
        self._manager(p, actor)
        row = self._feedback(p, feedback_id)
        if status not in {'received', 'needs_info', 'assigned', 'processing', 'planned', 'handled', 'fixed', 'reopened', 'closed'}:
            raise ContractError('INVALID_STATUS')
        if status == 'fixed' and (not release or not evidence):
            raise ContractError('EVIDENCE_REQUIRED')
        if status == 'fixed':
            row.update(status='handled', outcome='fixed', release=release, evidence=evidence)
        else:
            row['status'] = status
        row['revision'] += 1
        row['history'].append({'status': row['status'], 'outcome': row['outcome'],
                               'actor': p.owner_id, 'at': self.now, 'release': release, 'evidence': evidence})
        return row
