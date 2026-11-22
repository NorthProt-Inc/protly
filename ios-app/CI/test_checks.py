"""Offline tests for checks.py, memsample.py and leak-guard.sh (python3 -m unittest discover -s ios-app/CI)."""

import os
import re
import subprocess
import sys
import tempfile
import unicodedata
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import checks  # noqa: E402
import memsample  # noqa: E402
import prefsdump  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
# Split so no key-shaped literal sits in the source file (the compiled .pyc, gitignored, may fold it).
FAKE_KEY = "sk-" + "ant-test"


def every_id_but(*skip, status="PASS"):
    """A line per expected ID; the IDs checks.py judges by model output (RULES) as a key-less run writes them."""
    return "".join(f"CHECK {i} SKIP no network key\n" if i in checks.RULES else f"CHECK {i} {status} ok\n"
                   for i in checks.EXPECTED_IDS if i not in skip)


class ParseTests(unittest.TestCase):
    def test_well_formed_line(self):
        c = checks.parse_line('CHECK 6.8-1 PASS field="the "')
        self.assertEqual((c.id, c.status, c.evidence), ("6.8-1", "PASS", 'field="the "'))

    def test_line_without_evidence(self):
        c = checks.parse_line("CHECK icon RECORD")
        self.assertEqual((c.id, c.status, c.evidence), ("icon", "RECORD", ""))

    def test_blank_line_is_ignored(self):
        self.assertIsNone(checks.parse_line("   "))

    def test_unknown_status_is_fail_unreadable(self):
        c = checks.parse_line("CHECK 6.8-2 MAYBE something")
        self.assertEqual((c.id, c.status), ("6.8-2", "FAIL"))
        self.assertIn("unreadable", c.evidence)

    def test_line_without_id_is_fail_unreadable(self):
        c = checks.parse_line("CHECK")
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_other_text_is_fail_unreadable(self):
        c = checks.parse_line("garbage from a crashed runner")
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_quoted_field_round_trip(self):
        self.assertEqual(checks.quoted_field('CHECK x PENDING field="a \\"b\\"\\nc "', "field"), 'a "b"\nc ')
        self.assertIsNone(checks.quoted_field("CHECK x PENDING", "field"))


class SortAndCountTests(unittest.TestCase):
    def test_natural_sort(self):
        ids = ["6.8-10", "ws-1", "6.8-2", "8.5-1o", "icon", "6.8-1"]
        self.assertEqual(sorted(ids, key=checks.sort_key), ["6.8-1", "6.8-2", "6.8-10", "8.5-1o", "icon", "ws-1"])

    def test_counts(self):
        lines = [checks.Check("a", "PASS", ""), checks.Check("b", "FAIL", ""), checks.Check("c", "RECORD", ""),
                 checks.Check("d", "SKIP", ""), checks.Check("e", "PASS", "")]
        self.assertEqual(checks.summary(lines), "CHECKS pass 2 fail 1 record 1 skip 1")


class AssembleTests(unittest.TestCase):
    def test_all_present_sorted(self):
        final = checks.assemble(every_id_but(), "", "")
        self.assertEqual([c.id for c in final], sorted(checks.EXPECTED_IDS, key=checks.sort_key))

    def test_missing_id_is_fail_unreadable(self):
        final = {c.id: c for c in checks.assemble(every_id_but("ws-2"), "", "")}
        self.assertEqual(final["ws-2"].status, "FAIL")
        self.assertIn("unreadable", final["ws-2"].evidence)

    def test_missing_file_fails_every_id(self):
        # Every ID but those of the methods that run only in a filtered run (NOT-RUN in a full run: PeriodTests).
        final = checks.assemble(None, None, None)
        self.assertEqual(len(final), len(checks.EXPECTED_IDS))
        filtered_only = {i for m in checks.FILTERED_ONLY for i in checks.METHOD_IDS[m]}
        self.assertTrue(filtered_only)
        for c in final:
            if c.id in filtered_only:
                self.assertEqual(c.status, checks.NOT_RUN, c.id)
            else:
                self.assertTrue(c.status == "FAIL" and "unreadable" in c.evidence, c.id)

    def test_duplicate_id_is_fail(self):
        # A later PASS must not hide an earlier FAIL (or a malformed line for the same ID).
        text = every_id_but("ws-1") + "CHECK ws-1 FAIL first\nCHECK ws-1 PASS second\n"
        final = {c.id: c for c in checks.assemble(text, "", "")}
        self.assertEqual(final["ws-1"].status, "FAIL")
        self.assertIn("duplicate", final["ws-1"].evidence)
        self.assertIn("first", final["ws-1"].evidence)

    def test_malformed_then_valid_line_is_fail(self):
        text = every_id_but("ws-1") + "CHECK ws-1 PASSED x\nCHECK ws-1 PASS y\n"
        final = {c.id: c for c in checks.assemble(text, "", "")}
        self.assertEqual(final["ws-1"].status, "FAIL")

    def test_pass_without_evidence_is_fail(self):
        c = checks.parse_line("CHECK 6.8-1 PASS")
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_unresolved_pending_is_fail(self):
        text = every_id_but("6.8-3") + "CHECK 6.8-3 PENDING whatever\n"
        final = {c.id: c for c in checks.assemble(text, "", "")}
        self.assertEqual(final["6.8-3"].status, "FAIL")

    def test_unexpected_id_is_kept(self):
        final = {c.id: c for c in checks.assemble(every_id_but() + "CHECK extra RECORD x\n", "", "")}
        self.assertEqual(final["extra"].status, "RECORD")


class TextTests(unittest.TestCase):
    def test_nfc_and_nfd_hangul_compare_equal(self):
        nfc = "안녕하세요"
        nfd = unicodedata.normalize("NFD", nfc)
        self.assertNotEqual(nfc, nfd)
        self.assertTrue(checks.same_text(nfc, nfd))
        self.assertFalse(checks.same_text(nfc, "안녕"))

    def test_relaunch_compares_nfd_field(self):
        nfd = unicodedata.normalize("NFD", "wyd ")
        text = every_id_but("6.8-9") + f'CHECK 6.8-9 PENDING field="{nfd}"\n'
        marks = "MARK relaunch-before 100.0\nMARK relaunch-after 110.0\n"
        mem = "100.0 41 rss 9000\n110.0 52 rss 9100\n"
        final = {c.id: c for c in checks.assemble(text, marks, mem)}
        self.assertEqual(final["6.8-9"].status, "PASS")


def relaunch(field, mem, marks="MARK relaunch-before 100.0\nMARK relaunch-after 110.5\n"):
    text = every_id_but("6.8-9") + f'CHECK 6.8-9 PENDING field="{field}"\n'
    return {c.id: c for c in checks.assemble(text, marks, mem)}["6.8-9"]


class RelaunchTests(unittest.TestCase):
    def test_pid_changed_is_pass(self):
        c = relaunch("wyd ", "99.0 41 rss 9000\n101.0 41 rss 9000\n110.0 52 rss 9100\n")
        self.assertEqual(c.status, "PASS")
        self.assertIn("41", c.evidence)
        self.assertIn("52", c.evidence)

    def test_same_pid_is_record(self):
        c = relaunch("wyd ", "100.0 41 rss 9000\n110.0 41 rss 9100\n")
        self.assertEqual(c.status, "RECORD")
        self.assertIn("same process", c.evidence)

    def test_field_mismatch_is_fail(self):
        c = relaunch("죵 ", "100.0 41 rss 9000\n110.0 52 rss 9100\n")
        self.assertEqual(c.status, "FAIL")

    def test_no_samples_is_fail_unreadable(self):
        c = relaunch("wyd ", "")
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_missing_mark_is_fail_unreadable(self):
        c = relaunch("wyd ", "100.0 41 rss 9000\n", marks="MARK relaunch-before 100.0\n")
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_sample_far_from_the_mark_is_unreadable(self):
        c = relaunch("wyd ", "10.0 41 rss 9000\n200.0 52 rss 9100\n")
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)


