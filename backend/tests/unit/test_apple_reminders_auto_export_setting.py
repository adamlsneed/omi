import asyncio
import importlib
import sys
import types
from unittest.mock import MagicMock


def _stub_module(name: str) -> types.ModuleType:
    if name not in sys.modules:
        sys.modules[name] = types.ModuleType(name)
    return sys.modules[name]


def _load_task_sync(default_app='apple_reminders', integration=None):
    _stub_module('httpx')

    database_mod = _stub_module('database')
    if not hasattr(database_mod, '__path__'):
        database_mod.__path__ = []

    users_mod = _stub_module('database.users')
    users_mod.get_default_task_integration = MagicMock(return_value=default_app)
    users_mod.get_task_integration = MagicMock(return_value=integration or {'connected': True})

    action_items_mod = _stub_module('database.action_items')
    action_items_mod.batch_set_sync_requested = MagicMock()

    setattr(database_mod, 'users', users_mod)
    setattr(database_mod, 'action_items', action_items_mod)

    notifications_mod = _stub_module('utils.notifications')
    notifications_mod.send_apple_reminders_sync_push = MagicMock(return_value=True)

    import utils.task_sync as task_sync

    return importlib.reload(task_sync), users_mod, action_items_mod, notifications_mod


def test_batch_auto_sync_skips_apple_reminders_when_auto_export_disabled():
    task_sync, _, action_items_db, notifications = _load_task_sync(
        integration={'connected': True, 'auto_export_enabled': False}
    )

    results = asyncio.run(
        task_sync.auto_sync_action_items_batch(
            'uid-1',
            [{'id': 'item-1', 'description': 'Do the thing'}],
        )
    )

    assert results == [
        {
            'synced': False,
            'platform': 'apple_reminders',
            'reason': 'auto_export_disabled',
        }
    ]
    action_items_db.batch_set_sync_requested.assert_not_called()
    notifications.send_apple_reminders_sync_push.assert_not_called()


def test_batch_auto_sync_defaults_apple_reminders_auto_export_to_disabled():
    task_sync, _, action_items_db, notifications = _load_task_sync(integration={'connected': True})

    results = asyncio.run(
        task_sync.auto_sync_action_items_batch(
            'uid-1',
            [{'id': 'item-1', 'description': 'Do the thing'}],
        )
    )

    assert results == [
        {
            'synced': False,
            'platform': 'apple_reminders',
            'reason': 'auto_export_disabled',
        }
    ]
    action_items_db.batch_set_sync_requested.assert_not_called()
    notifications.send_apple_reminders_sync_push.assert_not_called()


def test_batch_auto_sync_exports_apple_reminders_when_auto_export_enabled():
    task_sync, _, action_items_db, notifications = _load_task_sync(
        integration={'connected': True, 'auto_export_enabled': True}
    )

    results = asyncio.run(
        task_sync.auto_sync_action_items_batch(
            'uid-1',
            [{'id': 'item-1', 'description': 'Do the thing'}],
        )
    )

    assert results == [{'synced': True, 'platform': 'apple_reminders', 'pending_device': True}]
    action_items_db.batch_set_sync_requested.assert_called_once_with('uid-1', ['item-1'])
    notifications.send_apple_reminders_sync_push.assert_called_once()


def test_batch_auto_sync_skips_apple_reminders_for_disabled_source():
    task_sync, _, action_items_db, notifications = _load_task_sync(
        integration={
            'connected': True,
            'auto_export_enabled': True,
            'auto_export_disabled_sources': ['desktop', 'screenpipe'],
        }
    )

    results = asyncio.run(
        task_sync.auto_sync_action_items_batch(
            'uid-1',
            [{'id': 'item-1', 'description': 'Do the thing'}],
            conversation_source='desktop',
        )
    )

    assert results == [
        {
            'synced': False,
            'platform': 'apple_reminders',
            'reason': 'source_auto_export_disabled',
            'source': 'desktop',
        }
    ]
    action_items_db.batch_set_sync_requested.assert_not_called()
    notifications.send_apple_reminders_sync_push.assert_not_called()
