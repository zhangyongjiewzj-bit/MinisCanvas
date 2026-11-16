#!/usr/bin/env python3
"""Finite, no-network test fixture; never run by preparation/compilation.

The first child setsid()s then forks the pipe holder. The intermediate is
reaped by the original fixture leader. The final holder is deliberately
reparented: no caller claims waitpid ownership of that process. It has an
independent monotonic hard lifetime and observes one owned release file.
There is no signal, exec, process search, or server/control socket here.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import time

IDENTITY_SHA = 'a21c42c24902e92b7704cff8fd7d77aaafaffc4a76c87caebfed91fc8d888f66'

def publish(root, name, value):
    raw = (json.dumps(value, sort_keys=True) + '\n').encode()
    target = root / name
    temp = root / ('.' + name + '-' + str(os.getpid()))
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    # Per-role paths are single-writer and absent; never overwrite a receipt.
    os.link(temp, target)
    temp.unlink()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--case-root', required=True)
    parser.add_argument('--nonce', required=True)
    parser.add_argument('--hard-seconds', type=float, required=True)
    args = parser.parse_args()
    root = Path(args.case_root)
    assert root.is_absolute() and root.resolve() == root
    rs = root.lstat()
    assert stat.S_ISDIR(rs.st_mode) and rs.st_uid == os.geteuid() and stat.S_IMODE(rs.st_mode) == 0o700
    assert len(args.nonce) == 32 and all(x in '0123456789abcdef' for x in args.nonce)
    assert args.hard_seconds == 20.0
    identity_file = Path(__file__).with_name('process_identity.py')
    assert hashlib.sha256(identity_file.read_bytes()).hexdigest() == IDENTITY_SHA
    spec = importlib.util.spec_from_file_location('_conc2_frozen_identity', identity_file)
    identity = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(identity)
    start = time.monotonic()
    hard = start + args.hard_seconds
    stdout = os.fstat(1)
    assert stat.S_ISFIFO(stdout.st_mode), 'actual product stdout must be a pipe'
    leader = {'pid': os.getpid(), 'generation': identity.generation(os.getpid()),
              'sid': os.getsid(0), 'pgid': os.getpgrp(), 'nonce': args.nonce,
              'stdout_dev': stdout.st_dev, 'stdout_ino': stdout.st_ino,
              'hard_monotonic': hard}
    assert leader['generation'] is not None
    publish(root, 'leader.json', leader)
    first = os.fork()
    if first == 0:
        os.setsid()
        middle = {'pid': os.getpid(), 'generation': identity.generation(os.getpid()),
                  'sid': os.getsid(0), 'pgid': os.getpgrp(), 'nonce': args.nonce}
        publish(root, 'intermediate.json', middle)
        last = os.fork()
        if last != 0:
            os._exit(0)
        # No inherited stdin is needed. stdout/stderr intentionally remain open.
        os.close(0)
        # Observe actual adoption, rather than merely claiming a double fork.
        while os.getppid() == middle['pid'] and time.monotonic() < hard:
            time.sleep(0.005)
        pipe = os.fstat(1)
        holder = {'pid': os.getpid(), 'ppid': os.getppid(),
                  'generation': identity.generation(os.getpid()),
                  'sid': os.getsid(0), 'pgid': os.getpgrp(),
                  'nonce': args.nonce, 'leader_pid': leader['pid'],
                  'intermediate_pid': middle['pid'],
                  'stdout_dev': pipe.st_dev, 'stdout_ino': pipe.st_ino,
                  'stdout_is_pipe': stat.S_ISFIFO(pipe.st_mode),
                  'hard_monotonic': hard, 'hard_seconds': args.hard_seconds,
                  'detached_from_leader_sid': os.getsid(0) != leader['sid'],
                  'detached_from_leader_pgid': os.getpgrp() != leader['pgid'],
                  'adopted_from_intermediate': os.getppid() != middle['pid']}
        publish(root, 'holder.json', holder)
        reason = 'HARD_NATURAL_LIFETIME'
        while time.monotonic() < hard:
            release = root / 'release.json'
            if release.is_file() and not release.is_symlink():
                try:
                    value = json.loads(release.read_text())
                    if value.get('nonce') == args.nonce and value.get('natural_release') is True:
                        reason = 'OWNED_RELEASE_FILE'
                        break
                except (OSError, ValueError):
                    pass  # hard lifetime is independent of controller success.
            time.sleep(0.01)
        publish(root, 'holder.natural-exit-intent.json', {
            'nonce': args.nonce, 'generation': holder['generation'],
            'reason': reason, 'monotonic': time.monotonic(),
            'not_a_kernel_exit_receipt': True, 'signals_by_fixture': []})
        os.close(1)
        os.close(2)
        os._exit(0)
    waited, status = os.waitpid(first, 0)
    publish(root, 'intermediate.reaped.json', {
        'nonce': args.nonce, 'pid': waited, 'status': status,
        'true_waitpid_of_direct_intermediate_only': True})
    # The product owns and cancels/times out this leader. If it fails to do so,
    # this leader also exits naturally at the same independent hard deadline.
    while time.monotonic() < hard:
        time.sleep(0.02)
    publish(root, 'leader.natural-exit-intent.json', {
        'nonce': args.nonce, 'generation': leader['generation'],
        'not_a_kernel_exit_receipt': True})

if __name__ == '__main__':
    main()