def memory(mem, marks="MARK mem-start 100.0\nMARK mem-end 160.0\n"):
    text = every_id_but("6.8-10") + "CHECK 6.8-10 PENDING presentations=30\n"
    return {c.id: c for c in checks.assemble(text, marks, mem)}["6.8-10"]


class MemoryTests(unittest.TestCase):
    def test_same_pid_records_both_numbers_and_growth(self):
        c = memory("100.5 41 rss 30720\n100.5 41 footprint 20480\n159.0 41 rss 31744\n159.0 41 footprint 25600\n")
        self.assertEqual(c.status, "RECORD")
        self.assertIn("20.0 MB", c.evidence)
        self.assertIn("25.0 MB", c.evidence)
        self.assertIn("+5.0 MB", c.evidence)
        self.assertIn("footprint", c.evidence)
        self.assertIn("whole MB", c.evidence)  # footprint prints MB: growth under 1 MB reads as zero

    def test_falls_back_to_rss(self):
        c = memory("100.0 41 rss 10240\n160.0 41 rss 12288\n")
        self.assertEqual(c.status, "RECORD")
        self.assertIn("+2.0 MB", c.evidence)
        self.assertIn("rss", c.evidence)

    def test_changed_pid_is_not_comparable(self):
        c = memory("100.0 41 rss 10240\n160.0 77 rss 12288\n")
        self.assertEqual(c.status, "RECORD")
        self.assertIn("pid changed, not comparable", c.evidence)

    def test_no_samples_is_fail_unreadable(self):
        c = memory("100.0 - none -\n160.0 - none -\n")
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_no_marks_is_fail_unreadable(self):
        c = memory("100.0 41 rss 10240\n", marks="")
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_malformed_sample_lines_are_ignored(self):
        c = memory("junk\n100.0 41 rss abc\n100.0 41 rss 10240\n160.0 41 rss 10240\n")
        self.assertEqual(c.status, "RECORD")
        self.assertIn("+0.0 MB", c.evidence)


class MainTests(unittest.TestCase):
    def test_writes_final_checks_and_keeps_the_raw(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "checks.txt"), "w", encoding="utf-8") as f:
                f.write(every_id_but("icon") + "CHECK icon RECORD found\n")
            out = subprocess.run([sys.executable, os.path.join(HERE, "checks.py"), d],
                                 capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr)
            lines = out.stdout.splitlines()
            self.assertEqual(lines[0], "CHECKS")
            ruled = len(checks.RULES)
            self.assertEqual(lines[-1], f"CHECKS pass {len(checks.EXPECTED_IDS) - 1 - ruled} fail 0 record 1 skip {ruled}")
            with open(os.path.join(d, "checks.txt"), encoding="utf-8") as f:
                self.assertEqual(f.read().splitlines(), lines[1:-1])
            self.assertTrue(os.path.exists(os.path.join(d, "checks-raw.txt")))

    def test_exit_1_on_a_fail(self):
        with tempfile.TemporaryDirectory() as d:
            out = subprocess.run([sys.executable, os.path.join(HERE, "checks.py"), d],
                                 capture_output=True, text=True)
            self.assertEqual(out.returncode, 1)
            self.assertIn("unreadable", out.stdout)


class MemsampleParseTests(unittest.TestCase):
    def test_footprint(self):
        text = ("======\nProtlyCIKeyboard [5432]: 64-bit    Footprint: 21 MB (16384 bytes per page)\n======\n")
        self.assertEqual(memsample.parse_footprint(text), 21 * 1024)
        self.assertEqual(memsample.parse_footprint("phys_footprint: 9584 KB"), 9584)
        self.assertEqual(memsample.parse_footprint("Footprint: 1.5 GB"), int(1.5 * 1024 * 1024))
        self.assertIsNone(memsample.parse_footprint("footprint: permission denied"))

    def test_vmmap(self):
        self.assertEqual(memsample.parse_vmmap("Physical footprint:         10.5M\n"), int(10.5 * 1024))
        self.assertEqual(memsample.parse_vmmap("Physical footprint:         900K\n"), 900)
        self.assertIsNone(memsample.parse_vmmap("vmmap: no process"))

    def test_rss(self):
        self.assertEqual(memsample.parse_rss("  12345\n"), 12345)
        self.assertIsNone(memsample.parse_rss(""))

    def test_wait_for_text(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "ui-log.txt")
            self.assertFalse(memsample.has_text(path, "== PhoneChecksUITests"))
            with open(path, "w", encoding="utf-8") as f:
                f.write("== KeyboardShotsUITests.testScenarios\n")
            self.assertFalse(memsample.has_text(path, "== PhoneChecksUITests"))
            with open(path, "a", encoding="utf-8") as f:
                f.write("== PhoneChecksUITests.test1_68\n")
            self.assertTrue(memsample.has_text(path, "== PhoneChecksUITests"))

    def test_probe_skips_vmmap(self):
        # Run 8: vmmap --summary hung 20 s on the keyboard process (it suspends its target).
        self.assertNotIn("vmmap", [m[0] for m in memsample.METHODS])

    def test_pids(self):
        self.assertEqual(memsample.parse_pids("41\n52\n"), [41, 52])
        self.assertEqual(memsample.parse_pids(""), [])


class LeakGuardTests(unittest.TestCase):
    def guard(self, d):
        return subprocess.run(["bash", os.path.join(HERE, "leak-guard.sh"), d], capture_output=True, text=True)

    def test_clean_folder_passes(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "report.txt"), "w") as f:
                f.write("STATUS measured\nRESULT PASS\n")
            out = self.guard(d)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)

    def test_key_in_a_nested_file_is_refused_without_printing_it(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "sub"))
            with open(os.path.join(d, "sub", "build.log"), "w") as f:
                f.write(f"let apiKey = \"{FAKE_KEY}-123\"\n")
            out = self.guard(d)
            self.assertEqual(out.returncode, 1)
            self.assertIn("build.log", out.stdout)
            self.assertNotIn(FAKE_KEY, out.stdout + out.stderr)

    def test_key_in_a_binary_file_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "c-x.png"), "wb") as f:
                f.write(b"\x89PNG\x00\x01" + FAKE_KEY.encode() + b"\x00")
            self.assertEqual(self.guard(d).returncode, 1)

    def test_missing_folder_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertNotEqual(self.guard(os.path.join(d, "nope")).returncode, 0)


def resolve(line):
    """One PENDING network line through assemble(), the way checks.py sees it."""
    return {c.id: c for c in checks.assemble(line + "\n", "", "")}[line.split()[1]]


class ScriptRuleTests(unittest.TestCase):
    """Plan Task 2.3: the script rules for model output."""

    def test_cyrillic(self):
        self.assertTrue(checks.has_cyrillic("Спасибо"))
        self.assertTrue(checks.has_cyrillic("Ѐ"))
        self.assertTrue(checks.has_cyrillic("ӿ"))
        self.assertFalse(checks.has_cyrillic("spasibo"))
        self.assertFalse(checks.has_cyrillic("Ԁ"))

    def test_hangul_syllables_and_compatibility_jamo(self):
        self.assertTrue(checks.has_hangul("안녕"))
        self.assertTrue(checks.has_hangul("ㅋㅋ"))
        self.assertTrue(checks.has_hangul("가"))
        self.assertTrue(checks.has_hangul("힣"))
        self.assertTrue(checks.has_hangul("ㄱ"))
        self.assertTrue(checks.has_hangul("ㆎ"))
        self.assertFalse(checks.has_hangul("hello"))
        self.assertFalse(checks.has_hangul("㄰"))

    def test_nfd_hangul_counts_as_hangul(self):
        # Conjoining jamo (U+1100...) are outside the plan's ranges; NFC composes them into syllables first.
        self.assertTrue(checks.has_hangul(unicodedata.normalize("NFD", "봐")))

    def test_kana_or_kanji(self):
        self.assertTrue(checks.has_kana_or_kanji("あした"))
        self.assertTrue(checks.has_kana_or_kanji("カタカナ"))
        self.assertTrue(checks.has_kana_or_kanji("明日"))
        self.assertTrue(checks.has_kana_or_kanji("぀"))
        self.assertTrue(checks.has_kana_or_kanji("鿿"))
        self.assertFalse(checks.has_kana_or_kanji("ashita"))
        self.assertFalse(checks.has_kana_or_kanji("내일"))

    def test_latin_needs_a_letter_and_no_hangul(self):
        self.assertTrue(checks.is_latin("See you at 3 tomorrow"))
        self.assertFalse(checks.is_latin("3:00"))
        self.assertFalse(checks.is_latin("See you 내일"))
        self.assertFalse(checks.is_latin("ㅋ ok"))
        self.assertFalse(checks.is_latin(""))

    def test_every_network_id_has_rules_or_is_written_by_the_test(self):
        written = {"7.7-1", "7.7-4", "7.7-5", "7.7-6", "8.5-10"}  # not model output: the test writes the status
        for i in checks.NETWORK_IDS:
            self.assertIn(i, checks.EXPECTED_IDS)
            self.assertTrue(i in checks.RULES or i in written, i)


