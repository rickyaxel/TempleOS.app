#!/usr/bin/env python3
"""Run with python3 -m unittest discover -s tools/program-discovery -v."""
import hashlib
import json
from pathlib import Path
import unittest
from discover import ROOT, ORIGINAL, discover, top_statements, demo_index, resolve
from menus import pulldown, markup, inventory


class DiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest=json.loads((ORIGINAL/'MANIFEST.json').read_text())
        cls.catalog=json.loads((ROOT/'shared/program-manifests/catalog.json').read_text())
        cls.distribution=json.loads((ROOT/'docs/distribution-audit/distribution.json').read_text())
        cls.menus=json.loads((ROOT/'docs/distribution-audit/menu-inventory.json').read_text())
        cls.names={p.lower():p for p in cls.manifest['files']}

    def test_every_iso_file_is_reconciled_and_hashes_match(self):
        files=self.distribution['files']
        self.assertEqual({r['path'][3:] for r in files},set(self.manifest['files']))
        self.assertEqual(self.distribution['directories'],sorted(self.manifest['dirs']))
        self.assertEqual(self.distribution['summary']['filesExamined'],len(files))
        self.assertEqual(self.distribution['summary']['holyCFilesExamined'],sum(r['path'].endswith('.HC') for r in files))
        for row in files:
            self.assertEqual(hashlib.sha256((ORIGINAL/row['path'][3:]).read_bytes()).hexdigest(),row['sha256'])
            self.assertTrue(row['role'])
        iso=ROOT/'reference/iso/TempleOS.ISO'
        self.assertEqual(hashlib.sha256(iso.read_bytes()).hexdigest(),self.manifest['iso_sha256'])

    def test_build_time_discovery_is_reproducible(self):
        baseline=json.loads((ROOT/'docs/distribution-audit/baseline-catalog.json').read_text())['programs']
        regenerated=discover(ROOT/'shared',baseline)
        self.assertEqual(regenerated['files'],self.distribution['files'])
        self.assertEqual(regenerated['additions'],self.distribution['additions'])

    def test_helpers_and_package_loaders_are_not_flattened(self):
        paths={p['path'] for p in self.catalog['programs']}
        for path in ['C:/Apps/Budget/BgtMain.HC','C:/Apps/ToTheFront/AIs/SimpleAI.HC','C:/Demo/ToHtmlToTXTDemo/ToHtml.HC','C:/Demo/AcctExample/MakeHome.HC']:
            self.assertNotIn(path,paths)
        self.assertIn('C:/Apps/Budget/Run.HC',paths)
        self.assertIn('C:/Demo/Games/Stadium/Stadium.HC',paths)
        rows={r['path']:r for r in self.distribution['files']}
        self.assertEqual(rows['C:/Demo/Games/Stadium/StadiumGen.HC']['role'],'asset-generator')
        self.assertEqual(rows['C:/Demo/Templates/ODE1.HC']['role'],'template')

    def test_brace_aware_launch_evidence(self):
        self.assertEqual(top_statements('U0 Helper(){Game();}\n'),[])
        self.assertEqual(top_statements('U0 Main(){Game();}\nMain;'),['Main'])
        self.assertEqual(len(top_statements('"one"\n"two";')),1)
        self.assertEqual(top_statements('// Fake();\n/* Other(); */\nI64 value;'),[])

    def test_original_demo_index_grouping_and_order(self):
        groups=demo_index((ORIGINAL/'Doc/DemoIndex.DD').read_text('latin1'),self.names)
        self.assertEqual([g['title'] for g in groups],['Games: Beginner','Games: Intermediate','Games: Advanced','Non-Game','TempleOS Specific'])
        self.assertEqual(groups[0]['entries'][0]['path'],'C:/Demo/Graphics/NetOfDots.HC')
        self.assertTrue(any(e.get('path')=='C:/Demo/Snd/WaterFowl.HC' for e in groups[1]['entries']))
        self.assertTrue(any(e.get('directory') and e['path']=='C:/Demo/Games/Stadium' for e in groups[0]['entries']))

    def test_identity_graph_has_no_dangling_routes_or_cycles(self):
        programs=self.catalog['programs'];groups=self.catalog['groups'];menus=self.menus['menus']
        pids={p['id'] for p in programs};gids={g['id'] for g in groups};mids={m['id'] for m in menus}
        self.assertEqual(len(pids),len(programs));self.assertEqual(len(gids),len(groups));self.assertEqual(len(mids),len(menus))
        parents={g['id']:g['parent'] for g in groups}
        for g in groups:
            self.assertTrue(set(g['programIds'])<=pids)
            self.assertTrue(set(g.get('menuIds',[]))<=mids)
            self.assertEqual(len(g['programIds']),len(set(g['programIds'])))
            path=set();current=g['id']
            while current:
                self.assertNotIn(current,path);path.add(current);current=parents[current]
        for p in programs:
            self.assertTrue((ROOT/'shared/bundled-fs'/p['path'][3:]).is_file(),p['path'])
            for dep in p['dependencies']:
                self.assertTrue((ROOT/'shared/bundled-fs'/dep[3:]).is_file() or (p['status']=='unsupported' and dep in p['missingDependencies']),dep)
            if p['author']=='Terry A. Davis':
                self.assertTrue(any(p['id'] in g['programIds'] for g in groups),p['id'])

    def test_personal_menu_all_actions_and_actual_icons(self):
        menu=next(m for m in self.menus['menus'] if m['source']=='C:/PersonalMenu.DD')
        icons=[e for e in menu['entries'] if e['iconAsset']]
        self.assertEqual(len(icons),28)
        self.assertEqual([e['iconOrder'] for e in icons],list(range(28)))
        self.assertEqual(list(dict.fromkeys(e['group'] for e in icons)),['Fun Games','Unfun Games','Code Scraps','Nongames'])
        self.assertTrue(any(e['actionKind']=='openDirectory' and e['target']=='C:/Demo/MultiCore' for e in menu['entries']))
        self.assertTrue(any(e['actionKind']=='openDocument' and e['target']=='C:/Doc/DemoIndex.DD' for e in menu['entries']))
        self.assertFalse(any(e['programId']=='sound.waterfowl' for e in icons))
        models=next(p for p in self.catalog['programs'] if p['id']=='app.grmodels')
        self.assertEqual(models['launch']['entrypoint'],'View')

    def test_pull_down_events_are_not_application_launches(self):
        source=(ORIGINAL/'Doc/EdPullDown.DD').read_text('latin1')
        entries=pulldown(source)
        self.assertEqual(len(entries),55)
        self.assertEqual(list(dict.fromkeys(e['group'] for e in entries)),['File','Edit','Insert','Program','View','Help'])
        include=next(e for e in entries if e['group']=='Program' and e['label']=='Include')
        self.assertEqual(include['arg2'],'0x3F0000003F')
        self.assertTrue(all(e['actionKind']=='sendEvent' and not e['globalNavigation'] for e in entries))

    def test_source_links_do_not_masquerade_as_launchers(self):
        resolver=lambda p,b:resolve(p,b,self.names)
        entries=markup('$LK,"::/Demo/Games/Maze.HC"$\n$MA+PU,"Maze",LM="#include \\"::/Demo/Games/Maze\\""$', 'Doc/DemoIndex.DD',resolver,{})
        self.assertEqual(entries[0]['actionKind'],'openSource')

    def test_positional_link_auxiliary_argument(self):
        resolver=lambda p,b:resolve(p,b,self.names)
        entries=markup('$LK,"Print","MN:Print"$', 'Doc/DemoIndex.DD', resolver, {})
        self.assertEqual(entries[0]['symbol'],'MN:Print')
        self.assertEqual(entries[0]['actionKind'],'openSymbol')

    def test_dynamic_templates_and_infrastructure_are_distinguished(self):
        self.assertTrue(any(m['dynamic'] and m['menuType']=='generated-document' and m['source']=='C:/Apps/Psalmody/JukeBox.HC' for m in self.menus['menus']))
        self.assertTrue(any(c['api']=='MenuPop' for c in self.menus['callSites']))
        self.assertTrue(any(m['scope']=='infrastructure' for m in self.menus['menus']))
        self.assertTrue(any(m['scope']=='application' for m in self.menus['menus']))
        self.assertTrue(any(c['api']=='PopUpPickFile' and c['source'].startswith('C:/Apps/') for c in self.menus['callSites']))
        self.assertTrue(all(m['scope']=='system-context' for m in self.menus['menus'] if m['source']=='C:/Adam/ABlkDev/DskPrt.HC'))

    def test_unsupported_presentations_retain_diagnostic_and_source_only_launch(self):
        for p in self.catalog['programs']:
            if p.get('discoveryRole') and p['status']=='unsupported':
                self.assertTrue(p['note']);self.assertEqual(p['launch']['type'],'source-only')
        for e in self.menus['edges']:
            if e['kind']=='launchProgram':
                self.assertIn(e['target'],{p['id'] for p in self.catalog['programs']})


if __name__=='__main__':unittest.main()
