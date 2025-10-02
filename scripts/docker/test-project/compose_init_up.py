"""Lightweight import shim for tests.

This wrapper imports the functions we need from the main script so tests
can import them as a module.
"""
import runpy
import os
import types

SCRIPT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'compose-init-up.py'))

# Execute script in a fresh module namespace under a non-__main__ name so that
# the script's `if __name__ == '__main__': main()` guard does not execute.
ns = runpy.run_path(SCRIPT, run_name='compose_init_module')

def _get(name):
    if name in ns:
        return ns[name]
    raise ImportError(f"Symbol {name} not found in compose-init-up.py")

gen_pw = _get('gen_pw')
expand_vars = _get('expand_vars')