class NetworkResolveTests(unittest.TestCase):
    """PENDING network lines: the test's `group#n="..."` outputs against RULES; one retry, two FAILs is a FAIL."""

    def test_russian_insert_passes(self):
        c = resolve('CHECK 8.5-1 PENDING translating=yes out#1="Спасибо за конспект, ты меня спасла." undo=ok')
        self.assertEqual(c.status, "PASS", c.evidence)
        self.assertIn("out#1 ok", c.evidence)
        self.assertIn("undo=ok", c.evidence)

    def test_russian_with_the_code_left_in_fails(self):
        c = resolve('CHECK 8.5-1 PENDING out#1="ru: Спасибо, ты меня спасла."')
        self.assertEqual(c.status, "FAIL")
        self.assertIn("ru:", c.evidence)

    def test_russian_with_the_draft_left_in_fails(self):
        c = resolve('CHECK 8.5-1 PENDING out#1="누나 노트 Спасибо, ты меня спасла."')
        self.assertEqual(c.status, "FAIL")

    def test_masculine_spas_is_not_spasla(self):
        self.assertEqual(resolve('CHECK 8.5-1 PENDING out#1="Ты меня спас."').status, "FAIL")

    def test_retry_that_passes_is_pass_with_both_outputs(self):
        c = resolve('CHECK 8.5-4 PENDING out#1="Estoy muy cansada hoy" out#2="Hoy estoy muy cansado"')
        self.assertEqual(c.status, "PASS", c.evidence)
        self.assertIn("cansada", c.evidence)
        self.assertIn("out#1 fails", c.evidence)
        self.assertIn("out#2 ok", c.evidence)

    def test_two_fails_is_fail(self):
        c = resolve('CHECK 8.5-9 PENDING out#1="the colour" out#2="el colour, jaja"')
        self.assertEqual(c.status, "FAIL")
        self.assertIn("out#2 fails", c.evidence)

    def test_no_output_is_fail_unreadable(self):
        c = resolve("CHECK 8.5-5 PENDING translating=yes")
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_escaped_output_is_unescaped(self):
        self.assertEqual(resolve(r'CHECK 8.5-5 PENDING out#1="He said \"see you\" at 3"').status, "PASS")

    def test_japanese(self):
        self.assertEqual(resolve('CHECK 8.5-3 PENDING out#1="明日時間ある？一緒にご飯食べよう笑"').status, "PASS")
        self.assertEqual(resolve('CHECK 8.5-3 PENDING out#1="明日時間ある？ご飯行こう lol"').status, "FAIL")
        self.assertEqual(resolve('CHECK 8.5-3 PENDING out#1="明日時間ある？ご飯行こう ㅋㅋ"').status, "FAIL")
        self.assertEqual(resolve('CHECK 8.5-3 PENDING out#1="ashita jikan aru?"').status, "FAIL")

    def test_no_prefix_and_ok_prefix_are_latin(self):
        self.assertEqual(resolve('CHECK 8.5-5 PENDING out#1="See you at 3 tomorrow"').status, "PASS")
        self.assertEqual(resolve('CHECK 8.5-6 PENDING out#1="ok: see you tomorrow"').status, "PASS")
        self.assertEqual(resolve('CHECK 8.5-6 PENDING out#1="내일 봐"').status, "FAIL")
        self.assertEqual(resolve('CHECK 6.8-11 PENDING flip=ok out#1="See you tomorrow"').status, "PASS")

    def test_korean_polish(self):
        good = 'CHECK 8.5-7 PENDING polishing=yes out#1="낼 시간 돼? 같이 밥 먹자 ㅋㅋ 안 되면 말해줘"'
        self.assertEqual(resolve(good).status, "PASS")
        self.assertEqual(resolve(good.replace("ㅋㅋ ", "")).status, "FAIL")
        self.assertEqual(resolve(good.replace("말해줘", "말해죠")).status, "FAIL")
        # Tower ruling (2026-10-31): the auxiliary verb spaced (the standard, run 41's output) or joined.
        self.assertEqual(resolve(good.replace("말해줘", "말해 줘")).status, "PASS")
        self.assertEqual(resolve(good.replace("말해줘", "말해  줘")).status, "FAIL")
        self.assertEqual(resolve(good.replace("말해줘", "말해 죠")).status, "FAIL")
        self.assertEqual(resolve(good.replace('out#1="', 'out#1="ko: ')).status, "FAIL")
        self.assertEqual(resolve('CHECK 8.5-7 PENDING out#1="Are you free tomorrow? lol"').status, "FAIL")

    def test_long_korean_polish(self):
        self.assertEqual(resolve('CHECK 8.5-8 PENDING out#1="오늘 진짜 길었어.\\n\\n내일 아침에 전화할게."').status, "PASS")
        self.assertEqual(resolve('CHECK 8.5-8 PENDING out#1="KO: 오늘 진짜 길었어"').status, "FAIL")

    def test_spanish_polish(self):
        good = 'CHECK 8.5-9 PENDING out#1="Me encanta el color de tu chaqueta, ¿dónde la compraste? Jaja"'
        self.assertEqual(resolve(good).status, "PASS")
        self.assertEqual(resolve(good.replace("compraste", "conprastes")).status, "FAIL")

    def test_spanish_polish_replaces_the_draft(self):
        appended = ('CHECK 8.5-9 PENDING out#1="me encanta el color de tu chaqueta, donde la conprastes? jaja '
                    'Me encanta el color de tu chaqueta, ¿dónde la compraste? Jaja"')
        self.assertEqual(resolve(appended).status, "FAIL")
        self.assertEqual(resolve('CHECK 8.5-9 PENDING out#1="el color, ¿dónde la comprastes? jaja"').status, "FAIL")

    def test_about_me_insert_replaces_the_korean_draft(self):
        c = resolve('CHECK 7.7-2 PENDING out#1="우리 문빔 킬른 다음 주에 오픈해 Moonbeam Kiln opens next week"')
        self.assertEqual(c.status, "FAIL")

    def test_about_me_name_and_nothing_else(self):
        good = 'CHECK 7.7-2 PENDING out#1="Moonbeam Kiln opens next week"'
        self.assertEqual(resolve(good).status, "PASS")
        self.assertEqual(resolve('CHECK 7.7-2 PENDING out#1="Moonbeam kiln opens next week"').status, "FAIL")
        self.assertEqual(resolve('CHECK 7.7-2 PENDING out#1="Our pottery studio Moonbeam Kiln opens"').status, "FAIL")
        self.assertEqual(resolve('CHECK 7.7-2 PENDING out#1="Moonbeam Kiln opens in Victoria"').status, "FAIL")
        self.assertEqual(resolve('CHECK 7.7-2 PENDING out#1="Munbim Killeun opens next week"').status, "FAIL")

    def test_two_groups_must_both_pass(self):
        line = 'CHECK 7.7-3 PENDING panel#1="어제 사진 보내줄 수 있어?" four=ok out#1="Moonbeam Kiln opens next week"'
        self.assertEqual(resolve(line).status, "PASS")
        self.assertEqual(resolve(line.replace("어제 사진 보내줄 수 있어?", "Can you send me the photos?")).status, "FAIL")
        self.assertEqual(resolve(line.replace("Moonbeam Kiln", "Munbim Kilreun")).status, "FAIL")
        missing = resolve('CHECK 7.7-3 PENDING panel#1="어제 사진 보내줄 수 있어?"')
        self.assertEqual(missing.status, "FAIL")
        self.assertIn("unreadable", missing.evidence)

    def test_status_the_test_wrote_is_kept(self):
        # A FAIL for a step the test judged itself (Undo, a missing label) is not overturned by good output.
        c = resolve('CHECK 8.5-1 FAIL out#1="Ты меня спасла." undo="ru: x" want "ru: y"')
        self.assertEqual(c.status, "FAIL")
        self.assertEqual(resolve("CHECK 8.5-3 SKIP no network key").status, "SKIP")


