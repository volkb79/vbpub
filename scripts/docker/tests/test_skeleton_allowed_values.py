import sys
from pathlib import Path
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compose_init_up import generate_skeleton_toml, CONFIG_VARIABLES


def test_allowed_values_present_in_toml(tmp_path):
    out = tmp_path / 'test.toml'
    generate_skeleton_toml(str(out))
    content = out.read_text(encoding='utf-8')

    # Find the control section and ensure allowed values are present as comments
    # For the two control vars we added
    allowed_start = next((v for v in CONFIG_VARIABLES if v['name']=='COMPINIT_COMPOSE_START_MODE'), None)
    allowed_reset = next((v for v in CONFIG_VARIABLES if v['name']=='COMPINIT_RESET_BEFORE_START'), None)
    assert allowed_start is not None
    assert allowed_reset is not None

    for val in allowed_start.get('allowed_values', []):
        assert val in content

    for val in allowed_reset.get('allowed_values', []):
        assert val in content
