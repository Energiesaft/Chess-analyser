"""Smoke tests for Python code embedded in the CloudFormation template."""
from pathlib import Path
import ast
import os
import re
import textwrap

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = Path(os.environ.get("CLOUDFORMATION_TEMPLATE", REPO_ROOT / "Schachformation.yml"))


def extract_inline_lambda_sources(template_text: str) -> dict[str, str]:
    """Extract AWS::Lambda::Function Code.ZipFile blocks without resolving CFN tags."""
    lines = template_text.splitlines()
    resources: dict[str, str] = {}
    current_resource = None
    i = 0
    while i < len(lines):
        line = lines[i]
        # Resource logical IDs are top-level children of Resources and end with ':'
        match = re.match(r"^  ([A-Za-z0-9]+):\s*$", line)
        if match:
            current_resource = match.group(1)
        if current_resource and re.match(r"^\s+ZipFile:\s*\|\s*$", line):
            indent = len(line) - len(line.lstrip())
            code_lines = []
            i += 1
            while i < len(lines):
                candidate = lines[i]
                if candidate.strip() and len(candidate) - len(candidate.lstrip()) <= indent:
                    break
                code_lines.append(candidate)
                i += 1
            # YAML literal block indentation is the minimum indentation of nonblank lines.
            nonblank = [len(x) - len(x.lstrip()) for x in code_lines if x.strip()]
            if nonblank:
                block_indent = min(nonblank)
                source = "\n".join(x[block_indent:] if x.strip() else "" for x in code_lines).rstrip() + "\n"
                resources[current_resource] = source
            continue
        i += 1
    return resources


@pytest.fixture(scope="module")
def lambda_sources():
    assert TEMPLATE.exists(), f"CloudFormation template not found: {TEMPLATE}"
    return extract_inline_lambda_sources(TEMPLATE.read_text(encoding="utf-8"))


def test_inline_lambdas_exist(lambda_sources):
    assert "SchachProcessorLambda" in lambda_sources
    assert "SchachConfirmLambda" in lambda_sources
    assert len(lambda_sources) >= 3, "Expected to discover multiple inline Lambda handlers"


@pytest.mark.parametrize("logical_id", ["SchachProcessorLambda", "SchachConfirmLambda"])
def test_lambda_python_syntax(lambda_sources, logical_id):
    source = lambda_sources[logical_id]
    # compile() catches syntax errors without executing AWS calls.
    compile(source, f"{logical_id}/index.py", "exec")
    ast.parse(source)


def test_processor_parses_eml_body_not_headers(lambda_sources):
    source = lambda_sources["SchachProcessorLambda"]
    assert "BytesParser(policy=policy.default).parsebytes(content)" in source
    assert "message.get_body(preferencelist=('plain',))" in source


def test_confirm_lambda_parses_eml_body_not_headers(lambda_sources):
    source = lambda_sources["SchachConfirmLambda"]
    assert "BytesParser(" in source
    assert "preferencelist=('plain',)" in source