class NetworkGuardTests(unittest.TestCase):
    """A network item can PASS only through its model output, and a run with the key cannot SKIP for want of one."""

    def test_pass_without_model_output_is_fail_unreadable(self):
        c = resolve("CHECK 8.5-5 PASS field looked fine")
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_no_key_skip_is_kept_without_the_key(self):
        c = {x.id: x for x in checks.assemble("CHECK 8.5-5 SKIP no network key\n", "", "")}["8.5-5"]
        self.assertEqual(c.status, "SKIP")

    def test_no_key_skip_with_the_key_is_fail_unreadable(self):
        lines = checks.assemble("CHECK 8.5-5 SKIP no network key\nCHECK 7.7-6 SKIP needs a phone reinstall\n",
                                "", "", network_key=True)
        by_id = {c.id: c for c in lines}
        self.assertEqual(by_id["8.5-5"].status, "FAIL")
        self.assertIn("unreadable", by_id["8.5-5"].evidence)
        self.assertEqual(by_id["7.7-6"].status, "SKIP")

    def test_main_takes_the_network_key_flag(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "checks.txt"), "w", encoding="utf-8") as f:
                f.write("CHECK 8.5-5 SKIP no network key\n")
            out = subprocess.run([sys.executable, os.path.join(HERE, "checks.py"), d, "--network-key"],
                                 capture_output=True, text=True)
            self.assertIn("CHECK 8.5-5 FAIL unreadable", out.stdout)


class WriteSecretsTests(unittest.TestCase):
    """write-secrets.sh: the key reaches Secrets.swift through make-secrets.sh in a temporary HOME, never output."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        # A throwaway copy of the two scripts in a git repo shaped like this one, so the real Secrets.swift is
        # never touched.
        self.repo = os.path.join(root, "repo")
        for sub in ("ios-app/CI", "ios-app/scripts", "ios-app/Sources/ProtlyKeyboard"):
            os.makedirs(os.path.join(self.repo, sub))
        for rel in ("ios-app/CI/write-secrets.sh", "ios-app/scripts/make-secrets.sh"):
            with open(os.path.join(HERE, "..", "..", rel), encoding="utf-8") as src, \
                    open(os.path.join(self.repo, rel), "w", encoding="utf-8") as dst:
                dst.write(src.read())
        with open(os.path.join(self.repo, ".gitignore"), "w", encoding="utf-8") as f:
            f.write("ios-app/Sources/ProtlyKeyboard/Secrets.swift\n")
        subprocess.run(["git", "init", "-q", self.repo], check=True)
        self.secrets = os.path.join(self.repo, "ios-app/Sources/ProtlyKeyboard/Secrets.swift")
        self.env_file = os.path.join(root, "github-env")
        open(self.env_file, "w").close()
        self.tmpdir = os.path.join(root, "t")
        os.makedirs(self.tmpdir)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, key):
        env = {"PATH": os.environ["PATH"], "HOME": os.path.join(self.tmp.name, "home"), "GITHUB_ENV": self.env_file,
               "TMPDIR": self.tmpdir}
        if key is not None:
            env["PROTLY_API_KEY"] = key
        return subprocess.run(["bash", os.path.join(self.repo, "ios-app/CI/write-secrets.sh")],
                              capture_output=True, text=True, env=env)

    def github_env(self):
        with open(self.env_file, encoding="utf-8") as f:
            return f.read()

    def test_key_is_written_and_never_printed(self):
        key = FAKE_KEY + "-Abc_123"
        out = self.run_script(key)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertNotIn(key, out.stdout + out.stderr)
        self.assertNotIn("ant-", out.stdout + out.stderr)
        with open(self.secrets, encoding="utf-8") as f:
            self.assertIn(f'apiKey = "{key}"', f.read())
        self.assertEqual(self.github_env(), "HAS_KEY=true\n")
        self.assertNotIn(key, self.github_env())
        # The temporary HOME with the key file is gone.
        self.assertEqual(os.listdir(self.tmpdir), [])

    def test_empty_secret_keeps_the_stand_in(self):
        for key in (None, ""):
            out = self.run_script(key)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
            self.assertFalse(os.path.exists(self.secrets))
            self.assertIn("no network key", out.stdout)
        self.assertEqual(self.github_env(), "HAS_KEY=false\nHAS_KEY=false\n")

    def test_malformed_key_fails_without_printing_it(self):
        out = self.run_script("not-a-key-SECRETVALUE")
        self.assertNotEqual(out.returncode, 0)
        self.assertNotIn("SECRETVALUE", out.stdout + out.stderr)
        self.assertFalse(os.path.exists(self.secrets))
        self.assertNotIn("HAS_KEY=true", self.github_env())
        self.assertEqual(os.listdir(self.tmpdir), [])


class DeadlineTests(unittest.TestCase):
    """run-shots.sh's with_deadline: a hung command is stopped (exit 124), others keep their exit code."""

    def run_fn(self, body):
        with open(os.path.join(HERE, "run-shots.sh"), encoding="utf-8") as f:
            src = f.read()
        fn = src[src.index("with_deadline() {"):]
        fn = fn[:fn.index("\n}\n") + 3]
        with tempfile.TemporaryDirectory() as work:
            script = f"work={work}\n{fn}\n{body}\n"
            return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30)

    def test_hung_command_is_stopped(self):
        out = self.run_fn("with_deadline 1 sleep 20; echo code=$?")
        self.assertIn("code=124", out.stdout)

    def test_exit_code_is_kept(self):
        self.assertIn("code=3", self.run_fn("with_deadline 5 sh -c 'exit 3'; echo code=$?").stdout)
        self.assertIn("code=0", self.run_fn("with_deadline 5 true; echo code=$?").stdout)


class TestFailureLinesTests(unittest.TestCase):
    """run-shots.sh copies xcodebuild's error lines to test-failures.txt (the log tail missed run 44's reason)."""

    def run_block(self, log_text):
        with open(os.path.join(HERE, "run-shots.sh"), encoding="utf-8") as f:
            src = f.read()
        block = src[src.index("grep -E ': error: "):]
        block = block[:block.index("\nfi\n") + 4]
        with tempfile.TemporaryDirectory() as tmp:
            work, out = os.path.join(tmp, "work"), os.path.join(tmp, "out")
            os.makedirs(work)
            os.makedirs(out)
            with open(os.path.join(work, "test.log"), "w", encoding="utf-8") as f:
                f.write(log_text)
            script = f'work={work}; out={out}\nnote() {{ echo "$1"; }}\n{block}\nls "$out"\n'
            return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30).stdout

    def test_error_lines_are_kept(self):
        log = ("t = 1.00s Launch com.northprot.protly.cihost\n"
               "/x/KeyboardShotsUITests.swift:18: error: -[ProtlyCIUITests.KeyboardShotsUITests testScenarios] : "
               "Failed to launch com.northprot.protly.cihost\n"
               "t = 2.00s Ignoring failure to get hierarchy for remote element\n")
        out = self.run_block(log)
        self.assertIn("test failures (1 lines, test-failures.txt):", out)
        self.assertIn("  /x/KeyboardShotsUITests.swift:18: error:", out)
        self.assertIn("test-failures.txt", out.splitlines()[-1])
        self.assertNotIn("Ignoring", out)

    def test_no_file_without_errors(self):
        out = self.run_block("Test Case '-[A b]' passed (1.0 seconds).\n")
        self.assertEqual("", out.strip())


