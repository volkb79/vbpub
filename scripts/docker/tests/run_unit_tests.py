import importlib.util
import sys
import traceback

import os
TEST_FILE = os.path.join(os.path.dirname(__file__), 'test_compose_init.py')

spec = importlib.util.spec_from_file_location('test_module', TEST_FILE)
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
    print('Imported test module successfully')
    # Run detected test functions
    funcs = [getattr(mod, name) for name in dir(mod) if name.startswith('test_')]
    failures = 0
    for f in funcs:
        try:
            print(f'Running {f.__name__}...')
            f()
            print('  OK')
        except Exception:
            failures += 1
            print('  FAIL')
            traceback.print_exc()
    if failures:
        print(f'FAILED: {failures} tests')
        sys.exit(2)
    else:
        print('All tests passed')
except Exception:
    print('Failed to import or run tests')
    traceback.print_exc()
    sys.exit(1)
