#!/usr/bin/env python3
"""Evidence inventory of every V5.03 Games/Snd/Graphics/Apps file and Demo Index source.
Compilation outcomes are evidence from the existing build-time compiler, not claims of playability.
Classification based only on path/include/index evidence; uncertain entry points remain candidates.
"""
import hashlib,json,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];SHARED=ROOT/'shared';DOC=ROOT/'docs/games-preservation'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 orig=ROOT/'reference/templeos-iso';bundle=SHARED/'bundled-fs'
 current=json.loads((SHARED/'program-manifests/catalog.json').read_text())['programs'];cat={p['path']:p for p in current}
 baseline=json.loads((DOC/'baseline-catalog.json').read_text())['programs'];before={p['path']:p for p in baseline}
 native={p['path']:p for p in json.loads((SHARED/'native-translation/manifest.json').read_text())['sources']}
 oldnative={p['path']:p for p in json.loads((DOC/'baseline-native.json').read_text())['sources']}
 menu=json.loads((SHARED/'runtime/games-menu/menu.json').read_text())['entries'];by_menu={p['sourcePath']:p for p in menu}
 restored_titles={'Budget','Psalmody','GrModels','ToTheFront','Vocabulary','JukeBox'}
 ios_summary=DOC/'evidence/ios-restored-summary.json'
 ios_restored=ios_summary.exists() and json.loads(ios_summary.read_text()).get('result')=='Passed'
 android_report=DOC/'evidence/android-restored/report.json'
 android_steps=json.loads(android_report.read_text()).get('steps',[]) if android_report.exists() else []
 android_passed={step['name'] for step in android_steps if step.get('launch') and step.get('close') and step.get('reopen') and not step.get('error')}
 sound_titles={'ASCIIOrgan','MorseCode','OhGreat','WaterFowl','Psalmody','JukeBox'}
 sound_ios=all((DOC/('evidence/sound-keyboard/ios/'+mode+'-summary.json')).is_file() and json.loads((DOC/('evidence/sound-keyboard/ios/'+mode+'-summary.json')).read_text()).get('result')=='Passed' for mode in ['terry','native'])
 sound_android_file=DOC/'evidence/sound-keyboard/android/report.json'
 sound_android_steps=json.loads(sound_android_file.read_text()).get('steps',[]) if sound_android_file.exists() else []
 sound_android_passed={(step.get('program'),step.get('engine')) for step in sound_android_steps if step.get('customKeyboard') and step.get('input') and step.get('exitSilence') and not step.get('error')}
 levels={};directory_levels={};level=''
 for line in (orig/'Doc/DemoIndex.DD').read_text('latin1').splitlines():
  m=re.search(r'\$TR,"([^"]+)"',line)
  if m:level=m[1]
  for f in re.findall(r'::/([^"$]+\.HC)',line):levels['C:/'+f]=level
  for f in re.findall(r'\$MA[^$]*,"::/([^"]+)",LM=',line):directory_levels['C:/'+f]=level
 files=set()
 for d in ['Demo/Games','Demo/Snd','Demo/Graphics','Apps']:
  files.update(p for p in (orig/d).rglob('*') if p.is_file() and not p.name.startswith("."))
 files.update(orig/p[3:] for p in levels if (orig/p[3:]).exists())
 def resolve(base,inc):
  inc=inc.removesuffix('.Z');base=base.parent
  if inc.startswith('::/'):base=orig;inc=inc[3:]
  elif inc.startswith('/') or inc.startswith('C:/'):base=orig;inc=inc.removeprefix('C:').lstrip('/')
  elif inc.startswith('~/'):base=orig;inc=inc[2:]
  for suffix in ['', '.HC','.HH','.DD']:
   p=base/(inc+suffix)
   if p.is_file():return 'C:/'+str(p.relative_to(orig))
  return 'UNRESOLVED:'+inc
 includes={};texts={};included_by={}
 for f in orig.rglob('*.HC'):
  t=f.read_bytes().split(b'\0')[0].decode('latin1');texts[f]=t
  deps=[resolve(f,i) for i in re.findall(r'^\s*#include\s+"([^"]+)"',t,re.M)]
  includes[f]=deps
  for dep in deps:included_by.setdefault(dep,[]).append('C:/'+str(f.relative_to(orig)))
 def closure(f,seen=None):
  seen=set() if seen is None else seen
  for dep in includes.get(f,[]):
   if dep not in seen:
    seen.add(dep)
    if dep.startswith('C:/'):closure(orig/dep[3:],seen)
  return sorted(seen)
 rows=[]
 for f in sorted(files):
  rel=str(f.relative_to(orig));path='C:/'+rel;p=cat.get(path);e=by_menu.get(path);n=native.get(path,{})
  text=texts.get(f,'');ext=f.suffix.upper();role='supporting resource'
  evidence=[]
  if ext=='.HC':
   if p or e or f.stem=='Run':role='registered entry point' if p else 'application entry point';evidence.append('catalog/menu/Run.HC')
   elif path in levels:role='Demo Index launch candidate';evidence.append(levels[path])
   elif path in included_by:role='source dependency';evidence.extend(included_by[path])
   elif '/Examples/' in path and '/Psalmody/' in path:role='song source';evidence.append('Psalmody Examples directory')
   elif re.search(r'(?m)^\s*[A-Za-z_]\w*\s*(?:\([^;{}]*\))?\s*;\s*$',text):role='standalone candidate (review required)';evidence.append('top-level invocation candidate; static heuristic, not proof')
   else:role='source/helper (review required)'
   # These roles are established from the complete sources, not the top-level-call heuristic.
   if rel in ['Apps/Psalmody/Install.HC','Apps/Span/Install.HC','Apps/ToTheFront/Install.HC']:
    role='installation/initialization script';evidence=['source creates the per-user application directory; no standalone program loop']
   elif rel in ['Apps/ToTheFront/AIs/Human.HC','Apps/ToTheFront/AIs/SimpleAI.HC']:
    role='dynamically loaded source dependency';evidence=['ToTheFront.HC PlayerPick("AIs",player) selects PlayerIndirect/PlayerMove/PlayerDirect implementations']
   elif rel=='Apps/TimeClock/Load.HC':
    role='application command loader';evidence=['includes TimeClk and Install; installation text requires subsequent PunchIn/PunchOut/TimeRep commands']
   elif rel=='Demo/Games/Stadium/Stadium.HC':
    role='standalone game';evidence=['Stadium invocation, GetMsg loop, original GRRead background, fan/ball simulation and Escape cleanup']
   elif rel=='Demo/Games/Stadium/StadiumGen.HC':
    role='asset-generation utility';evidence=['captures StadiumBG.DD into StadiumBG.GR using DCScrnCapture and GRWrite; not the game entry point']
  elif ext in ['.DD','.TXT']:role='document'
  elif ext in ['.HH']:role='library/header'
  status=p.get('status') if p else None
  legacy=path in ['C:/Demo/Games/BattleLines.HC','C:/Demo/Games/Varoom.HC','C:/Demo/Games/Maze.HC','C:/Apps/X-Caliber/Run.HC','C:/Demo/Games/Talons.HC']
  verified=f.stem in ['WaterFowl','ASCIIOrgan','OhGreat','SpritePlot','SpritePutExt','Blot','SpritePut','SpriteRaw','EdSprite'] and rel.startswith(('Demo/Snd/','Demo/Graphics/'))
  restored={
   'Apps/Budget/Run.HC':'DocLib structured documents/forms, date parsing and account hash tables; original save/reload exercised',
   'Apps/Psalmody/Run.HC':'structured document/forms, original lexer services, home installer directory and independent task input; recording/playback/save/replay exercised',
   'Apps/Psalmody/Load.HC':'missing compound launch registration; manifest now loads this original library then invokes JukeBox with the original Examples argument; song jobs/ratings exercised',
   'Apps/ToTheFront/Run.HC':'documents, glob discovery, CJob results, yielding indirect calls, runtime defines and AI source packages; terrain/AI selection/phase/exit exercised',
   'Apps/GrModels/Run.HC':'class field format metadata and lastclass defaults, 48 original lighting choices, owned document sprite binaries and export; Man generation exercised',
   'Apps/Vocabulary/Run.HC':'original dictionary omitted from bundles; exact word/definition data now packaged and bound lazily; quiz/definition/audio exercised',
   'Apps/TimeClock/Load.HC':'no standalone main: command loader omitted from allowlist; original PunchIn/PunchOut/TimeRep now have an explicit command launcher and persistence test',
   'Demo/Games/Stadium/Stadium.HC':'nested game omitted from fixed Games allowlist; original GR image read/display and ball interaction tested',
   'Demo/Snd/MorseCode.HC':'CDocEntry tag callbacks absent; live fields and held-key audio now tested with a source-defined dot/dash letter',
   'Demo/Graphics/Balloon.HC':'direct planar writes lacked bounded drawing memory and Busy timing; sandboxed drawing adapter and moving frames tested',
   'Demo/Graphics/Grid.HC':'mouse-grid globals, snap transform and custom cursor callback were absent; snap/restore tested',
   'Demo/Graphics/PoleZeros.HC':'CJob type and per-job result ownership absent; original recalculation/drag/phase/exit exercised (slow under HolyC)',
   'Demo/Graphics/FontEd.HC':'documents and original safe-character bitmap absent; real glyph bit modification and file save tested',
   'Demo/Graphics/SpriteText.HC':'original sprite-summary/code-output routines absent; original routines now execute in all four configurations',
   'Demo/Graphics/ScrnCapture.HC':'GR screenshot APIs absent; actual composed-screen pixels saved and read back',
   'Demo/Graphics/WallPaperCtrl.HC':'Adam-only installation returned immediately in ordinary user context; explicit resident Adam sandbox profile now retains real slider callbacks and exit cleanup'
  }
  verified=verified or rel in restored

  reasons=[]
  if ext=='.HC' and path not in before:
   reasons.append(('dependency/initialization/asset tool; no independent playable registration is expected' if role in ['source dependency','dynamically loaded source dependency','installation/initialization script','asset-generation utility'] else 'not in the fixed build_catalog.py allowlists (source was '+('already bundled' if (bundle/rel).exists() else 'not bundled')+')'))
  if before.get(path,{}).get('status')=='unsupported':reasons.append('baseline compatibility filter: '+before[path].get('note',''))
  if p and status=='unsupported':reasons.append(p.get('note',''))
  prev=oldnative.get(path,{})
  if prev.get('detail'):reasons.append('baseline compiler: '+prev['detail'])
  if rel in restored:reasons.append('verified restoration: '+restored[rel])
  if not reasons and ext=='.HC':reasons.append('registered before this task; no catalog omission')
  modules=[v.split(':',1)[0] for v in n.get('variants',[])] or ([n['module']] if n.get('module') else [])
  swift=[ROOT/'temple_os_swift/TempleCore/Sources/PureSwift/Generated'/(m+'.swift') for m in modules]
  kotlin=[ROOT/'temple_os_kotlin/purekotlin/src/main/kotlin/io/github/templeosmobile/purekotlin/gen'/(m+'.kt') for m in modules]
  swift_present=bool(swift) and all(f.is_file() for f in swift);kotlin_present=bool(kotlin) and all(f.is_file() for f in kotlin)
  directory=next((d for d in sorted(directory_levels,key=len,reverse=True) if path.startswith(d+'/')),None)
  dependencies=set(closure(f)) | (set(n.get('closure',{})) - {path})
  if rel=='Demo/Games/Stadium/Stadium.HC':dependencies.add('C:/Demo/Games/Stadium/StadiumBG.GR')
  if rel=='Demo/Games/Stadium/StadiumGen.HC':dependencies.add('C:/Demo/Games/Stadium/StadiumBG.DD')
  rows.append(dict(program=f.name,sourcePath=path,role=role,classificationEvidence=evidence,sourceSHA256=sha(f),sourceBundled=(bundle/rel).exists(),bundleMatchesOriginal=(bundle/rel).exists() and sha(bundle/rel)==sha(f),originalMenu=e and {k:e[k] for k in ['category','order','title','sprite','asset']},demoIndexCategory=levels.get(path) or directory_levels.get(directory),demoIndexReference='file' if path in levels else 'directory' if directory else None,swiftRegistration=bool(p),kotlinRegistration=bool(p),originallyRegistered=path in before,catalogStatus=status,holyC='bounded integration passed' if verified else 'initial-state four-engine parity passed (1 s), not full gameplay' if legacy else 'not functionally tested' if n.get('status')=='translated' else n.get('detail','not assessed'),nativeTranslation=n.get('status','no source record'),swiftNativeSource=swift_present,kotlinNativeSource=kotlin_present,nativeModules=modules,requiredDependencies=sorted(dependencies),missingReason=reasons,originallySourceOnly=before.get(path,{}).get('status')=='unsupported',restoration=restored.get(rel),resolution='restored executable original/native paths; bounded functional evidence in SOURCE_ONLY_COMPLETION.md' if rel in restored else 'registered this task' if p and path not in before else ('retains unsupported status' if status=='unsupported' else 'Sprite compatibility filter removed' if f.stem in ['Blot','EdSprite','SpritePut','SpriteRaw'] and p else 'existing registration' if p else 'discovery only; not advertised as supported'),verification='Four-engine bounded integration passed; see VERIFICATION.md for scope' if verified else 'See VERIFICATION.md; translation success is not functional verification',hostIntegrationTested=verified,simulatorWorkflowTested=(f.stem=='WaterFowl' and verified) or bool(p and p['title'] in restored_titles and ios_restored and all(p['title']+' '+mode in android_passed for mode in ['terry','native'])) or bool(p and p['title'] in sound_titles and sound_ios and all((p['title'],mode) in sound_android_passed for mode in ['terry','native'])),nativeSwiftStatus='bounded integration passed' if verified else 'compiled, runtime unverified' if swift_present else 'unavailable',nativeKotlinStatus='bounded integration passed' if verified else 'compiled, runtime unverified' if kotlin_present else 'unavailable'))
 report=dict(version='TempleOS V5.03',source='reference/iso/TempleOS.ISO',isoSHA256=sha(ROOT/'reference/iso/TempleOS.ISO'),notes=['All relevant files are enumerated; helper/standalone distinctions without an authoritative index remain explicitly uncertain.','Native translation diagnostics are compiler evidence, not runtime-observed failures.','Declarations, dynamic includes and optional dependencies may require additional review; static closures are not declared complete.'],counts={'files':len(rows),'holyC':sum(r['sourcePath'].endswith('.HC') for r in rows),'newRegistrations':sum(r['swiftRegistration'] and not r['originallyRegistered'] for r in rows)},files=rows)
 (DOC/'program-inventory.json').write_text(json.dumps(report,indent=1)+'\n')
 md=['# V5.03 program inventory','',*report['notes'],'',str(report['counts']),'','| Source | Role / original index | Before → now | Compiler/native evidence | Missing cause / remaining work |','|---|---|---|---|---|']
 for r in rows:
  if not r['sourcePath'].endswith('.HC'):continue
  clean=lambda s:str(s).replace('|','/').replace('\n',' ')
  md.append('| '+' | '.join(map(clean,[r['sourcePath'],r['role']+'; '+str(r['demoIndexCategory'] or (r['originalMenu'] or {}).get('category','')),('registered' if r['originallyRegistered'] else 'absent')+' → '+str(r['catalogStatus'] or 'discovery only'),r['nativeTranslation']+'; '+r['holyC'],'; '.join(r['missingReason'])]))+' |')
 (DOC/'PROGRAM_INVENTORY.md').write_text('\n'.join(md)+'\n')
 print(report['counts'])
if __name__=='__main__':main()
