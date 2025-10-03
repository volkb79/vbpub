# Shim module to allow importing the script in tests (hyphen-safe)
from importlib import import_module
import importlib.util
import os

_this_dir = os.path.dirname(__file__)
_script_path = os.path.join(_this_dir, 'compose-init-up.py')

spec = importlib.util.spec_from_file_location('compose_init_up_script', _script_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# Re-export commonly used symbols for tests
for name in dir(module):
    if not name.startswith('_'):
        globals()[name] = getattr(module, name)
