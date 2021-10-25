#!/usr/bin/env python3
"""A real file-size limit must fail salvage, not turn I/O errors into data loss."""
import json, pathlib, resource, signal, subprocess, tempfile
BIN=pathlib.Path(__file__).resolve().parents[1]/'bin'/'cairn'
def run(*args, **kwargs):
 return subprocess.run([str(BIN),*map(str,args)],capture_output=True,text=True,**kwargs)
def constrained():
 signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
 resource.setrlimit(resource.RLIMIT_FSIZE,(65536,65536))
with tempfile.TemporaryDirectory(prefix='cairn-io-regression-') as tmp:
 root=pathlib.Path(tmp); source=root/'source'; source.mkdir()
 source.joinpath('data').write_bytes(bytes(range(256))*2048)
 p=run('init',root/'archive','--data','2','--parity','1','--chunk-min','262144','--chunk-avg','262144','--chunk-max','262144'); assert p.returncode==0,p.stderr
 p=run('backup',root/'archive',source,'first'); assert p.returncode==0,p.stderr
 p=run('salvage',root/'archive','first',root/'salvaged',preexec_fn=constrained)
 print(json.dumps({'exit':p.returncode,'stderr':p.stderr,'destination_published':(root/'salvaged').exists()}))
 assert p.returncode != 0, 'salvage incorrectly succeeded after output writes hit EFBIG'
 assert not (root/'salvaged').exists(), 'salvage published output after a local I/O failure'