class WorkflowTests(unittest.TestCase):
    """keyboard-shots.yml (plan Task 2.1): the key reaches one step, and a run with the key never saves the cache."""

    @classmethod
    def setUpClass(cls):
        import yaml  # the verify command and the workflow's test step install it
        with open(os.path.join(HERE, "..", "..", ".github", "workflows", "keyboard-shots.yml"), encoding="utf-8") as f:
            cls.text = f.read()
        cls.steps = yaml.safe_load(cls.text)["jobs"]["shots"]["steps"]

    def test_secret_goes_to_the_write_secrets_step_only(self):
        self.assertEqual(self.text.count("secrets.PROTLY_API_KEY"), 1)
        users = [s for s in self.steps if "secrets.PROTLY_API_KEY" in str(s)]
        self.assertEqual(len(users), 1)
        self.assertEqual(users[0]["env"], {"PROTLY_API_KEY": "${{ secrets.PROTLY_API_KEY }}"})
        self.assertIn("write-secrets.sh", users[0]["run"])

    def test_cache_is_restore_then_save_without_the_key(self):
        uses = [s.get("uses", "") for s in self.steps]
        self.assertFalse([u for u in uses if u.startswith("actions/cache@")], "the combined action saves on its own")
        restore = [i for i, u in enumerate(uses) if u.startswith("actions/cache/restore@")]
        save = [i for i, u in enumerate(uses) if u.startswith("actions/cache/save@")]
        self.assertEqual((len(restore), len(save)), (1, 1))
        secrets_step = next(i for i, s in enumerate(self.steps) if "write-secrets.sh" in s.get("run", ""))
        # The cache key is hashed before Secrets.swift exists.
        self.assertLess(restore[0], secrets_step)
        self.assertIn("env.HAS_KEY == 'false'", self.steps[save[0]]["if"])  # unset (the step failed) never saves

    def test_build_step_times_out_before_the_job(self):
        job = next(iter(__import__("yaml").safe_load(self.text)["jobs"].values()))
        build = next(s for s in self.steps if "run-shots.sh" in s.get("run", ""))
        self.assertLess(build["timeout-minutes"] + 5, job["timeout-minutes"])
        # run-shots.sh stops the tests itself, leaving the step time for a cold build and boot (about 12 min in run
        # 53) before them and for measuring after them.
        script = open(os.path.join(HERE, "run-shots.sh"), encoding="utf-8").read()
        deadline = int(re.search(r'main_deadline="\$\{MAIN_TEST_DEADLINE:-(\d+)\}"', script).group(1))
        self.assertGreaterEqual(deadline, 3900)  # run 53's full suite ran past 3000 s on a slow runner
        self.assertLessEqual(deadline / 60 + 15, build["timeout-minutes"])
        publish =next(s for s in self.steps if "bash ios-app/CI/publish-shots.sh" in s.get("run", ""))
        self.assertIn("!cancelled()", publish["if"])

    def test_filtered_tag_starts_the_job(self):
        job = next(iter(__import__("yaml").safe_load(self.text)["jobs"].values()))
        self.assertIn("contains(github.event.head_commit.message, '[shots]')", job["if"])
        self.assertIn("contains(github.event.head_commit.message, '[shots:')", job["if"])

    def test_commit_message_reaches_run_shots_through_env_only(self):
        # A commit message inside a run: script would be shell code; in env it is data.
        for s in self.steps:
            self.assertNotIn("head_commit.message", s.get("run", ""), s.get("name"))
        build = next(s for s in self.steps if "run-shots.sh" in s.get("run", ""))
        self.assertEqual(build["env"]["SHOTS_MESSAGE"], "${{ github.event.head_commit.message }}")

    def test_judge_takes_not_run_layout_only_in_a_filtered_run(self):
        judge = next(s for s in self.steps if "RESULT PASS" in s.get("run", ""))["run"]
        self.assertIn("grep -q '^FILTER ' \"$report\"", judge)
        self.assertIn("grep -qx 'RESULT PASS' \"$report\"", judge)
        # NOT-RUN only when the filter left the layout out; a filtered run says so in the log and step summary.
        self.assertIn("grep -q '^FILTER .*KeyboardShotsUITests' \"$report\"", judge)
        self.assertIn("grep -q '^RESULT NOT-RUN' \"$report\"", judge)
        self.assertIn("FILTERED RUN", judge)
        self.assertIn("$GITHUB_STEP_SUMMARY", judge)

    def test_publish_goes_through_the_leak_guard(self):
        publish = [s for s in self.steps if "bash ios-app/CI/publish-shots.sh" in s.get("run", "")]
        self.assertEqual(len(publish), 1)
        with open(os.path.join(HERE, "publish-shots.sh"), encoding="utf-8") as f:
            script = f.read()
        self.assertLess(script.index("leak-guard.sh"), script.index("git push"))


class PrefsDumpTests(unittest.TestCase):
    """prefsdump.py (plan Task 2.2 step 1): what changed in a shut-down device's data folder around Full Access."""

    def setUp(self):
        import plistlib
        import sqlite3
        self.plistlib, self.sqlite3 = plistlib, sqlite3
        self.tmp = tempfile.TemporaryDirectory()
        self.data = os.path.join(self.tmp.name, "data")
        self.prefs = os.path.join(self.data, "Library", "Preferences")
        os.makedirs(self.prefs)
        os.makedirs(os.path.join(self.data, "Library", "TCC"))
        self.write_plist("com.apple.keyboard.preferences.plist", {"KeyboardPrediction": True})
        self.write_plist("com.apple.other.plist", {"x": 1})
        db = sqlite3.connect(os.path.join(self.data, "Library", "TCC", "TCC.db"))
        db.execute("create table access (service text, client text, auth_value integer)")
        db.execute("insert into access values ('kTCCServiceCamera', 'com.x', 0)")
        db.commit()
        db.close()

    def tearDown(self):
        self.tmp.cleanup()

    def write_plist(self, name, value):
        with open(os.path.join(self.prefs, name), "wb") as f:
            self.plistlib.dump(value, f, fmt=self.plistlib.FMT_BINARY)

    def snap(self, name):
        dest = os.path.join(self.tmp.name, name)
        prefsdump.snapshot(self.data, dest)
        return dest

    def test_changed_key_new_file_and_tcc_row(self):
        before = self.snap("before")
        self.write_plist("com.apple.keyboard.preferences.plist",
                         {"KeyboardPrediction": True, "KeyboardsWithFullAccess": ["com.northprot.protly.cihost.keyboard"]})
        self.write_plist("com.apple.new.plist", {"y": "z"})
        db = self.sqlite3.connect(os.path.join(self.data, "Library", "TCC", "TCC.db"))
        db.execute("insert into access values ('kTCCServiceKeyboardNetwork', 'com.northprot.protly.cihost.keyboard', 2)")
        db.commit()
        db.close()
        after = self.snap("after")
        text = prefsdump.diff(before, after)
        self.assertIn("Library/Preferences/com.apple.keyboard.preferences.plist", text)
        self.assertIn("+ KeyboardsWithFullAccess", text)
        self.assertIn("com.northprot.protly.cihost.keyboard", text)
        self.assertIn("new Library/Preferences/com.apple.new.plist", text)
        self.assertIn("kTCCServiceKeyboardNetwork", text)
        self.assertNotIn("kTCCServiceCamera", text)  # unchanged rows are not repeated
        self.assertNotIn("com.apple.other.plist", text)
        self.assertIn("create table access", text.lower())

    def test_tcc_wal_files_are_copied(self):
        # A TCC.db in WAL mode keeps its newest rows in TCC.db-wal; without it the copy reads as empty (run 40).
        tcc = os.path.join(self.data, "Library", "TCC")
        for suffix in ("-wal", "-shm"):
            with open(os.path.join(tcc, "TCC.db" + suffix), "wb") as f:
                f.write(b"x")
        dest = self.snap("before")
        for suffix in ("-wal", "-shm"):
            self.assertTrue(os.path.exists(os.path.join(dest, "files", "Library", "TCC", "TCC.db" + suffix)))

    def test_nothing_changed(self):
        before = self.snap("before")
        after = self.snap("after")
        self.assertIn("no plist or TCC change", prefsdump.diff(before, after))

    def test_unreadable_plist_is_reported_not_raised(self):
        before = self.snap("before")
        with open(os.path.join(self.prefs, "com.apple.other.plist"), "wb") as f:
            f.write(b"not a plist")
        after = self.snap("after")
        self.assertIn("unreadable", prefsdump.diff(before, after))

    def test_snapshot_of_a_missing_folder_fails(self):
        with self.assertRaises(SystemExit):
            prefsdump.snapshot(os.path.join(self.tmp.name, "nope"), os.path.join(self.tmp.name, "x"))
        code = subprocess.run([sys.executable, os.path.join(HERE, "prefsdump.py"), "snapshot",
                               os.path.join(self.tmp.name, "nope"), os.path.join(self.tmp.name, "y")],
                              capture_output=True).returncode
        self.assertNotEqual(code, 0)

    def test_diff_states_how_much_each_snapshot_held(self):
        before = self.snap("before")
        after = self.snap("after")
        self.assertIn("snapshots: before 2 plists", prefsdump.diff(before, after))

    def test_main_writes_the_diff(self):
        before = self.snap("before")
        self.write_plist("com.apple.other.plist", {"x": 2})
        out = os.path.join(self.tmp.name, "probe-prefs.txt")
        code = subprocess.run([sys.executable, os.path.join(HERE, "prefsdump.py"), "snapshot", self.data,
                               os.path.join(self.tmp.name, "after")]).returncode
        self.assertEqual(code, 0)
        code = subprocess.run([sys.executable, os.path.join(HERE, "prefsdump.py"), "diff", before,
                               os.path.join(self.tmp.name, "after"), out]).returncode
        self.assertEqual(code, 0)
        with open(out, encoding="utf-8") as f:
            self.assertIn("~ x: 1 -> 2", f.read())


