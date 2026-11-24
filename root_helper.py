#!/usr/bin/env python3
"""Root-owned narrow command gateway; installed 0755 root:root; only called by sudoers."""
import json, os, pwd, re, subprocess, sys

PAT = re.compile(r'^[a-z][a-z0-9_]{2,23}$')
BLOCK = {'root','admin','daemon','nobody','sshd','ubuntu','www-data','hakscorp'}

def run(argv, *, stdin=None, optional=False):
    p = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=12, check=False)
    if p.returncode and not optional:
        raise RuntimeError(p.stderr.strip()[:150] or 'Comando fallido')
    return p

def owned(name):
    try:
        pw = pwd.getpwnam(name)
    except KeyError:
        return False
    return pw.pw_gecos.startswith('HakScorpVPN:') and pw.pw_uid >= 1000

def process_sessions(name):
    if not owned(name):
        return []
    uid = pwd.getpwnam(name).pw_uid
    # /proc direct ancestry, sid/uid; only processes with real user uid and sshd names
    results=[]
    for item in os.scandir('/proc'):
        if not item.name.isdecimal():
            continue
        try:
            pid=int(item.name)
            status=open(f'/proc/{pid}/status').read()
            match=re.search(r'^Uid:\s+(\d+)',status,re.M)
            comm=open(f'/proc/{pid}/comm').read().strip()
            if match and int(match.group(1))==uid and comm in ('sshd','sshd-session'):
                stat=open(f'/proc/{pid}/stat').read()
                rest=stat[stat.rfind(')')+2:].split()
                start=int(rest[19]) # field 22 since after comm starts at field3
                results.append((start,pid))
        except (FileNotFoundError,PermissionError,ProcessLookupError,ValueError,IndexError):
            continue
    return sorted(results)

def main():
    if os.geteuid()!=0:
        raise RuntimeError('Se requiere root')
    data=json.loads(sys.stdin.readline())
    name=data.get('username','')
    act=data.get('action','')
    if not isinstance(name,str) or not PAT.fullmatch(name) or name in BLOCK or name.startswith('hs_'):
        raise ValueError('Nombre no permitido')
    if act=='create':
        try:
            pwd.getpwnam(name)
            raise ValueError('Usuario ya existe')
        except KeyError:
            pass
        run(['useradd','-M','-s','/bin/false','-c','HakScorpVPN:managed',name])
        try:
            password=data['password']
            if not isinstance(password,str) or not 12<=len(password)<=128 or '\n' in password or ':' in name:
                raise ValueError('Contraseña inválida')
            run(['chpasswd'],stdin=f'{name}:{password}\n')
        except Exception:
            run(['userdel',name],optional=True)
            raise
    elif act in ('password','unlock','lock','delete','disconnect','sessions','limit'):
        if not owned(name):
            raise ValueError('Usuario no administrado')
        if act=='password':
            password=data['password']
            if not isinstance(password,str) or not 12<=len(password)<=128 or '\n' in password:
                raise ValueError('Contraseña inválida')
            run(['chpasswd'],stdin=f'{name}:{password}\n')
        elif act=='lock':
            run(['usermod','-L',name])
            run(['pkill','-KILL','-u',name],optional=True)
        elif act=='unlock':
            run(['usermod','-U',name])
        elif act=='delete':
            run(['pkill','-KILL','-u',name],optional=True)
            run(['userdel',name])
        elif act=='disconnect':
            run(['pkill','-KILL','-u',name],optional=True)
        elif act=='sessions':
            print(json.dumps({'sessions':len(process_sessions(name))})); return
        elif act=='limit':
            limit=int(data.get('password') or 1)
            if limit<1 or limit>10: raise ValueError('Límite inválido')
            extra=process_sessions(name)[limit:]
            import signal
            for _,pid in extra:
                try: os.kill(pid,signal.SIGKILL)
                except ProcessLookupError: pass
            print(json.dumps({'terminated':len(extra)})); return
    else:
        raise ValueError('Acción inválida')
    print('{}')

if __name__=='__main__':
    try: main()
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
