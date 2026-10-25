#!/usr/bin/env python3
"""Ratchet raw speaker interpolation after #23379 and the Speaker 379 live-notes incident.

Existing storage/routing expressions are compared by AST fingerprint, not a count:
removing one old expression never buys permission to introduce a different leak.
Display text must use utils.speakers.display / SpeakerNames. Wire fields remain IDs.
"""

from __future__ import annotations

import argparse
import ast
from collections import Counter
from pathlib import Path
import re
import subprocess
import sys

AUTHORITY = {
    'backend/utils/speaker_display.py',
    'backend/utils/speakers/display.py',
    'app/lib/ui/format/speaker_names.dart',
    'app/lib/ui/format/diarization_label.dart',
}
# These exact expressions serialize identity for routing or hash parity, never display.
# Keep the function boundary as well as the fingerprint, so a copied UI leak fails.
WIRE_EXPRESSIONS = {
    ('backend/utils/episodes/policy.py', 'speaker_keys'): "keys.add(f\"speaker:{segment['speaker_id']}\")",
}

RAW = re.compile(r'(?i)(?:\b(?:raw_)?speaker_?id\b|\bdiarization_?label\b|raw_for_transport|rawForTransport)')


def findings(path: str, source: str) -> list[tuple[str, int]]:
    if path in AUTHORITY or '/tests/' in path or '/test/' in path or path.endswith('_test.py'):
        return []
    if path.startswith('backend/') and path.endswith('.py'):
        tree = ast.parse(source)
        display_resolvers = {
            alias.asname or alias.name
            for node in tree.body if isinstance(node, ast.ImportFrom) and node.module == 'utils.speakers.display'
            for alias in node.names if alias.name == 'display_participants'
        }
        parents = {id(child): node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
        hits = []
        def scope_nodes(scope):
            for child in ast.iter_child_nodes(scope):
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
                    continue
                yield child
                yield from scope_nodes(child)

        scopes = [tree] + [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda))]
        node_taints = {}
        node_scopes = {}
        scope_taints = {}
        scope_paths = {}
        scope_shadows = {}
        for scope in scopes:
            enclosing = parents.get(id(scope))
            while enclosing is not None and id(enclosing) not in scope_taints:
                enclosing = parents.get(id(enclosing))
            tainted = set(scope_taints.get(id(enclosing), set()))
            tainted_paths = set(scope_paths.get(id(enclosing), set()))
            local_names = {node.id for node in scope_nodes(scope) if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store)}
            if isinstance(scope, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                local_names.update(arg.arg for arg in ast.walk(scope.args) if isinstance(arg, ast.arg))
            for node in scope_nodes(scope):
                if isinstance(node, (ast.Import, ast.ImportFrom)):
                    for alias in node.names:
                        if not (isinstance(node, ast.ImportFrom) and node.module == 'utils.speakers.display' and alias.name == 'display_participants'):
                            local_names.add(alias.asname or alias.name.split('.')[0])
            local_names.update(node.name for node in ast.iter_child_nodes(scope) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)))
            tainted.difference_update(local_names)
            shadows = scope_shadows.get(id(enclosing), set()) | local_names
            trusted_resolvers = display_resolvers - shadows
            scope_taints[id(scope)] = tainted
            scope_paths[id(scope)] = tainted_paths
            scope_shadows[id(scope)] = shadows

            def is_raw(expression, ignore_slots=False):
                if not ignore_slots and isinstance(expression, (ast.Name, ast.Attribute, ast.Subscript)):
                    slot = ast.unparse(expression)
                    if any(path == slot or path.startswith(slot + '.') or path.startswith(slot + '[') for path in tainted_paths):
                        return True
                if isinstance(expression, ast.Name):
                    return bool(RAW.search(expression.id)) or expression.id in tainted
                if isinstance(expression, ast.Attribute):
                    return expression.attr == 'speaker' or bool(RAW.search(expression.attr)) or is_raw(expression.value, ignore_slots=True)
                if isinstance(expression, ast.Subscript):
                    key = expression.slice
                    raw_key = isinstance(key, ast.Constant) and isinstance(key.value, str) and (key.value == 'speaker' or RAW.search(key.value))
                    return is_raw(expression.value, ignore_slots=True) or is_raw(key) or bool(raw_key)
                if isinstance(expression, ast.Call):
                    key = None
                    if isinstance(expression.func, ast.Name) and expression.func.id in ('getattr', '_get') and len(expression.args) >= 2:
                        key = expression.args[1]
                    elif isinstance(expression.func, ast.Attribute) and expression.func.attr == 'get' and expression.args:
                        key = expression.args[0]
                    if isinstance(key, ast.Constant) and isinstance(key.value, str):
                        if key.value == 'speaker' or RAW.search(key.value):
                            return True
                        if isinstance(expression.func, ast.Attribute):
                            lookup = ast.Subscript(value=expression.func.value, slice=key, ctx=ast.Load())
                        elif expression.func.id == 'getattr':
                            lookup = ast.Attribute(value=expression.args[0], attr=key.value, ctx=ast.Load())
                        else:
                            lookup = ast.Subscript(value=expression.args[0], slice=key, ctx=ast.Load())
                        if is_raw(lookup):
                            return True
                    # Cardinality and approved display resolution do not return raw identities.
                    if isinstance(expression.func, ast.Name) and expression.func.id in (({'len'} - shadows) | trusted_resolvers):
                        return False
                    return (isinstance(expression.func, ast.Attribute) and is_raw(expression.func.value)) or any(is_raw(arg) for arg in expression.args) or any(is_raw(kw.value) for kw in expression.keywords)
                if isinstance(expression, ast.Dict):
                    return any(is_raw(value) for value in expression.values) or any(is_raw(key) for key in expression.keys if key is not None)
                return any(is_raw(child) for child in ast.iter_child_nodes(expression))

            def bind(target, value):
                if isinstance(target, ast.Name):
                    if is_raw(value):
                        tainted.add(target.id)
                elif isinstance(target, (ast.Tuple, ast.List)):
                    if isinstance(value, (ast.Tuple, ast.List)) and len(target.elts) == len(value.elts):
                        for item, item_value in zip(target.elts, value.elts):
                            bind(item, item_value)
                    else:
                        for item in target.elts:
                            bind(item, value)
                elif isinstance(target, (ast.Attribute, ast.Subscript)) and is_raw(value):
                    # Track the written slot, never contaminate unrelated receiver fields.
                    tainted_paths.add(ast.unparse(target))

            # Snapshot lexical taint in execution order. Later writes must not
            # retroactively taint earlier strings or names in another function.
            for node in scope_nodes(scope):
                if isinstance(node, (ast.For, ast.AsyncFor, ast.While)):
                    assignments = [part for part in scope_nodes(node) if isinstance(part, (ast.Assign, ast.AnnAssign)) and part.value is not None]
                    for _ in range(len(assignments) + 1):
                        before = (set(tainted), set(tainted_paths))
                        for assignment in assignments:
                            for target in assignment.targets if isinstance(assignment, ast.Assign) else [assignment.target]:
                                bind(target, assignment.value)
                        if before == (tainted, tainted_paths):
                            break
                node_scopes[id(node)] = getattr(scope, 'name', '')
                node_taints[id(node)] = is_raw(node)
                if isinstance(node, (ast.Assign, ast.AnnAssign)) and node.value is not None:
                    targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                    for target in targets:
                        bind(target, node.value)
        for node in ast.walk(tree):
            if (isinstance(node, ast.ImportFrom) and node.module == 'utils.speaker_display') or (
                isinstance(node, ast.Import) and any(alias.name == 'utils.speaker_display' for alias in node.names)
            ):
                hits.append((ast.dump(node, include_attributes=False), node.lineno))
            expressions = []
            speaker_template = False
            if isinstance(node, ast.JoinedStr):
                expressions = [v.value for v in node.values if isinstance(v, ast.FormattedValue)]
                speaker_template = any(
                    isinstance(left, ast.Constant)
                    and isinstance(left.value, str)
                    and re.search(r'(?<![_A-Za-z])Speaker[ \t]*$', left.value)
                    and isinstance(right, ast.FormattedValue)
                    for left, right in zip(node.values, node.values[1:])
                )
            elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'format':
                expressions = list(node.args) + [kw.value for kw in node.keywords]
                speaker_template = (
                    isinstance(node.func.value, ast.Constant)
                    and isinstance(node.func.value.value, str)
                    and bool(re.search(r'(?<![_A-Za-z])Speaker[ \t]*\{', node.func.value.value))
                )
            elif (
                isinstance(node, ast.BinOp)
                and isinstance(node.op, ast.Mod)
                and isinstance(node.left, ast.Constant)
                and isinstance(node.left.value, str)
            ):
                expressions = [node.right]
                speaker_template = bool(re.search(r'(?<![_A-Za-z])Speaker[ \t]*%', node.left.value))
            elif isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
                for literal, dynamic in ((node.left, node.right), (node.right, node.left)):
                    if (
                        isinstance(literal, ast.Constant)
                        and isinstance(literal.value, str)
                        and re.search(r'(?<![_A-Za-z])Speaker[ \t]*$', literal.value)
                    ):
                        expressions = [dynamic]
                        speaker_template = True
            if not expressions:
                continue
            rendered = ast.unparse(node)
            # Generic aliases are caught when the template itself says Speaker/SPEAKER.
            raw = any(node_taints.get(id(expr), False) for expr in expressions)
            template = (
                node.func.value if isinstance(node, ast.Call) else node.left if isinstance(node, ast.BinOp) else None
            )
            if isinstance(template, ast.Constant) and isinstance(template.value, str):
                raw = raw or bool(re.search(r'(?:\{|%\()(?:raw_)?speaker_?id\b', template.value, re.I))
            alias = re.search(r'[Ss][Pp][Ee][Aa][Kk][Ee][Rr][ _]', rendered) and any(
                re.search(r'\b(?:sid|speaker|speaker_key|speaker_idx)\b', ast.unparse(expr)) for expr in expressions
            )
            wire = WIRE_EXPRESSIONS.get((path, node_scopes.get(id(node))))
            wire_node = ast.parse(wire).body[0].value.args[0] if wire else None
            parent = parents.get(id(node))
            if (
                wire_node is not None
                and isinstance(parent, ast.Call)
                and ast.dump(parent, include_attributes=False) == ast.dump(ast.parse(wire).body[0].value, include_attributes=False)
                and ast.dump(node, include_attributes=False) == ast.dump(wire_node, include_attributes=False)
            ):
                continue
            if raw or alias or speaker_template:
                hits.append((ast.dump(node, include_attributes=False), node.lineno))
        return hits
    if path.startswith('app/lib/') and path.endswith('.dart') and '/gen/' not in path and '/l10n/' not in path:
        return [
            (match.group(), source.count('\n', 0, match.start()) + 1)
            for match in re.finditer(
                r'''(?:['"][^'"\n]*\$(?:\{[^}\n]*(?:speakerId|rawForTransport)[^}\n]*\}|speakerId\b)[^'"\n]*['"])''',
                source,
            )

        ]
    return []