def pick_readings(kind, texts, picks=None, moves=None):
    """The readings inside the tries of a pick kind: the field after each pick (p<i>, by default the try before's text
    with `the ` in front of the text after the cursor) and for pickmove the caret after each move (away<i>, back<i>,
    by default 0 and the end of the pick). `picks`/`moves` replace them; None entries leave a reading out."""
    if kind not in checks.PERIOD_PICK:
        return ""
    after = checks.PERIOD_AFTER.get(kind, "")
    if picks is None:
        picks = [t[:len(t) - len(after)] + "the " + after for t in texts[:-1]]
    out = "".join(f' p{i}="{p}"' for i, p in enumerate(picks, 1) if p is not None)
    if kind in checks.PERIOD_MOVES:
        if moves is None:
            moves = [("0", str(len(p) - len(after))) for p in picks]
        for i, (away, back) in enumerate(moves, 1):
            out += f' away{i}="{away}" back{i}="{back}"'
    return out


def period(check_id, texts, extra="", picks=None, moves=None):
    """One dsp-* PENDING line as UITests/PhoneChecksUITests.swift writes it, resolved through assemble()."""
    kind = check_id.split("-", 2)[2]
    readings = " ".join(f't{i}="{t}"' for i, t in enumerate(texts)) + pick_readings(kind, texts, picks, moves)
    line = f"CHECK {check_id} PENDING kind={kind} tries={len(texts) - 1} {readings}{extra}\n"
    return {c.id: c for c in checks.assemble(line, "", "", ran=checks.covered_ids([PERIOD_METHOD]))}[check_id]


PERIOD_METHOD = "PhoneChecksUITests/test5f_period"


