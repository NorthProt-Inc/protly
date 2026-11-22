import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

# Run as `python3 -I host/test_edit.py`. Isolated mode does not add the script dir to sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import protly_edit as e  # noqa: E402

KEY = 'sk-ant-test-123'
KOREAN = '이 함수 왜 느린지 봐줘 `foo()`'
TEMP_DIRS = []


def tearDownModule():
    for d in TEMP_DIRS:
        shutil.rmtree(d, True)


def temp_dir():
    d = tempfile.mkdtemp()
    TEMP_DIRS.append(d)
    return d


def make_home(key=KEY):
    d = temp_dir()
    base = os.path.join(d, '.config', 'anthropic')
    os.makedirs(base)
    if key is not None:
        with open(os.path.join(base, 'api-key'), 'w') as f:
            f.write(key + '\n')
    return d


def make_file(text, name='claude-prompt-1234.md'):
    path = os.path.join(temp_dir(), name)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)
    return path


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


class FakeResp:
    def __init__(self, body, status=200):
        self.status, self.headers, self._body = status, {}, body

    def read(self):
        return json.dumps(self._body).encode('utf-8')

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def api_ok(translation, stop_reason='end_turn'):
    text = json.dumps({'translation': translation})
    body = {'stop_reason': stop_reason, 'content': [{'type': 'thinking', 'thinking': 'x'}, {'type': 'text', 'text': text}]}
    return mock.Mock(return_value=FakeResp(body))


def run(path, urlopen, home=None, env=None, extra=()):
    err = io.StringIO()
    execvp, pause = mock.Mock(), mock.Mock()
    code = e.run([*extra, path], home or make_home(), env or {}, err, urlopen=urlopen, execvp=execvp, pause=pause)
    return code, err.getvalue(), execvp, pause


class ShouldTranslate(unittest.TestCase):
    def test_prompt_file_with_hangul(self):
        self.assertTrue(e.should_translate('/tmp/claude-1000/claude-prompt-ab12.md', KOREAN))

    def test_jamo_only_counts_as_hangul(self):
        self.assertTrue(e.should_translate('claude-prompt-1.md', 'ok ㅋㅋ'))

    def test_prompt_file_without_hangul(self):
        self.assertFalse(e.should_translate('claude-prompt-ab12.md', 'why is foo() slow'))

    def test_other_file_with_hangul(self):
        self.assertFalse(e.should_translate('/repo/.git/COMMIT_EDITMSG', KOREAN))


class BuildRequest(unittest.TestCase):
    def test_uses_the_outgoing_profile_and_carries_the_draft(self):
        body = e.build_request(KOREAN)
        self.assertEqual(body['model'], 'claude-opus-5-5')
        self.assertEqual(body['thinking'], {'type': 'adaptive'})
        self.assertEqual(body['output_config']['effort'], 'low')
        self.assertEqual(body['output_config']['format']['schema']['required'], ['translation'])
        self.assertEqual(body['messages'], [{'role': 'user', 'content': f'DRAFT:\n{KOREAN}'}])
        json.dumps(body, allow_nan=False)


