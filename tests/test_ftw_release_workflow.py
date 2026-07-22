"""Release workflow ordering checks."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_stable_validation_precedes_every_release_write() -> None:
    workflow = (ROOT / ".github/workflows/ftw-drivers-release.yml").read_text()

    validation = workflow.index("name: Verify stable promotion before release writes")
    create_release = workflow.index("name: Create channel release when missing")
    upload = workflow.index("gh release upload")
    move_tag = workflow.index("gh api --method PATCH")

    assert validation < create_release < upload < move_tag
    validation_block = workflow[validation:create_release]
    assert "if: steps.channel.outputs.name == 'stable'" in validation_block
    assert "verify-stable-promotion" in validation_block
    assert "--beta-manifest" in validation_block
    assert "--previous-stable-manifest" in validation_block
    assert "--candidate-artifacts" in validation_block
