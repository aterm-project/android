#!/usr/bin/env python3
"""Staged Android UI acceptance. All actions are confined to an empty catalog.

Private baseline bytes stay in a 0600 archive for interruption recovery. No pm
clear is used. Cleanup only removes the uniquely owned profile/file delta, then
restores byte-identical originals and checks preexisting Keystore metadata.
"""
from __future__ import annotations
import argparse,hashlib,json,os,re,secrets,shlex,subprocess,time,zipfile
from pathlib import Path
from android_local_profile_smoke import Android,PACKAGE
from android_auto_resume_smoke import CATALOG,data_names,read_data,write_data,catalog_profiles

ROOT=Path('/tmp/atermius-files-20261106')
STATE=ROOT/'android-ui-private.json'
EVIDENCE=ROOT/'artifacts/android-workspace-evidence.json'
JAR='/data/local/tmp/atermius-android-inventory-20261106.jar'

class Device(Android):
    def find(self,label,**options):
        try:return super().find(label,**options)
        except LookupError:
            if label=='主机' and not options.get('edit'):
                tree=self.ui();buttons=[n for n in tree.iter('node') if n.get('class')=='android.widget.Button' and label in self.labels(n)]
                if len(buttons)==1:return buttons[0]
            if label not in ('搜索名称、地址、用户、标签或分组','远端路径') or not options.get('edit'):raise
            tree=self.ui();fields=[n for n in tree.iter('node') if n.get('class')=='android.widget.EditText' and n.get('enabled')=='true']
            host_page=any(('添加' if label=='搜索名称、地址、用户、标签或分组' else '文件操作') in self.labels(n) for n in tree.iter('node'))
            if host_page and len(fields)==1:return fields[0]
            raise
    def require_host(self,name):
        if not any(name in v for n in self.ui().iter('node') if n.get('class')!='android.widget.EditText' for v in self.labels(n)):
            raise RuntimeError('Saved Host card not visible outside its input field')
    @staticmethod
    def bounds(n):
        m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',n.get('bounds',''))
        if not m: raise RuntimeError('Invalid UI bounds')
        return tuple(map(int,m.groups()))
    def scroll_find(self,label,edit=False):
        for attempt in range(6):
            try:return self.find(label,edit=edit)
            except LookupError:pass
            tree=self.ui(); boxes=[self.bounds(n) for n in tree.iter('node') if n.get('scrollable')=='true']
            if not boxes:raise RuntimeError('Expected editor scroll region missing')
            x1,y1,x2,y2=max(boxes,key=lambda b:(b[2]-b[0])*(b[3]-b[1]))
            self.shell('input','swipe',str((x1+x2)//2),str(y2-45),str((x1+x2)//2),str(y1+45),'350')
        raise RuntimeError('Expected editor field unavailable')
    def set_field(self,label,value,replace=False,submit=False):
        # Quoted remote argv; allow ASCII punctuation but never whitespace/control.
        if not all(33<=ord(c)<=126 for c in value) or '%s' in value:raise ValueError('Unsupported UI input')
        node=self.scroll_find(label,edit=True);self.tap_node(node)
        end=time.monotonic()+12
        while self.find(label,edit=True).get('focused')!='true':
            if time.monotonic()>end:raise RuntimeError('Field did not receive focus')
        if replace:
            old=self.find(label,edit=True).get('text','')
            self.shell('input','keyevent','123')
            if old:self.shell('input','keyevent',*(['67']*(len(old)+1)))
        if value:self.shell('input','text',value)
        n=self.find(label,edit=True);actual=n.get('text','')
        if (len(actual)!=len(value)) if n.get('password')=='true' else (actual!=value):raise RuntimeError('UI input validation failed')
        if submit:self.shell('input','keyevent','66')
        ime=self.shell('dumpsys','input_method')
        if not submit and ('mInputShown=true' in ime or 'isInputViewShown=true' in ime):self.shell('input','keyevent','4')
    def close(self):
        if not self.run('shell',f'pidof {PACKAGE}',check=False).strip():raise RuntimeError('App was not running')
        self.shell('input','keyevent','3');time.sleep(1);self.shell('am','kill',PACKAGE)
        end=time.monotonic()+10
        while self.run('shell',f'pidof {PACKAGE}',check=False).strip():
            if time.monotonic()>end:raise RuntimeError('Background process did not terminate')
            time.sleep(.2)
    def pane_bars(self):
        # Each terminal has one horizontal shortcut row beginning with Esc.
        # Its accessibility bounds identify the pane without reading output.
        tree=self.ui();bars=[]
        for n in tree.iter('node'):
            if any('Esc' in self.labels(k) for k in n.iter('node')):
                b=self.bounds(n)
                if 32<=b[3]-b[1]<=80 and b[2]-b[0]>200:bars.append(b)
        bars=sorted(set(bars))
        if len(bars)!=2:raise RuntimeError('Two terminal pane shortcut rows are not observable')
        return bars
    def divider(self):
        import io
        from PIL import Image
        bars=self.pane_bars();bottom=min(b[1] for b in bars)
        tree=self.ui();tabs=[self.bounds(n) for n in tree.iter('node') if any(' terminal tab, connected' in v for v in self.labels(n))]
        if not tabs:raise RuntimeError('Terminal tabs unavailable during pane measurement')
        top=max(b[3] for b in tabs)+4
        im=Image.open(io.BytesIO(self.run('exec-out','screencap','-p'))).convert('RGB')
        if bottom-top<60:raise RuntimeError('Terminal viewport too short to measure divider')
        xs=[]
        for x in range(16,im.width-16):
            colors=[im.getpixel((x,y)) for y in range(top+6,bottom-6,3)]
            if colors and len(set(colors))==1 and min(colors[0])>100:xs.append(x)
        runs=[]
        for x in xs:
            if runs and x==runs[-1][-1]+1:runs[-1].append(x)
            else:runs.append([x])
        runs=[r for r in runs if 3<=len(r)<=12]
        if len(runs)!=1:raise RuntimeError('Unique vertical pane divider unavailable')
        line=runs[0];return {'x':(line[0]+line[-1])//2,'width':im.width,'ratio':line[0]/(im.width-len(line)),'y':(top+bottom)//2,'divider_width':len(line)}
    def wait_sessions(self,hosts):
        end=time.monotonic()+80
        while time.monotonic()<end:
            try:labels=[v for n in self.ui().iter('node') for v in self.labels(n)]
            except RuntimeError:
                time.sleep(.3);continue
            if all(any(v.startswith(h+' terminal tab, connected') for v in labels) for h in hosts):return
        raise RuntimeError('Group did not connect both SSH hosts')
    def wait_file(self,name):
        end=time.monotonic()+40
        while time.monotonic()<end:
            if any(v==name or v.startswith(name+'\n') for n in self.ui().iter('node') for v in self.labels(n)):return
        raise RuntimeError('Remote fixture file row unavailable')
    def inventory(self):
        return json.loads(self.shell('run-as',PACKAGE,'env','CLASSPATH='+JAR,'app_process','/system/bin','Inventory',timeout=20))
    def labels_safe(self):
        # Debugging counts/coordinates only; excludes fields and terminal content.
        tree=self.ui();return [{'class':n.get('class'),'bounds':n.get('bounds'),'clickable':n.get('clickable'),'enabled':n.get('enabled'),'label':next((v for v in self.labels(n) if v),'')[:180]} for n in tree.iter('node') if n.get('class')!='android.widget.EditText' and any(self.labels(n))]

def save_json(path,data,private=False):
    path.parent.mkdir(parents=True,exist_ok=True)
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600 if private else 0o644)
    with os.fdopen(fd,'w') as f:json.dump(data,f,ensure_ascii=False,indent=2);f.write('\n')

def key_summary(value):
    return {'entry_count':len(value['entries']),'canonical_sha256':hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest(),'certificate_sha256':[e['certificate_sha256'] for e in value['entries']]}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('stage');p.add_argument('--serial',default='172.19.1.198:5555');p.add_argument('--apk',type=Path);p.add_argument('--source-sha256');a=p.parse_args();d=Device(a.serial)
    e=json.loads(EVIDENCE.read_text()) if EVIDENCE.exists() else {'schema':1,'checks':{},'stages':[],'passed':False}
    s=json.loads(STATE.read_text()) if STATE.exists() else {}
    c=json.loads((ROOT/'android-fixture-private.json').read_text())
    if a.stage=='start':
        if s:raise RuntimeError('Existing acceptance state must be cleaned first')
        if a.apk is None or not a.source_sha256:raise RuntimeError('APK/source required')
        names=data_names(d);baseline=read_data(d,names)
        if CATALOG not in baseline or catalog_profiles(baseline[CATALOG]) or any('.sqlite' in n and n!=CATALOG for n in names):raise RuntimeError('Refuse nonempty original catalog or additional database')
        if any(n.startswith('shared_prefs/') for n in names):raise RuntimeError('Refuse preexisting secure-store preferences')
        if d.run('shell',f'pidof {PACKAGE}',check=False).strip():raise RuntimeError('App active before proof; preserve it')
        before=d.inventory();expected=json.loads((ROOT/'android-keystore-before-private.json').read_text())
        if before!=expected:raise RuntimeError('Keystore changed after baseline inventory')
        backup=ROOT/'android-baseline-private.zip'
        fd=os.open(backup,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'wb') as out:
            with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED) as z:
                for n,data in baseline.items():z.writestr(n,data)
        m=secrets.token_hex(5);s={'backup':str(backup),'owned_profile':None,'marker':m,'group':'ui-group-'+m,'hosts':['alpha-'+m,'beta-'+m],'inventory_before':before}
        save_json(STATE,s,True)
        e.update({'source_sha256':a.source_sha256,'apk_sha256':hashlib.sha256(a.apk.read_bytes()).hexdigest(),'baseline_files':len(baseline),'baseline_catalog_sha256':hashlib.sha256(baseline[CATALOG]).hexdigest(),'keystore_before':key_summary(before),'limits':['x86_64 LineageOS virtual device, debug APK','OS nonexportable key metadata compared; no hardware security claim','layout means in-app panes/ratio/active selection; external desktop window geometry excluded','SCP file browser lists through SFTP; protocol byte transfer not repeated']})
        save_json(EVIDENCE,e)
        out=d.run('install','-r',str(a.apk.resolve()),timeout=120)
        if b'Success' not in out:raise RuntimeError('Install did not succeed')
        d.shell('am','force-stop',PACKAGE)
        # Temporarily remove only the backed-up mode selection to model a fresh
        # native launch, restoring its exact original bytes at cleanup.
        if 'files/workspace-mode-v1' in baseline:d.shell('run-as',PACKAGE,'rm','--','files/workspace-mode-v1')
        d.launch();d.wait('还没有 Host',timeout=90);d.wait('添加')
        profiles=catalog_profiles(read_data(d,[CATALOG])[CATALOG])
        if len(profiles)!=1:raise RuntimeError('Expected exactly one owned device profile')
        s['owned_profile']=profiles[0];save_json(STATE,s,True)
        e['checks']['fresh_native_launch_direct_workspace_without_selection_or_password']=True
        (ROOT/'artifacts/android-fresh-workspace.png').write_bytes(d.run('exec-out','screencap','-p'))
        d.close();d.launch();d.wait('还没有 Host',timeout=60);d.wait('添加')
        e['checks']['background_close_cold_restart_without_chooser_or_password']=True
    elif a.stage=='create':
        if not s.get('group_created'):
            d.tap('新建分组');d.set_field('分组名称',s['group']);d.tap('保存分组');d.wait(s['group'])
            s['group_created']=True;save_json(STATE,s,True)
        for name in s['hosts']:
            if name in s.get('hosts_created',[]):continue
            d.tap('添加');d.set_field('Display name',name);d.set_field('Hostname or IP',c['host']);d.set_field('Port',str(c['port']),replace=True);d.set_field('SSH username',c['username'],replace=True);d.set_field('SSH password',c['password'])
            d.tap_node(d.scroll_find('Group\nNo group'));d.tap(s['group']);d.tap('Save encrypted host');d.wait(name,contains=True);d.wait('添加')
            s.setdefault('hosts_created',[]).append(name);save_json(STATE,s,True)
        e['checks']['two_encrypted_hosts_and_group_created']=True
        d.set_field('搜索名称、地址、用户、标签或分组',s['hosts'][0],replace=True);d.require_host(s['hosts'][0])
        if any(s['hosts'][1] in v for n in d.ui().iter('node') for v in d.labels(n)):raise RuntimeError('Search did not filter second host')
        d.set_field('搜索名称、地址、用户、标签或分组','no-match-'+s['marker'],replace=True);d.wait('没有匹配的主机')
        d.set_field('搜索名称、地址、用户、标签或分组','',replace=True);d.require_host(s['hosts'][1])
        e['checks']['host_search_filters_and_empty_result']=True
    elif a.stage=='connect':
        d.tap(s['group']);d.wait('核实并信任此密钥',timeout=45)
        if not any(c['host_fingerprint'] in v for n in d.ui().iter('node') for v in d.labels(n)):raise RuntimeError('SSH fingerprint differs from trusted endpoint')
        d.tap('核实并信任此密钥');d.wait('终端菜单',timeout=75)
        d.wait_sessions(s['hosts'])
        e['checks']['group_click_connects_two_real_ssh_sessions']=True;e['trusted_fingerprint']=c['host_fingerprint']
    elif a.stage=='files':
        d.tap(s['hosts'][0]+' terminal tab, connected',prefix=True)
        d.tap('终端菜单');d.tap('SFTP 文件管理');d.wait('远端路径',edit=True,timeout=40)
        d.set_field('远端路径',c['remote_fixture'],replace=True,submit=True);d.wait_file(c['proof_name'])
        tree=d.ui();filetabs=[n for n in tree.iter('node') if any(v.startswith('SFTP · ') and 'terminal tab' in v for v in d.labels(n))]
        if len(filetabs)!=1:raise RuntimeError('SFTP is not a single top-level tab')
        e['checks']['sftp_top_level_tab_real_fixture_directory']=True
        title=next(v for v in d.labels(filetabs[0]) if v.startswith('SFTP · '));s['file_host']=next(h for h in s['hosts'] if h in title);save_json(STATE,s,True)
        d.tap(s['file_host']+' terminal tab, connected',prefix=True);d.tap('终端菜单');d.tap('SCP 文件管理');d.wait('远端路径',edit=True,timeout=40)
        d.set_field('远端路径',c['remote_fixture'],replace=True,submit=True);d.wait_file(c['proof_name'])
        tree=d.ui();scp=[n for n in tree.iter('node') if any(v.startswith('SCP · ') and 'terminal tab' in v for v in d.labels(n))]
        sftp=[n for n in tree.iter('node') if any(v.startswith('SFTP · ') and 'terminal tab' in v for v in d.labels(n))]
        if len(scp)!=1 or len(sftp)!=1 or d.bounds(scp[0])[1:4:2]!=d.bounds(sftp[0])[1:4:2]:raise RuntimeError('SFTP/SCP tabs are not peers')
        e['checks']['scp_same_top_level_file_tab_real_fixture_directory']=True
        (ROOT/'artifacts/android-file-tabs.png').write_bytes(d.run('exec-out','screencap','-p'))
        d.tap('Close SCP · '+s['file_host']);d.tap('Close SFTP · '+s['file_host']);d.tap('主机')
        labels=[v for n in d.ui().iter('node') for v in d.labels(n) if v.startswith('操作系统：')]
        if len(labels)!=2 or any('尚未识别' in v for v in labels):raise RuntimeError('OS auto-detection not visible on both hosts')
        e['checks']['authenticated_os_observation_visible_on_host_cards']=True;e['detected_os_labels']=[v.split('\n')[0] for v in labels]
        (ROOT/'artifacts/android-host-cards.png').write_bytes(d.run('exec-out','screencap','-p'))
    elif a.stage=='layout':
        d.tap(s['hosts'][0]+' terminal tab, connected',prefix=True)
        divider=d.divider();target=int(divider['width']*.34)
        d.shell('input','swipe',str(divider['x']),str(divider['y']),str(target),str(divider['y']),'600')
        measurement=d.divider();ratio=measurement['ratio']
        if not .29<ratio<.40:raise RuntimeError('Pane divider did not acquire intended nondefault ratio')
        d.tap(s['hosts'][1]+' terminal tab, connected',prefix=True)
        d.tap('主机');d.tap('分组操作：'+s['group']);d.tap('保存当前窗口布局');d.wait('分组窗口布局已保存。')
        s['saved_ratio']=ratio;s['saved_active']=s['hosts'][1];save_json(STATE,s,True)
        e['checks']['nondefault_pane_ratio_layout_saved']=True
        d.close();d.launch();d.wait(s['group'],timeout=60);d.wait('添加');d.tap(s['group']);d.wait_sessions(s['hosts'])
        restored_measurement=d.divider();restored=restored_measurement['ratio']
        if abs(restored-ratio)>.015:raise RuntimeError('Saved pane ratio did not restore across process restart')
        selected=[n for n in d.ui().iter('node') if n.get('selected')=='true' and any(v.startswith(s['saved_active']+' terminal tab, connected') for v in d.labels(n))]
        if len(selected)!=1:raise RuntimeError('Saved active pane did not restore')
        e['checks']['group_layout_reconnect_after_restart_preserves_ratio_and_active_pane']=True;e['layout_ratios']={'saved':ratio,'restored':restored};e['layout_measurements']={'saved':measurement,'restored':restored_measurement,'method':'uniform vertical divider pixels in memory; no terminal content retained'}
    elif a.stage=='inspect':
        print(json.dumps(d.labels_safe(),ensure_ascii=False,indent=2));return
    elif a.stage=='cleanup':
        if not s:raise RuntimeError('No owned proof state')
        d.shell('am','force-stop',PACKAGE)
        if d.run('shell',f'pidof {PACKAGE}',check=False).strip():raise RuntimeError('App process still active during cleanup')
        with zipfile.ZipFile(s['backup']) as z:baseline={n:z.read(n) for n in z.namelist()}
        current=data_names(d);profiles=catalog_profiles(read_data(d,[CATALOG])[CATALOG]);owned=tuple(s['owned_profile']) if s['owned_profile'] else None
        if profiles!=([] if owned is None else [owned]):raise RuntimeError('Unexpected catalog owner; preserving data')
        allowed={CATALOG+suffix for suffix in ('-journal','-wal','-shm')}
        for key in ('atermius.local-profile-resume.v1','atermius.device-key.local-profile-resume.v1'):
            allowed.add('files/local-resume-'+hashlib.sha256(key.encode()).hexdigest()+'.revoked')
        for pref in ('FlutterSecureStorage','FlutterSecureKeyStorage','FlutterSecureStorageConfiguration:FlutterSecureStorage','FlutterSecureStorageConfiguration'):
            allowed.update('shared_prefs/'+pref+'.xml'+suffix for suffix in ('','.bak'))
        allowed.add('files/coordination/'+hashlib.sha256(b'local-profile-device-bootstrap-v1').hexdigest()+'.lock')
        if owned:
            pid,domain,vault=owned;allowed.update('app_flutter/atermius_local_vault_'+pid+'.sqlite'+suffix for suffix in ('','-journal','-wal','-shm'))
            scope=hashlib.sha256((domain+'\0'+vault).encode()).hexdigest();allowed.add('files/coordination/'+hashlib.sha256(('atermius.known-host-auth.v1.'+scope).encode()).hexdigest()+'.lock')
        unknown=set(current)-baseline.keys()-allowed
        if unknown:e['preserved_unowned_files']=[hashlib.sha256(n.encode()).hexdigest() for n in sorted(unknown)];raise RuntimeError('Unexpected private file delta preserved')
        persisted=read_data(d,current)
        if any(secret.encode() in b for secret in [c['password'],s['group'],*s['hosts']] for b in persisted.values()):raise RuntimeError('Sensitive plaintext persisted')
        e['checks']['plaintext_fixture_marker_matches']=0
        after=d.inventory()
        if after!=s['inventory_before']:raise RuntimeError('Keystore metadata differs; preserve for ownership review')
        removed=[]
        for n in current:
            if n not in baseline:d.shell('run-as',PACKAGE,'rm','--',n);removed.append(n)
        for n,b in baseline.items():
            if n not in persisted or persisted[n]!=b:write_data(d,n,b)
        if read_data(d,data_names(d))!=baseline:raise RuntimeError('Original data restoration differs')
        final=d.inventory()
        if final!=s['inventory_before']:raise RuntimeError('Final Keystore metadata differs')
        e['cleanup']={'original_files_restored_byte_exact':True,'original_file_count':len(baseline),'final_profile_count':0,'keystore_existing_entries_unchanged':True,'keystore':key_summary(final),'new_managed_profile_secure_records_removed_via_owned_preferences_delta':True,'owned_bootstrap_and_profile_locks_removed_after_force_stop':True,'removed_owned_file_count':len(removed),'pm_clear_used':False,'new_apk_retained':True,'app_force_stopped':True}
        required=('fresh_native_launch_direct_workspace_without_selection_or_password','background_close_cold_restart_without_chooser_or_password','two_encrypted_hosts_and_group_created','host_search_filters_and_empty_result','group_click_connects_two_real_ssh_sessions','sftp_top_level_tab_real_fixture_directory','scp_same_top_level_file_tab_real_fixture_directory','authenticated_os_observation_visible_on_host_cards','nondefault_pane_ratio_layout_saved','group_layout_reconnect_after_restart_preserves_ratio_and_active_pane')
        e['passed']=all(e['checks'].get(k) is True for k in required)
        Path(s['backup']).unlink();STATE.unlink()
    else:raise RuntimeError('Unknown acceptance stage')
    e['stages'].append({'stage':a.stage,'runner_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'completed_unix':int(time.time())})
    save_json(EVIDENCE,e);print('android-workspace-stage: '+a.stage+' passed',flush=True)

if __name__=='__main__':
    try:main()
    except Exception as error:
        import sys
        e=json.loads(EVIDENCE.read_text()) if EVIDENCE.exists() else {'schema':1}
        e.setdefault('attempt_failures',[]).append({'stage':sys.argv[1] if len(sys.argv)>1 else None,'failure_type':type(error).__name__,'runner_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'unix':int(time.time())})
        save_json(EVIDENCE,e)
        raise
