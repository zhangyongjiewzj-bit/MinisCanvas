"""Exact qualified process identity/census spans; no launch at import."""
import ctypes, subprocess
_libproc=None

def ps():
 raw=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,lstart=,comm='],text=True);rows={}
 for line in raw.splitlines():
  v=line.split(None,7)
  if len(v)==8:rows[int(v[0])]={'pid':int(v[0]),'ppid':int(v[1]),'birth':' '.join(v[2:7]),'comm':v[7]}
 return raw,rows

class BSDInfo(ctypes.Structure):
 _fields_=[(n,ctypes.c_uint32) for n in ['flags','status','xstatus','pid','ppid','uid','gid','ruid','rgid','svuid','svgid','rfu']]+[('comm',ctypes.c_char*16),('name',ctypes.c_char*32)]+[(n,ctypes.c_uint32) for n in ['nfiles','pgid','jobc','tdev','tpgid']]+[('nice',ctypes.c_int32),('start_sec',ctypes.c_uint64),('start_usec',ctypes.c_uint64)]

def generation(pid):
 global _libproc
 if _libproc is None:
  _libproc=ctypes.CDLL('/usr/lib/libproc.dylib');_libproc.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int];_libproc.proc_pidinfo.restype=ctypes.c_int
 info=BSDInfo();n=_libproc.proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info))
 if n!=ctypes.sizeof(info):return None
 return {'pid':info.pid,'uid':info.uid,'start_sec':info.start_sec,'start_usec':info.start_usec}

def snapshot_known(known,rows):
 result=[]
 for k,v in sorted(known.items()):
  now=generation(k);same=now is not None and now==v.get('generation')
  result.append({'known':v,'current':rows.get(k),'generation_now':now,'gone':k not in rows and now is None,'same_generation':same})
 return result
