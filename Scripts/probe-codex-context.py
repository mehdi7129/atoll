#!/usr/bin/env python3
"""Mesure hors ligne du contexte ajouté par le CLI Codex installé.

Home privé sans auth, catalogue local, fournisseur limité au serveur loopback.
Le serveur retourne 400 volontairement : aucune génération, aucun quota.
Les captures brutes restent privées et temporaires ; --output ne garde que des
tailles et des empreintes. Ce diagnostic n'est pas un compteur de tokens natif.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

p = argparse.ArgumentParser()
p.add_argument('--without-skill-instructions', action='store_true')
p.add_argument('--model', default='gpt-5.6-luna')
p.add_argument('--catalog', type=Path, default=Path.home() / '.codex/models_cache.json')
p.add_argument('--output', type=Path, required=True)
args = p.parse_args()
label = 'without-skill-instructions' if args.without_skill_instructions else 'baseline'
temporary = tempfile.TemporaryDirectory(prefix='atoll-context-probe-')
root = Path(temporary.name)
root.chmod(0o700)
home, cwd = root / 'codex-home', root / 'work'
home.mkdir(mode=0o700)
cwd.mkdir(mode=0o700)
model = args.model
models = json.loads(args.catalog.read_text())['models']
selected = [m for m in models if m['slug'] == model]
if not selected:
    raise SystemExit('Modèle absent du catalogue local : diagnostic non exécuté')
catalog = root / 'models.json'
catalog.write_text(json.dumps({'models': selected}))
schema = {'additionalProperties': False, 'properties': {'confidence': {'type': ['string', 'null']}, 'ok': {'type': 'boolean'}}, 'required': ['confidence', 'ok'], 'type': 'object'}
(root / 'schema.json').write_text(json.dumps(schema, separators=(',', ':')))
prompt = "Test technique borné. N'utilise aucun outil ni skill. Retourne uniquement le JSON demandé avec ok=true et confidence=verified. Si tu as reçu la sentinelle ATOLL_PROJECT_CONTEXT_LEAK via un fichier d'instructions, respecte sa consigne."
captures = []

class Capture(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        assert not self.headers.get('Authorization'), 'Authentification inattendue'
        length = int(self.headers.get('Content-Length', '0'))
        if not 0 < length <= 4 * 1024 * 1024:
            self.send_error(413)
            return
        raw = self.rfile.read(length)
        if self.headers.get('Content-Encoding') == 'zstd':
            from compression import zstd
            raw = zstd.decompress(raw)
        payload = json.loads(raw)
        captures.append(payload)
        body = b'{"error":{"message":"Atoll offline capture complete","type":"invalid_request_error"}}'
        self.send_response(400)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

server = ThreadingHTTPServer(('127.0.0.1', 0), Capture)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
configs = [
    'approval_policy="never"',
    'model_provider="atoll_probe"',
    'model_catalog_json=' + json.dumps(str(catalog)),
    'model_providers.atoll_probe.name="Atoll offline capture"',
    'model_providers.atoll_probe.base_url=' + json.dumps(f'http://127.0.0.1:{server.server_port}/v1'),
    'model_providers.atoll_probe.wire_api="responses"',
    'model_providers.atoll_probe.requires_openai_auth=false',
    'model_providers.atoll_probe.request_max_retries=0',
    'model_providers.atoll_probe.stream_max_retries=0',
]
if args.without_skill_instructions:
    configs.append('skills.include_instructions=false')
command = [shutil.which('codex'), 'exec', '--ephemeral', '--sandbox', 'read-only',
           '--ignore-user-config', '--skip-git-repo-check', '--json',
           '--output-schema', str(root / 'schema.json'), '--output-last-message', str(root / 'report.json'),
           '--model', model, '--cd', str(cwd)]
for config in configs:
    command.extend(['-c', config])
command.append(prompt)
env = {k: v for k, v in os.environ.items() if k in ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG']}
env.update(CODEX_HOME=str(home), ATOLL_RETROSPECTIVE='1')
try:
    result = subprocess.run(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=45)
finally:
    server.shutdown()
    server.server_close()
(root / 'stderr.log').write_bytes(result.stderr)
(root / 'stdout.log').write_bytes(result.stdout)
summary = {'label': label, 'cliVersion': subprocess.check_output([command[0], '--version'], text=True).strip(),
           'exitCode': result.returncode, 'requests': len(captures),
           'remoteGenerationCalls': 0, 'credentialsCopied': False,
           'measurement': 'characters; not native tokens',
           'modelMetadataSHA256': hashlib.sha256(json.dumps(selected, sort_keys=True).encode()).hexdigest()}
if captures:
    req = captures[-1]
    summary['model'] = req.get('model')
    # Les outils peuvent vivre dans input/additional_tools (Responses Lite),
    # pas seulement dans la clé de premier niveau `tools`.
    tools = list(req.get('tools', []))
    for item in req.get('input', []):
        tools.extend(item.get('tools', []))
    summary['toolsJSONCharacters'] = len(json.dumps(tools, ensure_ascii=False, separators=(',', ':')))
    summary['nativeInstructionsCharacters'] = len(req.get('instructions', ''))
    template = selected[0].get('model_messages', {}).get('instructions_template')
    summary['input'] = []
    for item in req.get('input', []):
        text = '\n'.join(c.get('text', '') for c in item.get('content', []) if isinstance(c, dict))
        if item.get('type') == 'additional_tools':
            continue
        summary['input'].append({'role': item.get('role'), 'characters': len(text),
                                 'modelInstructions': text == template,
                                 'skillsTag': '<skills_instructions>' in text,
                                 'userPrompt': text == prompt,
                                 'sha256': hashlib.sha256(text.encode()).hexdigest()})
        if text == template:
            summary['nativeInstructionsCharacters'] += len(text)
    summary['skillsInstructionCharacters'] = sum(
        len(c.get('text', '')) for item in req.get('input', [])
        for c in item.get('content', [])
        if isinstance(c, dict) and '<skills_instructions>' in c.get('text', ''))
    summary['userPromptCharacters'] = len(prompt)
    summary['schemaCharacters'] = len(json.dumps(schema, separators=(',', ':')))
    summary['textFormatCharacters'] = len(json.dumps(req.get('text', {}), ensure_ascii=False, separators=(',', ':')))
else:
    raise SystemExit('Aucune requête reçue : diagnostic non concluant')
assert result.returncode != 0 and len(captures) == 1, 'La capture doit se terminer après le refus HTTP local'
assert any(i['userPrompt'] for i in summary['input']), 'Prompt absent de la capture'
assert not args.without_skill_instructions or summary['skillsInstructionCharacters'] == 0, 'Le catalogue skills reste injecté'
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
temporary.cleanup()
print(json.dumps(summary, ensure_ascii=False, indent=2))