class PeriodTests(unittest.TestCase):
    """fix/double-space-period (docs/research/2026-11-17-keyboard-diagnosis.md, P4): two space taps after a word give
    ". ", also with a word right after the cursor (case D: `hello| world`)."""

    WORD = ["world"] + ["hello. " * i + "world" for i in range(1, 7)]
    # The caret before the first try: the UITextView's `location,length`, the web composer's offset.
    UIKIT_SEL = ' sel0="0,0"'
    WEB_SEL = ' sel0="0"'

    def test_every_id_is_expected_has_a_method_and_a_rule(self):
        kinds = ("en", "word", "ko", "pick2", "pick1", "fast", "kofast", "kopick2", "pickmid", "pickmove")
        ids = [f"dsp-{f}-{k}" for f in ("uikit", "composer") for k in kinds]
        self.assertEqual(checks.METHOD_IDS["test5f_period"], ids)
        for i in ids:
            self.assertIn(i, checks.EXPECTED_IDS)
            self.assertIn(i, checks.RESOLVERS)
        self.assertTrue(checks.known_entry(PERIOD_METHOD))

    def test_the_ui_test_runs_the_same_kinds_with_enough_tries(self):
        # PhoneRun.periodCases is the other half of PERIOD_IDS: a kind missing there is a FAIL `no CHECK line` in CI.
        with open(os.path.join(HERE, "UITests", "PhoneChecksUITests.swift"), encoding="utf-8") as f:
            swift = f.read()
        block = swift[swift.index("static let periodCases"):]
        cases = re.findall(r'\("(\w+)", (\d+)\)', block[:block.index("]\n")])
        self.assertEqual([k for k, _ in cases], list(checks.PERIOD_KINDS))
        for kind, tries in cases:
            self.assertIn(kind, checks.PERIOD_UNIT)
            self.assertGreaterEqual(int(tries), checks.PERIOD_MIN_TRIES.get(kind, checks.PERIOD_DEFAULT_TRIES), kind)

    def test_a_filtered_period_run_marks_the_other_ids_not_run(self):
        ran = checks.covered_ids(["PhoneChecksUITests/test0_access", PERIOD_METHOD])
        final = {c.id: c for c in checks.assemble("", "", "", ran=ran)}
        self.assertEqual(final["pad-1"].status, checks.NOT_RUN)
        self.assertEqual(final["dsp-composer-word"].status, "FAIL")
        self.assertIn("no CHECK line", final["dsp-composer-word"].evidence)

    def test_a_full_run_marks_the_period_ids_not_run(self):
        # test5f_period skips itself outside a filtered run (MAIN_TEST_DEADLINE): its IDs are NOT-RUN, not FAIL.
        final = {c.id: c for c in checks.assemble(every_id_but(*checks.PERIOD_IDS), "", "")}
        for i in checks.PERIOD_IDS:
            self.assertEqual(final[i].status, checks.NOT_RUN, i)
            self.assertIn("runs only in a filtered run (deadline)", final[i].evidence)
        self.assertFalse(any(c.status == "FAIL" for c in final.values()))

    def test_a_full_run_still_fails_the_other_missing_ids(self):
        final = {c.id: c for c in checks.assemble(every_id_but("ws-2", *checks.PERIOD_IDS), "", "")}
        self.assertEqual(final["ws-2"].status, "FAIL")
        self.assertEqual(final["dsp-uikit-en"].status, checks.NOT_RUN)

    def test_a_full_run_still_judges_the_period_lines_it_has(self):
        line = ('CHECK dsp-uikit-en PENDING kind=en tries=3 t0="" t1="hello  " t2="hello  hello  " '
                't3="hello  hello  hello  "\n')
        final ={c.id: c for c in checks.assemble(every_id_but(*checks.PERIOD_IDS) + line, "", "")}
        self.assertEqual(final["dsp-uikit-en"].status, "FAIL")
        self.assertEqual(final["dsp-composer-en"].status, checks.NOT_RUN)

    def test_main_without_a_filter_counts_the_period_ids_not_run(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "checks.txt"), "w", encoding="utf-8") as f:
                f.write(every_id_but(*checks.PERIOD_IDS))
            out = subprocess.run([sys.executable, os.path.join(HERE, "checks.py"), d], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stdout)
            self.assertTrue(out.stdout.splitlines()[-1].endswith(f" not-run {len(checks.PERIOD_IDS)}"), out.stdout)

    def test_word_after_the_cursor_gets_the_period(self):
        for check_id, sel in [("dsp-uikit-word", self.UIKIT_SEL), ("dsp-composer-word", self.WEB_SEL)]:
            c = period(check_id, self.WORD, sel)
            self.assertEqual(c.status, "PASS", c.evidence)
            self.assertIn("6/6", c.evidence)

    def test_two_spaces_before_the_word_fail(self):
        # Protly before the fix (report run 125 pr-word): KeyboardKit's endSentence left both spaces.
        c = period("dsp-composer-word", ["world", "hello  world"] + self.WORD[2:], self.WEB_SEL)
        self.assertEqual(c.status, "FAIL")
        self.assertNotIn("unreadable", c.evidence)
        self.assertIn("try 1", c.evidence)

    def test_a_lost_space_before_the_word_fails(self):
        c = period("dsp-uikit-word", ["world", "hello.world", "hello.hello. world"] + self.WORD[3:], self.UIKIT_SEL)
        self.assertEqual(c.status, "FAIL")
        self.assertNotIn("unreadable", c.evidence)

    def test_a_caret_that_is_not_at_the_word_start_is_unreadable(self):
        for check_id, sel in [("dsp-composer-word", ' sel0="5"'), ("dsp-composer-word", ' sel0="-1"'),
                              ("dsp-composer-word", ""), ("dsp-composer-word", " sel0=<unreadable>"),
                              ("dsp-uikit-word", ' sel0="5,0"')]:
            c = period(check_id, self.WORD, sel)
            self.assertEqual(c.status, "FAIL", f"{check_id}{sel}")
            self.assertIn("unreadable", c.evidence)
            self.assertIn("caret not at word start", c.evidence)

    def test_word_needs_six_tries(self):
        c = period("dsp-uikit-word", self.WORD[:6], self.UIKIT_SEL)
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)
        self.assertIn("at least 6", c.evidence)

    def test_a_setup_that_did_not_type_the_word_is_unreadable(self):
        c = period("dsp-uikit-word", ["wrld"] + self.WORD[1:], self.UIKIT_SEL)
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_a_missing_reading_is_unreadable(self):
        line = 'CHECK dsp-uikit-en PENDING kind=en tries=3 t0="" t1="hello. " t3="hello. hello. hello. "\n'
        c = {c.id: c for c in checks.assemble(line, "", "")}["dsp-uikit-en"]
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_end_of_text_kinds(self):
        for check_id, unit in [("dsp-uikit-en", "hello. "), ("dsp-composer-en", "hello. "),
                               ("dsp-uikit-ko", "안녕. "), ("dsp-composer-ko", "안녕. "),
                               ("dsp-uikit-pick2", "the. "), ("dsp-composer-pick2", "the. ")]:
            c = period(check_id, [unit * i for i in range(4)])
            self.assertEqual(c.status, "PASS", f"{check_id}: {c.evidence}")

    def test_end_of_text_needs_three_tries(self):
        c = period("dsp-uikit-en", ["", "hello. ", "hello. hello. "])
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)

    def test_nfd_hangul_counts(self):
        nfd = [unicodedata.normalize("NFD", "안녕. " * i) for i in range(4)]
        self.assertEqual(period("dsp-composer-ko", nfd).status, "PASS")

    def test_end_of_text_without_the_period_fails(self):
        c = period("dsp-composer-en", ["", "hello. ", "hello. hello  ", "hello. hello  hello. "])
        self.assertEqual(c.status, "FAIL")
        self.assertIn("try 2", c.evidence)

    # K4E (report P4 case E): one tap after a pick from the bar adds nothing, as on Apple's keyboard (4/4).

    def test_one_tap_after_a_pick_adds_nothing(self):
        for check_id in ("dsp-uikit-pick1", "dsp-composer-pick1"):
            c = period(check_id, ["the " * i for i in range(5)])
            self.assertEqual(c.status, "PASS", f"{check_id}: {c.evidence}")
            self.assertIn("4/4 tries added 'the ' at the end", c.evidence)

    def test_one_tap_after_a_pick_that_types_a_second_space_fails(self):
        # Protly before K4E (report run 121 pick1, 18/18): the pick's space and the tap's.
        c = period("dsp-uikit-pick1", ["the  " * i for i in range(5)])
        self.assertEqual(c.status, "FAIL")
        self.assertNotIn("unreadable", c.evidence)
        self.assertIn("try 1", c.evidence)

    def test_one_tap_after_a_pick_never_ends_the_sentence(self):
        # From the code: a space typed less than 3 s before the pick made that one tap a period.
        c = period("dsp-composer-pick1", ["", "the ", "the the. ", "the the. the ", "the the. the the "])
        self.assertEqual(c.status, "FAIL")
        self.assertIn("try 2", c.evidence)
        self.assertNotIn("try 3", c.evidence)

    def test_one_tap_after_a_pick_needs_four_tries(self):
        c = period("dsp-uikit-pick1", ["the " * i for i in range(4)])
        self.assertEqual(c.status, "FAIL")
        self.assertIn("unreadable", c.evidence)
        self.assertIn("at least 4", c.evidence)

    def test_a_pick_reading_that_does_not_show_the_pick_is_unreadable(self):
        texts = ["the " * i for i in range(5)]
        for picks in (["the ", "the ", "the the the ", "the the the the "], [None, "the the ", "the the the ", None]):
            c = period("dsp-uikit-pick1", texts, picks=picks)
            self.assertEqual(c.status, "FAIL", picks)
            self.assertIn("unreadable", c.evidence)
            self.assertIn("the field after the pick", c.evidence)

    def test_the_pick_reading_is_named_in_the_verdict(self):
        c = period("dsp-composer-pick1", ["the " * i for i in range(5)])
        self.assertIn("the field showed the pick 'the ' before each tap", c.evidence)

    # The pick in front of a word (pickmid): one tap after it adds nothing, so `world` gets `the ` and one space.
    MID = ["world"] + ["the " * i + "world" for i in range(1, 5)]

    def test_one_tap_after_a_pick_in_front_of_a_word_adds_nothing(self):
        for check_id, sel in [("dsp-uikit-pickmid", self.UIKIT_SEL), ("dsp-composer-pickmid", self.WEB_SEL)]:
            c = period(check_id, self.MID, sel)
            self.assertEqual(c.status, "PASS", f"{check_id}: {c.evidence}")
            self.assertIn("4/4 tries added 'the ' before 'world'", c.evidence)

    def test_a_pick_in_front_of_a_word_whose_tap_types_a_second_space_fails(self):
        # The pick kept no text after the cursor (`after: ""`): the field never shows it, so the tap types.
        texts = ["world"] + ["the  " * i + "world" for i in range(1, 5)]
        c = period("dsp-uikit-pickmid", texts, self.UIKIT_SEL)
        self.assertEqual(c.status, "FAIL")
        self.assertNotIn("unreadable", c.evidence)
        self.assertIn("try 1: 'world' became 'the  world', want 'the world'", c.evidence)

    def test_a_pick_in_front_of_a_word_needs_the_caret_there_and_four_tries(self):
        c = period("dsp-uikit-pickmid", self.MID, ' sel0="5,0"')
        self.assertIn("caret not at word start", c.evidence)
        c = period("dsp-uikit-pickmid", self.MID[:4], self.UIKIT_SEL)
        self.assertIn("at least 4", c.evidence)
        c = period("dsp-composer-pickmid", ["the " * i for i in range(5)], self.WEB_SEL)
        self.assertIn("the field started as ''", c.evidence)

    # A caret moved away and back between the pick and the tap (pickmove): the tap types its space.
    MOVE = ["the  " * i for i in range(4)]

    def test_a_tap_after_the_caret_moved_types_a_space(self):
        for check_id in ("dsp-uikit-pickmove", "dsp-composer-pickmove"):
            c = period(check_id, self.MOVE)
            self.assertEqual(c.status, "PASS", f"{check_id}: {c.evidence}")
            self.assertIn("3/3 tries added 'the  ' at the end", c.evidence)

    def test_a_pick_that_outlives_a_caret_move_fails(self):
        # The host's callback for the move did not end the pick: the tap after the caret came back typed nothing.
        c = period("dsp-uikit-pickmove", ["the " * i for i in range(4)])
        self.assertEqual(c.status, "FAIL")
        self.assertNotIn("unreadable", c.evidence)
        self.assertIn("try 1: '' became 'the ', want 'the  '", c.evidence)

    def test_a_caret_that_did_not_move_is_unreadable(self):
        picks = ["the ", "the  the ", "the  the  the "]
        for moves in ([("0", "4"), ("4", "9"), ("0", "14")],  # never left
                      [("0", "4"), ("0", "0"), ("0", "14")],  # never came back
                      [("0", "4"), ("0,0", "9,0"), ("<unreadable>", "14")]):
            c = period("dsp-uikit-pickmove", self.MOVE, picks=picks, moves=moves)
            self.assertEqual(c.status, "FAIL", moves)
            self.assertIn("unreadable", c.evidence)
        c = period("dsp-uikit-pickmove", self.MOVE, picks=picks, moves=[("0,0", "4,0"), ("0,0", "9,0"), ("0,0", "14,0")])
        self.assertEqual(c.status, "PASS", c.evidence)

    def test_fast_double_taps_and_the_korean_pick_end_the_sentence(self):
        for field in ("uikit", "composer"):
            for kind, unit in [("fast", "hello. "), ("kofast", "안녕. "), ("kopick2", "안녕. ")]:
                c = period(f"dsp-{field}-{kind}", [unit * i for i in range(4)])
                self.assertEqual(c.status, "PASS", f"{field}-{kind}: {c.evidence}")

    def test_a_fast_double_tap_without_the_period_fails(self):
        c = period("dsp-uikit-fast", ["", "hello. ", "hello. hello  ", "hello. hello  hello. "])
        self.assertEqual(c.status, "FAIL")
        self.assertIn("try 2", c.evidence)

    def test_caret_posts_are_gated_to_the_period_check(self):
        # The web page posts its state on a caret move only with `?caret=1` (HostApp `-caret 1`), which only
        # test5f_period asks for: test5a_web's ret-* timings and every other web check see the page as on main.
        def read(*parts):
            with open(os.path.join(HERE, *parts), encoding="utf-8") as f:
                return f.read()
        page = read("Host", "web-composer.html")
        code = [ln.strip() for ln in page.splitlines() if not ln.strip().startswith("//")]
        self.assertIn('const caretPosts = new URLSearchParams(location.search).get("caret") === "1";', code)
        listeners = [ln for ln in code if "selectionchange" in ln]
        self.assertEqual(listeners, ['if (caretPosts) document.addEventListener("selectionchange", state);'])
        # The edit count and times (the double tap's spacing) are gated the same way.
        self.assertEqual([ln for ln in code if "caretPosts" in ln and "selectionchange" not in ln],
                         ['if (caretPosts) s.edits = { n: editCount, t: editTimes.slice() };',
                          'if (!caretPosts || name !== "composer" || e.type !== "input") return;',
                          'const caretPosts = new URLSearchParams(location.search).get("caret") === "1";'])
        self.assertEqual([ln for ln in code if "editTimes.push(" in ln], ["editTimes.push(Math.round(performance.now()));"])
        host = read("Host", "HostApp.swift")
        gate = host.index('UserDefaults.standard.string(forKey: "caret") == "1"')
        self.assertLess(gate, host.index('URLQueryItem(name: "caret", value: "1")'))
        self.assertEqual(host.count("URLQueryItem("), 1)
        users = {name: read("UITests", name).count('"-caret"') for name in os.listdir(os.path.join(HERE, "UITests"))}
        self.assertEqual({n: c for n, c in users.items() if c}, {"PhoneChecksUITests.swift": 1})
        swift = read("UITests", "PhoneChecksUITests.swift")
        period = swift[swift.index("func checksPeriod()"):]
        self.assertIn('d.launch(arguments: ["-screen", "web", "-caret", "1"])', period[:period.index("\n    }\n")])
        self.assertIn('d.launch(arguments: ["-screen", "web"])', read("UITests", "TypingChecks.swift"))

    def test_a_driver_problem_stays_fail(self):
        line = 'CHECK dsp-uikit-en FAIL unreadable: problems="no keyboard to type on" kind=en\n'
        c = {c.id: c for c in checks.assemble(line, "", "")}["dsp-uikit-en"]
        self.assertEqual(c.status, "FAIL")


