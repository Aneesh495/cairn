#!/usr/bin/env python3
"""Use an installed Nim or a checksum-pinned official compiler in .toolchain.

Downloads happen only when no supported compiler is available, or when
--bootstrap is requested. CAIRN_OFFLINE=1 forbids downloads. No home-directory
files, shell profiles, system packages, or global symlinks are changed.
"""
import hashlib
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = '2.2.12'
MINIMUM = (2, 2, 6)
CHECKSUMS = {
    'linux_x64': '7df1611449a6842af69322aa2c1206942982650a5f6bc0d37bc8ec109932f638',
    'linux_arm64': '3dc04191af72a8310cf1c8ffb6f772cc3716fc5f264bc7c453ab4aecb4085221',
    'macosx_x64': 'a09fa096aeb5f6ef32f8839eced2591e145e526e42f56c79e04a18519b8b132c',
    'macosx_arm64': '130a43eff76c1c3cc78b89329a7efd892c1f65839dbc6d8e53651f3f77516fe5',
}


def error(message):
    print('cairn toolchain: ' + message, file=sys.stderr)
    raise SystemExit(1)


def supported(path):
    if not path:
        return False
    try:
        output = subprocess.check_output([str(path), '--version'], text=True, stderr=subprocess.STDOUT)
        match = re.search(r'Nim Compiler Version (\d+)\.(\d+)\.(\d+)', output)
        return match is not None and tuple(map(int, match.groups())) >= MINIMUM
    except (OSError, subprocess.SubprocessError):
        return False


def compiler(force=False):
    if not shutil.which('cc'):
        error('a C compiler is required; install Xcode command line tools on macOS or gcc/clang on Linux')
    system = shutil.which('nim')
    if not force and supported(system):
        return pathlib.Path(system)
    operating_system = {'Darwin': 'macosx', 'Linux': 'linux'}.get(platform.system())
    architecture = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64', 'AMD64': 'x64'}.get(platform.machine())
    target = str(operating_system) + '_' + str(architecture)
    if target not in CHECKSUMS:
        error('install Nim >= 2.2.6 manually for this POSIX platform')
    toolchain = ROOT / '.toolchain'
    installed = toolchain / (VERSION + '-' + target)
    executable = installed / ('nim-' + VERSION) / 'bin' / 'nim'
    if supported(executable):
        return executable
    if os.environ.get('CAIRN_OFFLINE') == '1':
        error('offline mode: install Nim >= 2.2.6 or run make bootstrap with network access first')
    if sys.version_info < (3, 12):
        error('automatic toolchain extraction requires Python >= 3.12; install Nim manually or update Python')
    if not shutil.which('curl'):
        error('curl is required for the official compiler download')
    toolchain.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='download-', dir=toolchain) as temporary:
        temporary = pathlib.Path(temporary)
        archive = temporary / 'compiler.tar.xz'
        url = f'https://nim-lang.org/download/nim-{VERSION}-{target}.tar.xz'
        print(f'cairn toolchain: fetching official Nim {VERSION} for {target}', file=sys.stderr)
        subprocess.run(['curl', '--fail', '--show-error', '--silent', '--location',
                        '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', '15',
                        '--max-time', '180', '--retry', '2', '--output', str(archive), url], check=True)
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual != CHECKSUMS[target]:
            error('official compiler checksum mismatch; nothing was installed')
        unpacked = temporary / 'unpacked'
        unpacked.mkdir()
        with tarfile.open(archive) as tar:
            tar.extractall(unpacked, filter='data')
        candidate = unpacked / ('nim-' + VERSION) / 'bin' / 'nim'
        if not supported(candidate):
            error('downloaded compiler did not run successfully')
        if installed.exists():
            error('incomplete local compiler directory exists; inspect .toolchain before retrying')
        unpacked.rename(installed)
    return executable


def main():
    args = sys.argv[1:]
    force = args[:1] == ['--bootstrap']
    if force:
        args = args[1:] or ['--version']
    executable = compiler(force)
    os.execv(str(executable), [str(executable), *args])


if __name__ == '__main__':
    main()
