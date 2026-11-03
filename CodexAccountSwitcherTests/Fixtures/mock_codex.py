#!/usr/bin/python3
"""Small stdio app-server used with temporary homes and fake credentials only."""
import base64
import json
import os
import shutil
import sys

home = os.environ['CODEX_HOME']

if sys.argv[1:] == ['login', '--with-api-key']:
    key = sys.stdin.readline().rstrip('\n')
    if not key or os.getenv('MOCK_API_LOGIN_FAIL'):
        sys.exit(1)
    marker = os.getenv('MOCK_API_HOME_MARKER')
    if marker:
        with open(marker, 'w', encoding='utf-8') as f:
            json.dump({'home': home, 'mode': os.stat(home).st_mode & 0o777,
                       'config': open(os.path.join(home, 'config.toml'), encoding='utf-8').read()}, f)
    with open(os.path.join(home, 'auth.json'), 'w', encoding='utf-8') as f:
        json.dump({'OPENAI_API_KEY': key}, f)
    os.chmod(os.path.join(home, 'auth.json'), 0o600)
    sys.exit(0)

config_written = False

def account():
    try:
        with open(os.path.join(home, 'auth.json'), encoding='utf-8') as f:
            auth = json.load(f)
    except FileNotFoundError:
        return None
    if auth.get('OPENAI_API_KEY'):
        return {'type': 'apiKey'}
    try:
        payload = auth['tokens']['id_token'].split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
        plan = claims.get('https://api.openai.com/auth', {}).get('chatgpt_plan_type', 'unknown')
        return {'type': 'chatgpt', 'email': os.getenv('MOCK_EMAIL', claims.get('email')), 'planType': os.getenv('MOCK_PLAN_TYPE', plan)}
    except (KeyError, ValueError, IndexError):
        return None

for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if 'id' not in request:
        continue
    if method == 'initialize':
        result = {}
    elif method == 'config/read':
        settings = {'cli_auth_credentials_store': os.getenv('MOCK_STORE', 'file'), 'model_provider': 'openai', 'model': 'unchanged'}
        layer = {}
        if os.getenv('MOCK_CUSTOM_ENDPOINT'):
            layer['openai_base_url'] = os.environ['MOCK_CUSTOM_ENDPOINT']
        if os.getenv('MOCK_CHATGPT_ENDPOINT'):
            layer['chatgpt_base_url'] = os.environ['MOCK_CHATGPT_ENDPOINT']
        result = {'config': settings, 'layers': [{'name': {'type': 'user'}, 'version': 'v1', 'config': layer}]}
    elif method == 'account/read':
        result = {'account': None if config_written and os.getenv('MOCK_VERIFY_FAILURE') else account()}
    elif method == 'account/rateLimits/read':
        if request.get('params') is not None:
            print(json.dumps({'id': request['id'], 'error': {'code': -32602, 'message': 'expected null params'}}), flush=True)
            continue
        local_counter = os.path.join(home, 'mock_quota_counter')
        if os.path.exists(local_counter):
            with open(local_counter, 'a', encoding='utf-8') as marker:
                marker.write('read\n')
        if os.getenv('MOCK_QUOTA_MARKER'):
            with open(os.environ['MOCK_QUOTA_MARKER'], 'a', encoding='utf-8') as marker:
                marker.write('read\n')
        if os.getenv('MOCK_SWAP_AUTH_PATH'):
            with open(os.environ['MOCK_SWAP_AUTH_PATH'], 'rb') as replacement:
                content = replacement.read()
            with open(os.path.join(home, 'auth.json'), 'wb') as target:
                target.write(content)
        if os.getenv('MOCK_QUOTA_ERROR') or os.path.exists(os.path.join(home, 'mock_quota_error')):
            print(json.dumps({'id': request['id'], 'error': {'code': -32000, 'message': 'mock failure'}}), flush=True)
            continue
        local_quota = os.path.join(home, 'mock_quota.json')
        if os.path.exists(local_quota):
            with open(local_quota, encoding='utf-8') as quota_file:
                result = json.load(quota_file)
        else:
            result = json.loads(os.getenv('MOCK_QUOTA', '{"rateLimits": {}}'))
    elif method == 'config/batchWrite':
        if os.getenv('MOCK_CONFIG_WRITE_SWAP_AUTH_PATH'):
            shutil.copyfile(os.environ['MOCK_CONFIG_WRITE_SWAP_AUTH_PATH'], os.path.join(home, 'auth.json'))
        if os.getenv('MOCK_CONFIG_WRITE_FAIL'):
            print(json.dumps({'id': request['id'], 'error': {'code': -32000, 'message': 'mock failure'}}), flush=True)
            continue
        config_written = True
        result = {'status': 'ok'}
    elif method == 'account/login/start':
        login_type = request.get('params', {}).get('type')
        if login_type == 'chatgptDeviceCode' and os.getenv('MOCK_DEVICE_UNAVAILABLE'):
            print(json.dumps({'id': request['id'], 'error': {'code': -32000, 'message': 'device login disabled'}}), flush=True)
            continue
        marker = os.getenv('MOCK_LOGIN_HOME_MARKER')
        if marker:
            with open(marker, 'w', encoding='utf-8') as f:
                json.dump({'home': home, 'mode': os.stat(home).st_mode & 0o777,
                           'config': open(os.path.join(home, 'config.toml'), encoding='utf-8').read()}, f)
        address = 'https://evil.example/login' if os.getenv('MOCK_UNSAFE_LOGIN_URL') else 'https://auth.openai.com/codex/device'
        result = {'type': login_type, 'loginId': 'test-login'}
        if login_type == 'chatgptDeviceCode':
            result.update({'verificationUrl': address, 'userCode': 'ABCD-1234'})
        else:
            result['authUrl'] = address
    elif method == 'account/login/cancel':
        marker = os.getenv('MOCK_LOGIN_CANCEL_MARKER')
        if marker:
            with open(marker, 'w', encoding='utf-8') as f:
                f.write('cancelled')
        result = {'status': 'canceled'}
    else:
        result = {}
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
    if method == 'account/login/start' and not os.getenv('MOCK_LOGIN_PENDING'):
        source = os.getenv('MOCK_LOGIN_AUTH_PATH')
        if source:
            shutil.copyfile(source, os.path.join(home, 'auth.json'))
            os.chmod(os.path.join(home, 'auth.json'), 0o600)
        print(json.dumps({'method': 'account/login/completed', 'params': {
            'loginId': 'test-login', 'success': bool(source)}}), flush=True)
