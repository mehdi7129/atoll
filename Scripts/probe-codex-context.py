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
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

p = argparse.ArgumentParser()
mode = p.add_mutually_exclusive_group()
mode.add_argument('--without-skill-instructions', action='store_true')
mode.add_argument('--production-plan', action='store_true', help='Compiler et capturer le vrai CodexExecPlan du dépôt')
p.add_argument('--plan-source', type=Path, help='Copie du plan pour les contre-épreuves locales')
p.add_argument('--model', default='gpt-5.6-luna')
p.add_argument('--catalog', type=Path, default=Path.home() / '.codex/models_cache.json')
p.add_argument('--output', type=Path, required=True)
args = p.parse_args()
label = 'production-plan' if args.production_plan else 'without-skill-instructions' if args.without_skill_instructions else 'baseline'
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
analysis_instructions = None
sentinels = ['ATOLL_UNRELATED_GLOBAL_GUIDANCE', 'ATOLL_UNRELATED_PROJECT_GUIDANCE', 'ATOLL_UNRELATED_SKILL_GUIDANCE']
if args.production_plan:
    # Le contrat est compilé depuis le code produit : aucune copie de ses flags.
    # Les sentinelles vérifient le projet et les skills. Codex 0.155.1 charge
    # encore AGENTS.md global malgré project_doc_max_bytes=0 : on le mesure.
    repo = Path(__file__).resolve().parent.parent
    plan_source = args.plan_source or repo / 'AtollCore/Sources/AtollCore/CodexExecPlan.swift'
    main = root / 'main.swift'
    main.write_text('''import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let instructions = root.appendingPathComponent("analysis-instructions.md")
try CodexExecPlan.analysisInstructions.write(to: instructions, atomically: true, encoding: .utf8)
let arguments = CodexExecPlan.arguments(schemaPath: root.appendingPathComponent("schema.json").path,
    outputPath: root.appendingPathComponent("report.json").path, instructionsPath: instructions.path,
    workingDirectory: root.appendingPathComponent("work").path, model: CommandLine.arguments[2])
let data = try JSONSerialization.data(withJSONObject: arguments)
FileHandle.standardOutput.write(data)
''')
    binary = root / 'plan'
    subprocess.run(['swiftc', str(plan_source), str(main), '-o', str(binary)], check=True, timeout=60)
    plan = json.loads(subprocess.check_output([str(binary), str(root), model], timeout=10))
    command = [command[0]] + plan
    analysis_instructions = (root / 'analysis-instructions.md').read_text()
    (home / 'AGENTS.md').write_text(sentinels[0] + '\n')
    (cwd / 'AGENTS.md').write_text(sentinels[1] + '\n')
    skill = home / 'skills' / 'probe'
    skill.mkdir(parents=True)
    (skill / 'SKILL.md').write_text('---\nname: probe\ndescription: ' + sentinels[2] + '\n---\nPrivate test skill.\n')
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
    def declared_tools(items):
        names = []
        for item in items:
            if item.get('type') == 'namespace':
                names.extend(declared_tools(item.get('tools', [])))
            else:
                names.append(item.get('name', item.get('type')))
                # Code Mode expose les outils imbriqués dans sa description.
                names.extend(re.findall(r'^### `([^`]+)`', item.get('description', ''), re.MULTILINE))
        return names
    summary['declaredTools'] = sorted(set(declared_tools(tools)))
    summary['toolsJSONCharacters'] = len(json.dumps(tools, ensure_ascii=False, separators=(',', ':')))
    summary['analysisInstructionsCharacters'] = 0
    summary['nativeInstructionsCharacters'] = len(req.get('instructions', ''))
    template = selected[0].get('model_messages', {}).get('instructions_template')
    summary['input'] = []
    for item in req.get('input', []):
        text = '\n'.join(c.get('text', '') for c in item.get('content', []) if isinstance(c, dict))
        if item.get('type') == 'additional_tools':
            continue
        summary['input'].append({'role': item.get('role'), 'characters': len(text),
                                 'modelInstructions': text == template,
                                 'analysisInstructions': analysis_instructions is not None and text == analysis_instructions,
                                 'skillsTag': '<skills_instructions>' in text,
                                 'userPrompt': text == prompt,
                                 'sha256': hashlib.sha256(text.encode()).hexdigest()})
        if text == template:
            summary['nativeInstructionsCharacters'] += len(text)
        if analysis_instructions is not None and text == analysis_instructions:
            summary['analysisInstructionsCharacters'] += len(text)
    summary['skillsInstructionCharacters'] = sum(
        len(c.get('text', '')) for item in req.get('input', [])
        for c in item.get('content', [])
        if isinstance(c, dict) and '<skills_instructions>' in c.get('text', ''))
    summary['userPromptCharacters'] = len(prompt)
    summary['schemaCharacters'] = len(json.dumps(schema, separators=(',', ':')))
    summary['textFormatCharacters'] = len(json.dumps(req.get('text', {}), ensure_ascii=False, separators=(',', ':')))
    request_text = json.dumps(req, ensure_ascii=False)
    summary['unrelatedInstructionSentinelPresent'] = any(s in request_text for s in sentinels)
    summary['presentSentinels'] = [s for s in sentinels if s in request_text]
    actual_schema = req.get('text', {}).get('format', {}).get('schema')
    summary['schemaPreserved'] = actual_schema == schema
else:
    raise SystemExit('Aucune requête reçue : diagnostic non concluant')
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
assert result.returncode != 0 and len(captures) == 1, 'La capture doit se terminer après le refus HTTP local'
assert any(i['userPrompt'] for i in summary['input']), 'Prompt absent de la capture'
assert not args.without_skill_instructions or summary['skillsInstructionCharacters'] == 0, 'Le catalogue skills reste injecté'
if args.production_plan:
    assert summary['analysisInstructionsCharacters'] == len(analysis_instructions), 'Instructions Atoll absentes de la requête'
    assert summary['nativeInstructionsCharacters'] == 0, 'Instructions natives encore présentes'
    assert summary['skillsInstructionCharacters'] == 0, 'Le catalogue skills reste injecté'
    assert not any(s in summary['presentSentinels'] for s in sentinels[1:]), 'Instructions projet ou skills injectées'
    assert summary['schemaPreserved'], 'Le schéma métier a changé'
    assert not {'exec_command', 'shell', 'shell_command', 'write_stdin', 'view_image', 'request_user_input', 'web_search'}.intersection(summary['declaredTools']), 'Outils inutiles encore exposés'
temporary.cleanup()
print(json.dumps(summary, ensure_ascii=False, indent=2))
