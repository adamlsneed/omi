"""Run alongside the upstream contract suite with its hermetic backend fixtures."""

from copy import deepcopy
import json

import pytest

from watch_task_source import add_watch_source


@pytest.fixture(scope='module')
def source_contract():
    from utils.task_intelligence import contracts

    upstream = json.loads(contracts.SOURCE_MANIFEST_PATH.read_text())
    return contracts, upstream, contracts.discover_backend_writer_anchors()


def test_upstream_inventory_rejects_missing_watch_registration(source_contract):
    contracts, upstream, discovered = source_contract
    with pytest.raises(ValueError, match='unregistered writer anchors.*watch_capture_worker'):
        contracts.validate_source_manifest(upstream, discovered_anchors=discovered)


def test_registered_watch_writer_and_all_upstream_writers_validate(source_contract):
    contracts, upstream, discovered = source_contract
    assert ('app/lib/services/watch/watch_capture_worker.dart', 'client.createTask') in discovered
    contracts.validate_source_manifest(add_watch_source(upstream), discovered_anchors=discovered)


def test_new_real_writer_is_not_hidden_by_watch_registration(source_contract, tmp_path):
    contracts, upstream, discovered = source_contract
    writer = tmp_path / 'app/lib/new_writer.dart'
    writer.parent.mkdir(parents=True)
    writer.write_text('Future<void> write() async { await client.createTask(); }\n')
    unexpected = contracts.discover_backend_writer_anchors(repository_root=tmp_path)
    assert unexpected == {('app/lib/new_writer.dart', 'client.createTask')}
    with pytest.raises(ValueError, match='unregistered writer anchors.*new_writer'):
        contracts.validate_source_manifest(add_watch_source(upstream), discovered_anchors=discovered | unexpected)


def test_stale_registered_anchor_still_fails(source_contract):
    contracts, upstream, discovered = source_contract
    manifest = deepcopy(add_watch_source(upstream))
    manifest['sources'][0]['writer_anchors'].append({
        'path': 'backend/removed_writer.py', 'symbol': 'action_items_db.create_action_item', 'discover': True,
    })
    with pytest.raises(ValueError, match='stale writer anchors'):
        contracts.validate_source_manifest(manifest, discovered_anchors=discovered)


def test_real_jinja_dependency_survives_upstream_test_collection():
    import jinja2

    assert jinja2.Environment().from_string('{{ value }}').render(value='real') == 'real'
