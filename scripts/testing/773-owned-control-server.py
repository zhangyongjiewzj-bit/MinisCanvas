#!/usr/bin/python3 -IS
"""Original 773 owned stdio fixture, with opt-in controlled EXTE responses.

Without owned-control-scenario.json the original resume/approval flow remains
available. Markers separate request ACK from authoritative turn notification;
neither mode reads user sessions or sends network traffic.
"""
import json
import os
import sys
import time

home = os.environ['CODEX_HOME']
scenario_path = os.path.join(home, 'owned-control-scenario.json')
scenario = {'threadID': '12345678-1234-1234-1234-123456789abc'}
if os.path.exists(scenario_path):
    with open(scenario_path) as scenario_file:
        scenario = json.load(scenario_file)
controlled = scenario.get('mode') == 'controlled'
owned_thread = scenario['threadID']
owned_turn = scenario.get('turnID', 'turn_owned')
open(os.path.join(home, 'server-started'), 'w').close()


def emit(value):
    print(json.dumps(value), flush=True)


def wait_marker(name):
    deadline = time.monotonic() + 5
    while not os.path.exists(os.path.join(home, name)):
        if time.monotonic() >= deadline:
            raise RuntimeError('owned fixture marker timed out: ' + name)
        time.sleep(0.01)


def reject(rid, message):
    emit({'id': rid, 'error': {'code': -32000, 'message': message}})


for line in sys.stdin:
    req = json.loads(line)
    method, rid = req.get('method'), req.get('id')
    with open(os.path.join(home, 'requests.jsonl'), 'a') as audit:
        audit.write(json.dumps(req) + '\n')
    if method is None and rid == 'approval-1':
        emit({'method': 'serverRequest/resolved', 'params': {'threadId': owned_thread, 'requestId': 'approval-1'}})
        emit({'method': 'turn/completed', 'params': {'threadId': owned_thread, 'turn': {'id': owned_turn, 'status': 'completed'}}})
        continue
    if method == 'initialized':
        continue
    if method == 'initialize':
        result = {'userAgent': 'miniscanvas/0.151.0 (synthetic)', 'platformFamily': 'unix', 'platformOs': 'macos'}
    elif method == 'thread/resume':
        tid = req['params']['threadId']
        if tid != owned_thread:
            reject(rid, 'thread is not owned by this fixture')
            continue
        if controlled:
            emit({'id': rid, 'result': {'thread': {'id': tid}}})
            wait_marker('allow-turn-started')
            emit({'method': 'turn/started', 'params': {'threadId': tid, 'turn': {'id': owned_turn}}})
            continue
        emit({'method': 'turn/started', 'params': {'threadId': tid, 'turn': {'id': owned_turn}}})
        emit({'id': 'approval-1', 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': tid, 'turnId': owned_turn, 'itemId': 'command-1'}})
        result = {'thread': {'id': tid}}
    elif controlled and method == 'turn/steer':
        params = req['params']
        if (params.get('threadId') != owned_thread or params.get('expectedTurnId') != owned_turn
                or params.get('input') != [{'type': 'text', 'text': scenario['steerInput']}]):
            reject(rid, 'steer target or bounded input mismatch')
            continue
        emit({'id': rid, 'result': {'turnId': owned_turn}})
        emit({'method': 'item/started', 'params': {'threadId': owned_thread, 'turnId': owned_turn,
                                                'item': {'id': 'steer-accepted', 'type': 'commandExecution'}}})
        continue
    elif controlled and method == 'turn/interrupt':
        params = req['params']
        if params != {'threadId': owned_thread, 'turnId': owned_turn}:
            reject(rid, 'interrupt target mismatch')
            continue
        if scenario.get('timeoutACK'):
            open(os.path.join(home, 'interrupt-observed'), 'w').close()
            # The real client's timeout must expire after provider I/O. No
            # synthetic successful receipt is returned to settle UNKNOWN.
            deadline = time.monotonic() + 20
            while not os.path.exists(os.path.join(home, 'allow-interrupt-ack')):
                if time.monotonic() >= deadline:
                    raise RuntimeError('owned timeout scenario was not released')
                time.sleep(0.01)
            emit({'id': rid, 'result': {}})
            continue
        # Empty ACK is not a stopped-turn fact. The App must separately
        # consume turn/completed(status=interrupted) on the selected lease.
        if not scenario.get('terminalBeforeACK'):
            emit({'id': rid, 'result': {}})
        open(os.path.join(home, 'interrupt-observed'), 'w').close()
        if scenario.get('pendingNoise'):
            emit({'method': 'item/started', 'params': {'threadId': owned_thread,
                                                      'turnId': 'foreign-turn',
                                                      'item': {'id': 'foreign-progress', 'type': 'commandExecution'}}})
            emit({'id': 'approval-during-cancel', 'method': 'item/commandExecution/requestApproval',
                  'params': {'threadId': owned_thread, 'turnId': owned_turn, 'itemId': 'pending-command'}})
        if scenario.get('foreignTerminal'):
            emit({'method': 'turn/completed', 'params': {'threadId': owned_thread,
                                                       'turn': {'id': 'foreign-turn', 'status': 'interrupted'}}})
            open(os.path.join(home, 'foreign-terminal-emitted'), 'w').close()
        wait_marker('allow-interrupt-terminal')
        emit({'method': 'turn/completed', 'params': {'threadId': owned_thread,
                                                   'turn': {'id': owned_turn, 'status': 'interrupted'}}})
        if scenario.get('terminalBeforeACK'):
            wait_marker('allow-interrupt-ack')
            emit({'id': rid, 'result': {}})
        wait_marker('allow-late-terminal')
        emit({'method': 'turn/completed', 'params': {'threadId': owned_thread,
                                                   'turn': {'id': owned_turn, 'status': 'completed'}}})
        continue
    else:
        result = None
    if rid is not None:
        if result is None:
            reject(rid, 'unsupported')
        else:
            emit({'id': rid, 'result': result})
