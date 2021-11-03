"""Source binding shared by evidence generation and validation."""
import hashlib
import pathlib

EXCLUDED = {'.git', 'build', 'bin', '.runtime', '.toolchain', 'evidence'}

def sha(data):
    return hashlib.sha256(data).hexdigest()

def source_manifest(root):
    root = pathlib.Path(root)
    result = {}
    for path in sorted(root.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if relative.parts[0] in EXCLUDED or '__pycache__' in relative.parts:
            continue
        result[str(relative)] = sha(path.read_bytes())
    return result
