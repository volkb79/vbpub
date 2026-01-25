# CIU Hook Examples

These hooks demonstrate both class-based and function-based interfaces supported by CIU.

## Files

- pre_compose_example.py: shows metadata returns with toml persistence
- post_compose_example.py: shows env-only updates

## Usage

1. Copy an example into your stack directory.
2. Reference it in your stack config under <stack_key>.hooks.pre_compose or post_compose.
3. Run CIU for that stack.

These samples are intentionally side-effect free and safe to use as templates.