# CIU

CIU is a lightweight CLI wrapper that runs the CIU engine inside a target
repository. It discovers the repository root and executes the engine entry
point found at scripts/ciu/ciu.py.

## Usage

```bash
ciu --help
```

## Requirements

- The target repository must include scripts/ciu/ciu.py
- Python 3.11+

## Installation (local dev)

```bash
pip install -e .
```


