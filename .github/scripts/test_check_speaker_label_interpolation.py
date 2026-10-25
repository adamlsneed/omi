import unittest

from check_speaker_label_interpolation import regressions


class SpeakerPresentationRatchetTest(unittest.TestCase):
    def test_python_interpolations(self):
        for source in [
            'x = f"Speaker {segment.speaker_id}"',
            'x = f"{speaker_id}: hello"',
            'x = "Speaker {}".format(segment["speaker_id"])',
            'x = "Speaker %s" % raw_speaker_id',
            'x = f"Speaker {speaker}"',
            'x = "Speaker " + value',
            'x = f"Speaker {display_key}"',
            'sid = segment.speaker_id\nx = f"Who: {sid}"',
            'x = f"{segment.speaker}"',
            'x = "Speaker {speaker_id}".format(**segment)',
            'x = "Speaker %(speaker_id)s" % segment',
        ]:
            with self.subTest(source=source):
                self.assertTrue(regressions('backend/utils/review.py', '', source))

    def test_baseline_is_fingerprinted(self):
        old = 'x = f"Speaker {speaker_id}"'
        self.assertFalse(regressions('backend/utils/review.py', old, old))
        self.assertFalse(regressions('backend/utils/review.py', old, 'x = names.label(row)'))
        self.assertTrue(regressions('backend/utils/review.py', old, 'x = f"Who: {speaker_id}"'))

    def test_authority_and_tests(self):
        for path in ['backend/utils/speakers/display.py', 'backend/tests/unit/test_display.py']:
            self.assertFalse(regressions(path, '', 'x = f"{speaker_id}"'))

    def test_lexical_and_scalar_taint(self):
        safe_sources = [
            'def a(segment):\n key = segment.speaker_id\ndef b():\n key = "Alex"\n return f"{key}"',
            'conversation.speaker_resolution.ids = [s.speaker_id]\nx = f"conversation:{conversation.id}"',
            "bag[speaker_id] = speaker_id\nx = f\"{bag['id']}\"",
            'sid, label = segment.speaker_id, "Alex"\nx = f"{label}"',
            'clusters = [segment.speaker_id]\nx = f"v{len(clusters)}"',
            'from utils.speakers.display import display_participants as names\ndisplay = names(segments)\nparticipant = display.for_segment(row)\nkey, name = participant.key, participant.name\nx = f"{key} {name}"',
        ]
        for source in safe_sources:
            with self.subTest(source=source):
                self.assertFalse(regressions('backend/utils/review.py', '', source))
        for source in [
            'sid, label = segment.speaker_id, "Alex"\nx = f"{sid}"',
            'a = segment.speaker_id\nb = a\nc = b\nd = c\ne = d\nx = f"{e}"',
            'if condition:\n value = segment.speaker_id\nelse:\n value = "Alex"\nx = f"{value}"',
            'from other import display_participants\nvalue = display_participants(speaker_id)\nx = f"{value}"',
            'x = f"{display.for_segment(row).name} {segment.speaker_id}"',
        ]:
            with self.subTest(source=source):
                self.assertTrue(regressions('backend/utils/review.py', '', source))

    def test_routing_identity_is_not_a_display_exception(self):
        source = "def speaker_keys(segments):\n for segment in segments:\n  keys.add(f\"speaker:{segment['speaker_id']}\")\n return frozenset(keys)"
        self.assertFalse(regressions('backend/utils/episodes/policy.py', '', source))
        self.assertTrue(regressions('backend/utils/episodes/policy.py', '', source.replace('speaker_keys', 'prompt')))
        self.assertTrue(regressions('backend/utils/episodes/policy.py', '', source.replace('speaker:', 'Speaker ')))
        self.assertTrue(regressions('backend/utils/display.py', '', source))
        self.assertTrue(regressions('backend/utils/episodes/policy.py', '', source.replace('keys.add', 'render')))

    def test_dart_hash_has_no_display_exception(self):
        self.assertTrue(regressions(
            'app/lib/services/on_device/on_device_projection.dart', '',
            "String onDeviceTranscriptHash() { showLabel('${segment.speakerId}'); return sha256.convert(bytes.takeBytes()).toString(); }"
        ))

    def test_aliases_in_containers_receivers_and_enclosing_scopes(self):
        for source in [
            'sid = segment.speaker_id\nx = f"{str(sid).strip()}"',
            'labels = [segment.speaker_id]\nx = f"{labels[0]}"',
            'labels = {"name": segment.speaker_id}\nx = f"{labels[\'name\']}"',
            'class Display:\n label = f"{speaker_id}"',
            'sid = segment.speaker_id\ndef render():\n return f"{sid}"',
            'from utils.speakers.display import display_participants\ndef render(display_participants):\n value = display_participants(speaker_id)\n return f"{value}"',
        ]:
            with self.subTest(source=source):
                self.assertTrue(regressions('backend/utils/review.py', '', source))

    def test_raw_lookup_keys_and_attribute_names(self):
        for expression in [
            "getattr(segment, 'speaker_id')", "segment.get('speaker_id')",
            "_get(segment, 'raw_speaker_id')", 'segment.diarization_label',
            'segment.raw_speaker_id', "segment['diarization_label']",
        ]:
            with self.subTest(expression=expression):
                self.assertTrue(regressions('backend/utils/review.py', '', f'label = {expression}\nx = f"{{label}}"'))

    def test_shadowed_sanitizers_written_fields_and_loop_aliases(self):
        for source in [
            'def render(len):\n value = len(speaker_id)\n return f"{value}"',
            'from utils.speakers.display import display_participants\ndisplay_participants = other\ndef render():\n value = display_participants(speaker_id)\n return f"{value}"',
            'from utils.speakers.display import display_participants\ndef outer(display_participants):\n def render():\n  value = display_participants(speaker_id)\n  return f"{value}"',
            'values = {}\nvalues["name"] = speaker_id\nx = f"{values[\'name\']}"',
            'record.name = speaker_id\nx = f"{record.name}"',
            'alias = ""\nfor segment in segments:\n text = f"{alias}"\n alias = segment.speaker_id',
            'values = {speaker_id: "x"}\nx = f"{values}"',
        ]:
            with self.subTest(source=source):
                self.assertTrue(regressions('backend/utils/review.py', '', source))

    def test_written_containers_getters_and_import_shadows(self):
        for source in [
            'values = {}\nvalues["name"] = speaker_id\nx = f"{values}"',
            'values = {}\nvalues["name"] = speaker_id\nx = f"{values.get(\'name\')}"',
            'record.name = speaker_id\nx = f"{getattr(record, \'name\')}"',
            'from other import len\nx = f"{len(speaker_id)}"',
            'from utils.speakers.display import display_participants\ndef render():\n from other import display_participants\n return f"{display_participants(speaker_id)}"',
        ]:
            with self.subTest(source=source):
                self.assertTrue(regressions('backend/utils/review.py', '', source))

    def test_named_emulator_test(self):
        source = 'x = f"{speaker_id}"'
        self.assertFalse(regressions('backend/scripts/contention_emulator_test.py', '', source))
        self.assertTrue(regressions('backend/scripts/contention_emulator.py', '', source))

    def test_dart(self):
        self.assertTrue(
            regressions('backend/utils/new_renderer.py', '', 'from utils.speaker_display import SpeakerLabeler')
        )
        self.assertFalse(
            regressions('backend/utils/new_renderer.py', '', 'from utils.speakers.display import display_participants')
        )
        self.assertTrue(regressions('app/lib/widgets/transcript.dart', '', 'Text("Speaker ${segment.speakerId}")'))
        self.assertFalse(regressions('app/lib/widgets/transcript.dart', '', 'Text(names.forSegment(segment))'))


if __name__ == '__main__':
    unittest.main()
