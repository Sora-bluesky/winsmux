"""Read one closed CI ZIP without extraction or executing its contents.

The host first binds this ZIP's digest to an actual GitHub artifact original.
This parser checks member bytes against the fixed publication bundle; its JSON
alone is neither CI provenance, native verification nor publication authority.
"""
import hashlib
import json
import stat
import sys
import zipfile
from pathlib import Path


def strict(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('Duplicate artifact contract key')
        value[key] = item
    return value


def digest(stream):
    result = hashlib.sha256()
    count = 0
    while chunk := stream.read(65536):
        result.update(chunk)
        count += len(chunk)
    return result.hexdigest(), count


def inspect(archive_file, expected_sha, contract_file):
    contract = json.loads(Path(contract_file).read_bytes(), object_pairs_hook=strict)
    if not isinstance(contract, list) or not contract:
        raise ValueError('Closed artifact member inventory required')
    expected = {}
    for row in contract:
        if (not isinstance(row, dict) or set(row) != {'name', 'bytes', 'sha256'}
                or not isinstance(row['name'], str) or not row['name'].isascii()
                or '/' in row['name'] or '\\' in row['name'] or ':' in row['name']
                or row['name'] in {'', '.', '..'} or row['name'] in expected):
            raise ValueError('Exact canonical nonduplicate member required')
        if (row['bytes'] is None) != (row['sha256'] is None):
            raise ValueError('Member byte/hash pair required')
        if row['bytes'] is not None and (type(row['bytes']) is not int or row['bytes'] <= 0
                or not isinstance(row['sha256'], str) or len(row['sha256']) != 64
                or any(c not in '0123456789abcdef' for c in row['sha256'])):
            raise ValueError('Exact nonempty member byte/hash required')
        expected[row['name']] = row
    with open(archive_file, 'rb') as original:
        archive_sha, archive_bytes = digest(original)
        if archive_sha != expected_sha:
            raise ValueError('CI ZIP differs from actual GitHub artifact digest')
        original.seek(0)
        with zipfile.ZipFile(original) as archive:
            entries = archive.infolist()
            if (len(entries) != len(expected) or len({e.filename for e in entries}) != len(entries)
                    or set(e.filename for e in entries) != set(expected)):
                raise ValueError('CI artifact contains missing, duplicate or extra members')
            members = []
            for entry in entries:
                mode = stat.S_IFMT(entry.external_attr >> 16)
                if (entry.is_dir() or mode not in {0, stat.S_IFREG} or entry.external_attr & 16
                        or entry.flag_bits & 1 or entry.compress_type not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}):
                    raise ValueError('CI artifact member must be a plain unencrypted file')
                row = expected[entry.filename]
                if row['bytes'] is not None and entry.file_size != row['bytes']:
                    raise ValueError('CI artifact member length differs from bundle')
                with archive.open(entry) as stream:
                    checksum, count = digest(stream)
                if count != entry.file_size or (row['sha256'] is not None and checksum != row['sha256']):
                    raise ValueError('CI artifact member bytes differ from fixed bundle')
                members.append({'name': entry.filename, 'bytes': count, 'sha256': checksum,
                                'bundle_member': row['sha256'] is not None})
    return {'schema': 'winsmux-ci-artifact-members/v1', 'archive_sha256': archive_sha,
            'archive_bytes': archive_bytes, 'members': sorted(members, key=lambda row: row['name']),
            'publication_admitted': False}


if __name__ == '__main__':
    try:
        if len(sys.argv) != 4:
            raise ValueError('Exact archive, actual digest and member contract required')
        result = inspect(*sys.argv[1:])
        sys.stdout.write(json.dumps(result, separators=(',', ':')) + '\n')
    except Exception as error:
        sys.stderr.write(str(error) + '\n')
        sys.exit(1)
