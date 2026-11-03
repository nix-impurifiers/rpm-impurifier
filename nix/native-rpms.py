# SPDX-License-Identifier: MIT
"""Compile the shared object graph with native rpmbuild."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

collection, destination = map(Path, sys.argv[1:3])
architecture = sys.argv[3]
destination.mkdir()
for package in json.loads((collection / 'packages.json').read_text()):
    record = json.loads((collection / package / 'metadata.json').read_text())
    source = collection / package / 'tree'
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        work.chmod(0o755)
        for directory in ('BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS', 'db'):
            (work / directory).mkdir()
        filelist = work / 'files'
        files = sorted('/' + str(p.relative_to(source)) for p in source.rglob('*') if p.is_file() or p.is_symlink())
        if record.get('storePath'):
            base = source / record['storePath'].lstrip('/')
            directories = [base] + list(base.rglob('*')) if base.is_dir() and not base.is_symlink() else []
            files += ['%dir /' + str(p.relative_to(source)) for p in directories if p.is_dir() and not p.is_symlink()]
        filelist.write_text('\n'.join(sorted(files)) + '\n')
        spec = work / 'package.spec'
        dependencies = ''.join(f'Requires: {name} = 1-1\n' for name in record['dependencies'])
        spec.write_text(f'''Name: {record['name']}
Version: {record['version']}
Release: 1
BuildArch: {architecture}
Summary: Native-owned Nix-built payload
License: LicenseRef-Unknown
AutoReqProv: no
{dependencies}
%description
Native-owned payload and exact immutable reference dependencies.
%install
mkdir -p %{{buildroot}}
cp -a {source}/. %{{buildroot}}/
chmod -R u+w %{{buildroot}}
%files -f {filelist}
''')
        subprocess.run(['rpmbuild', '-bb', '--nodeps', str(spec), '--buildroot', str(work / 'root'),
                        '--define', f'_topdir {work}', '--define', f'_dbpath {work / "db"}',
                        '--define', '_buildhost localhost', '--define', f'_tmppath {os.environ["TMPDIR"]}', '--define', f'_buildshell {sys.argv[4]}', '--define', '__os_install_post %{nil}',
                        '--define', '_build_id_links none', '--define', 'use_source_date_epoch_as_buildtime 1',
                        '--define', 'clamp_mtime_to_source_date_epoch 1'],
                       check=True, env={**os.environ, 'SOURCE_DATE_EPOCH': '1'})
        for artifact in (work / 'RPMS').rglob('*.rpm'):
            shutil.copy2(artifact, destination / artifact.name)
