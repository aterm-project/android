"""Real authenticated WebSocket/guacd handshake and revocation acceptance.

The fake guacd peer asserts that the gateway, not the browser, chooses the
Relay-authorized target. Pixel/protocol interoperability is separately tested
against real guacd + xrdp/x11vnc by desktop_guacd_acceptance_test.dart.
"""
import json
import socket
import threading
import time
import pytest
from test_relay import relay_world, _issue_ticket, _websocket_handshake, _send_ticket, _assert_closed


def instruction(*values):
    return (','.join(f'{len(str(v))}.{v}' for v in values)+';').encode()


def read_instruction(conn):
    values=[]
    while True:
        length=b''
        while True:
            c=conn.recv(1)
            if not c: raise EOFError()
            if c==b'.': break
            length+=c
            assert len(length)<8
        count=int(length)
        # Fixture instructions/credentials are ASCII. Unicode framing has
        # dedicated Rust and Dart tests.
        text=b''
        while len(text)<count:
            chunk=conn.recv(count-len(text))
            if not chunk: raise EOFError()
            text+=chunk
        values.append(text.decode())
        delimiter=conn.recv(1)
        if delimiter==b';': return values
        assert delimiter==b','


@pytest.fixture
def desktop_world(tmp_path,request,monkeypatch):
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(8);listener.settimeout(.2)
    monkeypatch.setenv('ATERMIUS_GUACD_ADDRESS',f'127.0.0.1:{listener.getsockname()[1]}')
    stop=threading.Event();observations=[];errors=[];threads=[]
    def handle(conn):
        try:
            with conn:
                conn.settimeout(5)
                select=read_instruction(conn)
                conn.sendall(instruction('args','VERSION_1_5_0','hostname','port','username','password','ignore-cert','enable-drive'))
                caps=[read_instruction(conn) for _ in range(4)]
                connect=read_instruction(conn)
                observations.append((select,caps,connect))
                conn.sendall(instruction('ready','fixture')+instruction('size',0,640,480)+instruction('sync',1))
                while not stop.is_set():
                    try:
                        command=read_instruction(conn)
                        if command[0]=='key': conn.sendall(instruction('sync',2))
                    except EOFError: break
        except (OSError,EOFError): pass
        except Exception as e: errors.append(type(e).__name__)
    def accept():
        while not stop.is_set():
            try: conn,_=listener.accept()
            except socket.timeout: continue
            except OSError: break
            thread=threading.Thread(target=handle,args=(conn,),daemon=True);threads.append(thread);thread.start()
    thread=threading.Thread(target=accept,daemon=True);thread.start()
    try:
        world=request.getfixturevalue('relay_world')
        yield world,observations,errors
    finally:
        stop.set();listener.close();thread.join(2)
        for t in threads:t.join(6)


@pytest.mark.parametrize('protocol',['rdp','vnc'])
def test_desktop_ticket_target_input_and_replay(desktop_world,protocol):
    world,observations,errors=desktop_world
    status,_,ws=_websocket_handshake(world.base_url,'https://wrong.example',path='/desktop/v1/connect')
    assert status==403 and ws is None
    ticket=_issue_ticket(world).json()['ticket']
    status,_,ws=_websocket_handshake(world.base_url,world.base_url,path='/desktop/v1/connect')
    assert status==101
    try:
        _send_ticket(ws,ticket)
        ws.send(1,json.dumps({'protocol':protocol,'username':'test','password':'transient-secret'}).encode())
        opcode,payload=ws.receive()
        assert opcode==2 and b'ready' in payload
        assert observations[0][0]==['select',protocol]
        connect=observations[0][2]
        assert connect==['connect','VERSION_1_0_0',world.echo.address,str(world.echo.port),'test','transient-secret','false','false']
        ws.send(2,instruction('key',65,1))
        # Input is forwarded only after the handshake; forbidden connect/argv
        # instructions cannot change the ticket's pinned destination.
        ws.send(2,instruction('connect','another-host'))
        _assert_closed(ws)
    finally:ws.close()
    _,_,replay=_websocket_handshake(world.base_url,world.base_url,path='/desktop/v1/connect')
    try:_send_ticket(replay,ticket);_assert_closed(replay)
    finally:replay.close()
    assert len(observations)==1 and not errors
    assert world.echo.accepted==0
    # Ticket persistence must not contain the desktop password.
    assert b'transient-secret' not in world.database.read_bytes()


def test_desktop_rejects_browser_supplied_destination(desktop_world):
    world,observations,errors=desktop_world
    ticket=_issue_ticket(world).json()['ticket']
    _,_,ws=_websocket_handshake(world.base_url,world.base_url,path='/desktop/v1/connect')
    try:
        _send_ticket(ws,ticket)
        ws.send(1,json.dumps({'protocol':'vnc','hostname':'127.0.0.1'}).encode())
        _assert_closed(ws)
    finally:ws.close()
    assert not observations and not errors


def test_desktop_active_connection_closes_when_device_is_revoked(desktop_world):
    world,observations,errors=desktop_world
    ticket=_issue_ticket(world).json()['ticket']
    _,_,ws=_websocket_handshake(world.base_url,world.base_url,path='/desktop/v1/connect')
    try:
        _send_ticket(ws,ticket)
        ws.send(1,json.dumps({'protocol':'vnc'}).encode())
        assert ws.receive()[0]==2
        revoked=world.api.request('POST',f'/api/v1/devices/{world.device_id}/revoke',token=world.access_token,json_body={})
        assert revoked.status in (200,204)
        _assert_closed(ws)
    finally:ws.close()
    assert len(observations)==1 and not errors
