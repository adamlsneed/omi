"""Extend upstream's test inventory with the fork's explicit Watch task writer."""

from copy import deepcopy
import json
from pathlib import Path, PurePosixPath

REGISTRATION = Path(__file__).with_name('watch-task-source.json')


def add_watch_source(manifest, registration_path=REGISTRATION):
    registration = json.loads(Path(registration_path).read_text())
    if not isinstance(registration, dict) or set(registration) != {'owner_paths', 'writer_anchors'}:
        raise ValueError('Watch registration requires only owner_paths and writer_anchors')
    owners = registration['owner_paths']
    anchors = registration['writer_anchors']
    if not isinstance(owners, list) or not owners or not all(
        isinstance(path, str) and path.startswith('app/lib/services/watch/')
        and '..' not in PurePosixPath(path).parts for path in owners
    ) or len(set(owners)) != len(owners):
        raise ValueError('Watch registration requires unique Watch owner paths')
    if not isinstance(anchors, list) or not anchors:
        raise ValueError('Watch registration requires writer anchors')
    for anchor in anchors:
        if (
            not isinstance(anchor, dict)
            or set(anchor) != {'path', 'symbol', 'discover'}
            or anchor['path'] not in owners
            or anchor['symbol'] != 'client.createTask'
            or anchor['discover'] is not True
        ):
            raise ValueError('Watch registration requires discoverable createTask anchors owned by Watch')
    result = deepcopy(manifest)
    sources = [source for source in result['sources'] if source['id'] == 'mobile_manual']
    if len(sources) != 1 or sources[0]['policy_class'] != 'direct_command':
        raise ValueError('Watch capture requires one direct-command mobile_manual source')
    source = sources[0]
    source['owner_paths'].extend(path for path in owners if path not in source['owner_paths'])
    source['writer_anchors'].extend(anchor for anchor in anchors if anchor not in source['writer_anchors'])
    return result


def install_manifest_loader(contracts):
    """Adapt only default inventory reads, leaving explicit-path tests untouched."""
    original = contracts.load_source_manifest

    def load_source_manifest(path=None):
        if path is not None:
            return original(path)
        return add_watch_source(original())

    contracts.load_source_manifest = load_source_manifest
    return original