def regressions(path: str, before: str, after: str) -> list[int]:
    old = Counter(fingerprint for fingerprint, _ in findings(path, before))
    lines = []
    for fingerprint, line in findings(path, after):
        if old[fingerprint]:
            old[fingerprint] -= 1
        else:
            lines.append(line)
    return lines


def _main_ratchet(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--changed-files', required=True)
    parser.add_argument('--base', required=True)
    args = parser.parse_args(argv)
    failures = []
    for path in Path(args.changed_files).read_text().splitlines():
        file = Path(path)
        if not file.is_file() or not (path.endswith('.py') or path.endswith('.dart')):
            continue
        result = subprocess.run(['git', 'show', f'{args.base}:{path}'], text=True, capture_output=True)
        failures.extend(
            f'{path}:{line}: raw speaker interpolation; use display_participants / SpeakerNames'
            for line in regressions(path, result.stdout if result.returncode == 0 else '', file.read_text())
        )
    print('\n'.join(failures) if failures else 'OK: no new raw speaker interpolation')
    return int(bool(failures))



REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCAN_ROOT = Path('backend')
# Tool environments under backend/ (the venv, the OpenAPI runner's venv, ...) are
# not repository source: they contain third-party code that need not even parse.
EXCLUDED_DIRS = {'tests', 'testing', 'node_modules', 'site-packages'}
ALLOWED_FILES = {'backend/utils/speaker_display.py'}
_DYNAMIC_NODES = (ast.Name, ast.Call, ast.Attribute, ast.Subscript, ast.BinOp, ast.IfExp, ast.JoinedStr)
_SPEAKER_SUFFIX = re.compile(r'(?<![_A-Za-z])Speaker[ \t]*$')
_FORMAT_TEMPLATE = re.compile(r'(?<![_A-Za-z])Speaker[ \t]*\{')
_PERCENT_TEMPLATE = re.compile(r'(?<![_A-Za-z])Speaker[ \t]*%')


def _violation(node: ast.AST, detail: str) -> str:
    return f'{node.lineno}:{node.col_offset} {detail}'


def _check_joined_string(node: ast.JoinedStr) -> list[str]:
    """A constant chunk ending in the word ``Speaker`` directly before a dynamic value."""
    errors = []
    values = node.values
    for index, (chunk, following) in enumerate(zip(values, values[1:])):
        if not isinstance(chunk, ast.Constant) or not isinstance(chunk.value, str):
            continue
        if isinstance(following, ast.FormattedValue) and _SPEAKER_SUFFIX.search(chunk.value):
            errors.append(_violation(node, f'f-string interpolates a value into "Speaker {chunk.value.strip()}"'))
    return errors


def _check_concatenation(node: ast.BinOp) -> list[str]:
    if not isinstance(node.op, ast.Add):
        return []
    for literal, dynamic in ((node.left, node.right), (node.right, node.left)):
        if (
            isinstance(literal, ast.Constant)
            and isinstance(literal.value, str)
            and _SPEAKER_SUFFIX.search(literal.value)
            and isinstance(dynamic, _DYNAMIC_NODES)
        ):
            return [
                _violation(node, f'string concatenation appends a dynamic value to "Speaker {literal.value.strip()}"')
            ]
    return []


def _check_percent(node: ast.BinOp) -> list[str]:
    if not isinstance(node.op, ast.Mod) or not isinstance(node.left, ast.Constant):
        return []
    template = node.left.value
    if isinstance(template, str) and _PERCENT_TEMPLATE.search(template):
        return [_violation(node, f'"%" template interpolates a value into a Speaker label: {template!r}')]
    return []


def _check_format_call(node: ast.Call) -> list[str]:
    func = node.func
    if not isinstance(func, ast.Attribute) or func.attr != 'format':
        return []
    receiver = func.value
    if isinstance(receiver, ast.Constant) and isinstance(receiver.value, str):
        template = receiver.value
        if _FORMAT_TEMPLATE.search(template):
            return [_violation(node, f'.format() template interpolates a value into a Speaker label: {template!r}')]
    return []


class _Visitor(ast.NodeVisitor):
    def __init__(self) -> None:
        self.errors: list[str] = []

    def visit_JoinedStr(self, node: ast.JoinedStr) -> None:
        self.errors.extend(_check_joined_string(node))
        self.generic_visit(node)

    def visit_BinOp(self, node: ast.BinOp) -> None:
        self.errors.extend(_check_concatenation(node))
        self.errors.extend(_check_percent(node))
        self.generic_visit(node)

    def visit_Call(self, node: ast.Call) -> None:
        self.errors.extend(_check_format_call(node))
        self.generic_visit(node)


def check_source(source: str, filename: str = '<unknown>') -> list[str]:
    visitor = _Visitor()
    visitor.visit(ast.parse(source, filename=filename))
    return visitor.errors


def _is_excluded(parts: tuple[str, ...]) -> bool:
    return any(part in EXCLUDED_DIRS or part.endswith('venv') for part in parts[1:])


def collect_violations(repository_root: Path, scan_root: Path) -> dict[str, list[str]]:
    violations = {}
    for path in sorted((repository_root / scan_root).rglob('*.py')):
        relative = path.relative_to(repository_root).as_posix()
        if _is_excluded(Path(relative).parts):
            continue
        if relative in ALLOWED_FILES:
            continue
        errors = check_source(path.read_text(encoding='utf-8'), relative)
        if errors:
            violations[relative] = errors
    return violations


def _self_test() -> int:
    caught = check_source('label = f"Speaker {seg.speaker_id}: {text}"')
    assert caught, 'f-string interpolation must be caught'
    assert check_source('label = "Speaker " + str(sid)')
    assert check_source("label = 'Speaker %d' % sid")
    assert check_source("label = 'Speaker {}'.format(sid)")
    assert check_source("label = 'Speaker {sid}:'.format(sid=sid)")
    assert check_source('parts = ["Speaker " + name]')
    # Adjacent-but-not-label uses stay legal.
    assert not check_source('log.warning(f"Speaker assignment failed: {e}")')
    assert not check_source('log.warning(f"Speaker cap ({n}) reached; merging into SPEAKER_{best}")')
    assert not check_source('label = "Speaker A"')
    assert not check_source('prompt = "never write Speaker 2 in the people field"')
    print('self-test passed')
    return 0


def _main_fullscan(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=REPOSITORY_ROOT)
    parser.add_argument('--scan-root', type=Path, default=SCAN_ROOT)
    parser.add_argument('--self-test', action='store_true', help='run embedded fixtures and exit')
    args = parser.parse_args(argv)
    if args.self_test:
        return _self_test()
    violations = collect_violations(args.root.resolve(), args.scan_root)
    if not violations:
        return 0
    print('FAIL: "Speaker" labels must not interpolate a raw id; use utils.speakers.display.display_participants:', file=sys.stderr)
    for path, errors in sorted(violations.items()):
        for error in errors:
            print(f'  {path}:{error}', file=sys.stderr)
    return 1



def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if '--changed-files' in arguments or '--base' in arguments:
        return _main_ratchet(arguments)
    return _main_fullscan(arguments)


if __name__ == '__main__':
    raise SystemExit(main())
