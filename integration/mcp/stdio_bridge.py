#!/usr/bin/env python3
"""Dependency-free stdio adapter for Atermius's authenticated local MCP endpoint.

Set ATERMIUS_MCP_URL and ATERMIUS_MCP_TOKEN in the MCP client's environment.
Neither credentials nor protocol messages are logged to stderr.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

MAX_LINE = 512 * 1024
MAX_RESPONSE = 2 * 1024 * 1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    url = os.environ.get('ATERMIUS_MCP_URL', 'http://127.0.0.1:8765/mcp')
    token = os.environ.get('ATERMIUS_MCP_TOKEN', '')
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost')
            or parsed.path != '/mcp' or parsed.query or parsed.fragment or parsed.username
            or len(token) < 32 or any(ord(c) < 33 or ord(c) > 126 for c in token)):
        print('Configure a loopback MCP URL and its current access token.', file=sys.stderr)
        return 2
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    while True:
        line = sys.stdin.buffer.readline(MAX_LINE + 1)
        if not line:
            return 0
        if len(line) > MAX_LINE:
            print('MCP input exceeded its size limit.', file=sys.stderr)
            return 2
        request_id = None
        try:
            message = json.loads(line)
            if not isinstance(message, dict):
                raise ValueError('object required')
            request_id = message.get('id')
            params = message.get('params') or {}
            meta = params.get('_meta') or {}
            version = meta.get('io.modelcontextprotocol/protocolVersion', '2025-11-25')
            headers = {'Content-Type': 'application/json',
                       'Accept': 'application/json, text/event-stream',
                       'Authorization': 'Bearer ' + token,
                       'MCP-Protocol-Version': version}
            if version == '2026-07-28':
                headers['Mcp-Method'] = message['method']
                if message['method'] in ('tools/call', 'prompts/get', 'resources/read'):
                    headers['Mcp-Name'] = params.get('name', params.get('uri', ''))
            request = urllib.request.Request(url, data=line, headers=headers, method='POST')
            try:
                response = opener.open(request, timeout=140)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                body = response.read(MAX_RESPONSE + 1)
            if len(body) > MAX_RESPONSE:
                raise ValueError('response too large')
            if body:
                decoded = json.loads(body)
                if request_id is not None:
                    sys.stdout.write(json.dumps(decoded, ensure_ascii=True) + '\n')
                    sys.stdout.flush()
            elif request_id is not None:
                raise ValueError('empty response')
        except Exception:
            if request_id is not None:
                sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': request_id,
                    'error': {'code': -32603, 'message': 'Local MCP request failed. Check that Atermius is unlocked and MCP is enabled with the current token. Do not automatically retry side effects.'}}) + '\n')
                sys.stdout.flush()
            else:
                print('Invalid or rejected MCP notification.', file=sys.stderr)


if __name__ == '__main__':
    sys.exit(main())
