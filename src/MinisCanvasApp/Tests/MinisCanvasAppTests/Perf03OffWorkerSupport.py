#!/usr/bin/env python3
"""Existing OFF adapter: fresh official SDK process and ordinary result parsing."""
import argparse, importlib.machinery, importlib.util, json, os
from pathlib import Path
import pwd, stat, subprocess

METHOD = 'diagnosticFlagOffDoesNotObserveRealProducers'
SUITE = 'Perf03ThreeScaleProductionOperationTests'
HELPER = Path('/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper')
RESULT_CLASSIFIER = Path(__file__).parents[4] / 'scripts/lib/swift_testing_result.py'

def save(path,value):
    data=(json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode()
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    with os.fdopen(fd,'wb') as f: f.write(data)

def physical(path,directory=False,trusted_system=False):
    p=Path(path)
    if not p.is_absolute() or os.path.normpath(str(p))!=str(p): raise ValueError('physical absolute path required')
    for x in [*reversed(p.parents),p]:
        if x.is_symlink(): raise ValueError('symlink component '+str(x))
    s=p.stat()
    if s.st_uid not in ({0,os.geteuid()} if trusted_system else {os.geteuid()}) or (directory and not stat.S_ISDIR(s.st_mode)): raise ValueError('owner/type mismatch')
    return s

def module(path,name):
    loader=importlib.machinery.SourceFileLoader(name,str(path))
    spec=importlib.util.spec_from_loader(name,loader)
    result=importlib.util.module_from_spec(spec);loader.exec_module(result);return result

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--request',required=True);a=ap.parse_args()
    request_path=Path(a.request);physical(request_path)
    q=json.loads(request_path.read_text());root=Path(q['root']);s=physical(root,True)
    if stat.S_IMODE(s.st_mode)!=0o700 or request_path.parent!=root: raise ValueError('unique owned0700 request root required')
    bundle=Path(q['bundle']);physical(bundle)
    if not bundle.is_file(): raise ValueError('compiled test bundle must be a file')
    physical(Path(__file__))
    physical(HELPER,trusted_system=True)
    physical(RESULT_CLASSIFIER)
    classifier=module(RESULT_CLASSIFIER,'perf03_existing_swift_testing_result')
    # Use the existing formal profile contract, including the package-named scratch.
    scratch=root/'MinisCanvasApp';scratch.mkdir(mode=0o700)
    for name in ['home','tmp','cache','config','security','formal-test-root','aux']:(scratch/name).mkdir(mode=0o700)
    formal=scratch/'formal-test-root';fs=physical(formal,True)
    # Constructed environment implements env -i; no parent variables or credentials are copied.
    developer='/Applications/Xcode.app/Contents/Developer'
    username=pwd.getpwuid(os.geteuid()).pw_name
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8',
         'USER':username,'LOGNAME':username,'SHELL':'/bin/zsh','HOME':str(scratch/'home'),
         'CFFIXED_USER_HOME':str(scratch/'home'),'ZDOTDIR':str(scratch/'home'),'TMPDIR':str(scratch/'tmp'),
         'XDG_CACHE_HOME':str(scratch/'cache'),'XDG_CONFIG_HOME':str(scratch/'config'),
         'PYTHONNOUSERSITE':'1','PYTHONDONTWRITEBYTECODE':'1',
         'DYLD_FRAMEWORK_PATH':developer+'/Platforms/MacOSX.platform/Developer/Library/Frameworks:'+developer+'/../SharedFrameworks',
         'DYLD_LIBRARY_PATH':developer+'/Platforms/MacOSX.platform/Developer/usr/lib:'+developer+'/../SharedFrameworks',
         'SWT_EXPERIMENTAL_EVENT_STREAM_FIELDS_ENABLED':'1','MINISCANVAS_TEST_PROFILE':'1',
         'MINISCANVAS_TEST_DIRECTORY':str(formal),'MINISCANVAS_TEST_SCRATCH_DIRECTORY':str(scratch),
         'MINISCANVAS_PROFILE_IDENTITY':'formal-test:'+root.name+':MinisCanvasApp:off',
         'MINISCANVAS_TEST_RUN_ID':root.name,'MINISCANVAS_TEST_PACKAGE':'MinisCanvasApp',
         'MINISCANVAS_TEST_ROOT_DEVICE':str(fs.st_dev),'MINISCANVAS_TEST_ROOT_INODE':str(fs.st_ino),
         'MINISCANVAS_TEST_ROOT_OWNER':str(fs.st_uid),'MINISCANVAS_PERF03_OFF_WORKER':'1'}
    assert 'MINISCANVAS_TRANSCRIPT_OPERATION_DIAGNOSTICS' not in env
    events=root/'events.ndjson'
    argv=[str(HELPER),'--test-bundle-path',str(bundle),'--testing-library','swift-testing',
          '--filter',rf'^MinisCanvasAppTests\.{SUITE}/{METHOD}\(\)(?:/|$)','--no-parallel','--verbose','--event-stream-output-path',str(events)]
    save(root/'environment_whitelist.json',env);save(root/'argv.json',argv)
    # Existing same-DSO OFF selector, with a fresh whitelist environment.
    # subprocess.run delivers the real wait; regular files avoid pipe custody.
    with open(root/'stdout.raw','xb') as stdout, open(root/'stderr.raw','xb') as stderr:
        completed=subprocess.run(argv,cwd=str(scratch),env=env,
            stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,close_fds=True,check=False)
    code=completed.returncode
    (root/'REAL_EXIT').write_text(str(code)+'\n')
    raw=(root/'stdout.raw').read_text(errors='replace')+'\n'+(root/'stderr.raw').read_text(errors='replace')
    evidence=classifier.classify(raw,code)
    passed=(code==0 and evidence['result_REAL_EXIT']==0
            and evidence['tests']==1 and evidence['suites']==1)
    result={'passed':passed,'REAL_EXIT':code,'swift_testing_result':evidence}
    save(root/'result.json',result)
    return 0 if result['passed'] else 1

if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception as error:
        import sys
        print('B0003_FAIL_CLOSED: '+repr(error),file=sys.stderr);raise SystemExit(2)
