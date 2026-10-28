from pathlib import Path
import json,re,xml.etree.ElementTree as ET,zipfile
p=Path(__file__).resolve().parent.parent
tools=json.loads((p/'Config/tools.json').read_text(encoding='utf-8'))
techs=json.loads((p/'Config/technologies.json').read_text(encoding='utf-8'))
t={v['Key']:v for v in tools}; q={v['Key']:v for v in techs}
assert len(t)==len(tools) and len(q)==len(techs)
assert len(t)>30 and len(q)>=17
for x in tools:
 assert all(key in x for key in ('Key','Name','Required','Type','Command','ProbeArgs','ProbePaths','WinGetId','ChocolateyId','ScoopId','ScoopBucket','Direct','NpmPackage','DependsOn'))
 assert all(d in t for d in x['DependsOn']), x['Key']
 assert x['Type'] in ('package','npm','cluster','manual')
for x in techs:
 assert all(d in t for d in x['Tools']), x['Key']
 assert x['Category'] in ('Frontend','Backend','Language','Tooling')

def make(keys,include_required=False):
 deps=[x['Key'] for x in tools if x['Required']] if include_required else []
 for key in keys:
  profile=q[key]
  deps.extend(profile['Tools'])
  deps.extend({'Frontend':['Docker','FirebaseCLI'],'Backend':['MySQL','Docker','Kubectl','KubernetesCluster']}.get(profile['Category'],[]))
 done=set(); active=set(); output=[]
 def visit(key):
  if key in done:return
  if key in active:raise RuntimeError('cycle')
  active.add(key)
  for dep in t[key]['DependsOn']:visit(dep)
  active.remove(key);done.add(key);output.append(key)
 for key in deps: visit(key)
 return output

for choice in ['Angular','Ionic','React','Vue','Vite']:
 plan=make([choice]);assert 'Docker' in plan and 'FirebaseCLI' in plan and 'MySQL' not in plan
for choice in ['Go','Java','NestJS','Express','PythonBackend','RustBackend']:
 plan=make([choice]);assert all(x in plan for x in ('MySQL','Docker','Kubectl','KubernetesCluster'))
 assert plan.index('Docker')<plan.index('KubernetesCluster') and plan.index('Kubectl')<plan.index('KubernetesCluster')
plan=make(['Angular','Ionic','Go','NestJS'],True)
assert len(plan)==len(set(plan))
assert 'AngularCLI' in make(['Ionic'])
assert 'TypeScriptCLI' not in make(['Angular'])
assert 'TypeScriptCLI' in make(['TypeScript'])
assert 'Node' not in make([],True) # Neovim toolchain via WinGet, no forced Node
assert 'ViteCLI' in make(['Vite'])
# Validate WPF XML
content=(p/'UI/WindowsDevInstalls.Gui.ps1').read_text()
xaml=content.split("[xml]$xaml = @'\n",1)[1].split("\n'@",1)[0]
ET.fromstring(xaml)
# Structural PowerShell sanity (not a PowerShell parse or runtime test)
for f in p.rglob('*.ps*'):
 contents=f.read_text(encoding='utf8')
 assert contents.count('{')==contents.count('}'),f
 assert '\x00' not in contents
 assert '#requires -Version 5.1' in contents
print('Static validation PASS:',len(tools),'tools,',len(techs),'technologies,','plan of mixed selections=',len(plan),'unique tools')
print('Dry-run example (planned, no changes):', ', '.join(make(['Angular','Go'],False)))
