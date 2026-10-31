#!/usr/bin/env python3
"""Build-time model pin/extraction safety tests; no ML dependencies or network."""
import copy, hashlib, importlib.util, json, stat, subprocess, sys, tempfile, unittest, warnings, zipfile
from pathlib import Path

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('prepare_search_models',HERE/'prepare-windows-search-models.py');prepare=importlib.util.module_from_spec(spec);spec.loader.exec_module(prepare)

def record(data):return {'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}

class ModelPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.root=Path(self.temporary.name)
        self.config=json.loads((HERE.parent/'windows/search-model-config.json').read_text())
        self.files={name:('Synthetic safety test '+name).encode() for name in prepare.NAMES if name!='model-source.json'}
        manifest={'version':self.config['version'],'sourceRevision':self.config['sourceRevision'],'checkpointSHA256':self.config['checkpointSHA256'],
                  'files':{name:record(data) for name,data in self.files.items()},'verification':{'rankingPassed':True}}
        self.files['model-source.json']=json.dumps(manifest).encode();self.config['files']={name:record(data) for name,data in self.files.items()}
        self.archive=self.root/'models.zip';self.output=self.root/'output';self.output.mkdir();self.write_archive()
    def tearDown(self):self.temporary.cleanup()
    def write_archive(self,entries=None):
        entries=list(self.files.items()) if entries is None else entries
        with warnings.catch_warnings():
            warnings.simplefilter('ignore',UserWarning)
            with zipfile.ZipFile(self.archive,'w') as bundle:
                for name,data in entries:
                    entry=zipfile.ZipInfo(name) if isinstance(name,str) else name
                    bundle.writestr(entry,data)
        self.config['archive'].update(prepare.digest(self.archive))
    def test_trusted_exact_pin_extracts_and_checks_without_ml_runtime(self):
        prepare.extract(self.archive,self.output,self.config);self.assertTrue(prepare.verified(self.output,self.config))
        self.assertEqual({file.name for file in self.output.iterdir()},prepare.NAMES)
    def test_archive_digest_is_checked_before_any_extraction(self):
        self.config['archive']['sha256']='0'*64
        with self.assertRaisesRegex(RuntimeError,'archive size/hash'):prepare.extract(self.archive,self.output,self.config)
        self.assertEqual(list(self.output.iterdir()),[])
    def test_duplicate_and_traversal_names_are_rejected(self):
        for entries in [list(self.files.items())+[next(iter(self.files.items()))],[(('../'+name) if index==0 else name,data) for index,(name,data) in enumerate(self.files.items())]]:
            with self.subTest(entries=[str(name) for name,_ in entries]):
                self.write_archive(entries)
                with self.assertRaisesRegex(RuntimeError,'missing, duplicate or unexpected paths'):prepare.extract(self.archive,self.output,self.config)
                self.assertEqual(list(self.output.iterdir()),[])
    def test_symbolic_link_entries_are_rejected(self):
        entries=[]
        for index,(name,data) in enumerate(self.files.items()):
            info=zipfile.ZipInfo(name);info.create_system=3;info.external_attr=((stat.S_IFLNK|0o777) if index==0 else (stat.S_IFREG|0o644))<<16
            entries.append((info,data))
        self.write_archive(entries)
        with self.assertRaisesRegex(RuntimeError,'regular files'):prepare.extract(self.archive,self.output,self.config)
    def test_entry_size_and_hash_mismatches_are_rejected(self):
        name=next(iter(self.files));original=copy.deepcopy(self.config)
        for replacement in [dict(original['files'][name],bytes=original['files'][name]['bytes']+1),dict(original['files'][name],sha256='0'*64)]:
            with self.subTest(replacement=replacement):
                self.config=copy.deepcopy(original);self.config['files'][name]=replacement
                destination=self.root/('size' if replacement['bytes']!=original['files'][name]['bytes'] else 'digest');destination.mkdir()
                with self.assertRaisesRegex(RuntimeError,'entry size/type|entry digest'):prepare.extract(self.archive,destination,self.config)
    def test_extra_files_cannot_be_accepted_as_prepared_models(self):
        prepare.extract(self.archive,self.output,self.config);extra=self.output/'unexpected';extra.write_bytes(b'not a model')
        with self.assertRaisesRegex(RuntimeError,'unexpected files'):prepare.verified(self.output,self.config)

    def test_local_symlinks_cannot_be_accepted_as_prepared_models(self):
        prepare.extract(self.archive,self.output,self.config)
        file=self.output/'clip-vocab.json';file.unlink()
        try: file.symlink_to(self.archive)
        except OSError as error:
            if getattr(error, 'winerror', None) != 1314: raise
            self.skipTest('Creating symlinks on Windows requires Developer Mode or administrator rights')
        with self.assertRaisesRegex(RuntimeError,'Unsafe model asset'):prepare.verified(self.output,self.config)
    def test_configuration_must_pin_canonical_repo_asset_and_safe_sizes(self):
        for mutate in [lambda c:c['archive'].update(url='https://example.com/models.zip'),lambda c:c['files']['clip-vocab.json'].update(bytes=prepare.MAXIMUM+1),lambda c:c.update(checkpointSHA256='0'*64)]:
            candidate=copy.deepcopy(self.config);mutate(candidate);file=self.root/'bad-config.json';file.write_text(json.dumps(candidate))
            with self.assertRaises(RuntimeError):prepare.config_at(file)
    def test_download_redirect_cannot_escape_https_github_asset_hosts(self):
        request=prepare.urllib.request.Request(prepare.URL)
        for url in ['http://release-assets.githubusercontent.com/model.zip','https://example.com/model.zip','https://user'+':secret@github.com/model.zip']:
            with self.assertRaises(RuntimeError):prepare.SafeRedirect().redirect_request(request,None,302,'found',{},url)
    def test_check_mode_never_downloads_or_creates_missing_assets(self):
        config=self.root/'config.json';config.write_text(json.dumps(self.config));missing=self.root/'missing'
        result=subprocess.run([sys.executable,str(HERE/'prepare-windows-search-models.py'),'--config',str(config),'--output',str(missing),'--check'],text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0);self.assertIn('has not been prepared',result.stderr);self.assertFalse(missing.exists())

if __name__=='__main__':unittest.main()