class ParseReply(unittest.TestCase):
    def reply(self, text, stop_reason='end_turn'):
        return {'status': 200, 'body': {'stop_reason': stop_reason, 'content': [{'type': 'text', 'text': text}]}}

    def test_returns_the_translation_stripped(self):
        self.assertEqual(e.parse_reply(self.reply('{"translation": " Look at foo()\\n"}')), 'Look at foo()')

    def test_truncated(self):
        with self.assertRaisesRegex(e.EditError, 'truncated'):
            e.parse_reply(self.reply('{"translation": "x"}', 'max_tokens'))

    def test_not_json(self):
        with self.assertRaisesRegex(e.EditError, 'expected JSON'):
            e.parse_reply(self.reply('Sure, here it is'))

    def test_empty_translation(self):
        with self.assertRaisesRegex(e.EditError, 'empty'):
            e.parse_reply(self.reply('{"translation": "  "}'))

    def test_api_error_names_type_and_status(self):
        r = {'status': 401, 'body': {'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}}}
        with self.assertRaisesRegex(e.EditError, r'authentication_error \(401\): invalid x-api-key'):
            e.parse_reply(r)

    def test_error_with_no_body(self):
        with self.assertRaisesRegex(e.EditError, r'error \(529\)'):
            e.parse_reply({'status': 529, 'body': {}})


class Run(unittest.TestCase):
    def test_korean_prompt_is_rewritten_in_place(self):
        path = make_file(KOREAN)
        op = api_ok('Look into why this function is slow: `foo()`')
        code, err, execvp, pause = run(path, op)
        self.assertEqual(code, 0)
        self.assertEqual(read(path), 'Look into why this function is slow: `foo()`')
        execvp.assert_not_called()
        pause.assert_not_called()
        sent = json.loads(op.call_args.args[0].data)
        self.assertIn(KOREAN, sent['messages'][0]['content'])

    def test_english_prompt_opens_the_real_editor(self):
        path = make_file('why is foo() slow')
        op = mock.Mock()
        _, _, execvp, _ = run(path, op, env={'PROTLY_EDITOR': 'code --wait'})
        execvp.assert_called_once_with('code', ['code', '--wait', path])
        op.assert_not_called()
        self.assertEqual(read(path), 'why is foo() slow')

    def test_other_file_opens_the_default_editor_with_every_argument(self):
        path = make_file(KOREAN, name='COMMIT_EDITMSG')
        op = mock.Mock()
        _, _, execvp, _ = run(path, op, extra=('+3',))
        execvp.assert_called_once_with('nano', ['nano', '+3', path])
        op.assert_not_called()

    def test_missing_file_opens_the_real_editor(self):
        path = os.path.join(temp_dir(), 'claude-prompt-new.md')
        _, _, execvp, _ = run(path, mock.Mock())
        execvp.assert_called_once_with('nano', ['nano', path])

    def test_api_error_keeps_the_draft(self):
        path = make_file(KOREAN)
        body = io.BytesIO(json.dumps({'error': {'type': 'overloaded_error', 'message': 'Overloaded'}}).encode())
        op = mock.Mock(side_effect=urllib.error.HTTPError('u', 529, 'x', {}, body))
        code, err, _, pause = run(path, op)
        self.assertEqual(code, 0)
        self.assertEqual(read(path), KOREAN)
        self.assertIn('draft kept: overloaded_error (529)', err)
        pause.assert_called_once_with(e.FAIL_PAUSE_S)

    def test_network_error_keeps_the_draft(self):
        path = make_file(KOREAN)
        op = mock.Mock(side_effect=urllib.error.URLError(TimeoutError('timed out')))
        _, err, _, _ = run(path, op)
        self.assertEqual(read(path), KOREAN)
        self.assertIn('host_timeout', err)

    def test_missing_key_keeps_the_draft_and_makes_no_request(self):
        path = make_file(KOREAN)
        op = mock.Mock()
        _, err, _, _ = run(path, op, home=make_home(key=None))
        self.assertEqual(read(path), KOREAN)
        self.assertIn('host_config', err)
        op.assert_not_called()

    def test_bad_reply_keeps_the_draft(self):
        path = make_file(KOREAN)
        _, err, _, _ = run(path, api_ok('x', stop_reason='max_tokens'))
        self.assertEqual(read(path), KOREAN)
        self.assertIn('truncated', err)

    def test_the_key_is_never_written_to_the_terminal(self):
        for op in (api_ok('ok'), mock.Mock(side_effect=urllib.error.URLError('down'))):
            _, err, _, _ = run(make_file(KOREAN), op)
            self.assertNotIn(KEY, err)

    def test_no_arguments(self):
        err = io.StringIO()
        self.assertEqual(e.run([], make_home(), {}, err), 2)
        self.assertIn('usage', err.getvalue())

    def test_default_timeout_is_passed_to_urlopen(self):
        path = make_file(KOREAN)
        with mock.patch.object(e.urllib.request, 'urlopen', api_ok('ok')) as op:
            err = io.StringIO()
            e.run([path], make_home(), {}, err, pause=mock.Mock())
        self.assertEqual(op.call_args.kwargs['timeout'], e.TIMEOUT_S)
        self.assertEqual(read(path), 'ok')


if __name__ == '__main__':
    unittest.main()
