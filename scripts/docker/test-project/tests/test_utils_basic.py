import re
import string
import secrets
import sys
import os

here = os.path.dirname(__file__)
sys.path.insert(0, os.path.abspath(os.path.join(here, '..')))

from compose_init_up import gen_pw, expand_vars


def test_gen_pw_alnum_length():
    pw = gen_pw(32, 'ALNUM')
    assert len(pw) == 32
    assert all(c in (string.ascii_letters + string.digits) for c in pw)


def test_gen_pw_hex_length():
    pw = gen_pw(31, 'HEX')
    assert len(pw) == 31
    assert re.match(r'^[0-9a-f]+$', pw)


def test_expand_vars_command_and_env(tmp_path, monkeypatch):
    env = {'FOO': 'bar', 'HOME': '/home/test'}
    # command substitution using echo
    res = expand_vars('val-$(echo hello)-$FOO-${HOME}', env)
    assert 'hello' in res
    assert 'bar' in res
    assert '/home/test' in res