HEIGHT_METHOD = "PhoneChecksUITests/test9_height"


class HeightTests(unittest.TestCase):
    """fix/keyboard-height (K2, report P2): the band above the bar on every presentation path (UITests/HeightChecks.swift)."""

    def test_every_id_is_expected_and_has_a_method(self):
        ids = ["hb-apple", "hb-launch", "hb-hide-fresh", "hb-globe", "hb-hide-globe", "hb-emoji", "hb-hide-emoji",
               "hb-switch", "hb-hide-switch", "hb-switch-hidden", "hb-kill-up", "hb-kill-hidden", "hb-card",
               "hb-cancel"]
        self.assertEqual(checks.HEIGHT_IDS, ids)
        self.assertEqual(checks.METHOD_IDS["test9_height"], ids)
        for i in ids:
            self.assertIn(i, checks.EXPECTED_IDS)
        self.assertTrue(checks.known_entry(HEIGHT_METHOD))

    def test_the_ui_test_writes_the_same_ids(self):
        with open(os.path.join(HERE, "UITests", "HeightChecks.swift"), encoding="utf-8") as f:
            swift = f.read()
        block = swift[swift.index("static let heightIDs"):]
        self.assertEqual(re.findall(r'"(hb-[\w-]+)"', block[:block.index("]")]), checks.HEIGHT_IDS)

    def test_the_ui_test_skips_itself_outside_a_filtered_run(self):
        with open(os.path.join(HERE, "UITests", "PhoneChecksUITests.swift"), encoding="utf-8") as f:
            swift = f.read()
        method = swift[swift.index("func test9_height()"):]
        method = method[:method.index("\n    }\n")]
        self.assertIn('environment["FILTERED"] == "1"', method)
        self.assertIn("XCTSkip", method)

    def test_the_test_judges_pass_and_fail_and_checks_keeps_them(self):
        lines = ('CHECK hb-hide-switch PASS shots="52.00@512.00/564.00" band=52.00..52.00 apple=52.00 wrong=0\n'
                 'CHECK hb-globe FAIL shots="69.00@495.00/564.00" band=69.00..69.00 apple=52.00 wrong=1 (not as expected)\n'
                 'CHECK hb-apple RECORD shots="52.00@509.00/561.00/english" band=52.00..52.00 apple=5/5\n')
        final = {c.id: c for c in checks.assemble(lines, "", "", ran=checks.covered_ids([HEIGHT_METHOD]))}
        self.assertEqual(final["hb-hide-switch"].status, "PASS")
        self.assertEqual(final["hb-globe"].status, "FAIL")
        self.assertEqual(final["hb-apple"].status, "RECORD")
        # Every other height ID without a line is FAIL, and the other methods' IDs are NOT-RUN.
        self.assertEqual(final["hb-switch"].status, "FAIL")
        self.assertIn("no CHECK line", final["hb-switch"].evidence)
        self.assertEqual(final["pad-1"].status, checks.NOT_RUN)

    def test_a_full_run_marks_the_height_ids_not_run(self):
        final = {c.id: c for c in checks.assemble(every_id_but(*checks.PERIOD_IDS, *checks.HEIGHT_IDS), "", "")}
        for i in checks.HEIGHT_IDS:
            self.assertEqual(final[i].status, checks.NOT_RUN, i)
            self.assertIn("runs only in a filtered run (deadline)", final[i].evidence)
        self.assertFalse(any(c.status == "FAIL" for c in final.values()))


if __name__ == "__main__":
    unittest.main()
