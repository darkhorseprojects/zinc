import copy
import tomllib

import pytest

from tools import check_dependencies


def lock():
    with (check_dependencies.ROOT / "dependencies.lock").open("rb") as source:
        return tomllib.load(source)


def test_dependency_metadata_and_repository_references_are_consistent():
    dependencies = check_dependencies.validate_lock(lock())
    check_dependencies.validate_repository(dependencies)


def test_dependency_metadata_rejects_missing_license_hash_and_revision():
    missing_license = copy.deepcopy(lock())
    del missing_license["dependency"][0]["license"]
    with pytest.raises(ValueError, match="requires license"):
        check_dependencies.validate_lock(missing_license)

    missing_hash = copy.deepcopy(lock())
    lua = next(value for value in missing_hash["dependency"] if value["name"] == "lua")
    del lua["sha256"]
    with pytest.raises(ValueError, match="requires SHA-256"):
        check_dependencies.validate_lock(missing_hash)

    missing_revision = copy.deepcopy(lock())
    model = next(
        value for value in missing_revision["dependency"] if value["name"] == "llama-nemotron-rerank-1b-v2"
    )
    del model["revision"]
    with pytest.raises(ValueError, match="version or revision"):
        check_dependencies.validate_lock(missing_revision)
